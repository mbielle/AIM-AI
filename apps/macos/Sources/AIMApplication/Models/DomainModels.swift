import AIMCore
import Foundation

public enum AIMMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case chat
    case code
    case agent

    public var id: String { rawValue }
}

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var provider: ChatProvider?
    public var modelID: String?
    public var workspacePath: String?
    public var id: UUID
    public var title: String
    public var mode: AIMMode
    public var projectID: UUID?
    public var engineID: String?
    public var isArchived: Bool
    public var pinnedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        mode: AIMMode = .chat,
        projectID: UUID? = nil,
        engineID: String? = nil,
        isArchived: Bool = false,
        pinnedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        provider: ChatProvider? = nil,
        modelID: String? = nil,
        workspacePath: String? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.workspacePath = workspacePath
        self.id = id
        self.title = title
        self.mode = mode
        self.projectID = projectID
        self.engineID = engineID
        self.isArchived = isArchived
        self.pinnedAt = pinnedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum AssistantCompletionStatus: String, Codable, Hashable, Sendable {
    case failed
    case cancelled
}

public struct ConversationMessage: Codable, Identifiable, Hashable, Sendable {
    public var routeAttempts: [ConversationRouteAttempt]?
    public var sources: [ConversationSource]?
    public var actions: [ConversationAction]?
    /// Order of reasoning, text and actions in this turn; nil for older messages.
    public var timeline: TurnTimeline?
    public var visualReport: VisualAnalysisReport?
    public var attachments: [TextAttachment]?
    public var images: [ImageAttachment]?
    /// Generated videos (files in the media folder; only their metadata is stored here).
    public var videos: [VideoAttachment]?
    /// Nil means a completed message (and remains compatible with older rows).
    public var completionStatus: AssistantCompletionStatus?
    public var id: UUID
    public var conversationID: UUID
    public var role: MessageRole
    public var content: String
    public var sequence: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: MessageRole,
        content: String,
        sequence: Int,
        createdAt: Date = .now,
        attachments: [TextAttachment]? = nil,
        images: [ImageAttachment]? = nil,
        completionStatus: AssistantCompletionStatus? = nil,
        videos: [VideoAttachment]? = nil,
        actions: [ConversationAction]? = nil,
        visualReport: VisualAnalysisReport? = nil,
        sources: [ConversationSource]? = nil, routeAttempts: [ConversationRouteAttempt]? = nil, timeline: TurnTimeline? = nil
    ) {
        self.timeline = timeline; self.routeAttempts = routeAttempts; self.sources = sources; self.visualReport = visualReport; self.actions = actions
        self.attachments = attachments
        self.images = images
        self.videos = videos
        self.completionStatus = completionStatus
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

public struct AIMProject: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var instructions: String
    public var usesGlobalMemory: Bool?
    /// Optional so legacy local records remain distinguishable from an explicit synced pin.
    public var isPinned: Bool?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProjectSource: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var canonicalPath: String
    public var displayName: String
    public var createdAt: Date
    public var lastScannedAt: Date?
    public var writeAccessGranted: Bool

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        canonicalPath: String,
        displayName: String,
        createdAt: Date = .now,
        lastScannedAt: Date? = nil,
        writeAccessGranted: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.canonicalPath = canonicalPath
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastScannedAt = lastScannedAt
        self.writeAccessGranted = writeAccessGranted
    }
}

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case identity
    case preference
    case constraint
    case decision
    case architecture
    case fact
    case correction
    case procedure
    case lesson
    case episodicReference = "episodic_reference"
}

public enum MemoryStatus: String, Codable, Sendable {
    case provisional
    case verified
    case superseded
    case archived
    case quarantined
}

public struct MemoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MemoryKind
    public var scope: String
    public var scopeKey: String
    public var subjectKey: String
    public var content: String
    public var evidenceQuote: String?
    public var sourceMessageID: UUID?
    public var status: MemoryStatus
    public var confidence: Double
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: MemoryKind,
        scope: String,
        scopeKey: String,
        subjectKey: String,
        content: String,
        evidenceQuote: String? = nil,
        sourceMessageID: UUID? = nil,
        status: MemoryStatus = .provisional,
        confidence: Double = 1,
        isPinned: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.scopeKey = scopeKey
        self.subjectKey = subjectKey
        self.content = content
        self.evidenceQuote = evidenceQuote
        self.sourceMessageID = sourceMessageID
        self.status = status
        self.confidence = confidence
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ScheduledTaskState: String, Codable, Sendable {
    case enabled
    case running
    case paused
    case disabled
}

public struct ScheduledTask: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var prompt: String
    public var recurrenceRule: String?
    public var nextRunAt: Date?
    public var state: ScheduledTaskState
    public var consecutiveFailures: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// The typed definition; tasks created before it existed have none and never run.
    public var spec: ScheduledTaskSpec?
    /// Set while one execution owns the task; prevents self-overlap.
    public var runningSince: Date?
    public var lastRunAt: Date?
    public var lastStatus: String?
    public var pausedReason: String?

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        recurrenceRule: String? = nil,
        nextRunAt: Date? = nil,
        state: ScheduledTaskState = .enabled,
        consecutiveFailures: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        spec: ScheduledTaskSpec? = nil,
        runningSince: Date? = nil,
        lastRunAt: Date? = nil,
        lastStatus: String? = nil,
        pausedReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.recurrenceRule = recurrenceRule
        self.nextRunAt = nextRunAt
        self.state = state
        self.consecutiveFailures = consecutiveFailures
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.spec = spec
        self.runningSince = runningSince
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.pausedReason = pausedReason
    }

    /// Consecutive failed runs after which a recurring task disables itself.
    public static let failureLimit = 10
}

public struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var application: String
    public var title: String
    public var url: String?
    public var startedAt: Date
    public var endedAt: Date

    public init(
        id: Int64? = nil,
        application: String,
        title: String,
        url: String? = nil,
        startedAt: Date,
        endedAt: Date
    ) {
        self.id = id
        self.application = application
        self.title = title
        self.url = url
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct ActivitySettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var retentionDays: Int
    public var excludedApplications: [String]
    public var excludedDomains: [String]

    public init(
        isEnabled: Bool = false,
        retentionDays: Int = 30,
        excludedApplications: [String] = [],
        excludedDomains: [String] = ActivityPrivacyPolicy.defaultExcludedDomains
    ) {
        self.isEnabled = isEnabled
        self.retentionDays = min(max(retentionDays, 1), 30)
        self.excludedApplications = excludedApplications
        self.excludedDomains = excludedDomains
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Nil in older preferences preserves local saved-memory recall.
    public var memoryEnabled: Bool?
    /// Extra provider calls to propose durable memories require a new,
    /// explicit opt-in. A missing value from older settings means disabled.
    public var externalMemoryCaptureEnabled: Bool?
    public var anthropicOutputTokensByModel: [String: Int]?
    public var openAIReasoningEffortByModel: [String: OpenAIReasoningEffort]?
    public var conversationAppearance: ConversationAppearance?
    public var favoriteModels: [FavoriteModel]?
    public var personalization: Personalization?
    public var selectedProvider: ChatProvider?
    public var workspacePath: String?
    public var recentWorkspacePaths: [String]?
    public var launchAtLogin: Bool
    public var selectedMode: AIMMode
    public var selectedModelID: String?
    /// The engine to preselect for a new Agent conversation. Existing rows without it use AIM.
    public var selectedAgentEngineID: String?
    public var activity: ActivitySettings
    /// Settings pages' preferences (nil in older settings: all defaults).
    public var preferences: AppPreferences?
    /// Missing values preserve the embedded runtime and conservative concurrency.
    public var continuity: ContinuitySettings?

    public init(
        launchAtLogin: Bool = false,
        selectedMode: AIMMode = .chat,
        selectedModelID: String? = nil,
        activity: ActivitySettings = .init()
    ) {
        self.launchAtLogin = launchAtLogin
        self.selectedMode = selectedMode
        self.selectedModelID = selectedModelID
        self.activity = activity
    }

    public mutating func rememberWorkspace(_ canonicalPath: String) {
        recentWorkspacePaths = Array(([canonicalPath] + (recentWorkspacePaths ?? []))
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) { paths.append(path) }
            }.prefix(8))
    }
}

public struct ContinuitySettings: Codable, Equatable, Sendable {
    public var permanent: Bool
    public var keepAwake: Bool
    public var maximumRoots: Int
    public var maximumChildren: Int
    public init(permanent: Bool = false, keepAwake: Bool = true, maximumRoots: Int = 2, maximumChildren: Int = 3) {
        self.permanent = permanent; self.keepAwake = keepAwake
        self.maximumRoots = max(1, maximumRoots); self.maximumChildren = max(1, maximumChildren)
    }
}
