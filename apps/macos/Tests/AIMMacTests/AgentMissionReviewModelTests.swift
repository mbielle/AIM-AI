@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class AgentMissionReviewModelTests: XCTestCase {
    func testReviewFlowUpdatesVisibleMissionWithoutRewritingInterruptedAction() async throws {
        let database = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Interrupted fixture", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        let missions = SQLiteAgentMissionRepository(database: database)
        let runs = SQLiteWorkspaceRunRepository(database: database)
        var mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Create fixture")
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                               modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "uncertain", name: "write", arguments: [:])))
        try await runs.launched(runID: run.id, callID: "uncertain")
        try await runs.finish(runID: run.id, state: .failed)
        _ = try await missions.finalizeRun(missionID: mission.id, expectedRevision: mission.revision,
                                           runID: run.id)
        // The blocked run must remain reviewable even after it falls outside
        // the ordinary latest-ten history window.
        for _ in 0..<12 {
            let newer = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                                     modelID: "fixture", workspacePath: "")
            try await runs.begin(newer)
            try await runs.finish(runID: newer.id, state: .unverified)
        }

        let model = AppModel(database: database)
        await model.selectConversation(chat.id)
        await model.loadWorkspaceHistory()
        XCTAssertEqual(model.agentMission?.state, .blocked)
        XCTAssertEqual(model.workspaceHistory.count, 11)
        XCTAssertTrue(model.workspaceHistory.contains { $0.run.id == run.id })
        let recorded = await model.recordActionReview(callID: "uncertain", assessment: .observed,
                                                      note: "The target file is present")
        XCTAssertTrue(recorded)
        XCTAssertEqual(model.actionReconciliations.first?.assessment, .observed)
        let completed = await model.completeMissionReview(note: "Inspect the file before continuing")
        XCTAssertTrue(completed)
        XCTAssertEqual(model.agentMission?.state, .partial)
        XCTAssertTrue(model.messages.last?.content.contains("The target file is present") == true)
        let reviewedRun = try XCTUnwrap(model.workspaceHistory.first { $0.run.id == run.id })
        XCTAssertEqual(reviewedRun.calls.first?.state, .interrupted)
        XCTAssertTrue(reviewedRun.calls.first?.requiresReconciliation == true)
    }
}
