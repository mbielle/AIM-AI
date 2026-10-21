import CryptoKit
import Foundation

public protocol DirectRemoteRevocationHandling: Sendable {
    /// Stop pair-owned interactive control surfaces; disconnect alone does not cancel native jobs.
    func revokeAccess(pairID: UUID) async
    func suspendAccess(pairID: UUID) async
    func updatePermissions(pair: DirectRemotePair) async
}
public extension DirectRemoteRevocationHandling {
    func suspendAccess(pairID: UUID) async { await revokeAccess(pairID: pairID) }
    func updatePermissions(pair: DirectRemotePair) async { await suspendAccess(pairID: pair.id) }
}
private struct DirectRemoteJournalEntry: Codable, Sendable {
    enum State: String, Codable { case started, completed, failed }
    let id: UUID
    let pairID: UUID
    let permissionRevision: UInt64?
    let digest: Data
    var state: State
    var result: RemoteJSONValue?
    let createdAt: Date
}
/// Durable admission for direct commands. A process dying after admission never
/// retries a possibly performed effect automatically; its outcome remains unknown.
/// Read-only snapshots are live, enabling recovery of a running native job.
public actor DirectRemoteHostDispatcher: DirectRemoteRequestHandling, DirectRemoteRevocationHandling {
    private let identity: DirectRemoteIdentity
    private let host: DirectRemotePairingHost
    private let endpoint: any DirectRemoteRequestHandling
    private let directory: URL
    private var active: [UUID: Task<RemoteJSONValue, any Error>] = [:]
    public init(identity: DirectRemoteIdentity, pairingHost: DirectRemotePairingHost,
                endpoint: any DirectRemoteRequestHandling, journalDirectory: URL) throws {
        guard identity.publicIdentity.role == .mac, journalDirectory.isFileURL else { throw DirectRemoteError.invalidConfiguration }
        self.identity = identity; host = pairingHost; self.endpoint = endpoint
        directory = journalDirectory.appendingPathComponent(identity.publicIdentity.localProfileID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DirectRemoteError.invalidConfiguration }
    }
    public func execute(operation: String, payload: RemoteJSONValue, commandID: UUID, pair: DirectRemotePair) async throws -> RemoteJSONValue {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let current = try await host.pair(pair.id)
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard current == pair, current.host == identity.publicIdentity, pair.permissions.contains(.read) else { throw DirectRemoteError.unauthorized }
        guard operation.utf8.count <= 64, try DirectRemoteCoding.encode(payload).count <= 4194304 else { throw DirectRemoteError.invalidPacket }
        // The downstream native endpoint checks command-specific permissions,
        // profile ownership, approval modes and provider budgets again.
        if ["health", "overview", "messages", "folders", "history", "attachments"].contains(operation) {
            return try await endpoint.execute(operation: operation, payload: payload, commandID: commandID, pair: current)
        }
        guard ["command", "createSession", "createFolder", "upload", "rename", "archive", "pin", "project", "deleteSessions"].contains(operation) else { throw DirectRemoteError.unauthorized }
        let digest = Data(SHA256.hash(data: Data((operation + "/" + pair.id.uuidString).utf8) + (try DirectRemoteCoding.encode(payload))))
        if let entry = try load(commandID) {
            guard entry.pairID == pair.id, entry.digest == digest else { throw DirectRemoteError.conflictingCommand }
            // A downgrade must not disclose a cached terminal/settings response
            // admitted under old rights. Retain the command ID without replaying
            // its effect; read-only task snapshots remain available separately.
            guard entry.permissionRevision == current.revision else { throw DirectRemoteError.unauthorized }
            if let task = active[commandID] { return try await task.value }
            switch entry.state {
            case .completed: return entry.result ?? .null
            case .failed: throw DirectRemoteError.unavailable("previous_command_failed")
            case .started: throw DirectRemoteError.outcomeUnknown
            }
        }
        let entry = DirectRemoteJournalEntry(id: commandID, pairID: pair.id, permissionRevision: current.revision, digest: digest, state: .started, result: nil, createdAt: .now)
        try save(entry) // Admission is durable before the native side effect starts.
        let endpoint = self.endpoint
        let task = Task { try await endpoint.execute(operation: operation, payload: payload, commandID: commandID, pair: current) }
        active[commandID] = task
        do {
            let result = try await task.value
            guard try DirectRemoteCoding.encode(result).count <= 4194304 else { throw DirectRemoteError.unavailable("command_result_too_large") }
            var completed = entry; completed.state = .completed; completed.result = result; try save(completed)
            active[commandID] = nil; return result
        } catch {
            // A storage failure after the effect is deliberately left 'started',
            // so recovery cannot silently perform the effect twice.
            active[commandID] = nil; throw error
        }
    }
    public func updatePermissions(pair: DirectRemotePair) async {
        await (endpoint as? any DirectRemoteRevocationHandling)?.updatePermissions(pair: pair)
    }
    public func suspendAccess(pairID: UUID) async {
        await (endpoint as? any DirectRemoteRevocationHandling)?.suspendAccess(pairID: pairID)
    }
    public func revokeAccess(pairID: UUID) async {
        await (endpoint as? any DirectRemoteRevocationHandling)?.revokeAccess(pairID: pairID)
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func load(_ id: UUID) throws -> DirectRemoteJournalEntry? {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8388608 else { throw DirectRemoteError.invalidConfiguration }
        return try JSONDecoder().decode(DirectRemoteJournalEntry.self, from: Data(contentsOf: file))
    }
    private func save(_ entry: DirectRemoteJournalEntry) throws {
        let file = url(entry.id)
        guard !((try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false) else { throw DirectRemoteError.invalidConfiguration }
        try DirectRemoteCoding.encode(entry).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
