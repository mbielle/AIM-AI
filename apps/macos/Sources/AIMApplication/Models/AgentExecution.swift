import AIMCore
import Foundation

public enum ExecutionState: String, Codable, Sendable, CaseIterable {
    case queued, running, waitingEvent, waitingNetwork, waitingUser, awaitingReview
    case paused, blocked, verified, accepted, failed, cancelled
    public var isTerminal: Bool { [.verified, .accepted, .failed, .cancelled].contains(self) }
    public var isRecoverable: Bool { [.queued, .running, .waitingEvent, .waitingNetwork].contains(self) }
}

/// Never contains credentials. The request envelope belongs to the engine contract.
public struct AgentExecution: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var commandID: UUID
    public var conversationID: UUID
    public var accountID: UUID?
    public var request: Data
    public var state: ExecutionState
    public var revision: Int64
    public var ownerGeneration: UUID?
    public var reason: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var boundaryPauseReason: String?
    public var transferResumeState: ExecutionState?
    public var completedTurns: Int?
    public var settledCheckpointAt: Date?
    public init(id: UUID = UUID(), commandID: UUID, conversationID: UUID, accountID: UUID? = nil,
                request: Data, at date: Date = .now) {
        self.id = id; self.commandID = commandID; self.conversationID = conversationID
        self.accountID = accountID; self.request = request; state = .queued; revision = 0
        ownerGeneration = nil; reason = nil; createdAt = date; updatedAt = date
    }
}

public enum ToolRecoveryPolicy: String, Codable, Sendable {
    case readOnly, idempotent, reconcile, neverReplay
}

public struct ExecutionEffect: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case requested, launched, returned }
    public var call: ModelToolCall
    public var policy: ToolRecoveryPolicy
    public var state: State
    public var output: ModelToolOutput?
    public var wasLaunched: Bool?
    public init(call: ModelToolCall, policy: ToolRecoveryPolicy) {
        self.call = call; self.policy = policy; state = .requested; output = nil
    }
}

public struct ModelConversationCheckpoint: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var codec: String
    public var provider: ChatProvider
    public var modelID: String
    public var transcript: Data
    public var pendingIDs: [String]
    public var seenIDs: Set<String>
    public var finished: Bool
    public var usage: TokenUsage
    /// Provider-specific correlation/configuration, never authentication.
    public var metadata: Data
    public var extensions: [String: Data]?
    public init(codec: String, provider: ChatProvider, modelID: String, transcript: Data,
                pendingIDs: [String], seenIDs: Set<String>, finished: Bool,
                usage: TokenUsage, metadata: Data = Data("{}".utf8)) {
        self.codec = codec; self.provider = provider; self.modelID = modelID; self.transcript = transcript
        self.pendingIDs = pendingIDs; self.seenIDs = seenIDs; self.finished = finished
        self.usage = usage; self.metadata = metadata
    }
}

public struct ExecutionCheckpoint: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var conversation: ModelConversationCheckpoint
    public var turn: ModelToolTurn
    public var effects: [ExecutionEffect]
    public var ordinal: Int
    public var seenCallIDs: Set<String>
    public var blockedCalls: [ModelToolCall]
    public var savedAt: Date
    public var toolState: [String: Data]?
    public var missionID: UUID?
    public var workspaceRunID: String?
    public var deliveredMissionInputIDs: [UUID]?
    public init(conversation: ModelConversationCheckpoint, turn: ModelToolTurn,
                effects: [ExecutionEffect], ordinal: Int, seenCallIDs: Set<String>,
                blockedCalls: [ModelToolCall] = [], savedAt: Date = .now, toolState: [String: Data]? = nil,
                missionID: UUID? = nil, workspaceRunID: String? = nil) {
        self.conversation = conversation; self.turn = turn; self.effects = effects
        self.ordinal = ordinal; self.seenCallIDs = seenCallIDs; self.blockedCalls = blockedCalls
        self.savedAt = savedAt
        self.toolState = toolState
        self.missionID = missionID; self.workspaceRunID = workspaceRunID
    }
    public var needsReconciliation: Bool {
        effects.contains {
            guard $0.policy != .readOnly else { return false }
            if $0.state == .launched { return true }
            // A command or a check that ran to completion reported its own result (a failing
            // test, a nonzero exit): the effect is known, the agent simply reads it and goes on.
            if $0.output?.metadata["exit_code"] != nil || $0.output?.metadata["verification"] != nil { return false }
            guard $0.output?.metadata["reconciled_by"] == nil,
                  let outcome = $0.output?.metadata["action_outcome"] else {
                return $0.wasLaunched == true && $0.output?.isError == true
            }
            return ["unknown", "unverified", "partial"].contains(outcome)
        }
    }
}

public struct ExecutionEvent: Codable, Sendable, Equatable {
    public var sequence: Int64
    public var executionID: UUID
    public var kind: String
    public var payload: Data
    public var createdAt: Date
}

public struct WakeCondition: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case deadline, folder, script, webhook, mail, network, process, subagent, user, desktop
    }
    public var id: UUID
    public var executionID: UUID
    public var kind: Kind
    public var key: String
    public var dueAt: Date?
    public var baseline: String?
    public init(id: UUID = UUID(), executionID: UUID, kind: Kind, key: String, dueAt: Date? = nil, baseline: String? = nil) {
        self.id = id; self.executionID = executionID; self.kind = kind; self.key = key; self.dueAt = dueAt
        self.baseline = baseline
    }
}

public enum ExecutionStoreError: Error, Equatable {
    case staleOwner, staleRevision, duplicateConversation, commandConflict
    case notFound, incompatibleCheckpoint, invalidTransition
}

public protocol DurableModelConversation: ModelToolConversation {
    func exportCheckpoint() async throws -> ModelConversationCheckpoint
    func restoreCheckpoint(_ checkpoint: ModelConversationCheckpoint) async throws
}

public struct ExecutionUserInput: Sendable {
    public let id: UUID
    public let content: String
    public init(id: UUID, content: String) { self.id = id; self.content = content }
}
public protocol ExecutionCheckpointing: Sendable {
    func load() async throws -> ExecutionCheckpoint?
    func prepare(_ checkpoint: ExecutionCheckpoint) async throws
    func launched(_ callID: String) async throws
    func returned(_ output: ModelToolOutput) async throws
    func returned(_ output: ModelToolOutput, toolState: [String: Data]) async throws
    func checkBoundary() async throws
    func pendingUserInputs() async throws -> [ExecutionUserInput]
}
public extension ExecutionCheckpointing {
    func checkBoundary() async throws {}
    func pendingUserInputs() async throws -> [ExecutionUserInput] { [] }
    func returned(_ output: ModelToolOutput, toolState: [String: Data]) async throws { try await returned(output) }
}
public struct ExecutionBoundaryPause: Error, Sendable { public init() {} }
public struct ExecutionManagedWait: Error, Sendable {
    public let kind: WakeCondition.Kind
    public let key: String
    public let dueAt: Date?
    public let baseline: String?
    public init(kind: WakeCondition.Kind, key: String, dueAt: Date? = nil, baseline: String? = nil) {
        self.kind = kind; self.key = key; self.dueAt = dueAt; self.baseline = baseline
    }
    public static func from(_ outputs: [ModelToolOutput]) -> ExecutionManagedWait? {
        for output in outputs {
            if output.metadata["screen_locked"] == "true" { return .init(kind: .desktop, key: "unlocked") }
            guard output.metadata["expected_wait"] == "true" else { continue }
            if output.metadata["wait_condition"] == "all_children_terminal" { return .init(kind: .subagent, key: "children") }
            guard output.metadata["wait_condition"] == "system_event",
                  let kind = output.metadata["wake_kind"].flatMap(WakeCondition.Kind.init(rawValue:)),
                  let key = output.metadata["wake_key"], !key.isEmpty else { continue }
            let date = output.metadata["wake_due"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            return .init(kind: kind, key: key, dueAt: date, baseline: output.metadata["wake_baseline"])
        }
        return nil
    }
}
