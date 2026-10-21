import AIMAgentKit
import AIMApplication
import AIMMacPlatform
@testable import AIMAgentRuntime
import XCTest

private actor ContinuityFixtureDriver: ContinuityTurnDriving {
    var calls = 0
    let outcome: @Sendable (Int, RuntimeExecutionContext) throws -> ContinuityTurnOutcome
    init(outcome: @escaping @Sendable (Int, RuntimeExecutionContext) throws -> ContinuityTurnOutcome) { self.outcome = outcome }
    func run(_ request: AgentRequest, context: RuntimeExecutionContext,
             event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
        calls += 1
        return try outcome(calls, context)
    }
    func cancel(conversationID: UUID) async {}
}

final class RunCoordinatorTests: XCTestCase {
    private func fixture(_ driver: ContinuityFixtureDriver) async throws -> (RunCoordinator, SQLiteAgentExecutionRepository, AgentRequest, RuntimeLease, URL) {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "continuity", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        let repository = SQLiteAgentExecutionRepository(database: db)
        let path = FileManager.default.temporaryDirectory.appending(path: "aim-lease-\(UUID())")
        let lease = try RuntimeLease(url: path)
        let coordinator = RunCoordinator(repository: repository, driver: driver, lease: lease, authorized: { _ in true })
        try await coordinator.start()
        return (coordinator, repository, AgentRequest(conversationID: conversation.id, text: "Build the result", modelID: "fake", mode: .agent, workspaceToolsEnabled: true), lease, path)
    }
    private func settled(_ coordinator: RunCoordinator, id: UUID, state: ExecutionState) async throws -> AgentExecution {
        for _ in 0..<200 {
            if let value = try await coordinator.snapshot(id), value.state == state { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Execution did not reach \(state)")
        throw ExecutionStoreError.invalidTransition
    }
    func testDeliveredAnswerEndsTheTaskAndDeliverySurvivesReconnect() async throws {
        let driver = ContinuityFixtureDriver { _, _ in .completed(result: Data("delivered".utf8)) }
        let (coordinator, repository, request, lease, path) = try await fixture(driver)
        defer { lease.release(); try? FileManager.default.removeItem(at: path) }
        let command = UUID()
        let admitted = try await coordinator.admit(commandID: command, accountID: nil, request: request)
        let duplicate = try await coordinator.admit(commandID: command, accountID: nil, request: request)
        XCTAssertEqual(admitted.id, duplicate.id)
        // Like ChatGPT or Codex: no acceptance is asked once the answer is delivered.
        let finished = try await settled(coordinator, id: admitted.id, state: .accepted)
        XCTAssertEqual(finished.reason, "Completed.")
        let deliveries = try await repository.pendingDeliveries()
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.payload, Data("delivered".utf8))
        let count = await driver.calls; XCTAssertEqual(count, 1)
    }
    func testPrematureFinalContinuesWithoutGlobalQuota() async throws {
        let driver = ContinuityFixtureDriver { count, _ in
            count < 250 ? .continueObjective(progress: String(count)) : .completed(result: Data("done".utf8))
        }
        let (coordinator, _, request, lease, path) = try await fixture(driver)
        defer { lease.release(); try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        _ = try await settled(coordinator, id: admitted.id, state: .accepted)
        let calls = await driver.calls; XCTAssertEqual(calls, 250)
    }
    func testRepeatedLackOfProgressBlocksWithReason() async throws {
        let driver = ContinuityFixtureDriver { _, _ in .continueObjective(progress: "same") }
        let (coordinator, _, request, lease, path) = try await fixture(driver)
        defer { lease.release(); try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        let record = try await settled(coordinator, id: admitted.id, state: .blocked)
        XCTAssertTrue(record.reason?.contains("without observable progress") == true)
        let count = await driver.calls; XCTAssertEqual(count, 3)
    }
    func testThreeDayWaitHasNoModelCallsAndSurvivesOwnerRestart() async throws {
        let due = Date.now.addingTimeInterval(72 * 3600)
        let driver = ContinuityFixtureDriver { count, context in
            count == 1 ? .wait(WakeCondition(executionID: context.executionID, kind: .deadline, key: "later", dueAt: due)) : .completed(result: Data("awake".utf8))
        }
        let (coordinator, repository, request, lease, path) = try await fixture(driver)
        defer { try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        _ = try await settled(coordinator, id: admitted.id, state: .waitingEvent)
        for hour in 1..<72 { try await coordinator.tick(at: due.addingTimeInterval(Double(hour - 72) * 3600)) }
        let count = await driver.calls; XCTAssertEqual(count, 1)
        lease.release() // Simulated process death: no shutdown/pause transition.
        let replacementLease = try RuntimeLease(url: path)
        defer { replacementLease.release() }
        let replacement = RunCoordinator(repository: repository, driver: driver, lease: replacementLease, authorized: { _ in true })
        try await replacement.start()
        try await replacement.tick(at: due)
        _ = try await settled(replacement, id: admitted.id, state: .accepted)
        let after = await driver.calls; XCTAssertEqual(after, 2)
    }
    func testSubagentsCanArchiveTheirHistoryWhileTheParentWaitsForThem() async throws {
        let driver = ContinuityFixtureDriver { _, context in .wait(WakeCondition(executionID: context.executionID, kind: .subagent, key: "children")) }
        let (coordinator, repository, request, lease, path) = try await fixture(driver)
        defer { lease.release(); try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        _ = try await settled(coordinator, id: admitted.id, state: .waitingEvent)
        // This refusal used to stop every sub-agent whose history needed compacting.
        try await repository.archiveConversation(executionID: admitted.id, content: Data("[]".utf8), owner: lease.generation)
        let archives = try await repository.archivedConversations(executionID: admitted.id)
        XCTAssertEqual(archives.count, 1)
    }

    func testRunInterruptedBeforeAnyActionWaitsForThePersonInsteadOfNeedingInspection() async throws {
        let driver = ContinuityFixtureDriver { _, context in .wait(WakeCondition(executionID: context.executionID, kind: .folder, key: "never")) }
        let (coordinator, repository, request, lease, path) = try await fixture(driver)
        defer { try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        let waiting = try await settled(coordinator, id: admitted.id, state: .waitingEvent)
        // The app stops while the first turn runs: no checkpoint was written.
        _ = try await repository.transition(admitted.id, owner: lease.generation, expectedRevision: waiting.revision, to: .running)
        let checkpoint = try await repository.checkpoint(admitted.id); XCTAssertNil(checkpoint)
        lease.release()
        let replacementLease = try RuntimeLease(url: path)
        defer { replacementLease.release() }
        let replacement = RunCoordinator(repository: repository, driver: driver, lease: replacementLease, authorized: { _ in true })
        try await replacement.start()
        let record = try await replacement.snapshot(admitted.id)
        XCTAssertEqual(record?.state, .waitingUser)
        XCTAssertEqual(record?.reason, "Interrupted before any action. Nothing was changed.")
        let calls = await driver.calls; XCTAssertEqual(calls, 1, "nothing is resent without the person")
    }
    func testClosingAIMPausesActiveTasksAndReopeningResumesThem() async throws {
        let driver = ContinuityFixtureDriver { _, context in .wait(WakeCondition(executionID: context.executionID, kind: .folder, key: "files")) }
        let (coordinator, repository, request, lease, path) = try await fixture(driver)
        defer { try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        _ = try await settled(coordinator, id: admitted.id, state: .waitingEvent)
        try await coordinator.shutdown()
        let closed = try await repository.execution(admitted.id)
        XCTAssertEqual(closed?.state, .paused)
        XCTAssertEqual(closed?.reason, RunCoordinator.closedReason)
        let replacementLease = try RuntimeLease(url: path)
        defer { replacementLease.release() }
        let replacement = RunCoordinator(repository: repository, driver: driver, lease: replacementLease, authorized: { _ in true })
        try await replacement.start()
        _ = try await settled(replacement, id: admitted.id, state: .waitingEvent)
        let calls = await driver.calls; XCTAssertEqual(calls, 2, "the task continued on its own")
    }

    func testDeliveryCompletesTheMessageTheAppAlreadySaved() async throws {
        let driver = ContinuityFixtureDriver { call, context in
            call == 1 ? .wait(WakeCondition(executionID: context.executionID, kind: .folder, key: "files")) : .completed(result: Data("Final report.".utf8))
        }
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "continuity", mode: .agent)
        let conversations = SQLiteConversationRepository(database: db)
        try await conversations.save(conversation)
        let repository = SQLiteAgentExecutionRepository(database: db)
        let path = FileManager.default.temporaryDirectory.appending(path: "aim-lease-\(UUID())")
        let lease = try RuntimeLease(url: path)
        defer { lease.release(); try? FileManager.default.removeItem(at: path) }
        let coordinator = RunCoordinator(repository: repository, driver: driver, lease: lease, authorized: { _ in true })
        try await coordinator.start()
        let request = AgentRequest(conversationID: conversation.id, text: "Research", modelID: "fake", mode: .agent, workspaceToolsEnabled: true)
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        _ = try await settled(coordinator, id: admitted.id, state: .waitingEvent)
        // While the task waits for its sub-agents, the app saved what the person saw.
        let sequence = (try await conversations.messages(conversationID: conversation.id).map(\.sequence).max() ?? 0) + 1
        try await conversations.append(ConversationMessage(conversationID: conversation.id, role: .assistant,
            content: "I started two sub-agents.", sequence: sequence))
        try await coordinator.wake(admitted.id, key: "files-1", payload: Data())
        _ = try await settled(coordinator, id: admitted.id, state: .accepted)
        let assistant = try await conversations.messages(conversationID: conversation.id).filter { $0.role == .assistant }
        XCTAssertEqual(assistant.count, 1, "no second message for the same turn")
        XCTAssertEqual(assistant.first?.content, "I started two sub-agents.\n\nFinal report.")
    }

    func testPauseAndCancelCannotBeOverriddenByWake() async throws {
        let driver = ContinuityFixtureDriver { _, context in .wait(WakeCondition(executionID: context.executionID, kind: .folder, key: "files")) }
        let (coordinator, _, request, lease, path) = try await fixture(driver)
        defer { lease.release(); try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        _ = try await settled(coordinator, id: admitted.id, state: .waitingEvent)
        try await coordinator.pause(admitted.id)
        try await coordinator.wake(admitted.id, key: "files-1", payload: Data("malicious: resume".utf8))
        let paused = try await coordinator.snapshot(admitted.id); XCTAssertEqual(paused?.state, .paused)
        try await coordinator.cancel(admitted.id)
        try await coordinator.tick(at: .now.addingTimeInterval(3600))
        let cancelled = try await coordinator.snapshot(admitted.id); XCTAssertEqual(cancelled?.state, .cancelled)
        do { try await coordinator.resume(admitted.id); XCTFail("Cancelled run resumed") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .invalidTransition) }
        let count = await driver.calls; XCTAssertEqual(count, 1)
    }

    func testProviderRetryAfterPersistsAndNetworkEventCannotWakeEarly() async throws {
        let due = Date.now.addingTimeInterval(3600)
        let driver = ContinuityFixtureDriver { count, _ in
            if count == 1 { throw ProviderRetryDeferral(status: 429, notBefore: due) }
            return .completed(result: Data("recovered".utf8))
        }
        let (coordinator, repository, request, lease, path) = try await fixture(driver)
        defer { lease.release(); try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        _ = try await settled(coordinator, id: admitted.id, state: .waitingNetwork)
        try await coordinator.wake(admitted.id, key: "network-returned", payload: Data())
        for minute in 1..<60 { try await coordinator.tick(at: due.addingTimeInterval(Double(minute - 60) * 60)) }
        let before = await driver.calls; XCTAssertEqual(before, 1)
        let owner = UUID(); try await repository.installOwner(owner)
        lease.release()
        let newLease = try RuntimeLease(url: path); defer { newLease.release() }
        let replacement = RunCoordinator(repository: repository, driver: driver, lease: newLease, authorized: { _ in true })
        try await replacement.start(); try await replacement.tick(at: due)
        _ = try await settled(replacement, id: admitted.id, state: .accepted)
        let after = await driver.calls; XCTAssertEqual(after, 2)
    }

    func testTransferPreservesSystemWaitAndNeverResumesUserPause() async throws {
        let driver = ContinuityFixtureDriver { _, context in .wait(WakeCondition(executionID: context.executionID, kind: .deadline, key: "wait", dueAt: .now.addingTimeInterval(7200))) }
        let (coordinator, repository, request, lease, path) = try await fixture(driver)
        defer { try? FileManager.default.removeItem(at: path) }
        let admitted = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        _ = try await settled(coordinator, id: admitted.id, state: .waitingEvent)
        try await coordinator.relinquishForTransfer()
        let transferred = try await repository.execution(admitted.id)
        XCTAssertEqual(transferred?.state, .paused)
        XCTAssertEqual(transferred?.transferResumeState, .waitingEvent)
        let replacementLease = try RuntimeLease(url: path); defer { replacementLease.release() }
        let replacement = RunCoordinator(repository: repository, driver: driver, lease: replacementLease, authorized: { _ in true })
        try await replacement.start()
        let waiting = try await replacement.snapshot(admitted.id); XCTAssertEqual(waiting?.state, .waitingEvent)
        try await replacement.pause(admitted.id)
        try await replacement.relinquishForTransfer()
        let thirdLease = try RuntimeLease(url: path); defer { thirdLease.release() }
        let third = RunCoordinator(repository: repository, driver: driver, lease: thirdLease, authorized: { _ in true })
        try await third.start()
        let paused = try await third.snapshot(admitted.id); XCTAssertEqual(paused?.state, .paused)
        let calls = await driver.calls; XCTAssertEqual(calls, 1)
    }
}
