import AIMCore
import AIMApplication
import AIMAgentKit
import Foundation

/// Native worker adapter; all admission/control uses the durable coordinator.
/// The factory must bind the distributed budget proxy before returning a request.
package struct RuntimePeerExecutionEndpoint: Sendable {
    package typealias RequestProvider = @Sendable (RemotePeerGrant, Data, String) async throws -> AgentRequest
    package let coordinator: RunCoordinator
    package let executions: SQLiteAgentExecutionRepository
    package let workspace: @Sendable (RemotePeerGrant) async throws -> String
    package let requestProvider: RequestProvider
    package let budget: RuntimePeerRouter.Handler
    package let artifact: RuntimePeerRouter.Handler
    package let workspaceResult: @Sendable (RemotePeerGrant, AgentExecution) async throws -> RemotePeerArtifactCommit?
    package init(coordinator: RunCoordinator, executions: SQLiteAgentExecutionRepository, workspace: @escaping @Sendable (RemotePeerGrant) async throws -> String,
        requestProvider: @escaping RequestProvider, budget: @escaping RuntimePeerRouter.Handler,
        artifact: @escaping RuntimePeerRouter.Handler,
        workspaceResult: @escaping @Sendable (RemotePeerGrant, AgentExecution) async throws -> RemotePeerArtifactCommit? = { _, _ in nil }) {
        self.coordinator = coordinator; self.executions = executions; self.workspace = workspace; self.requestProvider = requestProvider
        self.budget = budget; self.artifact = artifact; self.workspaceResult = workspaceResult
    }
    package func handle(_ request: RemotePeerRequest, grant: RemotePeerGrant, recovering: Bool) async throws -> Data {
        switch request.action {
        case .budget: return try await budget(request, grant, recovering)
        case .artifactManifest, .artifactChunk, .artifactCommit: return try await artifact(request, grant, recovering)
        case .start:
            let mappedPath = try await workspace(grant)
            var admitted = try await requestProvider(grant, request.payload, mappedPath)
            let path = admitted.workspacePath ?? mappedPath
            guard admitted.mode == .code, admitted.conversationID == grant.childConversationID,
                  admitted.modelID == grant.modelID, admitted.provider?.rawValue == grant.provider,
                  admitted.allowedToolNames != nil, Set(admitted.allowedToolNames ?? []).isSubset(of: grant.allowedToolNames),
                  admitted.initialMissionScope?.allSatisfy({ rule in
                      rule.resource.kind == .directory &&
                      (rule.resource.identifier == path || rule.resource.identifier.hasPrefix(path + "/")) &&
                      (grant.writer || rule.operations == [.observe])
                  }) ?? true else { throw RemotePeerError.unauthorized }
            admitted.remoteSpendGrantData = try RemotePeerCoding.encode(request.grant)
            admitted.workspacePath = path
            if !grant.writer { admitted.workspaceEditsEnabled = false; admitted.workspaceCommandsEnabled = false }
            // Exact remote approvals below remain one-use; no session-wide extension.
            admitted.approvalPolicy = .alwaysAsk
            if let old = try await coordinator.snapshot(grant.childExecutionID) {
                guard old.commandID == request.commandID, old.accountID == grant.accountID,
                      old.conversationID == grant.childConversationID else { throw RemotePeerError.conflictingCommand }
                let original = try RemotePeerCoding.decode(AgentRequest.self, old.request)
                guard original.modelID == admitted.modelID, original.provider == admitted.provider,
                      original.text == admitted.text, original.workspacePath == path else { throw RemotePeerError.conflictingCommand }
                return try RemotePeerCoding.encode(old)
            }
            return try RemotePeerCoding.encode(await coordinator.admit(commandID: request.commandID,
                accountID: grant.accountID, request: admitted, executionID: grant.childExecutionID))
        case .snapshot:
            guard let record = try await coordinator.snapshot(grant.childExecutionID), record.accountID == grant.accountID,
                  record.conversationID == grant.childConversationID else { throw RemotePeerError.unauthorized }
            let result = try await executions.latestDeliveryEnvelope(executionID: grant.childExecutionID)?.payload
            return try RemotePeerCoding.encode(RuntimePeerExecutionSnapshot(execution: record, result: result, workspaceTransfer: try await workspaceResult(grant, record)))
        case .interactions:
            return try RemotePeerCoding.encode(await coordinator.interactions(grant.childExecutionID))
        case .answer:
            struct Answer: Decodable { let id: String; let text: String }
            let value = try RemotePeerCoding.decode(Answer.self, request.payload)
            guard !value.text.isEmpty, value.text.utf8.count <= 32768 else { throw RemotePeerError.invalidEnvelope }
            try await coordinator.answer(executionID: grant.childExecutionID, id: value.id, text: value.text)
            return Data("{}".utf8)
        case .events:
            struct Cursor: Decodable { let after: Int64 }
            let cursor = try RemotePeerCoding.decode(Cursor.self, request.payload)
            guard cursor.after >= 0 else { throw RemotePeerError.invalidEnvelope }
            return try RemotePeerCoding.encode(await coordinator.events(grant.childExecutionID, after: cursor.after))
        case .pause, .resume, .cancel:
            return try RemotePeerCoding.encode(await coordinator.control(commandID: request.commandID,
                id: grant.childExecutionID, action: request.action.rawValue))
        case .correction:
            struct Correction: Decodable { let text: String; let sourceMessageID: UUID }
            let value = try RemotePeerCoding.decode(Correction.self, request.payload)
            guard !value.text.isEmpty, value.text.utf8.count <= 32768 else { throw RemotePeerError.invalidEnvelope }
            return try RemotePeerCoding.encode(await coordinator.control(commandID: request.commandID,
                id: grant.childExecutionID, action: "correct", text: value.text, sourceMessageID: value.sourceMessageID))
        case .approval:
            // Approval driver receipts are checked by the coordinator; uncertain
            // journal recovery must not grant a fresh authorization.
            struct Approval: Decodable { let id: UUID; let sessionID: UUID; let decision: ApprovalDecision }
            let value = try RemotePeerCoding.decode(Approval.self, request.payload)
            guard value.sessionID == grant.childExecutionID, value.decision != .allowForSession, value.decision != .allowAlways else { throw RemotePeerError.unauthorized }
            try await coordinator.approve(executionID: grant.childExecutionID, id: value.id, sessionID: value.sessionID, decision: value.decision)
            return Data("{}".utf8)
        }
    }
    package func revoke(_ grant: RemotePeerGrant) async {
        guard let record = try? await coordinator.snapshot(grant.childExecutionID), !record.state.isTerminal else { return }
        _ = try? await coordinator.control(commandID: UUID(), id: grant.childExecutionID, action: "pause")
    }
}

package struct RuntimePeerExecutionSnapshot: Codable, Sendable {
    package let execution: AgentExecution
    package let result: Data?
    package let workspaceTransfer: RemotePeerArtifactCommit?
}
