import AIMAgentKit
import AIMProcessSupport
import Darwin
import Foundation

public struct ProcessOutputSnapshot: Sendable {
    public let stdout: String
    public let stderr: String
    public let wasTruncated: Bool
}

public enum ProcessStreamEvent: Sendable {
    case output(ProcessOutputSnapshot)
    case completed(ProcessOutput)
}

public enum ProcessExecutionError: LocalizedError {
    case timedOut, invalidArgument, shuttingDown
    public var errorDescription: String? {
        switch self {
        case .timedOut: "The command exceeded its time limit and was stopped."
        case .invalidArgument: "The command contains an invalid path, argument or environment variable."
        case .shuttingDown: "AIM AI is shutting down. No new command can start."
        }
    }
}

public enum ProcessInputError: LocalizedError {
    case notRunning, invalidInput, inputBackpressure, partiallyWritten(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "This process is not accepting input. Read its final state before retrying."
        case .invalidInput: "Process input must contain 1–16,384 UTF-8 bytes."
        case .inputBackpressure: "The process input pipe is full; no bytes were accepted. Read its output or wait before retrying."
        case .partiallyWritten(let sent, let total):
            "Only \(sent) of \(total) input bytes were accepted. Inspect process output before sending the remainder; do not replay the whole input."
        }
    }
}

/// The control flag is C-atomic. Output buffers are touched exclusively by the worker.
private final class ProcessJob: @unchecked Sendable {
    let control: OpaquePointer
    var stdout = Data()
    var stderr = Data()
    var truncated = false
    private let maximumBytes = 4 * 1_024 * 1_024
    private let onOutput: (@Sendable (ProcessOutputSnapshot) -> Void)?
    private let spool: ProcessOutputSpool?
    private var lastEmission: ContinuousClock.Instant?
    private var outputChanged = false

    init(onOutput: (@Sendable (ProcessOutputSnapshot) -> Void)? = nil,
         spool: ProcessOutputSpool? = nil) throws {
        guard let control = aim_process_control_create() else { throw POSIXError(.ENOMEM) }
        self.control = control
        self.onOutput = onOutput
        self.spool = spool
    }
    deinit { aim_process_control_destroy(control) }
    func cancel() { aim_process_control_cancel(control) }
    func append(stream: Int32, bytes: UnsafeRawPointer, count: Int) {
        spool?.append(stream: stream, bytes: bytes, count: count)
        let chunk = Data(bytes: bytes, count: count)
        outputChanged = true
        if stream == 1 {
            stdout.append(chunk)
            if stdout.count > maximumBytes {
                stdout.removeFirst(stdout.count - maximumBytes); truncated = true
            }
        } else {
            stderr.append(chunk)
            if stderr.count > maximumBytes {
                stderr.removeFirst(stderr.count - maximumBytes); truncated = true
            }
        }
        publish(force: false)
    }

    func publish(force: Bool) {
        guard let onOutput, outputChanged,
              force || lastEmission == nil || lastEmission!.duration(to: .now) >= .milliseconds(50) else { return }
        outputChanged = false
        lastEmission = .now
        onOutput(.init(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), wasTruncated: truncated))
    }

    func run(_ command: ProcessCommand) throws -> ProcessOutput {
        defer { publish(force: true) }
        let inherited = command.inheritsEnvironment ? ProcessInfo.processInfo.environment : [:]
        let environment = inherited.merging(command.environment) { _, new in new }
        let values = [command.executable.path] + command.arguments
        guard values.allSatisfy({ !$0.contains("\0") }),
              command.workingDirectory?.path.contains("\0") != true,
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") })
        else { throw ProcessExecutionError.invalidArgument }
        let arguments = values.map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in arguments { free(pointer) }
            for pointer in variables { free(pointer) }
        }
        guard arguments.dropLast().allSatisfy({ $0 != nil }), variables.dropLast().allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        let directory = command.workingDirectory.flatMap { strdup($0.path) }
        defer { free(directory) }
        if command.workingDirectory != nil && directory == nil { throw POSIXError(.ENOMEM) }
        let seconds = command.timeout.map { max(0, Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) } ?? -1
        let result = aim_process_run(command.executable.path, arguments, variables, directory, seconds,
            command.acceptsStandardInput ? 1 : 0, control, { context, stream, bytes, count in
            guard let context else { return }
            let job = Unmanaged<ProcessJob>.fromOpaque(context).takeUnretainedValue()
            if stream == 0 { job.publish(force: false) }
            else if let bytes { job.append(stream: stream, bytes: bytes, count: count) }
        }, Unmanaged.passUnretained(self).toOpaque())
        if result.error_code != 0 { throw POSIXError(POSIXErrorCode(rawValue: result.error_code) ?? .EIO) }
        if result.cancelled != 0 { throw CancellationError() }
        if result.timed_out != 0 { throw ProcessExecutionError.timedOut }
        return ProcessOutput(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), exitCode: result.exit_code, wasTruncated: truncated)
    }

    func write(_ input: Data) -> (sent: Int, error: Int32) {
        var written = 0
        let code = input.withUnsafeBytes { buffer in
            aim_process_control_write(control, buffer.baseAddress, buffer.count, &written)
        }
        return (written, code)
    }

    func closeInput() -> Int32 { aim_process_control_close_input(control) }
}

public actor MacProcessRunner: ProcessRunning {
    private let supervisor: ProcessSupervisor
    private var running: [UUID: ProcessJob] = [:]
    private var writing: Set<UUID> = []
    private var stopWaiters: [(remaining: Set<UUID>, continuation: CheckedContinuation<Void, Never>)] = []
    public init(supervisor: ProcessSupervisor = .shared) { self.supervisor = supervisor }

    public func run(_ command: ProcessCommand) async throws -> ProcessOutput {
        try await perform(command, id: UUID(), onOutput: nil, spool: nil)
    }

    public func runConfined(_ command: ConfinedProcessCommand) async throws -> ProcessOutput {
        try await perform(command.command, id: UUID(), onOutput: nil, spool: nil, confinedNetworkDenied: !command.permitsNetwork)
    }
    public nonisolated func streamConfined(_ command: ConfinedProcessCommand, id: UUID = UUID(),
        spool: ProcessOutputSpool? = nil) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let result = try await self.perform(command.command, id: id,
                        onOutput: { continuation.yield(.output($0)) }, spool: spool, confinedNetworkDenied: !command.permitsNetwork)
                    continuation.yield(.completed(result)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Latest bounded snapshot wins if the consumer falls behind; final output is complete
    /// up to the same per-stream byte limit as run(). Cancellation shares its supervisor.
    public nonisolated func stream(_ command: ProcessCommand, id: UUID = UUID(),
                                   spool: ProcessOutputSpool? = nil) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let result = try await self.perform(command, id: id,
                        onOutput: { continuation.yield(.output($0)) }, spool: spool)
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ input: String, to id: UUID) async throws -> Int {
        let bytes = Data(input.utf8)
        guard !bytes.isEmpty, bytes.count <= 16_384, !input.contains("\0") else {
            throw ProcessInputError.invalidInput
        }
        guard writing.insert(id).inserted else { throw ProcessInputError.notRunning }
        defer { writing.remove(id) }
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let job = running[id] {
                let outcome = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: job.write(bytes))
                    }
                }
                if outcome.error == 0 { return outcome.sent }
                if outcome.sent > 0 { throw ProcessInputError.partiallyWritten(outcome.sent, bytes.count) }
                if outcome.error == EAGAIN || outcome.error == EWOULDBLOCK {
                    throw ProcessInputError.inputBackpressure
                }
                if outcome.error != ENOTCONN { throw ProcessInputError.notRunning }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProcessInputError.notRunning
    }

    public func closeInput(to id: UUID) async throws {
        guard writing.insert(id).inserted else { throw ProcessInputError.notRunning }
        defer { writing.remove(id) }
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let job = running[id] {
                let code = job.closeInput()
                if code == 0 { return }
                if code != ENOTCONN { throw ProcessInputError.notRunning }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProcessInputError.notRunning
    }

    private func perform(_ command: ProcessCommand, id: UUID,
                         onOutput: (@Sendable (ProcessOutputSnapshot) -> Void)?,
                         spool: ProcessOutputSpool?, confinedNetworkDenied: Bool = false) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let job = try ProcessJob(onOutput: onOutput, spool: spool)
        try supervisor.register(id: id, confinedNetworkDenied: confinedNetworkDenied) { job.cancel() }
        running[id] = job
        defer { finish(id) }
        let output: ProcessOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try job.run(command) })
                }
            }
        } onCancel: { job.cancel() }
        try Task.checkCancellation()
        return output
    }

    /// Waits for teardown of every command that was active when called.
    public func terminateAll() async {
        let ids = Set(running.keys)
        guard !ids.isEmpty else { return }
        for job in running.values { job.cancel() }
        await withCheckedContinuation { stopWaiters.append((ids, $0)) }
    }

    private func finish(_ id: UUID) {
        running.removeValue(forKey: id)
        supervisor.finish(id: id)
        for index in stopWaiters.indices.reversed() {
            stopWaiters[index].remaining.remove(id)
            if stopWaiters[index].remaining.isEmpty {
                stopWaiters.remove(at: index).continuation.resume()
            }
        }
    }
}
