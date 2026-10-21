import AIMCore
import AIMApplication
import Foundation

public enum AgentEngineID: String, Codable, CaseIterable, Sendable, Identifiable {
    case aim
    case openClaw = "openclaw"
    case hermes
    case externalStdio = "external-stdio"

    public var id: String { rawValue }
}

public enum EnginePublicState: String, Codable, Sendable {
    case notInstalled = "not-installed"
    case stopped
    case starting
    case ready
    case stopping
    case error
}

public enum EngineLeaseKind: String, Codable, Sendable {
    case interactive
    case background
    case persistent
}

public struct EngineDiagnostic: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var isRecoverable: Bool
    public var timestamp: Date
    public var details: [String: String]

    public init(code: String, message: String, isRecoverable: Bool, timestamp: Date = .now, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
        self.timestamp = timestamp
        self.details = details
    }
}

public struct EngineStatus: Codable, Equatable, Sendable {
    public var id: AgentEngineID
    public var state: EnginePublicState
    public var isInstalled: Bool
    public var version: String?
    public var runtimeVersion: String?
    public var diagnostic: EngineDiagnostic?

    public init(
        id: AgentEngineID,
        state: EnginePublicState,
        isInstalled: Bool,
        version: String? = nil,
        runtimeVersion: String? = nil,
        diagnostic: EngineDiagnostic? = nil
    ) {
        self.id = id
        self.state = state
        self.isInstalled = isInstalled
        self.version = version
        self.runtimeVersion = runtimeVersion
        self.diagnostic = diagnostic
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case allowOnce
    /// This conversation: the same action type (or, for per-action tools, the same exact action).
    case allowForSession
    /// This action type everywhere, until revoked in Settings › Permissions.
    case allowAlways
    case deny
}

public struct AgentRequest: Codable, Sendable {
    /// Immutable profile snapshot admitted with this request; never grants rights.
    public var generalSubagentChoice: SubagentModelChoice?
    public var customAgentProfileID: UUID?
    public var providerPluginID: String?
    /// Selected external runtime; execution still belongs to the native coordinator.
    public var externalEngineID: AgentEngineID?
    public var customAgentInstructions: String?
    public var allowedToolNames: [String]?
    public var memoryEnabled: Bool?
    public var activitySettings: ActivitySettings?
    public var anthropicOutputTokens: Int?
    public var automaticWebSearch: Bool?
    public var researchMode: AIMResearchMode?
    public var openAIReasoningEffort: OpenAIReasoningEffort?
    public var personalization: Personalization?
    public var provider: ChatProvider?
    public var conversationID: UUID
    public var text: String
    public var modelID: String
    public var modelSupportsImages: Bool?
    /// The model's context window (catalog, or the local model's setting), for compaction and the context gauge.
    public var contextLength: Int?
    public var mode: AIMMode
    public var workspacePath: String?
    public var workspaceToolsEnabled: Bool?
    public var workspaceTextToolProtocol: Bool?
    public var workspaceEditsEnabled: Bool?
    public var workspaceCommandsEnabled: Bool?
    public var workspacePlanOnly: Bool?
    public var approvalPolicy: ApprovalPolicy?
    public var continuationMessage: String?
    public var sourceMessageID: UUID?
    public var continuityMaximumTurns: Int?
    public var continuityMaximumSpendUSD: String?
    /// Signed origin grant for a distributed child. Never fall back to local billing.
    public var remoteSpendGrantData: Data?
    public var initialMissionScope: [MissionAuthorizationRule]?

    public init(conversationID: UUID, text: String, modelID: String, mode: AIMMode, workspacePath: String? = nil, provider: ChatProvider = .openRouter, workspaceToolsEnabled: Bool = false, workspaceTextToolProtocol: Bool = false, workspaceEditsEnabled: Bool = false, workspaceCommandsEnabled: Bool = false, workspacePlanOnly: Bool = false, approvalPolicy: ApprovalPolicy = .alwaysAsk, personalization: Personalization? = nil, anthropicOutputTokens: Int? = nil, openAIReasoningEffort: OpenAIReasoningEffort? = nil, memoryEnabled: Bool = true, activitySettings: ActivitySettings? = nil, modelSupportsImages: Bool? = nil, contextLength: Int? = nil) {
        self.modelSupportsImages = modelSupportsImages
        self.continuationMessage = nil
        self.sourceMessageID = nil
        self.contextLength = contextLength
        self.memoryEnabled = memoryEnabled
        self.activitySettings = activitySettings
        self.anthropicOutputTokens = anthropicOutputTokens
        self.openAIReasoningEffort = openAIReasoningEffort
        self.personalization = personalization
        self.workspaceCommandsEnabled = workspaceCommandsEnabled
        self.workspaceEditsEnabled = workspaceEditsEnabled
        self.workspaceToolsEnabled = workspaceToolsEnabled
        self.workspaceTextToolProtocol = workspaceTextToolProtocol
        self.workspacePlanOnly = workspacePlanOnly
        self.approvalPolicy = approvalPolicy
        self.provider = provider
        self.conversationID = conversationID
        self.text = text
        self.modelID = modelID
        self.mode = mode
        self.workspacePath = workspacePath
    }
}

public enum AgentRunStage: String, Codable, Sendable, Equatable {
    case preparingContext
    case optimizingContext
    case waitingForModel
    case waitingForNetwork
}

public enum EngineEvent: Codable, Sendable, Equatable {
    case state(EngineStatus)
    case textDelta(conversationID: UUID, text: String)
    case reasoningDelta(conversationID: UUID, text: String)
    case contextCompacted(conversationID: UUID, throughSequence: Int)
    case runStage(conversationID: UUID, stage: AgentRunStage)
    case planUpdated(AgentPlan)
    case toolStarted(conversationID: UUID, callID: String, name: String)
    case toolStartedDetailed(conversationID: UUID, callID: String, name: String, detail: String?)
    case toolFinished(conversationID: UUID, callID: String, isError: Bool)
    case approvalRequested(conversationID: UUID, approvalID: String, summary: String)
    /// Tokens and timings of the answer just streamed (before `completed`).
    case routeAttempt(conversationID: UUID, attempt: ConversationRouteAttempt)
    case turnMetrics(conversationID: UUID, metrics: TurnMetrics)
    /// What fills the context window for this turn (estimated parts, model limit).
    case contextUsage(conversationID: UUID, usage: ContextUsage)
    /// A title the model wrote for a new conversation.
    case titleGenerated(conversationID: UUID, title: String)
    case completed(conversationID: UUID)
    case failed(conversationID: UUID?, diagnostic: EngineDiagnostic)
}

public protocol AgentEngine: Sendable {
    var id: AgentEngineID { get }
    func status() async -> EngineStatus
    func install() async throws
    func start() async throws
    func stop() async
    func diagnose() async -> EngineDiagnostic?
    func send(_ request: AgentRequest) async throws
    func cancel(conversationID: UUID) async
    func decide(approvalID: String, decision: ApprovalDecision) async
    func events() async -> AsyncStream<EngineEvent>
}

public actor AgentEngineRegistry {
    private var engines: [AgentEngineID: any AgentEngine] = [:]
    private var leases: [AgentEngineID: [UUID: EngineLeaseKind]] = [:]

    public init() {}

    public func register(_ engine: any AgentEngine) { engines[engine.id] = engine }
    public func unregister(_ id: AgentEngineID) { engines.removeValue(forKey: id) }

    public func engine(_ id: AgentEngineID) -> (any AgentEngine)? { engines[id] }

    public func statuses() async -> [EngineStatus] {
        var result: [EngineStatus] = []
        for id in AgentEngineID.allCases {
            if let engine = engines[id] {
                result.append(await engine.status())
            } else {
                result.append(EngineStatus(id: id, state: .notInstalled, isInstalled: id == .aim))
            }
        }
        return result
    }

    @discardableResult
    public func acquire(_ id: AgentEngineID, kind: EngineLeaseKind) -> UUID {
        let leaseID = UUID()
        leases[id, default: [:]][leaseID] = kind
        return leaseID
    }

    public func release(_ id: AgentEngineID, leaseID: UUID) async {
        leases[id]?.removeValue(forKey: leaseID)
        if leases[id]?.isEmpty == true { leases.removeValue(forKey: id) }
    }

    public func canStop(_ id: AgentEngineID) -> Bool { leases[id]?.isEmpty ?? true }
}

public protocol NativeAgentTurnRunning: Sendable {
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error>
    func cancel(conversationID: UUID) async
    func decide(approvalID: String, decision: ApprovalDecision) async
}

public extension NativeAgentTurnRunning {
    func decide(approvalID: String, decision: ApprovalDecision) async {}
}

public actor NativeAIMEngine: AgentEngine {
    public nonisolated let id: AgentEngineID

    private let runner: any NativeAgentTurnRunning
    private var currentStatus = EngineStatus(id: .aim, state: .stopped, isInstalled: true)
    private var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var runningTokens: [UUID: UUID] = [:]

    public init(runner: any NativeAgentTurnRunning, id: AgentEngineID = .aim, version: String? = nil) {
        self.runner = runner; self.id = id
        self.currentStatus = EngineStatus(id: id, state: .stopped, isInstalled: true, version: version)
    }

    public func status() -> EngineStatus { currentStatus }
    public func install() async throws {}

    public func start() async throws {
        guard currentStatus.state != .stopping else { throw EngineError.stopping }
        currentStatus.state = .ready
        publish(.state(currentStatus))
    }

    public func stop() async {
        currentStatus.state = .stopping
        publish(.state(currentStatus))
        let tasks = runningTasks
        for task in tasks.values { task.cancel() }
        for (id, task) in tasks {
            await runner.cancel(conversationID: id)
            await task.value
        }
        currentStatus.state = .stopped
        publish(.state(currentStatus))
    }

    public func diagnose() -> EngineDiagnostic? { currentStatus.diagnostic }
    /// Disconnect view observers without interpreting it as mission cancellation.
    public func detach() async {
        let tasks = runningTasks
        for task in tasks.values { task.cancel() }
        for task in tasks.values { await task.value }
        runningTasks.removeAll(); runningTokens.removeAll()
        currentStatus.state = .stopped; publish(.state(currentStatus))
    }

    public func send(_ request: AgentRequest) async throws {
        guard currentStatus.state != .stopping else { throw EngineError.stopping }
        if currentStatus.state != .ready { try await start() }
        guard runningTasks[request.conversationID] == nil else {
            throw EngineError.conversationAlreadyRunning
        }
        var request = request
        if id != .aim { request.externalEngineID = id }
        let stream = runner.run(request)
        let token = UUID()
        runningTokens[request.conversationID] = token
        runningTasks[request.conversationID] = Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.publish(event)
                }
                if !Task.isCancelled { await self?.publish(.completed(conversationID: request.conversationID)) }
            } catch {
                if !Task.isCancelled {
                    let diagnostic = EngineDiagnostic(code: "aim.turn.failed", message: error.localizedDescription, isRecoverable: true)
                    await self?.publish(.failed(conversationID: request.conversationID, diagnostic: diagnostic))
                }
            }
            await self?.clearTask(for: request.conversationID, token: token)
        }
    }

    public func cancel(conversationID: UUID) async {
        runningTasks.removeValue(forKey: conversationID)?.cancel()
        runningTokens.removeValue(forKey: conversationID)
        await runner.cancel(conversationID: conversationID)
    }

    public func decide(approvalID: String, decision: ApprovalDecision) async {
        await runner.decide(approvalID: approvalID, decision: decision)
    }

    public func events() -> AsyncStream<EngineEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.yield(.state(currentStatus))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func publish(_ event: EngineEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func clearTask(for id: UUID, token: UUID) {
        guard runningTokens[id] == token else { return }
        runningTasks.removeValue(forKey: id)
        runningTokens.removeValue(forKey: id)
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}

public enum EngineError: LocalizedError, Sendable {
    case stopping
    case conversationAlreadyRunning
    case notInstalled(AgentEngineID)
    case invalidRuntime(String)

    public var errorDescription: String? {
        switch self {
        case .stopping: "The engine is stopping."
        case .conversationAlreadyRunning: "A turn is already running for this conversation."
        case let .notInstalled(id): "\(id.rawValue) is not installed."
        case let .invalidRuntime(message): message
        }
    }
}
