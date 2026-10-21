import AIMProcessSupport
import Darwin
import Foundation

public enum TerminalStreamEvent: Sendable {
    case ready
    case output(String)
    case completed(Int32)
}

public enum TerminalInputError: LocalizedError {
    case notRunning, partiallyWritten(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "The terminal session is not running. Start it before sending a command."
        case .partiallyWritten(let sent, let total):
            "Only \(sent) of \(total) command bytes reached the terminal. Check its output before retrying."
        }
    }
}

/// Owns one PTY, its input channel and a bounded output snapshot. All mutable
/// output state is touched by the C worker; input uses the control's mutex.
private final class TerminalJob: @unchecked Sendable {
    let control: OpaquePointer
    let onEvent: @Sendable (TerminalStreamEvent) -> Void
    private var output = Data()
    private var outputChanged = false
    private var lastEmission: ContinuousClock.Instant?

    init(onEvent: @escaping @Sendable (TerminalStreamEvent) -> Void) throws {
        guard let control = aim_terminal_control_create() else { throw POSIXError(.ENOMEM) }
        self.control = control
        self.onEvent = onEvent
    }

    deinit { aim_terminal_control_destroy(control) }
    func cancel() { aim_terminal_control_cancel(control) }

    func run(workspace: String) throws -> Int32 {
        defer { publish(force: true) }
        let path = "/bin/zsh"
        // Interactive prompts and persistent shell state, but no independent
        // job-control groups: cancellation must tear down the entire group.
        let values = [path, "-f", "-i", "-o", "no_zle", "-o", "nomonitor"]
        let arguments = values.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "0"
        environment["HISTFILE"] = "/dev/null"
        environment["SAVEHIST"] = "0"
        environment["HISTSIZE"] = "0"
        // Finder-launched apps often lack Homebrew's PATH. Keep the inherited
        // order, then add common Apple Silicon/macOS tool locations if present.
        var pathEntries = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        if pathEntries.isEmpty { pathEntries = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        for location in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        where FileManager.default.fileExists(atPath: location) && !pathEntries.contains(location) {
            pathEntries.append(location)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in arguments { free(pointer) }
            for pointer in variables { free(pointer) }
        }
        guard arguments.dropLast().allSatisfy({ $0 != nil }),
              variables.dropLast().allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        let result = aim_terminal_run(path, arguments, variables, workspace, control,
                                      { context, stream, bytes, count in
            guard let context else { return }
            let job = Unmanaged<TerminalJob>.fromOpaque(context).takeUnretainedValue()
            if stream == 0 { job.onEvent(.ready) }
            else if stream == 1, let bytes { job.append(bytes: bytes, count: count) }
            else if stream == 2 { job.publish(force: false) }
        }, Unmanaged.passUnretained(self).toOpaque())
        if result.error_code != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: result.error_code) ?? .EIO)
        }
        if result.cancelled != 0 { throw CancellationError() }
        return result.exit_code
    }

    func write(_ input: String) throws {
        let bytes = Data(input.utf8)
        var written = 0
        let code = bytes.withUnsafeBytes { buffer in
            aim_terminal_control_write(control, buffer.baseAddress, buffer.count, &written)
        }
        if code != 0 {
            if written > 0 { throw TerminalInputError.partiallyWritten(written, bytes.count) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func append(bytes: UnsafeRawPointer, count: Int) {
        output.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        if output.count > 128_000 { output.removeFirst(output.count - 128_000) }
        outputChanged = true
        publish(force: false)
    }

    private func publish(force: Bool) {
        guard outputChanged,
              force || lastEmission == nil || lastEmission!.duration(to: .now) >= .milliseconds(50) else { return }
        outputChanged = false
        lastEmission = .now
        onEvent(.output(String(decoding: output, as: UTF8.self)))
    }
}

/// A foreground-only interactive shell. The one-shot MacProcessRunner remains
/// the separately approved execution route for agent tools.
public actor MacPTYTerminal {
    private let supervisor: ProcessSupervisor
    private var active: (id: UUID, job: TerminalJob)?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(supervisor: ProcessSupervisor = .shared) { self.supervisor = supervisor }

    public nonisolated func stream(workspace: String) -> AsyncThrowingStream<TerminalStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                do {
                    let exitCode = try await self.perform(workspace: workspace) { continuation.yield($0) }
                    continuation.yield(.completed(exitCode))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ input: String) async throws {
        try Task.checkCancellation()
        guard let job = active?.job else { throw TerminalInputError.notRunning }
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try job.write(input) })
            }
        }
        try Task.checkCancellation()
    }

    public func terminateAll() async {
        guard let active else { return }
        active.job.cancel()
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    private func perform(workspace: String,
                         onEvent: @escaping @Sendable (TerminalStreamEvent) -> Void) async throws -> Int32 {
        try Task.checkCancellation()
        guard active == nil else { throw TerminalInputError.notRunning }
        let id = UUID(), job = try TerminalJob(onEvent: onEvent)
        try supervisor.register(id: id) { job.cancel() }
        active = (id, job)
        defer {
            active = nil
            supervisor.finish(id: id)
            let waiters = stopWaiters
            stopWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let result: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try job.run(workspace: workspace) })
                }
            }
        } onCancel: { job.cancel() }
        try Task.checkCancellation()
        return result
    }
}
