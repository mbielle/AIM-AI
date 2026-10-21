import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import XCTest

final class WorkspaceEditToolTests: XCTestCase {
    func testMissionFolderScopeAppliesOnlyToPreparedFileInsideThatFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-scope-edit-\(UUID())")
            .resolvingSymlinksInPath()
        let allowed = root.appendingPathComponent("allowed")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedFile = allowed.appendingPathComponent("note.txt")
        let otherFile = other.appendingPathComponent("note.txt")
        try "before".write(to: allowedFile, atomically: true, encoding: .utf8)
        try "before".write(to: otherFile, atomically: true, encoding: .utf8)

        let database = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Scoped file edit", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        let missions = SQLiteAgentMissionRepository(database: database)
        let mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Edit allowed note")
        let folder = try MissionResource(kind: .directory, identifier: allowed.path)
        let rule = try MissionAuthorizationRule(resource: folder, operations: [.edit])
        _ = try await missions.replaceAuthorization(missionID: mission.id, expectedRevision: nil, rules: [rule])

        let executor = WorkspaceEditToolService(), broker = ToolApprovalBroker()
        func preparedID(_ path: String) async throws -> String {
            let result = await executor.execute(ToolRequest(name: "propose_edit",
                arguments: ["path": path, "old": "before", "new": "after"],
                risk: .readOnly, workspacePath: root.path))
            XCTAssertFalse(result.isError)
            return try XCTUnwrap(result.metadata["proposal_id"])
        }
        let allowedID = try await preparedID("allowed/note.txt")
        let outsideID = try await preparedID("other/note.txt")
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "apply_edit",
            risk: .localMutation, requiredArguments: ["proposal_id"], executor: executor)],
            broker: broker, policy: .autoApprove, workspacePath: root.path,
            missionRepository: missions, missionID: mission.id)
        let inside = await dispatcher.execute(id: "inside", name: "apply_edit", arguments: ["proposal_id": allowedID])
        XCTAssertFalse(inside.isError)
        XCTAssertEqual(try String(contentsOf: allowedFile, encoding: .utf8), "after")
        let noApproval = await broker.snapshot()
        XCTAssertTrue(noApproval.isEmpty)

        let outsideTask = Task { await dispatcher.execute(id: "outside", name: "apply_edit",
            arguments: ["proposal_id": outsideID]) }
        let approval = try await pending(broker)
        XCTAssertEqual(approval.review?.path, "other/note.txt")
        XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), "before")
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
        let denied = await outsideTask.value
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), "before")
        await dispatcher.close()
    }

    func testNewFileReviewDistinguishesAbsenceFromEmptyFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = WorkspaceEditToolService()
        let prepared = await executor.execute(ToolRequest(name: "propose_file", arguments: ["path": "empty.txt", "content": ""], risk: .readOnly, workspacePath: root.path))
        let id = try XCTUnwrap(prepared.metadata["proposal_id"])
        let apply = ToolRequest(name: "apply_edit", arguments: ["proposal_id": id], risk: .localMutation, workspacePath: root.path)
        let intent = try await executor.missionIntent(for: apply)
        XCTAssertEqual(intent?.operation, .edit)
        XCTAssertEqual(intent?.target.identifier, root.appendingPathComponent("empty.txt").path)
        let review = try await executor.review(apply)
        XCTAssertEqual(review?.beforeExists, false)
        XCTAssertEqual(review?.afterExists, true)
        let applied = await executor.execute(apply)
        XCTAssertFalse(applied.isError)
        let undo = ToolRequest(name: "undo_edit", arguments: ["proposal_id": id], risk: .localMutation, workspacePath: root.path)
        let undoReview = try await executor.review(undo)
        XCTAssertEqual(undoReview?.beforeExists, true)
        XCTAssertEqual(undoReview?.afterExists, false)
    }

    func testAutomaticPolicyCannotSkipSensitiveEditReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".env")
        try Data("before".utf8).write(to: file)
        let executor = WorkspaceEditToolService(), broker = ToolApprovalBroker()
        let prepared = await executor.execute(ToolRequest(name: "propose_edit", arguments: ["path": ".env", "old": "before", "new": "after"], risk: .readOnly, workspacePath: root.path))
        let id = try XCTUnwrap(prepared.metadata["proposal_id"])
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "apply_edit", risk: .localMutation, requiredArguments: ["proposal_id"], executor: executor)], broker: broker, policy: .autoApprove, workspacePath: root.path)
        let task = Task { await dispatcher.execute(id: "apply", name: "apply_edit", arguments: ["proposal_id": id]) }
        let approval = try await pending(broker)
        XCTAssertNotNil(approval.review)
        await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: .deny)
        let result = await task.value
        XCTAssertTrue(result.isError)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
        await dispatcher.close()
    }

    private func pending(_ broker: ToolApprovalBroker) async throws -> PendingToolApproval {
        for _ in 0..<200 {
            if let value = await broker.snapshot().first { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WorkspaceEditService.EditError.unknownProposal
    }

    func testPreparedReviewApprovalAndUndoAreBoundToExactFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("Hello world".utf8).write(to: file)
        let executor = WorkspaceEditToolService(), broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [
            RegisteredTool(name: "propose_edit", risk: .readOnly, requiredArguments: ["path", "old", "new"], executor: executor),
            RegisteredTool(name: "apply_edit", risk: .localMutation, requiredArguments: ["proposal_id"], executor: executor),
            RegisteredTool(name: "undo_edit", risk: .localMutation, requiredArguments: ["proposal_id"], executor: executor)
        ], broker: broker, policy: .alwaysAsk, workspacePath: root.path)
        let preparation = Task { await dispatcher.execute(id: "prepare", name: "propose_edit", arguments: ["path": "sample.txt", "old": "world", "new": "Mac"]) }
        let readApproval = try await pending(broker)
        XCTAssertNil(readApproval.review)
        await broker.decide(id: readApproval.id, sessionID: readApproval.sessionID, decision: .allowOnce)
        let prepared = await preparation.value
        let id = try XCTUnwrap(prepared.metadata["proposal_id"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Hello world")
        let cancelled = Task { await dispatcher.execute(id: "cancelled", name: "apply_edit", arguments: ["proposal_id": id]) }
        _ = try await pending(broker)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertTrue(cancelledResult.isError)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Hello world")
        for (callID, decision) in [("denied", ApprovalDecision.deny), ("apply", .allowOnce)] {
            let task = Task { await dispatcher.execute(id: callID, name: "apply_edit", arguments: ["proposal_id": id]) }
            let approval = try await pending(broker)
            XCTAssertEqual(approval.review?.before, "Hello world")
            XCTAssertEqual(approval.review?.after, "Hello Mac")
            XCTAssertFalse(approval.allowsSessionDecision)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Hello world")
            await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: decision)
            let result = await task.value
            XCTAssertEqual(result.isError, decision == .deny)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Hello Mac")
        let undo = Task { await dispatcher.execute(id: "undo", name: "undo_edit", arguments: ["proposal_id": id]) }
        let approval = try await pending(broker)
        XCTAssertEqual(approval.review?.before, "Hello Mac")
        XCTAssertEqual(approval.review?.after, "Hello world")
        // An external change after review must survive even an explicit approval.
        try Data("User's newer work".utf8).write(to: file)
        await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: .allowOnce)
        let undone = await undo.value
        XCTAssertTrue(undone.isError)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "User's newer work")
        await dispatcher.close()
    }

    func testUnknownProposalsAndPlanCannotRequestMutationApproval() async throws {
        let executor = WorkspaceEditToolService(), broker = ToolApprovalBroker()
        for policy in [ApprovalPolicy.plan, .alwaysAsk] {
            let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "apply_edit", risk: .localMutation, requiredArguments: ["proposal_id"], executor: executor)], broker: broker, policy: policy, workspacePath: "/fixture")
            let result = await dispatcher.execute(id: "invalid", name: "apply_edit", arguments: ["proposal_id": UUID().uuidString])
            XCTAssertTrue(result.isError)
            let approvals = await broker.snapshot()
            XCTAssertTrue(approvals.isEmpty)
            await dispatcher.close()
        }
    }
}
