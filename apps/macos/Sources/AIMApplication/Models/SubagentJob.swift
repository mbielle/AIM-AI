import Foundation

public enum SubagentJobState: String, Codable, Sendable {
    case queued, running, done, error, cancelled, interrupted
}

public struct SubagentJobRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let workspacePath: String
    public let title: String
    public let prompt: String
    public let retryOf: UUID?
    public var state: SubagentJobState
    public var result: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), conversationID: UUID, workspacePath: String,
                title: String, prompt: String, retryOf: UUID? = nil,
                state: SubagentJobState = .queued,
                result: String? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.conversationID = conversationID; self.workspacePath = workspacePath
        self.title = title; self.prompt = prompt; self.retryOf = retryOf
        self.state = state; self.result = result
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct SubagentJobPage: Sendable {
    public let jobs: [SubagentJobRecord]
    public let nextOffset: Int?
    public let totalJobs: Int
    public let activeJobs: Int
}

public protocol SubagentJobRepository: Sendable {
    func enqueue(_ job: SubagentJobRecord) async throws
    func markRunning(id: UUID) async throws
    func finish(id: UUID, state: SubagentJobState, result: String?) async throws
    func cancel(id: UUID) async throws
    func load(id: UUID, conversationID: UUID, workspacePath: String) async throws -> SubagentJobRecord?
    func list(conversationID: UUID, workspacePath: String,
              offset: Int, limit: Int) async throws -> SubagentJobPage
    func recoverInterrupted() async throws -> Int
}

/// A writer sub-agent's isolated Git worktree. The child edits only this copy;
/// its changes reach the parent workspace through a reviewed, approved merge.
public struct SubagentWorkspaceRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case active, merged, discarded, conflict }

    public let jobID: UUID
    public let conversationID: UUID
    public let title: String
    /// Canonical root of the parent's repository and the parent workspace within it.
    public let repositoryRoot: String
    public let relativeWorkspace: String
    public let worktreePath: String
    public let branch: String
    /// Snapshot of the parent's files (tracked and untracked, not ignored) the child started from.
    public let baseCommit: String
    public var state: State
    /// SHA-256 of the patch the parent reviewed; a merge applies only that exact patch.
    public var reviewedPatchSHA256: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(jobID: UUID, conversationID: UUID, title: String, repositoryRoot: String, relativeWorkspace: String,
                worktreePath: String, branch: String, baseCommit: String, state: State = .active,
                reviewedPatchSHA256: String? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.jobID = jobID; self.conversationID = conversationID; self.title = title
        self.repositoryRoot = repositoryRoot; self.relativeWorkspace = relativeWorkspace
        self.worktreePath = worktreePath; self.branch = branch; self.baseCommit = baseCommit
        self.state = state; self.reviewedPatchSHA256 = reviewedPatchSHA256
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// The parent workspace path (repository root plus relative folder).
    public var parentWorkspace: String {
        relativeWorkspace.isEmpty ? repositoryRoot : repositoryRoot + "/" + relativeWorkspace
    }

    /// Where the child works: the same relative folder inside its worktree.
    public var childWorkspace: String {
        relativeWorkspace.isEmpty ? worktreePath : worktreePath + "/" + relativeWorkspace
    }
}

public protocol SubagentWorkspaceRepository: Sendable {
    func save(_ record: SubagentWorkspaceRecord) async throws
    func load(jobID: UUID) async throws -> SubagentWorkspaceRecord?
    func list(states: Set<SubagentWorkspaceRecord.State>) async throws -> [SubagentWorkspaceRecord]
}
