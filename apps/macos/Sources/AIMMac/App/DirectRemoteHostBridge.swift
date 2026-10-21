import AIMAgentRuntime
import AIMCore
import AIMMacPlatform
import Foundation

/// Direct access is a paired-device authority over one local profile. It must
/// never inherit the account currently displayed by a later sign-in.
final class MacDirectRemoteHostBridge: DirectRemoteRequestHandling, DirectRemoteRevocationHandling, @unchecked Sendable {
    private weak var model: AppModel?
    private let profileID: UUID
    private let bridge: RemoteHostBridge
    private let runtime: DirectRemoteRuntimeBridge
    private let vault: DirectRemoteAttachmentVault
    private let grants = DirectRemoteGrantRegistry()
    #if DEBUG
    private let qaTrace = AIMQAContext.current.map { AIMQATraceRecorder(context: $0, role: .mac) }
    #endif
    init(model: AppModel, profileID: UUID, transferDirectory: URL) throws {
        self.model = model; self.profileID = profileID
        bridge = RemoteHostBridge(model: model, contextIsCurrent: { [weak model] in
            model?.account.identity?.isLocal == true && model?.account.identity?.storageID == profileID
                && DirectRemoteGrantContext.current?.isActive == true && !AIMNetworkPrivacyPolicy.isEnabled
        })
        runtime = DirectRemoteRuntimeBridge(model: model, profileID: profileID)
        vault = try DirectRemoteAttachmentVault(directory: transferDirectory)
    }
    private func verify(_ pair: DirectRemotePair, permission: DirectRemotePermission) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard DirectRemoteGrantContext.current?.isActive == true else { throw DirectRemoteError.revoked }
        let identity = await MainActor.run { self.model?.account.identity }
        guard DirectRemoteGrantContext.current?.isActive == true else { throw DirectRemoteError.revoked }
        try MacDirectAccessRules.authorize(pair: pair, expectedProfileID: profileID, currentIdentity: identity, permission: permission)
        try AIMNetworkPrivacyPolicy.requireNetwork()
    }
    func execute(operation: String, payload: RemoteJSONValue, commandID: UUID, pair: DirectRemotePair) async throws -> RemoteJSONValue {
        #if DEBUG
        await qaTrace?.record(commandID: commandID, operation: operation, phase: "received")
        #endif
        let grant = try await grants.grant(for: pair.id, revision: pair.revision)
        do {
            let result = try await DirectRemoteGrantContext.$current.withValue(grant) {
                try await executeGranted(operation: operation, payload: payload, commandID: commandID, pair: pair)
            }
            #if DEBUG
            await qaTrace?.record(commandID: commandID, operation: operation, phase: "response")
            #endif
            return result
        } catch {
            #if DEBUG
            await qaTrace?.record(commandID: commandID, operation: operation, phase: "refused-or-error")
            #endif
            throw error
        }
    }
    private func executeGranted(operation: String, payload: RemoteJSONValue, commandID: UUID, pair: DirectRemotePair) async throws -> RemoteJSONValue {
        try await verify(pair, permission: .read)
        guard let object = payload.objectValue else { throw DirectRemoteError.invalidPacket }
        if let target = object["machine_id"]?.stringValue,
           UUID(uuidString: target) != pair.host.id { throw DirectRemoteError.unauthorized }
        switch operation {
        case "health": return .object(["authenticated": .bool(true), "machine_id": .string(pair.host.id.uuidString.lowercased())])
        case "overview":
            let capabilities = await bridge.remoteCapabilities()
            var features = capabilities.features
            // Direct file transfer and arbitrary terminal/preview are separate
            // contracts. Do not advertise them just because the cloud has them.
            features["goal"] = false
            features["attachments"] = true; features["attachmentsAtCreation"] = true
            let runtimeReady = await runtime.isAvailable()
            features[RemoteCapabilities.Feature.history] = runtimeReady
            features[RemoteCapabilities.Feature.sessionManagement] = runtimeReady && pair.permissions.contains(.control)
            features[RemoteCapabilities.Feature.agentTerminal] = runtimeReady && pair.permissions.contains(.terminal)
            features["terminal"] = features[RemoteCapabilities.Feature.agentTerminal]
            features["code_terminal"] = features[RemoteCapabilities.Feature.agentTerminal]
            features[RemoteCapabilities.Feature.agentDiff] = runtimeReady
            features[RemoteCapabilities.Feature.structuredDiff] = runtimeReady
            features["diff"] = runtimeReady
            features[RemoteCapabilities.Feature.agentBrowser] = runtimeReady && pair.permissions.contains(.control)
            features["browser"] = features[RemoteCapabilities.Feature.agentBrowser]
            let snapshots = await bridge.remoteSnapshots()
            try await verify(pair, permission: .read)
            let overview = DirectRemoteOverviewSnapshot(machineID: pair.host.id, name: pair.host.name,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                capabilities: .init(version: capabilities.version, models: capabilities.models, engines: capabilities.engines, features: features),
                sessions: snapshots.compactMap { item in
                    guard let mode = RemoteMode(rawValue: item.mode), pair.permissions.contains(Self.permission(mode)) else { return nil }
                    return .init(id: item.id, mode: mode, title: item.title, workspace: item.workspace,
                        modelID: item.modelID, approvalMode: item.approvalMode, status: item.status,
                        messageCount: item.messages.count, updatedAt: item.updatedAt, agentSystem: item.agentSystem,
                        phase: item.phase, isSilent: item.silence, isInterrupted: item.interrupted,
                        pendingApproval: item.pendingApproval, runStartedAt: item.runStartedAt,
                        archivedAt: item.archivedAt, executionDeviceIDs: item.executionDeviceIDs,
                        latestResponseVersion: item.latestResponseVersion)
                })
            return try DirectRemoteSnapshotCodec.value(overview)
        case "messages":
            let session = try await session(object, pair: pair)
            let messages = session.messages.compactMap { message -> DirectRemoteMessageSnapshot? in
                guard let role = RemoteMessageRole(rawValue: message.role) else { return nil }
                return .init(id: message.id, sequence: message.sequence, role: role, content: message.content,
                    reasoning: message.reasoning, timeline: message.timeline?.arrayValue,
                    toolCalls: message.toolCalls?.arrayValue ?? [], model: message.model, runStats: message.runStats)
            }
            try await verify(pair, permission: .read)
            return try DirectRemoteSnapshotCodec.value(messages)
        case "folders":
            try await verify(pair, permission: .code)
            let listing = try RemoteHostFolders.list(object["path"]?.stringValue)
            return .object(["folders": listing.objectValue?["roots"] ?? listing.objectValue?["entries"] ?? .array([]),
                "currentPath": object["path"] ?? .null, "projectsDirectory": listing.objectValue?["projectsDir"] ?? .null])
        case "createFolder":
            try await verify(pair, permission: .code)
            return try RemoteHostFolders.create(parent: object["parent"]?.stringValue, name: object["name"]?.stringValue)
        case "upload":
            _ = try await session(object, pair: pair)
            guard let id = object["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw DirectRemoteError.invalidPacket }
            return try await vault.upload(object, pairID: pair.id, sessionID: id)
        case "createSession":
            guard let mode = object["mode"]?.stringValue.flatMap(RemoteMode.init(rawValue:)),
                  object["attachments"] == nil, object["goal"] == nil else { throw DirectRemoteError.invalidPacket }
            try await verify(pair, permission: Self.permission(mode))
            try MacDirectAccessRules.authorizeApprovalMode(object["approval_mode"]?.stringValue, pair: pair)
            // Admission may create a conversation before its first provider call.
            await grants.track(commandID.uuidString.lowercased(), pairID: pair.id)
            return try await bridge.remoteExecute(commandID: commandID.uuidString.lowercased(), type: "create_session",
                sessionID: nil, payload: payload, attachments: []) ?? .null
        case "command":
            guard let type = object["type"]?.stringValue, let body = object["payload"] else { throw DirectRemoteError.invalidPacket }
            switch type {
            case "get_mac_settings", "set_mac_settings", "set_model_added":
                try await verify(pair, permission: .settings)
            case "request_diff", "request_detail", "request_history", "run_command", "stop_command", "start_preview", "stop_preview", "rename_session", "archive_session", "delete_session":
                _ = try await session(object, pair: pair)
                if ["run_command", "stop_command"].contains(type) { try await verify(pair, permission: .terminal) }
                if ["start_preview", "stop_preview", "rename_session", "archive_session", "delete_session"].contains(type) { try await verify(pair, permission: .control) }
                try await verify(pair, permission: .read)
                return try await runtime.execute(commandID: commandID.uuidString.lowercased(), type: type,
                    sessionID: object["session_id"]?.stringValue, payload: body, pairID: pair.id) ?? .null
            case "user_message", "resume_turn", "set_model", "set_approval_mode", "stop_generation", "approval_response":
                _ = try await session(object, pair: pair)
                if type == "approval_response" { try await verify(pair, permission: .approve) }
                if type == "set_approval_mode" {
                    try await verify(pair, permission: .control)
                    try MacDirectAccessRules.authorizeApprovalMode(body.objectValue?["mode"]?.stringValue, pair: pair)
                }
            default: throw DirectRemoteError.unavailable("unsupported_direct_command")
            }
            try await verify(pair, permission: .read)
            let files: [RemoteHostAttachment]
            if let references = body.objectValue?["attachments"] {
                guard type == "user_message", let sessionID = object["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw DirectRemoteError.invalidPacket }
                files = try await vault.attachments(references, pairID: pair.id, sessionID: sessionID)
            } else { files = [] }
            if let id = object["session_id"]?.stringValue { await grants.track(id, pairID: pair.id) }
            try await verify(pair, permission: .read)
            return try await bridge.remoteExecute(commandID: commandID.uuidString.lowercased(), type: type,
                sessionID: object["session_id"]?.stringValue, payload: body, attachments: files) ?? .null
        default: throw DirectRemoteError.unavailable("unsupported_direct_operation")
        }
    }
    func revokeAccess(pairID: UUID) async {
        let conversations = await grants.revoke(pairID)
        await cleanUp(pairID: pairID, conversations: conversations)
    }
    func suspendAccess(pairID: UUID) async {
        let conversations = await grants.suspend(pairID)
        await cleanUp(pairID: pairID, conversations: conversations)
    }
    func updatePermissions(pair: DirectRemotePair) async {
        // The revision fence must be installed before cleanup suspends. A request
        // admitted by the dispatcher before the edit may only reach us afterward.
        guard let conversations = await grants.updatePermissions(pairID: pair.id, revision: pair.revision) else { return }
        await cleanUp(pairID: pair.id, conversations: conversations)
    }
    private func cleanUp(pairID: UUID, conversations: Set<String>) async {
        await runtime.revoke(pairID: pairID); await vault.revoke(pairID: pairID)
        try? await bridge.remoteStop(commandIDs: [], conversationIDs: conversations)
    }
    private func session(_ object: [String: RemoteJSONValue], pair: DirectRemotePair) async throws -> RemoteHostSessionSnapshot {
        guard let id = object["session_id"]?.stringValue, UUID(uuidString: id) != nil,
              let session = await bridge.remoteSnapshots().first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }),
              let mode = RemoteMode(rawValue: session.mode) else { throw DirectRemoteError.unauthorized }
        try await verify(pair, permission: Self.permission(mode)); return session
    }
    private static func permission(_ mode: RemoteMode) -> DirectRemotePermission {
        switch mode { case .chat: .chat; case .code: .code; case .agent: .agent }
    }
}

/// Reuses the native resource reservations, bounded outputs, private-mode checks
/// and browser contracts. It is intentionally not the cloud multiplexer: that
/// adapter enumerates account sessions and requires a Supabase identity.
private actor DirectRemoteRuntimeBridge {
    private weak var model: AppModel?
    private let profileID: UUID
    private var bridge: RuntimeRemoteSessionBridge?
    private var sessionsByPair: [UUID: Set<UUID>] = [:]
    init(model: AppModel, profileID: UUID) { self.model = model; self.profileID = profileID }
    private func service() async throws -> RuntimeRemoteSessionBridge {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard let model else { throw DirectRemoteError.unavailable("mac_unavailable") }
        guard await MainActor.run(body: { model.account.identity?.isLocal == true && model.account.identity?.storageID == self.profileID }) else { throw DirectRemoteError.unauthorized }
        if let bridge { return bridge }
        let created = try await model.makeDirectSessionBridge(profileID: profileID, authorizeOperation: {
            guard DirectRemoteGrantContext.current?.isActive == true else { throw DirectRemoteError.revoked }
            try AIMNetworkPrivacyPolicy.requireNetwork()
        })
        bridge = created; return created
    }
    func isAvailable() async -> Bool { (try? await service()) != nil }
    func execute(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue, pairID: UUID) async throws -> RemoteJSONValue? {
        if let id = sessionID.flatMap(UUID.init(uuidString:)) { sessionsByPair[pairID, default: []].insert(id) }
        let service = try await service()
        try AIMNetworkPrivacyPolicy.requireNetwork()
        return try await service.execute(commandID: commandID, type: type, sessionID: sessionID, payload: payload)
    }
    func revoke(pairID: UUID) async {
        let ids = sessionsByPair.removeValue(forKey: pairID) ?? []
        await bridge?.stop(conversationIDs: ids)
    }
}

enum MacDirectAccessRules {
    static func authorizeApprovalMode(_ mode: String?, pair: DirectRemotePair) throws {
        guard ["auto", "smart"].contains(mode ?? "") else { return }
        guard pair.permissions.contains(.control), pair.permissions.contains(.approve) else { throw DirectRemoteError.unauthorized }
    }
    static func authorize(pair: DirectRemotePair, expectedProfileID: UUID, currentIdentity: AppIdentity?, permission: DirectRemotePermission) throws {
        guard !pair.revoked, pair.host.role == .mac, pair.client.role == .phone,
              pair.host.localProfileID == expectedProfileID, pair.permissions.contains(permission),
              case let .local(profile) = currentIdentity, profile.id == expectedProfileID else { throw DirectRemoteError.unauthorized }
    }
}

/// A suspended UI adapter must re-check its live grant when it resumes after
/// catalogue lookup, conversation selection or document import. A copied pair
/// value alone cannot fence revocation during those awaits.
final class DirectRemoteLiveGrant: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
}
private enum DirectRemoteGrantContext {
    @TaskLocal static var current: DirectRemoteLiveGrant?
}
actor DirectRemoteGrantRegistry {
    private var grants: [UUID: DirectRemoteLiveGrant] = [:]
    private var revisions: [UUID: UInt64] = [:]
    private var revoked = Set<UUID>()
    private var conversations: [UUID: Set<String>] = [:]
    func grant(for id: UUID, revision: UInt64) throws -> DirectRemoteLiveGrant {
        guard !revoked.contains(id) else { throw DirectRemoteError.revoked }
        guard revision > 0, revision >= (revisions[id] ?? 0) else { throw DirectRemoteError.unauthorized }
        if revision > (revisions[id] ?? 0) {
            grants.removeValue(forKey: id)?.revoke()
            revisions[id] = revision
        }
        if let grant = grants[id] { return grant }
        let grant = DirectRemoteLiveGrant(); grants[id] = grant; return grant
    }
    func updatePermissions(pairID id: UUID, revision: UInt64) -> Set<String>? {
        guard revision > 0, revision >= (revisions[id] ?? 0) else { return nil }
        revisions[id] = revision
        return suspend(id)
    }
    func track(_ conversation: String, pairID: UUID) { conversations[pairID, default: []].insert(conversation) }
    func suspend(_ id: UUID) -> Set<String> {
        grants.removeValue(forKey: id)?.revoke()
        return conversations.removeValue(forKey: id) ?? []
    }
    func revoke(_ id: UUID) -> Set<String> {
        revoked.insert(id); return suspend(id)
    }
}
