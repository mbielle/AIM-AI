import AIMAgentKit
import AIMProcessSupport
import Darwin
import Foundation

public enum ConfinedBinaryProcessError: LocalizedError {
    case outputLimitExceeded, failed(Int32)
    public var errorDescription: String? {
        switch self {
        case .outputLimitExceeded: "The local conversion exceeded its output size limit."
        case .failed(let code): "The OS-confined local conversion failed (exit \(code))."
        }
    }
}
/// Selected input is copied before an untrusted parser starts. The parser gets
/// one private staging root, rather than the selected file's entire home folder.
public final class ConfinedProcessStaging: Sendable {
    public let root: URL
    public let home: URL
    public let input: URL?
    public init(source: URL? = nil) throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = parent.appendingPathComponent("AIM-confined-" + UUID().uuidString, isDirectory: true)
        root = directory
        home = directory.appendingPathComponent("home", isDirectory: true)
        input = source.map { _ in directory.appendingPathComponent("selected-input") }
        guard mkdir(root.path, mode_t(0o700)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if let source, let input { try FileManager.default.copyItem(at: source, to: input) }
        } catch {
            try? FileManager.default.removeItem(at: root); throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

/// Synchronous binary counterpart for existing synchronous local import APIs.
/// Callers already run them off the UI thread. No UTF-8 conversion corrupts ZIP
/// image members. Supervisor owns admission before spawn until the C worker reaps.
public enum ConfinedBinaryProcess {
    private final class Job: @unchecked Sendable {
        let control: OpaquePointer
        var stdout = Data()
        var stderr = Data()
        var exceeded = false
        let maximumOutputBytes: Int
        init(maximumOutputBytes: Int) throws {
            guard let value = aim_process_control_create() else { throw POSIXError(.ENOMEM) }
            control = value; self.maximumOutputBytes = maximumOutputBytes
        }
        deinit { aim_process_control_destroy(control) }
        func cancel() { aim_process_control_cancel(control) }
        func receive(stream: Int32, bytes: UnsafeRawPointer?, count: Int) {
            if Task.isCancelled { cancel() }
            guard let bytes, count > 0 else { return }
            if stream == 1 {
                guard stdout.count <= maximumOutputBytes - count else { exceeded = true; cancel(); return }
                stdout.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            } else if stream == 2, stderr.count + count <= 65_536 {
                stderr.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            }
        }
    }
    public static func runSynchronously(_ confined: ConfinedProcessCommand, maximumOutputBytes: Int,
        supervisor: ProcessSupervisor = .shared) throws -> Data {
        try run(confined.command, maximumOutputBytes: maximumOutputBytes,
            confinedNetworkDenied: !confined.permitsNetwork, supervisor: supervisor)
    }
    /// System diagnostics which need opaque OS IPC are refused during prepare
    /// and private mode. Their opaque lease remains held until native reap.
    public static func runOpaqueSynchronously(_ command: ProcessCommand, maximumOutputBytes: Int,
        supervisor: ProcessSupervisor = .shared) throws -> Data {
        try run(command, maximumOutputBytes: maximumOutputBytes, confinedNetworkDenied: false, supervisor: supervisor)
    }
    private static func run(_ command: ProcessCommand, maximumOutputBytes: Int,
        confinedNetworkDenied: Bool, supervisor: ProcessSupervisor) throws -> Data {
        try Task.checkCancellation()
        guard maximumOutputBytes > 0 else { throw ProcessExecutionError.invalidArgument }
        let values = [command.executable.path] + command.arguments
        guard values.allSatisfy({ !$0.contains("\0") }), command.workingDirectory?.path.contains("\0") != true,
              command.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw ProcessExecutionError.invalidArgument
        }
        let job = try Job(maximumOutputBytes: maximumOutputBytes), id = UUID()
        try supervisor.register(id: id, confinedNetworkDenied: confinedNetworkDenied) { job.cancel() }
        defer { supervisor.finish(id: id) }
        let arguments = values.map { strdup($0) } + [nil]
        let variables = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let directory = command.workingDirectory.flatMap { strdup($0.path) }
        defer {
            arguments.forEach { free($0) }; variables.forEach { free($0) }; free(directory)
        }
        guard arguments.dropLast().allSatisfy({ $0 != nil }), variables.dropLast().allSatisfy({ $0 != nil }),
              command.workingDirectory == nil || directory != nil else { throw POSIXError(.ENOMEM) }
        let seconds = command.timeout.map { max(0, Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) } ?? -1
        let result = aim_process_run(command.executable.path, arguments, variables, directory, seconds,
            0, job.control, { context, stream, bytes, count in
                guard let context else { return }
                Unmanaged<Job>.fromOpaque(context).takeUnretainedValue().receive(stream: stream, bytes: bytes, count: count)
            }, Unmanaged.passUnretained(job).toOpaque())
        if job.exceeded { throw ConfinedBinaryProcessError.outputLimitExceeded }
        if result.error_code != 0 { throw POSIXError(POSIXErrorCode(rawValue: result.error_code) ?? .EIO) }
        if result.cancelled != 0 { throw CancellationError() }
        if result.timed_out != 0 { throw ProcessExecutionError.timedOut }
        guard result.exit_code == 0 else { throw ConfinedBinaryProcessError.failed(result.exit_code) }
        return job.stdout
    }
}
