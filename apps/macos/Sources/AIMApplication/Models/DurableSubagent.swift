import Foundation

public struct DurableSubagent: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var parentExecutionID: UUID
    public var admissionCallID: String
    public var title: String
    public var prompt: String
    public var workspacePath: String
    public var providerID: String?
    public var modelID: String?
    /// Reasoning level chosen for this child; nil keeps the provider default.
    public var effort: String?
    public var profile: String
    public var worktree: SubagentWorkspaceRecord?
    /// Optional fields keep earlier JSON descriptors readable without a migration.
    public var remoteAssignment: DistributedSubagentAssignment?
    public var parentChildID: UUID?
    public var dependencyIDs: [UUID]?
    public var depth: Int?
    public var requiredResultKeys: [String]?
    public var state: ExecutionState = .queued
    public var revision: Int64 = 0
    public var result: String?
    public var retryAt: Date?
    public var hasStarted: Bool = false
    public var createdAt: Date = .now
    public init(id: UUID, parentExecutionID: UUID, admissionCallID: String, title: String,
                prompt: String, workspacePath: String, modelID: String?, profile: String,
                worktree: SubagentWorkspaceRecord?, parentChildID: UUID? = nil,
                dependencyIDs: [UUID]? = nil, depth: Int? = nil, requiredResultKeys: [String]? = nil) {
        self.id = id; self.parentExecutionID = parentExecutionID; self.admissionCallID = admissionCallID
        self.title = title; self.prompt = prompt; self.workspacePath = workspacePath
        self.modelID = modelID; self.profile = profile; self.worktree = worktree
        self.parentChildID = parentChildID; self.dependencyIDs = dependencyIDs; self.depth = depth
        self.requiredResultKeys = requiredResultKeys
    }
}
public struct DurableSubagentMessage: Codable, Sendable {
    public var id: String
    public var text: String
}

/// Persisted before remote admission. The selected peer is never replaced
/// automatically when delivery or effects are uncertain.
public struct DistributedSubagentAssignment: Codable, Sendable, Equatable {
    public var pairID: UUID
    public var grantID: UUID
    public var workerMachineID: UUID
    public var remoteExecutionID: UUID
    public var remoteConversationID: UUID
    public var provider: String
    public var modelID: String
    public var workspaceArtifactID: UUID?
    public var workspaceDigest: String?
    public init(pairID: UUID, grantID: UUID, workerMachineID: UUID, remoteExecutionID: UUID,
                remoteConversationID: UUID, provider: String, modelID: String,
                workspaceArtifactID: UUID? = nil, workspaceDigest: String? = nil) {
        self.pairID = pairID; self.grantID = grantID; self.workerMachineID = workerMachineID
        self.remoteExecutionID = remoteExecutionID; self.remoteConversationID = remoteConversationID
        self.provider = provider; self.modelID = modelID
        self.workspaceArtifactID = workspaceArtifactID; self.workspaceDigest = workspaceDigest
    }
}
