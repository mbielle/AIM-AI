import XCTest
@testable import AIMApplication

final class AgentExecutionPersistenceTests: XCTestCase {
    private func fixture() async throws -> (SQLiteAgentExecutionRepository, AgentExecution, UUID) {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "durable", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let store = SQLiteAgentExecutionRepository(database: database)
        let owner = UUID(); try await store.installOwner(owner)
        let execution = try await store.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id,
                                                             request: Data("request".utf8)), owner: owner)
        return (store, execution, owner)
    }

    func testAdmissionDeduplicatesButRejectsChangedPayloadAndSecondMission() async throws {
        let (store, execution, owner) = try await fixture()
        let duplicate = try await store.admit(execution, owner: owner)
        XCTAssertEqual(duplicate.id, execution.id)
        var conflicting = execution; conflicting.request = Data("changed".utf8)
        do { _ = try await store.admit(conflicting, owner: owner); XCTFail("changed command accepted") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .commandConflict) }
        let other = AgentExecution(commandID: UUID(), conversationID: execution.conversationID, request: execution.request)
        do { _ = try await store.admit(other, owner: owner); XCTFail("concurrent mission accepted") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .duplicateConversation) }
        let events = try await store.events(execution.id)
        XCTAssertEqual(events.map(\.kind), ["admitted"])
    }

    func testOldOwnerAndStaleRevisionCannotCommitAfterRestart() async throws {
        let (store, execution, oldOwner) = try await fixture()
        let newOwner = UUID(); try await store.installOwner(newOwner)
        do { _ = try await store.transition(execution.id, owner: oldOwner, expectedRevision: 0, to: .running); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
        let running = try await store.transition(execution.id, owner: newOwner, expectedRevision: 0, to: .running)
        do { _ = try await store.transition(execution.id, owner: newOwner, expectedRevision: 0, to: .cancelled); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleRevision) }
        let cancelled = try await store.transition(execution.id, owner: newOwner, expectedRevision: running.revision, to: .cancelled)
        do { _ = try await store.transition(execution.id, owner: newOwner, expectedRevision: cancelled.revision, to: .running); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .invalidTransition) }
    }

    func testFinishedCommandWithAnErrorIsAKnownResultNotAnUncertainEffect() {
        let call = ModelToolCall(id: "tests", name: "run_command", arguments: ["command": "swift test"])
        var effect = ExecutionEffect(call: call, policy: .neverReplay); effect.state = .returned; effect.wasLaunched = true
        effect.output = ModelToolOutput(id: call.id, content: "Exit code: 1", isError: true, metadata: ["exit_code": "1"])
        let conversation = ModelConversationCheckpoint(codec: "native-v1", provider: .openRouter, modelID: "m",
            transcript: Data("[]".utf8), pendingIDs: [], seenIDs: [call.id], finished: false, usage: TokenUsage())
        var checkpoint = ExecutionCheckpoint(conversation: conversation, turn: ModelToolTurn(text: "", calls: [call]),
            effects: [effect], ordinal: 0, seenCallIDs: [call.id])
        XCTAssertFalse(checkpoint.needsReconciliation, "a failing test run is a result the agent reads, not a stop")
        checkpoint.effects[0].output = ModelToolOutput(id: call.id, content: "Lost", isError: true)
        XCTAssertTrue(checkpoint.needsReconciliation, "an action that failed without a known outcome still needs a look")
    }

    func testCheckpointPreservesCorrelationAndFlagsUncertainMutation() async throws {
        let (store, execution, owner) = try await fixture()
        let running = try await store.transition(execution.id, owner: owner, expectedRevision: 0, to: .running)
        let call = ModelToolCall(id: "wire-call", name: "mail_send", arguments: ["subject": "hello"])
        var effect = ExecutionEffect(call: call, policy: .neverReplay); effect.state = .launched
        let conversation = ModelConversationCheckpoint(codec: "native-v1", provider: .google, modelID: "m",
            transcript: Data("[]".utf8), pendingIDs: [call.id], seenIDs: [call.id], finished: false, usage: TokenUsage())
        let checkpoint = ExecutionCheckpoint(conversation: conversation, turn: ModelToolTurn(text: "", calls: [call]),
            effects: [effect], ordinal: 0, seenCallIDs: [])
        _ = try await store.saveCheckpoint(checkpoint, executionID: execution.id, owner: owner, expectedRevision: running.revision)
        let restored = try await store.checkpoint(execution.id)
        XCTAssertEqual(restored, checkpoint)
        XCTAssertTrue(try XCTUnwrap(restored).needsReconciliation)
        var malformed = checkpoint; malformed.effects[0].output = ModelToolOutput(id: "other", content: "done", isError: false)
        do { _ = try await store.saveCheckpoint(malformed, executionID: execution.id, owner: owner, expectedRevision: 2); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .incompatibleCheckpoint) }
    }

    func testWakeSurvivesPauseDeduplicatesAndWaitsSeveralDaysWithoutModel() async throws {
        let (store, execution, owner) = try await fixture()
        let future = Date.now.addingTimeInterval(72 * 3600)
        let waiting = try await store.wait(WakeCondition(executionID: execution.id, kind: .deadline, key: "deadline", dueAt: future),
                                           owner: owner, expectedRevision: 0)
        let paused = try await store.transition(execution.id, owner: owner, expectedRevision: waiting.revision, to: .paused)
        let inserted = try await store.enqueueWake(executionID: execution.id, dedupKey: "one-event", payload: Data("untrusted".utf8), owner: owner)
        XCTAssertTrue(inserted)
        let repeated = try await store.enqueueWake(executionID: execution.id, dedupKey: "one-event", payload: Data(), owner: owner)
        XCTAssertFalse(repeated)
        let whilePaused = try await store.consumeWake(executionID: execution.id, owner: owner)
        XCTAssertNil(whilePaused)
        _ = try await store.transition(execution.id, owner: owner, expectedRevision: paused.revision, to: .waitingEvent)
        let newOwner = UUID(); try await store.installOwner(newOwner)
        let consumed = try await store.consumeWake(executionID: execution.id, owner: newOwner, at: future)
        XCTAssertEqual(consumed, Data("untrusted".utf8))
        let after = try await store.execution(execution.id)
        XCTAssertEqual(after?.state, .queued)
        XCTAssertEqual(after?.request, execution.request)
        let again = try await store.consumeWake(executionID: execution.id, owner: newOwner)
        XCTAssertNil(again)
    }

    func testOutboxRemainsPendingUntilReceipt() async throws {
        let (store, execution, owner) = try await fixture()
        let id = UUID()
        try await store.queueDelivery(id: id, executionID: execution.id, payload: Data("result".utf8), owner: owner)
        try await store.queueDelivery(id: id, executionID: execution.id, payload: Data("result".utf8), owner: owner)
        let pending = try await store.pendingDeliveries()
        XCTAssertEqual(pending.count, 1)
        try await store.delivered(id, owner: owner)
        let remaining = try await store.pendingDeliveries()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testScheduledBudgetIsOptionalAndLegacyCapSurvivesDecoding() throws {
        let task = ScheduledTaskSpec(schedule: .daily(hour: 8, minute: 0), modelID: "m")
        XCTAssertTrue(task.isValid); XCTAssertNil(task.maxSpendUSD)
        let legacy = ScheduledTaskSpec(schedule: .daily(hour: 8, minute: 0), modelID: "m", maxSpendUSD: "1.00")
        let decoded = try JSONDecoder().decode(ScheduledTaskSpec.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.maxSpendUSD, "1.00")
        XCTAssertTrue(ScheduledTaskSpec(schedule: task.schedule, modelID: "m", maxSpendUSD: "200.00").isValid)
        XCTAssertFalse(ScheduledTaskSpec(schedule: task.schedule, modelID: "m", maxSpendUSD: "NaN").isValid)
    }
}
