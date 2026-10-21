import XCTest
@testable import AIMApplication

final class CheckpointMissionRecoveryTests: XCTestCase {
    func testHostCheckpointRecoversJournalWithoutInventingApprovalOrSuccess() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Checkpoint mission", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let missions = SQLiteAgentMissionRepository(database: database)
        let runs = SQLiteWorkspaceRunRepository(database: database)
        let executions = SQLiteAgentExecutionRepository(database: database)
        let owner = UUID(); try await executions.installOwner(owner)
        let execution = try await executions.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id,
                                                                 request: Data()), owner: owner)
        _ = try await executions.transition(execution.id, owner: owner, expectedRevision: 0, to: .running)
        var mission = try await missions.beginOrSteer(conversationID: conversation.id, message: "Write report")
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openRouter, modelID: "fixture", workspacePath: "/tmp")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        let call = ModelToolCall(id: "edit", name: "apply_edit", arguments: ["id": "proposal"])
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0, call: call))
        try await runs.launched(runID: run.id, callID: call.id)
        var effect = ExecutionEffect(call: call, policy: .reconcile)
        effect.state = .returned; effect.wasLaunched = true
        effect.output = ModelToolOutput(id: call.id, content: "Observed exact file", isError: false,
                                       metadata: ["action_outcome": "confirmed", "reconciled_by": "host_file_observation"])
        let checkpoint = ExecutionCheckpoint(conversation: ModelConversationCheckpoint(codec: "native-v1", provider: .openRouter,
            modelID: "fixture", transcript: Data("[]".utf8), pendingIDs: [call.id], seenIDs: [call.id], finished: false, usage: TokenUsage()),
            turn: ModelToolTurn(text: "", calls: [call]), effects: [effect], ordinal: 1, seenCallIDs: [call.id],
            missionID: mission.id, workspaceRunID: run.id)
        _ = try await missions.recoverInterrupted()
        let prepared = try await missions.restoreExecution(checkpoint, executionID: execution.id, owner: owner, conversationID: conversation.id)
        XCTAssertEqual(prepared.state, .preparing); XCTAssertFalse(prepared.isVerified)
        let reconciliations = try await missions.reconciliations(missionID: mission.id)
        XCTAssertTrue(reconciliations.isEmpty, "A host recovery must not fabricate a human review")
        let restoredRun = try await runs.run(id: run.id)
        XCTAssertEqual(restoredRun?.calls.first?.state, .succeeded)
        XCTAssertEqual(restoredRun?.calls.first?.result, "Observed exact file")
        _ = try await missions.transition(missionID: mission.id, expectedRevision: prepared.revision,
                                         to: .suspendedHuman, reason: "User paused", activeRunID: nil)
        do { _ = try await missions.restoreExecution(checkpoint, executionID: execution.id, owner: owner, conversationID: conversation.id); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .invalidTransition) }
        let nextOwner = UUID(); try await executions.installOwner(nextOwner)
        do { _ = try await missions.restoreExecution(checkpoint, executionID: execution.id, owner: owner, conversationID: conversation.id); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
    }
}
