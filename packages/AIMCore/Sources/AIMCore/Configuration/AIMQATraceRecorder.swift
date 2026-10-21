#if DEBUG
import Foundation

/// Correlation facts only: no payloads, identities, invitations or provider keys.
public actor AIMQATraceRecorder {
    private let directory: URL
    private let runID: String
    private let role: DirectRemoteRole
    private var sequence = 0
    public init(context: AIMQAContext, role: DirectRemoteRole) {
        directory = context.directory; runID = context.runID; self.role = role
    }
    public func record(commandID: UUID, operation: String, phase: String, transport: String = "encrypted-rpc") {
        let allowed = ["health", "overview", "messages", "folders", "createFolder", "upload", "createSession", "command"]
        sequence += 1
        let event: [String: Any] = ["run_id": runID, "sequence": sequence,
            "command_id": commandID.uuidString.lowercased(), "role": role.rawValue,
            "operation": allowed.contains(operation) ? operation : "unsupported",
            "phase": phase, "transport": transport, "at": ISO8601DateFormatter().string(from: .now)]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(role.rawValue + "-rpc.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) + Data([10]))
        } catch {
            // A failed diagnostic write never changes authorization/execution.
        }
    }
}
#endif
