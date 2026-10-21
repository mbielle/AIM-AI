import AIMCore
import Foundation

extension AppIdentity {
    var displayName: String? {
        switch self {
        case .local: "Local profile"
        case let .account(user): user.fullName
        }
    }
    var accountEmail: String? { authenticatedUser?.email }
}

/// A network-free boundary. Local storage identifiers never enter Remote RPCs.
struct LocalRemoteService: RemoteServicing {
    func loadOverview() async throws -> RemoteOverview { .init(connectionState: .unpaired, machines: [], sessions: []) }
    func loadMessages(sessionID: String, machineID: String) async throws -> [RemoteMessage] { throw CloudContentError.unavailable }
    func pairDevice(code: String, name: String) async throws -> RemotePairingResult { throw CloudContentError.unavailable }
    func sendCommand(machineID: String, sessionID: String, type: RemoteCommandType, payload: RemoteJSONValue) async throws -> RemoteCommandResult { throw CloudContentError.unavailable }
    func createSession(_ request: RemoteSessionCreationRequest) async throws -> String { throw CloudContentError.unavailable }
    func loadFolders(machineID: String, path: String?) async throws -> RemoteFolderListing { throw CloudContentError.unavailable }
    func requestDiff(machineID: String, sessionID: String) async throws -> RemoteDiffResult { throw CloudContentError.unavailable }
    func runTerminalCommand(_ command: String, machineID: String, sessionID: String) async throws -> RemoteTerminalResult { throw CloudContentError.unavailable }
    func startPreview(script: String?, machineID: String, sessionID: String) async throws -> RemotePreviewResult { throw CloudContentError.unavailable }
    func stopPreview(machineID: String, sessionID: String) async throws { throw CloudContentError.unavailable }
}

/// Persistent local preferences; cloud-only mutations fail without network access.
actor LocalContentService: CloudContentServicing {
    private let storageID: UUID
    private let credentials: any SecureStoring
    init(storageID: UUID, credentials: any SecureStoring = KeychainSecureStore()) {
        self.storageID = storageID; self.credentials = credentials
    }
    private var key: String { "aim.local.content.v1." + storageID.uuidString.lowercased() }
    private struct Snapshot: Codable {
        var fullName = ""
        var preferredName = ""
        var personalPreferences = ""
        var preferences = AIMUserPreferences.defaults
        var memory = ""
        var memoryVersion = 0
        var memoryUpdatedAt: Date?
    }
    private func read() throws -> Snapshot {
        guard let data = try credentials.readData(forKey: key) else { return Snapshot() }
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }
    private func write(_ value: Snapshot) throws {
        try credentials.store(JSONEncoder().encode(value), forKey: key)
    }
    func loadProfile() async throws -> AIMUserProfile {
        let value = try read()
        return .init(fullName: value.fullName, preferredName: value.preferredName, personalPreferences: value.personalPreferences)
    }
    func saveProfile(_ profile: AIMUserProfile) async throws {
        var value = try read(); value.fullName = profile.fullName; value.preferredName = profile.preferredName
        value.personalPreferences = profile.personalPreferences; try write(value)
    }
    func loadProjects() async throws -> [AIMProject] { [] }
    func createProject(name: String, description: String?, customContext: String?) async throws -> AIMProject { throw CloudContentError.unavailable }
    func renameProject(id: String, name: String) async throws -> AIMProject { throw CloudContentError.unavailable }
    func setProjectFavorite(id: String, isFavorite: Bool) async throws -> AIMProject { throw CloudContentError.unavailable }
    func archiveProject(id: String) async throws { throw CloudContentError.unavailable }
    func deleteProject(id: String) async throws { throw CloudContentError.unavailable }
    func loadProjectConversations(projectID: String) async throws -> [AIMProjectConversation] { [] }
    func loadProjectFiles(projectID: String) async throws -> [AIMProjectFile] { [] }
    func uploadProjectFile(projectID: String, data: Data, name: String, mimeType: String) async throws -> AIMProjectFile { throw CloudContentError.unavailable }
    func deleteProjectFile(projectID: String, fileID: String) async throws { throw CloudContentError.unavailable }
    func loadLegacyMessages(conversationID: String) async throws -> [AIMLegacyMessage] { [] }
    func loadMedia(kind: AIMMediaKind) async throws -> [AIMMediaItem] { [] }
    func deleteMedia(_ item: AIMMediaItem) async throws { throw CloudContentError.unavailable }
    func loadConnectors() async throws -> [AIMConnector] { [] }
    func setConnectorActive(id: String, isActive: Bool) async throws { throw CloudContentError.unavailable }
    func setConnectorToolPermission(id: String, toolName: String, permission: ConnectorToolPermission) async throws { throw CloudContentError.unavailable }
    func deleteConnector(id: String) async throws { throw CloudContentError.unavailable }
    func connectorAuthorizationURL(provider: AIMConnectorOAuthProvider, redirectURL: URL) async throws -> URL { throw CloudContentError.unavailable }
    func loadPreferences() async throws -> AIMUserPreferences { try read().preferences }
    func savePreferences(_ preferences: AIMUserPreferences) async throws { var value = try read(); value.preferences = preferences; try write(value) }
    func loadMemoryDocument() async throws -> AIMMemoryDocument { let value = try read(); return .init(content: value.memory, version: value.memoryVersion, updatedAt: value.memoryUpdatedAt) }
    func saveMemoryDocument(content: String, expectedVersion: Int) async throws -> AIMMemoryDocument {
        var value = try read(); guard value.memoryVersion == expectedVersion else { throw CloudContentError.unavailable }
        value.memory = content; value.memoryVersion += 1; value.memoryUpdatedAt = .now; try write(value)
        return .init(content: value.memory, version: value.memoryVersion, updatedAt: value.memoryUpdatedAt)
    }
    func exportUserData() async throws -> Data { throw CloudContentError.unavailable }
    func deleteAccount(confirmEmail: String, confirmation: String) async throws { throw CloudContentError.unavailable }
}

/// An intentionally narrow document format: portable chat content only.
/// Provider credentials, account identities, jobs, activity and machine paths
/// are not part of this schema. Imported objects always receive new owner-local IDs.
struct AIMProfileArchive: Codable, Equatable {
    var format = "aim.profile-copy"
    var version = 1
    var conversations: [NativeChatConversation]
    var projects: [NativeChatProject]
    var omittedMediaReferences = 0
    var omittedActions = 0
    static let maximumBytes = 32_000_000

    var messageCount: Int { conversations.reduce(0) { $0 + $1.messages.count } }
    var attachmentCount: Int { conversations.reduce(0) { $0 + $1.messages.reduce(0) { $0 + ($1.attachments?.count ?? 0) } } }

    static func make(conversations: [NativeChatConversation], projects: [NativeChatProject]) throws -> Self {
        let archive = Self(conversations: conversations, projects: projects,
            omittedMediaReferences: conversations.reduce(0) { $0 + $1.messages.reduce(0) { $0 + ($1.mediaAssetIDs?.count ?? 0) } },
            omittedActions: conversations.reduce(0) { $0 + $1.messages.reduce(0) { $0 + ($1.actions?.count ?? 0) } })
        return try archive.validated()
    }
    func validated() throws -> Self {
        guard format == "aim.profile-copy", version == 1,
              conversations.count <= 5000, projects.count <= 1000,
              Set(conversations.map(\.id)).count == conversations.count,
              Set(projects.map(\.id)).count == projects.count,
              projects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 && $0.instructions.count <= 16_000 }) else { throw ChatServiceError.invalidResponse }
        var result = self
        result.conversations = try conversations.map { original in
            guard original.messages.count <= 10000,
                  Set(original.messages.map(\.id)).count == original.messages.count else { throw ChatServiceError.invalidResponse }
            let messages = try original.messages.map { message -> NativeChatMessage in
                try NativeChatAttachment.validate(message.attachments ?? [])
                // Inline document text, images, prepared video frames/transcripts are portable.
                // Tool actions and generated media references have external/account-bound graphs.
                return .init(id: message.id, role: message.role, text: message.text, createdAt: message.createdAt, attachments: message.attachments)
            }
            let portable = NativeChatConversation(id: original.id, title: original.title, provider: original.provider,
                modelID: original.modelID, messages: messages, projectID: original.projectID, updatedAt: original.updatedAt)
            guard try JSONEncoder().encode(portable).count <= 16_000_000 else { throw NativeDocumentError.limit }
            return portable
        }
        guard try JSONEncoder().encode(result).count <= Self.maximumBytes else { throw NativeDocumentError.limit }
        return result
    }
    func selecting(conversationIDs: Set<UUID>, projectIDs: Set<UUID>) throws -> Self {
        var result = self
        result.conversations = conversations.filter { conversationIDs.contains($0.id) }
        result.projects = projects.filter { projectIDs.contains($0.id) }
        return try result.validated()
    }
    func copiedWithNewIDs() throws -> Self {
        var result = try validated()
        let projectIDs = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.id.uuidString.lowercased(), UUID()) })
        result.projects = result.projects.map { project in var value = project; value.id = projectIDs[project.id.uuidString.lowercased()]!; return value }
        result.conversations = result.conversations.map { conversation in
            var value = conversation
            value.id = UUID()
            value.projectID = conversation.projectID.flatMap { projectIDs[$0.lowercased()]?.uuidString }
            value.messages = conversation.messages.map { message in var copy = message; copy.id = UUID(); return copy }
            return value
        }
        return result
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw NativeDocumentError.limit }
        if let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], raw["format"] != nil {
            return try JSONDecoder().decode(Self.self, from: data).validated()
        }
        return try make(conversations: ChatImportParser.parse(data), projects: [])
    }
}
