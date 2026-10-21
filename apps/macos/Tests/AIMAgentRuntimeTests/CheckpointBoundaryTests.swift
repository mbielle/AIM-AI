import AIMAgentKit
import AIMApplication
@testable import AIMAgentRuntime
import XCTest

private actor CheckpointFixtureConversation: DurableModelConversation, SteerableModelToolConversation {
    let call: ModelToolCall
    var cursor = 0
    var received: [ModelToolOutput] = []
    var steering: [String] = []
    init(call: ModelToolCall) { self.call = call }
    func next(outputs: [ModelToolOutput]) -> ModelToolTurn {
        received += outputs; cursor += 1
        return cursor == 1 ? ModelToolTurn(text: "", calls: [call]) : ModelToolTurn(text: "done", calls: [])
    }
    func next(outputs: [ModelToolOutput], userMessages: [String]) -> ModelToolTurn {
        steering += userMessages; return next(outputs: outputs)
    }
    func exportCheckpoint() -> ModelConversationCheckpoint {
        ModelConversationCheckpoint(codec: "fixture", provider: .openRouter, modelID: "fake", transcript: Data(),
            pendingIDs: cursor == 1 ? [call.id] : [], seenIDs: [call.id], finished: cursor > 1,
            usage: TokenUsage(), metadata: Data(String(cursor).utf8))
    }
    func restoreCheckpoint(_ checkpoint: ModelConversationCheckpoint) { cursor = Int(String(decoding: checkpoint.metadata, as: UTF8.self)) ?? 0 }
}
private actor CheckpointFixtureEffect: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["fixture_effect"]
    var effects = 0
    func execute(_ request: ToolRequest) -> ToolResult { effects += 1; return ToolResult(requestID: request.id, content: "effect \(effects)") }
    func cancel(requestID: String) {}
}
private actor CorrectionDuringFinalConversation: DurableModelConversation, SteerableModelToolConversation {
    let correction: @Sendable () async throws -> Void
    var calls = 0
    var steering: [String] = []
    init(correction: @escaping @Sendable () async throws -> Void) { self.correction = correction }
    func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn {
        calls += 1
        if calls == 1 { try await correction() }
        return ModelToolTurn(text: calls == 1 ? "obsolete" : "corrected", calls: [])
    }
    func next(outputs: [ModelToolOutput], userMessages: [String]) async throws -> ModelToolTurn {
        steering += userMessages; return try await next(outputs: outputs)
    }
    func exportCheckpoint() -> ModelConversationCheckpoint {
        ModelConversationCheckpoint(codec: "correction-fixture", provider: .openRouter, modelID: "fake",
            transcript: Data(), pendingIDs: [], seenIDs: [], finished: true, usage: TokenUsage(), metadata: Data(String(calls).utf8))
    }
    func restoreCheckpoint(_ checkpoint: ModelConversationCheckpoint) { calls = Int(String(decoding: checkpoint.metadata, as: UTF8.self)) ?? 0 }
}
private final class FinalTextCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func record(_ event: EngineEvent) { if case .textDelta(_, let delta) = event { lock.withLock { text += delta } } }
    var value: String { lock.withLock { text } }
}
private struct FailResultWriter: ExecutionCheckpointing {
    let inner: RunCheckpointWriter
    func load() async throws -> ExecutionCheckpoint? { try await inner.load() }
    func prepare(_ checkpoint: ExecutionCheckpoint) async throws { try await inner.prepare(checkpoint) }
    func launched(_ callID: String) async throws { try await inner.launched(callID) }
    func returned(_ output: ModelToolOutput) async throws { throw WorkspaceHistoryError.persistence }
}

final class CheckpointBoundaryTests: XCTestCase {
    func testExplicitContinuationAfterFinishedCheckpointRequestsFreshTurn() async throws {
        let (id, writer, _, _) = try await fixture()
        let call = ModelToolCall(id: "one", name: "fixture_effect", arguments: [:])
        let before = CheckpointFixtureConversation(call: call)
        _ = await before.next(outputs: [])
        let finished = await before.next(outputs: [ModelToolOutput(id: call.id, content: "done", isError: false)])
        try await writer.prepare(ExecutionCheckpoint(conversation: before.exportCheckpoint(), turn: finished, effects: [], ordinal: 1, seenCallIDs: [call.id]))
        let after = CheckpointFixtureConversation(call: call)
        let dispatcher = try ApprovedToolDispatcher(tools: [], broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil)
        try await NativeWorkspaceTurn.run(conversation: after, dispatcher: dispatcher, conversationID: id,
            checkpointing: writer, continuationMessage: "Continue the remaining objective", emit: { _ in })
        let cursor = await after.cursor, steering = await after.steering
        XCTAssertEqual(cursor, 3); XCTAssertEqual(steering, ["Continue the remaining objective"])
    }
    func testCodeCorrectionDuringFinalIsDeliveredOnceWithoutMissionAndSurvivesRestart() async throws {
        let (id, writer, store, executionID) = try await fixture(mode: .code)
        let command = UUID()
        let conversation = CorrectionDuringFinalConversation {
            _ = try await store.control(commandID: command, executionID: executionID, action: "correct", text: "Keep the existing file", owner: writer.owner)
        }
        let capture = FinalTextCapture()
        let dispatcher = try ApprovedToolDispatcher(tools: [], broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil)
        try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: id,
            checkpointing: writer, emit: capture.record)
        let steering = await conversation.steering, calls = await conversation.calls
        XCTAssertEqual(steering, ["Keep the existing file"]); XCTAssertEqual(calls, 2)
        XCTAssertEqual(capture.value, "corrected")
        let pending = try await writer.pendingUserInputs(); XCTAssertTrue(pending.isEmpty)
        let checkpoint = try await writer.load(); XCTAssertEqual(checkpoint?.deliveredMissionInputIDs?.count, 1)
        let after = CorrectionDuringFinalConversation { XCTFail("Restored final made a new request") }
        let nextDispatcher = try ApprovedToolDispatcher(tools: [], broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil)
        try await NativeWorkspaceTurn.run(conversation: after, dispatcher: nextDispatcher, conversationID: id,
            checkpointing: writer, emit: { _ in })
        let restoredCalls = await after.calls; XCTAssertEqual(restoredCalls, 2)
        let restoredSteering = await after.steering; XCTAssertTrue(restoredSteering.isEmpty)
    }
    private func fixture(mode: AIMMode = .agent) async throws -> (UUID, RunCheckpointWriter, SQLiteAgentExecutionRepository, UUID) {
        let db = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "fault injection", mode: mode)
        try await SQLiteConversationRepository(database: db).save(conversation)
        let store = SQLiteAgentExecutionRepository(database: db)
        let owner = UUID(); try await store.installOwner(owner)
        let record = try await store.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, request: Data()), owner: owner)
        _ = try await store.transition(record.id, owner: owner, expectedRevision: 0, to: .running)
        return (conversation.id, RunCheckpointWriter(repository: store, executionID: record.id, owner: owner), store, record.id)
    }
    func testCrashAfterEffectBeforeSavingResultCannotRepeatMutation() async throws {
        let (id, writer, store, executionID) = try await fixture()
        let call = ModelToolCall(id: "one", name: "fixture_effect", arguments: [:])
        let effect = CheckpointFixtureEffect()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: call.name, risk: .localMutation, executor: effect)],
            broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil)
        do {
            try await NativeWorkspaceTurn.run(conversation: CheckpointFixtureConversation(call: call), dispatcher: dispatcher,
                conversationID: id, checkpointing: FailResultWriter(inner: writer), emit: { _ in })
            XCTFail("Injected persistence failure ignored")
        } catch { XCTAssertEqual(error as? WorkspaceHistoryError, .persistence) }
        let saved = try await store.checkpoint(executionID)
        XCTAssertEqual(saved?.effects.first?.state, .launched)
        let replacement = try ApprovedToolDispatcher(tools: [RegisteredTool(name: call.name, risk: .localMutation, executor: effect)],
            broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil)
        do {
            try await NativeWorkspaceTurn.run(conversation: CheckpointFixtureConversation(call: call), dispatcher: replacement,
                conversationID: id, checkpointing: writer, emit: { _ in })
            XCTFail("Uncertain mutation replayed")
        } catch { XCTAssertEqual(error as? ExecutionStoreError, .invalidTransition) }
        let count = await effect.effects; XCTAssertEqual(count, 1)
    }
    func testSavedResultIsDeliveredToModelWithoutExecutingToolAgain() async throws {
        let (id, writer, _, _) = try await fixture()
        let call = ModelToolCall(id: "one", name: "fixture_effect", arguments: [:])
        let before = CheckpointFixtureConversation(call: call)
        let turn = await before.next(outputs: [])
        var saved = ExecutionEffect(call: call, policy: .neverReplay)
        saved.state = .returned; saved.output = ModelToolOutput(id: call.id, content: "durable receipt", isError: false)
        try await writer.prepare(ExecutionCheckpoint(conversation: before.exportCheckpoint(), turn: turn,
            effects: [saved], ordinal: 1, seenCallIDs: [call.id]))
        let after = CheckpointFixtureConversation(call: call)
        let effect = CheckpointFixtureEffect()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: call.name, risk: .localMutation, executor: effect)],
            broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil)
        try await NativeWorkspaceTurn.run(conversation: after, dispatcher: dispatcher, conversationID: id, checkpointing: writer, emit: { _ in })
        let count = await effect.effects; XCTAssertEqual(count, 0)
        let received = await after.received; XCTAssertEqual(received.first?.content, "durable receipt")
    }
    func testUnlaunchedIntentCanRunAndInterruptedReadIsFreshlyObserved() async throws {
        for state in [ExecutionEffect.State.requested, .launched] {
            let (id, writer, _, _) = try await fixture()
            let call = ModelToolCall(id: "one", name: "fixture_effect", arguments: [:])
            let before = CheckpointFixtureConversation(call: call); let turn = await before.next(outputs: [])
            var saved = ExecutionEffect(call: call, policy: state == .requested ? .neverReplay : .readOnly); saved.state = state
            try await writer.prepare(ExecutionCheckpoint(conversation: before.exportCheckpoint(), turn: turn,
                effects: [saved], ordinal: 0, seenCallIDs: []))
            let effect = CheckpointFixtureEffect()
            let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: call.name, risk: .readOnly, executor: effect)],
                broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil)
            try await NativeWorkspaceTurn.run(conversation: CheckpointFixtureConversation(call: call), dispatcher: dispatcher,
                conversationID: id, checkpointing: writer, emit: { _ in })
            let count = await effect.effects; XCTAssertEqual(count, 1)
        }
    }
}
