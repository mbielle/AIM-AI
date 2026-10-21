import AIMCore
import Foundation

public enum WorkspaceRunState: String, Codable, Sendable {
    case running, completed, failed, cancelled
    /// The model ended its turn; no host-verified mission success is implied.
    case unverified
}
public enum WorkspaceCallState: String, Codable, Sendable { case requested, succeeded, failed, interrupted }

public struct WorkspaceRun: Codable, Sendable, Identifiable {
    public let id: String
    public let conversationID: String
    public let provider: ChatProvider
    public let modelID: String
    public let workspacePath: String
    public var state: WorkspaceRunState
    public let startedAt: Date
    public var endedAt: Date?

    public init(id: String = UUID().uuidString, conversationID: UUID, provider: ChatProvider, modelID: String, workspacePath: String) {
        self.id = id; self.conversationID = conversationID.uuidString; self.provider = provider
        self.modelID = modelID; self.workspacePath = workspacePath; self.state = .running
        self.startedAt = .now; self.endedAt = nil
    }
}

public struct WorkspaceCall: Codable, Sendable, Identifiable {
    public let id: String
    public let runID: String
    public let ordinal: Int
    public let name: String
    public let argumentsJSON: Data
    public var state: WorkspaceCallState
    public var result: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var launchedAt: Date?
    public var executionEvidenceVersion: Int?
    public var resultMetadataJSON: Data?

    public var requiresReconciliation: Bool {
        (state == .requested || state == .interrupted) &&
            (executionEvidenceVersion == nil || launchedAt != nil)
    }

    public init(runID: String, ordinal: Int, call: ModelToolCall) throws {
        self.id = call.id; self.runID = runID; self.ordinal = ordinal; self.name = call.name
        self.argumentsJSON = try JSONEncoder().encode(call.jsonArguments)
        self.state = .requested; self.result = nil; self.startedAt = .now; self.endedAt = nil
    }
}

public struct WorkspaceRunHistory: Sendable, Identifiable {
    public var id: String { run.id }
    public let run: WorkspaceRun
    public let calls: [WorkspaceCall]
    public init(run: WorkspaceRun, calls: [WorkspaceCall]) { self.run = run; self.calls = calls }
}

public protocol WorkspaceRunRepository: Sendable {
    func begin(_ run: WorkspaceRun) async throws
    func requested(_ call: WorkspaceCall) async throws
    func launched(runID: String, callID: String) async throws
    func returned(runID: String, output: ModelToolOutput) async throws
    func finish(runID: String, state: WorkspaceRunState) async throws
    func history(conversationID: UUID, limit: Int) async throws -> [WorkspaceRunHistory]
    func run(id: String) async throws -> WorkspaceRunHistory?
}

public extension WorkspaceRunRepository {
    func run(id: String) async throws -> WorkspaceRunHistory? { nil }
}

public enum WorkspaceHistoryError: LocalizedError, Sendable {
    case invalidTransition, invalidRecord, persistence
    public var errorDescription: String? {
        switch self {
        case .invalidTransition, .invalidRecord: "The workspace action history is inconsistent. The run was stopped."
        case .persistence: "AIM could not save the workspace action history. The run was stopped; no action will be automatically replayed."
        }
    }
}
