import AIMApplication
import XCTest

private struct ScriptedChecks: MissionHostCheckRunning {
    let satisfied: Bool
    func observe(_ check: MissionHostCheck, workspacePath: String?) async throws -> MissionCheckObservation {
        MissionCheckObservation(satisfied: satisfied, digest: "digest-\(satisfied)",
            summary: satisfied ? "holds" : "does not hold")
    }
}

final class MissionHostCheckTests: XCTestCase {
    func testHostCheckValidation() {
        XCTAssertTrue(MissionHostCheck(kind: .command, executable: "/usr/bin/true").isValid)
        XCTAssertFalse(MissionHostCheck(kind: .command, executable: "true").isValid, "Executables are absolute")
        XCTAssertTrue(MissionHostCheck(kind: .web, url: "https://example.com/status", requiredText: "OK").isValid)
        XCTAssertFalse(MissionHostCheck(kind: .web, url: "file:///etc/hosts", requiredText: "x").isValid)
        XCTAssertFalse(MissionHostCheck(kind: .web, url: "https://user:pw@example.com", requiredText: "x").isValid)
        XCTAssertFalse(MissionHostCheck(kind: .web, url: "https://example.com").isValid, "Web needs required text")
        XCTAssertTrue(MissionHostCheck(kind: .desktop, bundleID: "com.apple.TextEdit", requiredText: "Done").isValid)
        XCTAssertFalse(MissionHostCheck(kind: .desktop, bundleID: "com.apple.TextEdit; rm", requiredText: "x").isValid)
        XCTAssertFalse(MissionHostCheck(kind: .command, executable: "/usr/bin/true", timeoutSeconds: 601).isValid)
    }

    func testCompletionReobservesHostChecksAfterTheLastAction() async throws {
        let holds = try await completion(runner: ScriptedChecks(satisfied: true))
        let fails = try await completion(runner: ScriptedChecks(satisfied: false))
        let unchecked = try await completion(runner: nil)
        XCTAssertEqual(holds, .verified)
        XCTAssertEqual(fails, .partial)
        XCTAssertEqual(unchecked, .partial, "An earlier receipt is not enough after a later action")
    }

    private func completion(runner: (any MissionHostCheckRunning)?) async throws -> AgentMissionState {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Checks", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await repository.beginOrSteer(conversationID: chat.id, message: "Make the build pass")
        for input in try await repository.pendingInputs(missionID: mission.id) {
            try await repository.consumeInput(id: input.id, missionID: mission.id)
        }
        mission = try await repository.appendHostCriterion(missionID: mission.id, expectedRevision: mission.revision,
            description: "Build succeeds", check: MissionHostCheck(kind: .command, executable: "/usr/bin/true"))
        let criterionID = try XCTUnwrap(mission.criteria.first?.id)
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI, modelID: "fixture", workspacePath: "/tmp")
        try await runs.begin(run)
        mission = try await repository.transition(missionID: mission.id, expectedRevision: mission.revision,
            to: .executing, reason: nil, activeRunID: run.id)
        // An early receipt, then a later action that could have changed the outcome.
        mission = try await repository.recordHostCheck(missionID: mission.id, expectedRevision: mission.revision,
            criterionID: criterionID, observation: MissionCheckObservation(satisfied: true, digest: "early",
                summary: "held earlier"), expectedRunID: run.id)
        try await Task.sleep(for: .milliseconds(20))
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "edit", name: "apply_edit", arguments: [:])))
        try await runs.launched(runID: run.id, callID: "edit")
        try await runs.returned(runID: run.id, output: ModelToolOutput(id: "edit", content: "ok", isError: false))
        try await runs.finish(runID: run.id, state: .unverified)
        let ended = try await AgentMissionCompletion.finalizeSuccessfulRun(repository: repository,
            missionID: mission.id, runID: run.id, hostChecks: runner, workspacePath: "/tmp")
        return ended.state
    }

    func testUnsatisfiedObservationIsNeverStored() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Checks", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteAgentMissionRepository(database: db)
        var mission = try await repository.beginOrSteer(conversationID: chat.id, message: "Ship")
        mission = try await repository.appendHostCriterion(missionID: mission.id, expectedRevision: mission.revision,
            description: "Page live", check: MissionHostCheck(kind: .web, url: "https://example.com", requiredText: "Live"))
        let criterionID = try XCTUnwrap(mission.criteria.first?.id)
        mission = try await repository.transition(missionID: mission.id, expectedRevision: mission.revision,
            to: .executing, reason: nil, activeRunID: UUID().uuidString)
        do {
            _ = try await repository.recordHostCheck(missionID: mission.id, expectedRevision: mission.revision,
                criterionID: criterionID, observation: MissionCheckObservation(satisfied: false, digest: "x", summary: "no"),
                expectedRunID: nil)
            XCTFail("A failed observation is not a receipt")
        } catch AgentMissionError.criterionNotMet {}
        let evidence = try await repository.hostEvidence(missionID: mission.id, criterionID: criterionID)
        XCTAssertNil(evidence)
    }
}
