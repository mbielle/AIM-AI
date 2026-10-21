import CryptoKit
import Foundation

/// Native snapshots use the same presentation models as the cloud adapter, but
/// never acquire a cloud account, token, mirror key or synthetic authenticated user.
public enum DirectRemoteSnapshotCodec {
    public static func value<T: Encodable>(_ value: T) throws -> RemoteJSONValue {
        try JSONDecoder().decode(RemoteJSONValue.self, from: JSONEncoder().encode(value))
    }
    public static func decode<T: Decodable>(_ type: T.Type, from value: RemoteJSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

public struct DirectRemoteSessionSnapshot: Codable, Sendable {
    public var id: String
    public var mode: RemoteMode
    public var title: String
    public var workspace: String?
    public var modelID: String?
    public var approvalMode: String?
    public var status: String
    public var messageCount: Int
    public var updatedAt: Date
    public var agentSystem: String?
    public var phase: String?
    public var isSilent: Bool
    public var isInterrupted: Bool
    public var pendingApproval: RemoteJSONValue?
    public var runStartedAt: Date?
    public var archivedAt: Date?
    public var executionDeviceIDs: [String]?
    public var latestResponseVersion: ConversationResponseVersion?

    public init(id: String, mode: RemoteMode, title: String, workspace: String? = nil,
                modelID: String? = nil, approvalMode: String? = nil, status: String,
                messageCount: Int, updatedAt: Date, agentSystem: String? = nil, phase: String? = nil,
                isSilent: Bool = false, isInterrupted: Bool = false, pendingApproval: RemoteJSONValue? = nil,
                runStartedAt: Date? = nil, archivedAt: Date? = nil, executionDeviceIDs: [String]? = nil,
                latestResponseVersion: ConversationResponseVersion? = nil) {
        self.id = id; self.mode = mode; self.title = title; self.workspace = workspace
        self.modelID = modelID; self.approvalMode = approvalMode; self.status = status
        self.messageCount = messageCount; self.updatedAt = updatedAt; self.agentSystem = agentSystem
        self.phase = phase; self.isSilent = isSilent; self.isInterrupted = isInterrupted
        self.pendingApproval = pendingApproval; self.runStartedAt = runStartedAt; self.archivedAt = archivedAt
        self.executionDeviceIDs = executionDeviceIDs; self.latestResponseVersion = latestResponseVersion
    }
    public func presentation(machineID: String) -> RemoteSession {
        .init(id: id, machineID: machineID, mode: mode, title: title, workspace: workspace,
              modelID: modelID, approvalMode: approvalMode, status: status, messageCount: messageCount,
              updatedAt: updatedAt, agentSystem: agentSystem, phase: phase, isSilent: isSilent,
              isInterrupted: isInterrupted, pendingApproval: RemotePendingApproval(json: pendingApproval),
              runStartedAt: runStartedAt, archivedAt: archivedAt, readState: .readable,
              executionDeviceIDs: executionDeviceIDs, latestResponseVersion: latestResponseVersion)
    }
}

public struct DirectRemoteOverviewSnapshot: Codable, Sendable {
    public let machineID: UUID
    public let name: String
    public let appVersion: String
    public let capabilities: RemoteCapabilities
    public let sessions: [DirectRemoteSessionSnapshot]
    public init(machineID: UUID, name: String, appVersion: String, capabilities: RemoteCapabilities,
                sessions: [DirectRemoteSessionSnapshot]) {
        self.machineID = machineID; self.name = name; self.appVersion = appVersion
        self.capabilities = capabilities; self.sessions = sessions
    }
    public func presentation() -> RemoteOverview {
        let id = machineID.uuidString.lowercased()
        return .init(connectionState: .paired, machines: [
            .init(id: id, name: name, platform: "macOS", appVersion: appVersion, lastSeenAt: Date(),
                  keyVersion: nil, capabilities: capabilities, readState: .readable)
        ], sessions: sessions.map { $0.presentation(machineID: id) })
    }
}

public struct DirectRemoteMessageSnapshot: Codable, Sendable {
    public let id: String
    public let sequence: Int
    public let role: RemoteMessageRole
    public let content: String
    public let reasoning: String?
    public let timeline: [RemoteJSONValue]?
    public let toolCalls: [RemoteJSONValue]
    public let model: String?
    public let runStats: RemoteJSONValue?
    public init(id: String, sequence: Int, role: RemoteMessageRole, content: String, reasoning: String? = nil,
                timeline: [RemoteJSONValue]? = nil, toolCalls: [RemoteJSONValue] = [], model: String? = nil,
                runStats: RemoteJSONValue? = nil) {
        self.id = id; self.sequence = sequence; self.role = role; self.content = content
        self.reasoning = reasoning; self.timeline = timeline; self.toolCalls = toolCalls
        self.model = model; self.runStats = runStats
    }
    public func presentation(sessionID: String) -> RemoteMessage {
        .init(id: id, sessionID: sessionID, sequence: sequence, role: role, content: content,
              reasoning: reasoning, timeline: timeline, toolCalls: toolCalls.compactMap(RemoteToolCall.init(json:)),
              model: model, runStats: RemoteRunStats(json: runStats), readState: .readable)
    }
}

public final class DirectRemoteClientService: RemoteServicing, Sendable {
    public typealias Transport = @Sendable () async throws -> any DirectRemoteRPCTransport
    private let transport: Transport
    private let admissions: DirectRemoteCommandAdmissions
    public init(profile: LocalProfile? = nil, store: (any SecureStoring)? = nil, transport: @escaping Transport) {
        self.transport = transport; admissions = DirectRemoteCommandAdmissions(profileID: profile?.id, store: store)
    }

    /// Only a reply on the encrypted paired session establishes direct access.
    public func isAuthenticatedDirectSession() async throws -> Bool {
        let result = try await call("health", .object([:]))
        return result.objectValue?["authenticated"]?.boolValue == true
    }
    private func call(_ operation: String, _ payload: RemoteJSONValue, id: UUID = UUID()) async throws -> RemoteJSONValue {
        try await transport().request(operation: operation, payload: payload, id: id)
    }
    public func loadOverview() async throws -> RemoteOverview {
        try DirectRemoteSnapshotCodec.decode(DirectRemoteOverviewSnapshot.self, from: await call("overview", .object([:]))).presentation()
    }
    public func loadMessages(sessionID: String, machineID: String) async throws -> [RemoteMessage] {
        let value = try await call("messages", .object(["machine_id": .string(machineID), "session_id": .string(sessionID)]))
        return try DirectRemoteSnapshotCodec.decode([DirectRemoteMessageSnapshot].self, from: value).map { $0.presentation(sessionID: sessionID) }
    }
    public func events(for sessionID: String?) async -> AsyncStream<RemoteEvent> {
        guard let rpc = try? await transport() else { return AsyncStream { $0.finish() } }
        return await rpc.subscribeEvents()
    }
    public func pairDevice(code: String, name: String) async throws -> RemotePairingResult {
        throw DirectRemoteError.unavailable("Use the direct pairing screen; Mac confirmation is required.")
    }
    public func checkBridge(machineID: String) async throws {
        let result = try await call("health", .object(["machine_id": .string(machineID)]))
        guard result.objectValue?["authenticated"]?.boolValue == true else { throw DirectRemoteError.unauthorized }
    }
    public func sendCommand(machineID: String, sessionID: String, type: RemoteCommandType, payload: RemoteJSONValue) async throws -> RemoteCommandResult {
        // The outbox may supply a stable identity. A retry must retain it rather
        // than silently admitting a second native execution after reconnect.
        let supplied = payload.objectValue?["client_request_id"]?.stringValue
        let body = RemoteJSONValue.object(["machine_id": .string(machineID), "session_id": .string(sessionID),
            "type": .string(type.rawValue), "payload": payload])
        let (result, id) = try await admitted("command", body, suppliedID: supplied)
        return .init(succeeded: true, result: result, commandID: id.uuidString.lowercased())
    }
    private func admitted(_ operation: String, _ payload: RemoteJSONValue, suppliedID: String?) async throws -> (RemoteJSONValue, UUID) {
        let key = SHA256.hash(data: Data(operation.utf8) + (try DirectRemoteCoding.encode(payload))).map { String(format: "%02x", $0) }.joined()
        let id = try await admissions.begin(key: key, suppliedID: suppliedID)
        do {
            let result = try await call(operation, payload, id: id)
            try await admissions.complete(key: key, id: id)
            return (result, id)
        } catch {
            // Only a definite refusal proves no native effect was admitted.
            // A timeout/disconnect retains its ID across reconnect and restart.
            if let direct = error as? DirectRemoteError, [.unauthorized, .revoked, .invalidPacket].contains(direct) {
                try await admissions.complete(key: key, id: id)
            }
            throw error
        }
    }
    public func createSession(_ request: RemoteSessionCreationRequest) async throws -> String {
        guard request.attachments.isEmpty, request.goal == nil else {
            throw DirectRemoteError.unavailable("Attachments and continuous goals are not supported by this direct endpoint.")
        }
        var payload: [String: RemoteJSONValue] = ["machine_id": .string(request.machineID),
            "mode": .string(request.mode.rawValue), "model_id": .string(request.modelID), "text": .string(request.text)]
        if let value = request.provider { payload["provider"] = .string(value) }
        if let value = request.workspace { payload["workspace"] = .string(value) }
        if let value = request.approvalMode { payload["approval_mode"] = .string(value) }
        if let value = request.agentSystem { payload["agent_system"] = .string(value) }
        if let value = request.effort { payload["effort"] = .string(value) }
        if let value = request.maximumSpendUSD { payload["maximum_spend_usd"] = .string(value) }
        if request.defersInitialMessage { payload["pieces_a_suivre"] = .bool(true) }
        let (result, _) = try await admitted("createSession", .object(payload), suppliedID: request.delegationID?.uuidString)
        guard let id = result.objectValue?["session_id"]?.stringValue, UUID(uuidString: id) != nil else { throw DirectRemoteError.invalidPacket }
        return id
    }
    public func loadFolders(machineID: String, path: String?) async throws -> RemoteFolderListing {
        var payload: [String: RemoteJSONValue] = ["machine_id": .string(machineID)]
        if let path { payload["path"] = .string(path) }
        let result = try await call("folders", .object(payload))
        guard let values = result.objectValue?["folders"]?.arrayValue else { throw DirectRemoteError.invalidPacket }
        return .init(folders: values.compactMap(RemoteFolder.init(json:)),
                     currentPath: result.objectValue?["currentPath"]?.stringValue,
                     projectsDirectory: result.objectValue?["projectsDirectory"]?.stringValue)
    }
    public func createFolder(machineID: String, parent: String, name: String) async throws -> RemoteFolder {
        let result = try await call("createFolder", .object(["machine_id": .string(machineID), "parent": .string(parent), "name": .string(name)]))
        guard let folder = RemoteFolder(json: result) else { throw DirectRemoteError.invalidPacket }; return folder
    }
    private func command(_ type: RemoteCommandType, machineID: String, sessionID: String, payload: RemoteJSONValue = .object([:])) async throws -> RemoteJSONValue {
        try await sendCommand(machineID: machineID, sessionID: sessionID, type: type, payload: payload).result ?? .null
    }
    public func requestDiff(machineID: String, sessionID: String) async throws -> RemoteDiffResult {
        let value = try await command(.requestDiff, machineID: machineID, sessionID: sessionID)
        guard let object = value.objectValue, let diff = object["diff"]?.stringValue else { throw DirectRemoteError.invalidPacket }
        return .init(diff: diff, base: object["base"]?.stringValue, directory: object["dir"]?.stringValue,
            files: object["files"]?.arrayValue?.compactMap { value in
                guard let row = value.objectValue, let path = row["path"]?.stringValue else { return nil }
                return RemoteChangedFile(path: path, status: row["status"]?.stringValue,
                    additions: Self.integer(row["additions"]) ?? 0, deletions: Self.integer(row["deletions"]) ?? 0)
            } ?? [])
    }
    private static func integer(_ value: RemoteJSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isFinite, number.rounded() == number,
              number >= Double(Int.min), number < Double(Int.max) else { return nil }; return Int(number)
    }
    public func runTerminalCommand(_ command: String, machineID: String, sessionID: String) async throws -> RemoteTerminalResult {
        let value = try await self.command(.runCommand, machineID: machineID, sessionID: sessionID, payload: .object(["command": .string(command)]))
        guard let row = value.objectValue, let output = row["output"]?.stringValue else { throw DirectRemoteError.invalidPacket }
        return .init(output: output, exitCode: Self.integer(row["exitCode"]), truncated: row["truncated"]?.boolValue ?? false, stopped: row["stopped"]?.boolValue ?? false)
    }
    public func stopTerminalCommand(machineID: String, sessionID: String) async throws {
        _ = try await command(.stopCommand, machineID: machineID, sessionID: sessionID)
    }
    public func startPreview(script: String?, machineID: String, sessionID: String) async throws -> RemotePreviewResult {
        var body: [String: RemoteJSONValue] = [:]; if let script { body["script"] = .string(script) }
        return .init(json: try await command(.startPreview, machineID: machineID, sessionID: sessionID, payload: .object(body)))
    }
    public func stopPreview(machineID: String, sessionID: String) async throws {
        _ = try await command(.stopPreview, machineID: machineID, sessionID: sessionID)
    }
    public func requestDetail(machineID: String, sessionID: String, detailID: String) async throws -> RemoteJSONValue {
        try await requestDetail(machineID: machineID, sessionID: sessionID, detailID: detailID, offset: 0)
    }
    public func requestDetail(machineID: String, sessionID: String, detailID: String, offset: Int) async throws -> RemoteJSONValue {
        guard (0...1_000_000).contains(offset) else { throw DirectRemoteError.invalidPacket }
        return try await command(.requestDetail, machineID: machineID, sessionID: sessionID,
            payload: .object(["detail_id": .string(detailID), "offset": .number(Double(offset))]))
    }
    public func renameSession(_ title: String, machineID: String, sessionID: String) async throws {
        _ = try await command(.renameSession, machineID: machineID, sessionID: sessionID, payload: .object(["title": .string(title)]))
    }
    public func deleteSessions(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        guard ids.count <= 100 else { throw DirectRemoteError.invalidPacket }
        let requested = try Set(ids.map { value -> UUID in
            guard let id = UUID(uuidString: value) else { throw DirectRemoteError.invalidPacket }; return id
        })
        let overview = try await loadOverview()
        let selected = overview.sessions.filter { session in UUID(uuidString: session.id).map(requested.contains) == true }
        // Never dispatch a guessed/foreign ID or a partial selection. The host
        // checks its current profile and live grant again for every deletion.
        guard selected.count == requested.count,
              selected.allSatisfy({ session in overview.machines.first(where: { $0.id == session.machineID })?.capabilities?.supports(RemoteCapabilities.Feature.sessionManagement) == true }) else {
            throw DirectRemoteError.unauthorized
        }
        for session in selected.sorted(by: { $0.id < $1.id }) {
            _ = try await command(.deleteSession, machineID: session.machineID, sessionID: session.id)
        }
    }
    public func setSessionArchived(_ archived: Bool, machineID: String, sessionID: String) async throws {
        _ = try await command(.archiveSession, machineID: machineID, sessionID: sessionID, payload: .object(["archived": .bool(archived)]))
    }
    public func loadHistory(machineID: String, sessionID: String, cursor: String?, limit: Int) async throws -> RemoteHistoryPage {
        var body: [String: RemoteJSONValue] = ["limit": .number(Double(min(100, max(1, limit))))]
        if let cursor { body["cursor"] = .string(cursor) }
        let value = try await command(.requestHistory, machineID: machineID, sessionID: sessionID, payload: .object(body))
        guard let row = value.objectValue, let values = row["messages"]?.arrayValue else { throw DirectRemoteError.invalidPacket }
        let messages = try values.map { value -> RemoteMessage in
            guard let object = value.objectValue, let id = object["id"]?.stringValue,
                  let role = object["role"]?.stringValue.flatMap(RemoteMessageRole.init(rawValue:)),
                  let sequence = Self.integer(object["seq"]), let content = object["content"]?.stringValue else { throw DirectRemoteError.invalidPacket }
            return .init(id: id, sessionID: sessionID, sequence: sequence, role: role, content: content,
                reasoning: object["reasoning"]?.stringValue, timeline: object["timeline"]?.arrayValue, readState: .readable)
        }
        return .init(messages: messages, nextCursor: row["next_cursor"]?.stringValue, hasMore: row["has_more"]?.boolValue ?? false)
    }
    /// Bounded upload RPCs avoid exposing a filesystem path or handing plaintext
    /// to a relay. The host verifies the final size/digest and binds it to the
    /// paired device and exact conversation before native import.
    public func uploadAttachment(data: Data, name: String, mimeType: String, machineID: String, sessionID: String) async throws -> RemoteAttachmentReference {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024, UUID(uuidString: sessionID) != nil,
              name.utf8.count <= 512, mimeType.utf8.count <= 256 else { throw DirectRemoteError.invalidPacket }
        let transfer = UUID().uuidString.lowercased(), digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let common: [String: RemoteJSONValue] = ["machine_id": .string(machineID), "session_id": .string(sessionID), "transfer_id": .string(transfer)]
        var begin = common; begin["phase"] = .string("begin"); begin["name"] = .string(name)
        begin["mime"] = .string(mimeType); begin["size"] = .number(Double(data.count)); begin["sha256"] = .string(digest)
        _ = try await call("upload", .object(begin))
        let size = 256 * 1024
        for offset in stride(from: 0, to: data.count, by: size) {
            try Task.checkCancellation()
            var chunk = common; chunk["phase"] = .string("chunk"); chunk["offset"] = .number(Double(offset))
            chunk["data"] = .string(data.subdata(in: offset..<min(data.count, offset + size)).base64EncodedString())
            _ = try await call("upload", .object(chunk))
        }
        var finish = common; finish["phase"] = .string("finish")
        let result = try await call("upload", .object(finish))
        guard result.objectValue?["ready"]?.boolValue == true else { throw DirectRemoteError.invalidPacket }
        return .init(transferID: transfer, name: name, mimeType: mimeType, size: data.count)
    }
}

/// Bounded receipts contain only a payload digest and operation UUID. Pending
/// uncertainty is retained in the local profile keychain, never a cloud table.
private actor DirectRemoteCommandAdmissions {
    private let storageKey: String?
    private let store: (any SecureStoring)?
    private var memory: [String: UUID] = [:]
    init(profileID: UUID?, store: (any SecureStoring)?) {
        storageKey = profileID.map { "remote-direct.command-admissions.v1." + $0.uuidString.lowercased() }
        self.store = store
    }
    private func load() throws -> [String: UUID] {
        guard let store, let storageKey else { return memory }
        guard let data = try store.readData(forKey: storageKey) else { return [:] }
        guard data.count <= 16_384 else { throw DirectRemoteError.invalidConfiguration }
        let value = try JSONDecoder().decode([String: UUID].self, from: data)
        guard value.count <= 64, value.keys.allSatisfy({ $0.count == 64 }) else { throw DirectRemoteError.invalidConfiguration }
        return value
    }
    private func save(_ entries: [String: UUID]) throws {
        if let store, let storageKey { try store.store(JSONEncoder().encode(entries), forKey: storageKey) }
        memory = entries
    }
    func begin(key: String, suppliedID: String?) throws -> UUID {
        if let suppliedID { guard let id = UUID(uuidString: suppliedID) else { throw DirectRemoteError.invalidPacket }; return id }
        var entries = try load()
        if let id = entries[key] { return id }
        guard entries.count < 64 else { throw DirectRemoteError.unavailable("pending_command_review_required") }
        let id = UUID(); entries[key] = id; try save(entries); return id
    }
    func complete(key: String, id: UUID) throws {
        var entries = try load(); guard entries[key] == id else { return }
        entries.removeValue(forKey: key); try save(entries)
    }
}
