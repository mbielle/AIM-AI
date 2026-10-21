import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import XCTest

final class AgentMissionEvidenceToolTests: XCTestCase {
    func testCriterionDefinitionNeedsExactApprovalAndVerificationReadsCurrentFile() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Evidence", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteAgentMissionRepository(database: db)
        var mission = try await repository.beginOrSteer(conversationID: chat.id, message: "Create an exact report")
        let initial = try await repository.pendingInputs(missionID: mission.id)
        for input in initial { try await repository.consumeInput(id: input.id, missionID: mission.id) }
        let runID = UUID().uuidString
        mission = try await repository.transition(missionID: mission.id,
            expectedRevision: mission.revision, to: .executing, reason: nil, activeRunID: runID)
        let service = AgentMissionEvidenceToolService(repository: repository,
            conversationID: chat.id, workspacePath: workspace.path)
        try await service.bind(missionID: mission.id, runID: runID)
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [
            RegisteredTool(name: "mission_define_file_criterion", risk: .missionDefinition,
                requiredArguments: ["description", "path"], optionalArguments: ["required_text"], executor: service),
            RegisteredTool(name: "mission_verify_file_criterion", risk: .localMutation,
                requiredArguments: ["criterion_id"], executor: service)
        ], broker: broker, policy: .autoApprove, workspacePath: workspace.path)
        let arguments = ["description": "Report has the requested result",
                         "path": "report.txt", "required_text": "approved result"]
        let denied = Task { await dispatcher.execute(id: "deny", name: "mission_define_file_criterion",
                                                      arguments: arguments) }
        let deniedApproval = try await pending(broker)
        XCTAssertFalse(deniedApproval.allowsSessionDecision)
        await broker.decide(id: deniedApproval.id, sessionID: deniedApproval.sessionID, decision: .deny)
        let deniedResult = await denied.value
        XCTAssertTrue(deniedResult.isError)
        let afterDenial = try await repository.load(id: mission.id)
        XCTAssertTrue(afterDenial?.criteria.isEmpty == true)

        let accepted = Task { await dispatcher.execute(id: "accept", name: "mission_define_file_criterion",
                                                        arguments: arguments) }
        let approval = try await pending(broker)
        XCTAssertEqual(approval.arguments["path"], "report.txt")
        await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: .allowOnce)
        let defined = await accepted.value
        XCTAssertFalse(defined.isError)
        let criterionID = try XCTUnwrap(defined.metadata["criterion_id"])
        try "approved result\n".write(to: workspace.appendingPathComponent("report.txt"),
                                       atomically: true, encoding: .utf8)
        let verified = await dispatcher.execute(id: "verify", name: "mission_verify_file_criterion",
            arguments: ["criterion_id": criterionID])
        XCTAssertFalse(verified.isError)
        XCTAssertEqual(verified.actionOutcome, .confirmed)
        let saved = try await repository.load(id: mission.id)
        XCTAssertNotNil(saved?.criteria.first?.evidenceReference)
        let paused = try await repository.transition(missionID: mission.id, expectedRevision: saved!.revision,
            to: .partial, reason: "Pause", activeRunID: nil)
        let stale = await dispatcher.execute(id: "stale", name: "mission_verify_file_criterion",
            arguments: ["criterion_id": criterionID])
        XCTAssertTrue(stale.isError)
        _ = try await repository.transition(missionID: mission.id, expectedRevision: paused.revision,
            to: .executing, reason: nil, activeRunID: UUID().uuidString)
        let olderRun = await dispatcher.execute(id: "older-run", name: "mission_verify_file_criterion",
            arguments: ["criterion_id": criterionID])
        XCTAssertTrue(olderRun.isError)
        await dispatcher.close()
    }

    private func pending(_ broker: ToolApprovalBroker) async throws -> PendingToolApproval {
        for _ in 0..<200 {
            if let value = await broker.snapshot().first { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AgentMissionError.conflict
    }
}
