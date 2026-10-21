import AIMApplication
import GRDB
import XCTest

final class AgentMissionPersistenceTests: XCTestCase {
    func testNormalTurnPromotesOnlyCurrentFileEvidence() async throws {
        let verified = try await completionState(afterLaterAction: false)
        let partial = try await completionState(afterLaterAction: true)
        let corrected = try await completionState(afterLaterAction: false, pendingCorrection: true)
        XCTAssertEqual(verified, .verified)
        XCTAssertEqual(partial, .partial)
        XCTAssertEqual(corrected, .partial)
    }

    private func completionState(afterLaterAction: Bool,
                                 pendingCorrection: Bool = false) async throws -> AgentMissionState {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "completed report".write(to: workspace.appendingPathComponent("result.txt"),
                                     atomically: true, encoding: .utf8)
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Completion", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await repository.beginOrSteer(conversationID: chat.id, message: "Produce result")
        for input in try await repository.pendingInputs(missionID: mission.id) {
            try await repository.consumeInput(id: input.id, missionID: mission.id)
        }
        mission = try await repository.appendFileCriterion(missionID: mission.id,
            expectedRevision: mission.revision, description: "Result file exists with expected text",
            check: MissionFileCheck(relativePath: "result.txt", requiredText: "completed report"))
        let criterionID = try XCTUnwrap(mission.criteria.first?.id)
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI,
            modelID: "fixture", workspacePath: workspace.path)
        try await runs.begin(run)
        mission = try await repository.transition(missionID: mission.id, expectedRevision: mission.revision,
            to: .executing, reason: nil, activeRunID: run.id)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "verify", name: "mission_verify_file_criterion", arguments: [:])))
        try await runs.launched(runID: run.id, callID: "verify")
        mission = try await repository.verifyFileCriterion(missionID: mission.id,
            expectedRevision: mission.revision, criterionID: criterionID, workspacePath: workspace.path)
        try await runs.returned(runID: run.id,
            output: ModelToolOutput(id: "verify", content: "Host verified", isError: false))
        do {
            _ = try await repository.transition(missionID: mission.id, expectedRevision: mission.revision,
                to: .verified, reason: nil, activeRunID: nil)
            XCTFail("A still-running model turn cannot declare mission success")
        } catch AgentMissionError.missingEvidence {}
        if afterLaterAction {
            try await Task.sleep(for: .milliseconds(20))
            try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 1,
                call: ModelToolCall(id: "later", name: "write_file", arguments: [:])))
            try await runs.launched(runID: run.id, callID: "later")
            try await runs.returned(runID: run.id,
                output: ModelToolOutput(id: "later", content: "Action returned", isError: false))
        }
        if pendingCorrection {
            _ = try await repository.enqueueCorrection(conversationID: chat.id,
                message: "Change the required result before finishing")
        }
        try await runs.finish(runID: run.id, state: .unverified)
        let ended = try await AgentMissionCompletion.finalizeSuccessfulRun(repository: repository,
            missionID: mission.id, runID: run.id)
        return ended.state
    }

    func testFileCriterionNeedsCurrentHostEvidenceAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AIMDatabase(path: root.appendingPathComponent("missions.sqlite").path)
        let chat = Conversation(title: "File proof", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        let repository = SQLiteAgentMissionRepository(database: database)
        var mission = try await repository.beginOrSteer(conversationID: chat.id, message: "Create report")
        let inputs = try await repository.pendingInputs(missionID: mission.id)
        let input = try XCTUnwrap(inputs.first)
        try await repository.consumeInput(id: input.id, missionID: mission.id)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("report.txt")
        let check = MissionFileCheck(relativePath: "report.txt", requiredText: "expected result")
        mission = try await repository.appendFileCriterion(missionID: mission.id,
            expectedRevision: mission.revision, description: "Report contains expected result", check: check)
        let criterionID = try XCTUnwrap(mission.criteria.first?.id)
        mission = try await repository.transition(missionID: mission.id, expectedRevision: mission.revision,
            to: .executing, reason: nil, activeRunID: nil)
        do {
            _ = try await repository.verifyFileCriterion(missionID: mission.id,
                expectedRevision: mission.revision, criterionID: criterionID, workspacePath: workspace.path)
            XCTFail("A missing file cannot verify the criterion")
        } catch AgentMissionError.criterionNotMet {}
        try "Header\nexpected result\n".write(to: file, atomically: true, encoding: .utf8)
        mission = try await repository.verifyFileCriterion(missionID: mission.id,
            expectedRevision: mission.revision, criterionID: criterionID, workspacePath: workspace.path)
        let savedEvidence = try await repository.fileEvidence(missionID: mission.id, criterionID: criterionID)
        let evidence = try XCTUnwrap(savedEvidence)
        XCTAssertEqual(evidence.relativePath, "report.txt")
        XCTAssertEqual(evidence.byteCount, Int64("Header\nexpected result\n".utf8.count))
        XCTAssertEqual(evidence.sha256.count, 64)
        XCTAssertEqual(mission.criteria.first?.evidenceReference, evidence.id.uuidString)
        let revisionBeforeStop = mission.revision
        let missionID = mission.id
        let cancelled = Task { () throws -> AgentMission in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.verifyFileCriterion(missionID: missionID,
                expectedRevision: revisionBeforeStop, criterionID: criterionID,
                workspacePath: workspace.path)
        }
        switch await cancelled.result {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Stop must not record a new file receipt")
        }
        let afterStop = try await repository.load(id: mission.id)
        XCTAssertEqual(afterStop?.revision, revisionBeforeStop)
        try "Changed".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try await repository.transition(missionID: mission.id, expectedRevision: mission.revision,
                to: .verified, reason: nil, activeRunID: nil)
            XCTFail("A stale file receipt cannot verify a changed target")
        } catch AgentMissionError.missingEvidence {}
        try "expected result restored".write(to: file, atomically: true, encoding: .utf8)
        mission = try await repository.verifyFileCriterion(missionID: mission.id,
            expectedRevision: mission.revision, criterionID: criterionID, workspacePath: workspace.path)
        mission = try await repository.transition(missionID: mission.id, expectedRevision: mission.revision,
            to: .partial, reason: "Host file check finished outside a run.", activeRunID: nil)
        mission = try await repository.transition(missionID: mission.id, expectedRevision: mission.revision,
            to: .verified, reason: nil, activeRunID: nil)
        XCTAssertTrue(mission.isVerified)
        let reopened = SQLiteAgentMissionRepository(database: try AIMDatabase(path: root.appendingPathComponent("missions.sqlite").path))
        let loaded = try await reopened.load(id: mission.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertTrue(restored.isVerified)
        let restoredEvidence = try await reopened.fileEvidence(missionID: mission.id, criterionID: criterionID)
        XCTAssertEqual(restoredEvidence?.id.uuidString, restored.criteria.first?.evidenceReference)
    }

    func testFileCriterionRejectsSymlinkEscapeAndMatchesTextAcrossReadChunks() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let workspace = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside.txt")
        try "private match".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("link.txt"), withDestinationURL: outside)
        let inside = workspace.appendingPathComponent("inside.txt")
        try (String(repeating: "x", count: 65_534) + "🌍match")
            .write(to: inside, atomically: true, encoding: .utf8)
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Path evidence", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let repository = SQLiteAgentMissionRepository(database: db)
        var mission = try await repository.beginOrSteer(conversationID: chat.id, message: "Inspect files")
        mission = try await repository.appendFileCriterion(missionID: mission.id,
            expectedRevision: mission.revision, description: "Escaping link",
            check: MissionFileCheck(relativePath: "link.txt", requiredText: "private match"))
        let linkID = try XCTUnwrap(mission.criteria.last?.id)
        mission = try await repository.appendFileCriterion(missionID: mission.id,
            expectedRevision: mission.revision, description: "Unicode split across chunks",
            check: MissionFileCheck(relativePath: "inside.txt", requiredText: "🌍match"))
        let insideID = try XCTUnwrap(mission.criteria.last?.id)
        mission = try await repository.transition(missionID: mission.id,
            expectedRevision: mission.revision, to: .partial, reason: nil, activeRunID: nil)
        do {
            _ = try await repository.verifyFileCriterion(missionID: mission.id,
                expectedRevision: mission.revision, criterionID: linkID, workspacePath: workspace.path)
            XCTFail("A symlink must not escape the workspace")
        } catch AgentMissionError.criterionNotMet {}
        mission = try await repository.verifyFileCriterion(missionID: mission.id,
            expectedRevision: mission.revision, criterionID: insideID, workspacePath: workspace.path)
        XCTAssertNotNil(mission.criteria.last?.evidenceReference)
        XCTAssertNil(mission.criteria.first?.evidenceReference)
    }
    func testExplicitReviewUnlocksOnlyAfterEveryUncertainActionAndKeepsJournalIntact() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Review", mode: .agent)
        let conversations = SQLiteConversationRepository(database: db)
        try await conversations.save(chat)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Create fixture")
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                               modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "first", name: "write", arguments: [:])))
        try await runs.launched(runID: run.id, callID: "first")
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 1,
            call: ModelToolCall(id: "second", name: "send", arguments: [:])))
        try await runs.launched(runID: run.id, callID: "second")
        try await runs.finish(runID: run.id, state: .failed)
        mission = try await missions.finalizeRun(missionID: mission.id,
                                                expectedRevision: mission.revision, runID: run.id)
        XCTAssertEqual(mission.state, .blocked)
        do {
            _ = try await missions.completeReview(missionID: mission.id,
                                                   expectedRevision: mission.revision,
                                                   note: "Inspect before continuing")
            XCTFail("Every uncertain action needs an observation")
        } catch AgentMissionError.missingEvidence {}
        do {
            _ = try await missions.recordReconciliation(missionID: mission.id,
                expectedRevision: mission.revision, callID: "other", assessment: .observed,
                note: "Wrong call")
            XCTFail("A review cannot be attached to another action")
        } catch AgentMissionError.conflict {}
        mission = try await missions.recordReconciliation(missionID: mission.id,
            expectedRevision: mission.revision, callID: "first", assessment: .observed,
            note: "The fixture exists at the target")
        let recorded = try await missions.reconciliations(missionID: mission.id)
        XCTAssertEqual(recorded.map(\.callID), ["first"])
        XCTAssertEqual(recorded.first?.assessment, .observed)
        do {
            _ = try await missions.recordReconciliation(missionID: mission.id,
                expectedRevision: mission.revision, callID: "first", assessment: .notObserved,
                note: "Change assessment")
            XCTFail("A recorded observation cannot be silently overwritten")
        } catch AgentMissionError.conflict {}
        do {
            _ = try await missions.completeReview(missionID: mission.id,
                                                   expectedRevision: mission.revision,
                                                   note: "Continue")
            XCTFail("Second action remains uncertain")
        } catch AgentMissionError.missingEvidence {}
        mission = try await missions.recordReconciliation(missionID: mission.id,
            expectedRevision: mission.revision, callID: "second", assessment: .notObserved,
            note: "No message appears in the outbox")
        mission = try await missions.completeReview(missionID: mission.id,
                                                    expectedRevision: mission.revision,
                                                    note: "Check the current state before any further action")
        XCTAssertEqual(mission.state, .partial)
        XCTAssertNil(mission.activeRunID)
        let savedMessages = try await conversations.messages(conversationID: chat.id)
        let reviewMessage = try XCTUnwrap(savedMessages.last)
        XCTAssertTrue(reviewMessage.content.contains("The fixture exists at the target"))
        XCTAssertTrue(reviewMessage.content.contains("No message appears in the outbox"))
        XCTAssertTrue(reviewMessage.content.contains("not verified tool results"))
        let history = try await runs.history(conversationID: chat.id)
        XCTAssertTrue(history[0].calls.allSatisfy(\.requiresReconciliation))
        XCTAssertEqual(history[0].calls.map(\.state), [.interrupted, .interrupted])
        let continued = try await missions.beginOrSteer(conversationID: chat.id, message: "Continue")
        XCTAssertEqual(continued.state, .preparing)
        XCTAssertEqual(continued.id, mission.id)
    }

    func testPreparedOnlyCrashCanResumeWithoutEffectReview() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Review prepared", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Read fixture")
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                               modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "prepared", name: "read", arguments: [:])))
        let recovered = try await missions.recoverInterrupted()
        mission = try XCTUnwrap(recovered.first)
        XCTAssertEqual(mission.state, .partial)
        XCTAssertNil(mission.activeRunID)
        let history = try await runs.history(conversationID: chat.id)
        XCTAssertEqual(history.first?.calls.first?.state, .interrupted)
        XCTAssertEqual(history.first?.calls.first?.requiresReconciliation, false)
        let continued = try await missions.beginOrSteer(conversationID: chat.id, message: "Continue")
        XCTAssertEqual(continued.state, .preparing)
    }

    func testCrashAfterReturnedActionRequiresReviewBeforeAnotherTurn() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Returned action", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Create fixture")
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                               modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "created", name: "create_file", arguments: [:])))
        try await runs.launched(runID: run.id, callID: "created")
        try await runs.returned(runID: run.id,
            output: ModelToolOutput(id: "created", content: "File created", isError: false))
        let recovered = try await missions.recoverInterrupted()
        mission = try XCTUnwrap(recovered.first)
        XCTAssertEqual(mission.state, .blocked)
        XCTAssertEqual(mission.activeRunID, run.id)
        XCTAssertTrue(mission.stateReason?.contains("recorded result") == true)
        let history = try await runs.history(conversationID: chat.id)
        XCTAssertEqual(history.first?.calls.first?.state, .succeeded)
        XCTAssertEqual(history.first?.calls.first?.requiresReconciliation, false)
    }

    func testLegacyPreparedCallWithoutLaunchEvidenceStillBlocksRecovery() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Legacy action", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Change fixture")
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                               modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "old", name: "change", arguments: [:])))
        try await db.pool.write { database in
            try database.execute(sql: "UPDATE workspaceCalls SET executionEvidenceVersion = NULL WHERE runID = ? AND id = ?",
                                 arguments: [run.id, "old"])
        }
        let recovered = try await missions.recoverInterrupted()
        XCTAssertEqual(recovered.first?.state, .blocked)
        let history = try await runs.history(conversationID: chat.id)
        XCTAssertEqual(history.first?.calls.first?.requiresReconciliation, true)
    }

    func testCorrectionIsAtomicVisibleAndRetainedWhenRunEndsBeforeDelivery() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: db)
        let conversation = Conversation(title: "Live correction", mode: .agent)
        try await conversations.save(conversation)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: conversation.id, message: "Draft a note")
        let originalInputs = try await missions.pendingInputs(missionID: mission.id)
        let original = try XCTUnwrap(originalInputs.first)
        try await missions.consumeInput(id: original.id, missionID: mission.id)
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openAI,
                               modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        let correction = try await missions.enqueueCorrection(conversationID: conversation.id, message: "Use a friendly tone")
        XCTAssertEqual(correction.sequence, 0)
        let savedMessages = try await conversations.messages(conversationID: conversation.id)
        XCTAssertEqual(savedMessages.map(\.id), [correction.id])
        let queued = try await missions.pendingInputs(missionID: mission.id)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.conversationMessageID, correction.id)
        do {
            _ = try await missions.enqueueCorrection(conversationID: conversation.id, message: "\0invalid")
            XCTFail("Invalid correction must not leave a partial chat message")
        } catch AgentMissionError.invalidInput {}
        let afterInvalid = try await conversations.messages(conversationID: conversation.id)
        XCTAssertEqual(afterInvalid.count, 1)
        try await runs.finish(runID: run.id, state: .unverified)
        mission = try await missions.finalizeRun(missionID: mission.id,
                                                expectedRevision: mission.revision, runID: run.id)
        XCTAssertEqual(mission.state, .partial)
        XCTAssertTrue(mission.stateReason?.contains("correction") == true)
        let stillQueued = try await missions.pendingInputs(missionID: mission.id)
        XCTAssertEqual(stillQueued.map(\.id), [queued[0].id])
        do {
            _ = try await missions.enqueueCorrection(conversationID: conversation.id, message: "Too late")
            XCTFail("A closed run must not accept a live correction")
        } catch AgentMissionError.invalidTransition {}
    }

    func testMissionInputsAndCriteriaSurviveReopenWithoutClaimingSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("missions.sqlite").path
        let database = try AIMDatabase(path: path)
        let conversation = Conversation(title: "Durable mission", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let first = SQLiteAgentMissionRepository(database: database)
        var mission = try await first.beginOrSteer(conversationID: conversation.id, message: "Create the report")
        XCTAssertEqual(mission.state, .preparing)
        let initialInputs = try await first.pendingInputs(missionID: mission.id)
        let input = try XCTUnwrap(initialInputs.first)
        try await first.consumeInput(id: input.id, missionID: mission.id)
        mission = try await first.beginOrSteer(conversationID: conversation.id, message: "Use the revised figures")
        XCTAssertEqual(mission.objective, "Create the report")
        let pending = try await first.pendingInputs(missionID: mission.id)
        XCTAssertEqual(pending.map(\.content), ["Use the revised figures"])

        let criterion = AgentMissionCriterion(description: "Report exists at the requested location")
        mission = try await first.setCriteria(missionID: mission.id, expectedRevision: mission.revision,
                                               criteria: [criterion])
        do {
            _ = try await first.setCriteria(missionID: mission.id, expectedRevision: 0, criteria: [criterion])
            XCTFail("A stale revision must not overwrite current criteria")
        } catch AgentMissionError.conflict {}

        mission = try await first.transition(missionID: mission.id, expectedRevision: mission.revision,
                                             to: .executing, reason: nil, activeRunID: nil)
        do {
            _ = try await first.transition(missionID: mission.id, expectedRevision: mission.revision,
                                           to: .verified, reason: nil, activeRunID: nil)
            XCTFail("Model completion is not a verification receipt")
        } catch AgentMissionError.missingEvidence {}
        mission = try await first.transition(missionID: mission.id, expectedRevision: mission.revision,
                                             to: .partial, reason: "The model ended without host verification.", activeRunID: nil)
        let reopened = SQLiteAgentMissionRepository(database: try AIMDatabase(path: path))
        let loaded = try await reopened.load(id: mission.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.state, .partial)
        XCTAssertFalse(restored.isVerified)
        let restoredInputs = try await reopened.pendingInputs(missionID: mission.id)
        XCTAssertEqual(restoredInputs.map(\.content), ["Use the revised figures"])
    }

    func testCrashPreservesLaunchedActionAsUnknownAndBlocksAutomaticResume() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Crash", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: conversation.id, message: "Write the document")
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openAI, modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "prepared", name: "write", arguments: [:])))
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 1,
            call: ModelToolCall(id: "launched", name: "write", arguments: [:])))
        try await runs.launched(runID: run.id, callID: "launched")

        let recovered = try await missions.recoverInterrupted()
        XCTAssertEqual(recovered.map(\.id), [mission.id])
        XCTAssertEqual(recovered.first?.state, .blocked)
        XCTAssertEqual(recovered.first?.activeRunID, run.id)
        XCTAssertTrue(recovered.first?.stateReason?.contains("no recorded result") == true)
        let recoveredAgain = try await missions.recoverInterrupted()
        XCTAssertTrue(recoveredAgain.isEmpty)
        let history = try await runs.history(conversationID: conversation.id)
        XCTAssertEqual(history.first?.run.state, .failed)
        XCTAssertEqual(history.first?.calls[0].requiresReconciliation, false)
        XCTAssertEqual(history.first?.calls[1].requiresReconciliation, true)
        XCTAssertEqual(history.first?.calls.map(\.state), [.interrupted, .interrupted])
        let steered = try await missions.beginOrSteer(conversationID: conversation.id, message: "Please continue")
        XCTAssertEqual(steered.state, .blocked)
        do {
            _ = try await missions.transition(missionID: steered.id, expectedRevision: steered.revision,
                                              to: .executing, reason: nil, activeRunID: nil)
            XCTFail("An unknown effect requires explicit reconciliation")
        } catch AgentMissionError.invalidTransition {}
    }

    func testRunFinalizationDistinguishesUnverifiedFromUnknownEffect() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Results", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: conversation.id, message: "Produce result")
        let firstRun = WorkspaceRun(conversationID: conversation.id, provider: .openAI, modelID: "fixture", workspacePath: "")
        try await runs.begin(firstRun)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: firstRun.id)
        try await runs.finish(runID: firstRun.id, state: .unverified)
        mission = try await missions.finalizeRun(missionID: mission.id,
                                                 expectedRevision: mission.revision, runID: firstRun.id)
        XCTAssertEqual(mission.state, .partial)
        XCTAssertFalse(mission.isVerified)

        mission = try await missions.beginOrSteer(conversationID: conversation.id, message: "Continue")
        XCTAssertEqual(mission.state, .preparing)
        let secondRun = WorkspaceRun(conversationID: conversation.id, provider: .openAI, modelID: "fixture", workspacePath: "")
        try await runs.begin(secondRun)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: secondRun.id)
        try await runs.requested(WorkspaceCall(runID: secondRun.id, ordinal: 0,
            call: ModelToolCall(id: "mutating", name: "write", arguments: [:])))
        try await runs.launched(runID: secondRun.id, callID: "mutating")
        try await runs.finish(runID: secondRun.id, state: .cancelled)
        mission = try await missions.finalizeRun(missionID: mission.id,
                                                 expectedRevision: mission.revision, runID: secondRun.id)
        XCTAssertEqual(mission.state, .blocked)
        XCTAssertEqual(mission.activeRunID, secondRun.id)
        XCTAssertTrue(mission.stateReason?.contains("may have taken effect") == true)
    }

    func testCompletedUnverifiedActionRequiresFreshApprovalInLaterRun() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Mail retry", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        let mission = try await missions.beginOrSteer(conversationID: conversation.id,
            message: "Send one message")
        let run = WorkspaceRun(conversationID: conversation.id, provider: .openAI,
            modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "send-1", name: "mail_send",
                jsonArguments: ["subject": .string("Hello"),
                                "to": .array([.string("user@example.com")])])))
        try await runs.launched(runID: run.id, callID: "send-1")
        try await runs.returned(runID: run.id, output: ModelToolOutput(id: "send-1",
            content: "Mail accepted the request", isError: false,
            metadata: ["action_outcome": "unverified"]))
        try await runs.finish(runID: run.id, state: .unverified)

        let matching = try await missions.wasUncertainAction(missionID: mission.id, name: "mail_send",
            arguments: ["subject": .string("Hello"), "to": .array([.string("user@example.com")])])
        let different = try await missions.wasUncertainAction(missionID: mission.id, name: "mail_send",
            arguments: ["subject": .string("Different"), "to": .array([.string("user@example.com")])])
        XCTAssertTrue(matching)
        XCTAssertFalse(different)
    }

    func testCrashBeforeRunJournalCanContinueAsPartial() async throws {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Prepared", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        let missions = SQLiteAgentMissionRepository(database: db)
        let started = try await missions.beginOrSteer(conversationID: conversation.id, message: "Review fixture")
        let recovered = try await missions.recoverInterrupted()
        XCTAssertEqual(recovered.first?.id, started.id)
        XCTAssertEqual(recovered.first?.state, .partial)
        XCTAssertNil(recovered.first?.activeRunID)
        let steered = try await missions.beginOrSteer(conversationID: conversation.id, message: "Continue")
        XCTAssertEqual(steered.state, .preparing)
    }
}
