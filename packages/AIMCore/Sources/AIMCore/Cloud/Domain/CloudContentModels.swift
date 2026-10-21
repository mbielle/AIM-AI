import Foundation

public struct AIMProject: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let customContext: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let lastActiveAt: Date
    public let isStarred: Bool

    public init(id: String, name: String, description: String? = nil, customContext: String? = nil, createdAt: Date, updatedAt: Date, lastActiveAt: Date, isStarred: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.customContext = customContext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActiveAt = lastActiveAt
        self.isStarred = isStarred
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case customContext = "custom_context"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastActiveAt = "last_active_at"
        case isStarred = "is_starred"
    }
}

public enum AIMProjectScope: String, CaseIterable, Identifiable, Sendable {
    case all, favorites, recent
    public var id: String { rawValue }
}

public enum AIMProjectRules {
    public static func filtered(
        _ projects: [AIMProject],
        scope: AIMProjectScope,
        query: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AIMProject] {
        let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter { project in
            let matchesScope = switch scope {
            case .all: true
            case .favorites: project.isStarred
            case .recent: project.updatedAt >= cutoff
            }
            return matchesScope && (
                needle.isEmpty
                    || project.name.localizedCaseInsensitiveContains(needle)
                    || project.description?.localizedCaseInsensitiveContains(needle) == true
            )
        }
        .sorted { lhs, rhs in
            if lhs.isStarred != rhs.isStarred { return lhs.isStarred }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

public struct AIMProjectConversation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let model: String?
    public let isPinned: Bool
    public let updatedAt: Date
    public init(id: String, title: String, model: String?, isPinned: Bool, updatedAt: Date) {
        self.id = id; self.title = title; self.model = model; self.isPinned = isPinned; self.updatedAt = updatedAt
    }
}

public struct AIMProjectFile: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String?
    public let sizeBytes: Int
    public let status: String
    public let errorMessage: String?
    public let createdAt: Date
    public init(id: String, name: String, mimeType: String?, sizeBytes: Int, status: String, errorMessage: String?, createdAt: Date) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.sizeBytes = sizeBytes; self.status = status; self.errorMessage = errorMessage; self.createdAt = createdAt
    }
}

public struct AIMLegacyMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let content: String
    public let reasoning: String?
    public let model: String?
    public let createdAt: Date
    public init(id: String, role: String, content: String, reasoning: String?, model: String?, createdAt: Date) {
        self.id = id; self.role = role; self.content = content; self.reasoning = reasoning; self.model = model; self.createdAt = createdAt
    }
}

public enum AIMMediaKind: String, Codable, Sendable { case image, video }

public enum ConnectorToolPermission: String, Codable, CaseIterable, Sendable {
    case alwaysAllow = "always_allow"
    case ask
    case block
}

public struct AIMConnectorTool: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public struct AIMConnector: Identifiable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let displayName: String
    public let serverURL: String
    public let isActive: Bool
    public let lastConnectedAt: Date?
    public let tools: [AIMConnectorTool]
    public let toolPermissions: [String: ConnectorToolPermission]
    public let defaultParentID: String?
    public let defaultParentName: String?
    public let createdAt: Date

    public init(id: String, type: String, displayName: String, serverURL: String, isActive: Bool, lastConnectedAt: Date?, tools: [AIMConnectorTool], toolPermissions: [String: ConnectorToolPermission], defaultParentID: String?, defaultParentName: String?, createdAt: Date) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.serverURL = serverURL
        self.isActive = isActive
        self.lastConnectedAt = lastConnectedAt
        self.tools = tools
        self.toolPermissions = toolPermissions
        self.defaultParentID = defaultParentID
        self.defaultParentName = defaultParentName
        self.createdAt = createdAt
    }

    public var productName: String {
        switch type {
        case "oauth_notion": "Notion"
        case "oauth_github": "GitHub"
        case "oauth_slack": "Slack"
        case "mcp_supabase": "Supabase"
        case "oauth_canva": "Canva"
        default: displayName
        }
    }

    public func permission(for toolName: String) -> ConnectorToolPermission {
        toolPermissions[toolName] ?? .ask
    }
}

public enum AIMTone: String, Codable, CaseIterable, Sendable {
    case userFriendly = "user-friendly"
    case professional, academic, friendly, sarcastic, neutral = "neutre"
}

public enum AIMResponseStyle: String, Codable, CaseIterable, Sendable {
    case educational, synthetic, technical
}

public enum AIMExpertise: String, Codable, CaseIterable, Sendable {
    case beginner, intermediate, advanced = "advance", expert
}

public enum AIMResponseLength: String, Codable, CaseIterable, Sendable {
    case concise
    case semiDetailed = "semi-detailed"
    case detailed
}

public struct AIMUserPreferences: Codable, Equatable, Sendable {
    public var autoModelSelection: Bool
    public var autoTitleGeneration: Bool
    public var smartContext: Bool
    public var hapticFeedback: Bool
    public var tone: AIMTone
    public var style: AIMResponseStyle
    public var expertise: AIMExpertise
    public var responseLength: AIMResponseLength
    public var emojis: Bool
    public var maxEmojis: Int
    public var webSearchEnabled: Bool
    public var detailedResponseEnabled: Bool
    public var libraryRetentionDays: Int
    public var shareProfileWithAI: Bool
    public var memoryEnabled: Bool

    public init(autoModelSelection: Bool, autoTitleGeneration: Bool, smartContext: Bool, hapticFeedback: Bool, tone: AIMTone, style: AIMResponseStyle, expertise: AIMExpertise, responseLength: AIMResponseLength, emojis: Bool, maxEmojis: Int, webSearchEnabled: Bool, detailedResponseEnabled: Bool, libraryRetentionDays: Int, shareProfileWithAI: Bool, memoryEnabled: Bool) {
        self.autoModelSelection = autoModelSelection
        self.autoTitleGeneration = autoTitleGeneration
        self.smartContext = smartContext
        self.hapticFeedback = hapticFeedback
        self.tone = tone
        self.style = style
        self.expertise = expertise
        self.responseLength = responseLength
        self.emojis = emojis
        self.maxEmojis = min(max(maxEmojis, 0), 20)
        self.webSearchEnabled = webSearchEnabled
        self.detailedResponseEnabled = detailedResponseEnabled
        self.libraryRetentionDays = min(max(libraryRetentionDays, 1), 365)
        self.shareProfileWithAI = shareProfileWithAI
        self.memoryEnabled = memoryEnabled
    }

    public static let defaults = AIMUserPreferences(
        autoModelSelection: false,
        autoTitleGeneration: true,
        smartContext: true,
        hapticFeedback: true,
        tone: .neutral,
        style: .synthetic,
        expertise: .intermediate,
        responseLength: .semiDetailed,
        emojis: false,
        maxEmojis: 6,
        webSearchEnabled: true,
        detailedResponseEnabled: false,
        libraryRetentionDays: 60,
        shareProfileWithAI: false,
        memoryEnabled: true
    )
}

public struct AIMMemoryDocument: Equatable, Sendable {
    public let content: String
    public let version: Int
    public let updatedAt: Date?

    public init(content: String, version: Int, updatedAt: Date?) {
        self.content = content
        self.version = version
        self.updatedAt = updatedAt
    }
}

public struct AIMUserProfile: Equatable, Sendable {
    public var fullName: String
    public var preferredName: String
    public var personalPreferences: String

    public init(fullName: String, preferredName: String, personalPreferences: String) {
        self.fullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredName = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.personalPreferences = String(personalPreferences.prefix(2_000))
    }
}

public struct AIMMediaItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: AIMMediaKind
    public let url: URL
    public let prompt: String
    public let model: String
    public let createdAt: Date
    public let expiresAt: Date
    public let storagePath: String
    public let duration: Double?
    public let resolution: String?

    public init(id: String, kind: AIMMediaKind, url: URL, prompt: String, model: String, createdAt: Date, expiresAt: Date, storagePath: String, duration: Double? = nil, resolution: String? = nil) {
        self.id = id
        self.kind = kind
        self.url = url
        self.prompt = prompt
        self.model = model
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.storagePath = storagePath
        self.duration = duration
        self.resolution = resolution
    }
}

public enum CloudContentError: Error, Equatable, Sendable { case unavailable, invalidInput, conflict }

public enum AIMConnectorOAuthProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case notion
    case slack
    case github
    case canva

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .notion: "Notion"
        case .slack: "Slack"
        case .github: "GitHub"
        case .canva: "Canva"
        }
    }
}

public protocol CloudContentServicing: Sendable {
    func loadProfile() async throws -> AIMUserProfile
    func saveProfile(_ profile: AIMUserProfile) async throws
    func loadProjects() async throws -> [AIMProject]
    func createProject(name: String, description: String?, customContext: String?) async throws -> AIMProject
    func renameProject(id: String, name: String) async throws -> AIMProject
    func setProjectFavorite(id: String, isFavorite: Bool) async throws -> AIMProject
    func archiveProject(id: String) async throws
    func deleteProject(id: String) async throws
    func loadProjectConversations(projectID: String) async throws -> [AIMProjectConversation]
    func loadProjectFiles(projectID: String) async throws -> [AIMProjectFile]
    func uploadProjectFile(projectID: String, data: Data, name: String, mimeType: String) async throws -> AIMProjectFile
    func uploadProjectFile(projectID: String, data: Data, name: String, mimeType: String, extractedText: String?) async throws -> AIMProjectFile
    func deleteProjectFile(projectID: String, fileID: String) async throws
    func loadLegacyMessages(conversationID: String) async throws -> [AIMLegacyMessage]
    func loadMedia(kind: AIMMediaKind) async throws -> [AIMMediaItem]
    func deleteMedia(_ item: AIMMediaItem) async throws
    func loadConnectors() async throws -> [AIMConnector]
    func setConnectorActive(id: String, isActive: Bool) async throws
    func setConnectorToolPermission(id: String, toolName: String, permission: ConnectorToolPermission) async throws
    func deleteConnector(id: String) async throws
    func connectorAuthorizationURL(provider: AIMConnectorOAuthProvider, redirectURL: URL) async throws -> URL
    func loadPreferences() async throws -> AIMUserPreferences
    func savePreferences(_ preferences: AIMUserPreferences) async throws
    func loadMemoryDocument() async throws -> AIMMemoryDocument
    func saveMemoryDocument(content: String, expectedVersion: Int) async throws -> AIMMemoryDocument
    func exportUserData() async throws -> Data
    func deleteAccount(confirmEmail: String, confirmation: String) async throws
}

public struct EmptyCloudContentService: CloudContentServicing {
    public init() {}
    public func loadProfile() async throws -> AIMUserProfile { .init(fullName: "", preferredName: "", personalPreferences: "") }
    public func saveProfile(_ profile: AIMUserProfile) async throws { throw CloudContentError.unavailable }
    public func loadProjects() async throws -> [AIMProject] { [] }
    public func createProject(name: String, description: String?, customContext: String?) async throws -> AIMProject { throw CloudContentError.unavailable }
    public func renameProject(id: String, name: String) async throws -> AIMProject { throw CloudContentError.unavailable }
    public func setProjectFavorite(id: String, isFavorite: Bool) async throws -> AIMProject { throw CloudContentError.unavailable }
    public func archiveProject(id: String) async throws { throw CloudContentError.unavailable }
    public func deleteProject(id: String) async throws { throw CloudContentError.unavailable }
    public func loadProjectConversations(projectID: String) async throws -> [AIMProjectConversation] { [] }
    public func loadProjectFiles(projectID: String) async throws -> [AIMProjectFile] { [] }
    public func uploadProjectFile(projectID: String, data: Data, name: String, mimeType: String) async throws -> AIMProjectFile { throw CloudContentError.unavailable }
    public func deleteProjectFile(projectID: String, fileID: String) async throws { throw CloudContentError.unavailable }
    public func loadLegacyMessages(conversationID: String) async throws -> [AIMLegacyMessage] { [] }
    public func loadMedia(kind: AIMMediaKind) async throws -> [AIMMediaItem] { [] }
    public func deleteMedia(_ item: AIMMediaItem) async throws { throw CloudContentError.unavailable }
    public func loadConnectors() async throws -> [AIMConnector] { [] }
    public func setConnectorActive(id: String, isActive: Bool) async throws { throw CloudContentError.unavailable }
    public func setConnectorToolPermission(id: String, toolName: String, permission: ConnectorToolPermission) async throws { throw CloudContentError.unavailable }
    public func deleteConnector(id: String) async throws { throw CloudContentError.unavailable }
    public func connectorAuthorizationURL(provider: AIMConnectorOAuthProvider, redirectURL: URL) async throws -> URL { throw CloudContentError.unavailable }
    public func loadPreferences() async throws -> AIMUserPreferences { .defaults }
    public func savePreferences(_ preferences: AIMUserPreferences) async throws { throw CloudContentError.unavailable }
    public func loadMemoryDocument() async throws -> AIMMemoryDocument { .init(content: "", version: 0, updatedAt: nil) }
    public func saveMemoryDocument(content: String, expectedVersion: Int) async throws -> AIMMemoryDocument { throw CloudContentError.unavailable }
    public func exportUserData() async throws -> Data { throw CloudContentError.unavailable }
    public func deleteAccount(confirmEmail: String, confirmation: String) async throws { throw CloudContentError.unavailable }
}

public extension CloudContentServicing {
    /// Compatibility for existing adapters. Supabase overrides this to save the reviewed snapshot directly.
    func uploadProjectFile(projectID: String, data: Data, name: String, mimeType: String, extractedText: String?) async throws -> AIMProjectFile {
        if let extractedText {
            guard !data.isEmpty, data.count <= 20_000_000,
                  !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudContentError.invalidInput }
            try NativeDocumentSnapshot.validate([.init(name: name, content: extractedText)])
        }
        try Task.checkCancellation()
        return try await uploadProjectFile(projectID: projectID, data: data, name: name, mimeType: mimeType)
    }
}
