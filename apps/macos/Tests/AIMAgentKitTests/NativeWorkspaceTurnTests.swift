import AIMAgentKit
import AIMApplication
import XCTest

private actor LoopConversation: ModelToolConversation {
    var received: [[ModelToolOutput]] = []
    let turns: [ModelToolTurn]
    init(_ turns: [ModelToolTurn]) { self.turns = turns }
    func next(outputs: [ModelToolOutput]) throws -> ModelToolTurn {
        let index = received.count
        received.append(outputs)
        guard index < turns.count else { throw ModelToolError.invalidProtocol }
        return turns[index]
    }
}
private actor SteeringConversation: SteerableModelToolConversation {
    var delivered: ([ModelToolOutput], [String])?
    func next(outputs: [ModelToolOutput]) throws -> ModelToolTurn {
        guard outputs.isEmpty, delivered == nil else { throw ModelToolError.invalidProtocol }
        return ModelToolTurn(text: "", calls: [ModelToolCall(id: "read-1", name: "read_file", arguments: ["path": "README.md"])])
    }
    func next(outputs: [ModelToolOutput], userMessages: [String]) throws -> ModelToolTurn {
        delivered = (outputs, userMessages)
        return ModelToolTurn(text: "Updated", calls: [])
    }
}
private actor DelayedFinalConversation: SteerableModelToolConversation {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var correction: [String] = []
    var isWaiting: Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn {
        await withCheckedContinuation { gate = $0 }
        return ModelToolTurn(text: "Obsolete final", calls: [])
    }
    func next(outputs: [ModelToolOutput], userMessages: [String]) throws -> ModelToolTurn {
        correction = userMessages
        return ModelToolTurn(text: "Revised final", calls: [])
    }
}
private final class FinalTextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ event: EngineEvent) {
        if case let .textDelta(_, text) = event { lock.withLock { values.append(text) } }
    }
    var texts: [String] { lock.withLock { values } }
}
private actor LoopExecutor: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["read_file"]
    var count = 0
    func execute(_ request: ToolRequest) -> ToolResult {
        count += 1
        return ToolResult(requestID: request.id, content: "untrusted fixture text")
    }
    func cancel(requestID: String) {}
}

private actor WaitingExecutor: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["await_subagents"]
    var count = 0
    func execute(_ request: ToolRequest) -> ToolResult {
        count += 1
        return ToolResult(requestID: request.id, content: "children still running",
            metadata: ["expected_wait": "true", "wait_condition": "all_children_terminal"])
    }
    func cancel(requestID: String) {}
}

private actor UncertainMutationExecutor: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["mutate"]
    var count = 0
    func execute(_ request: ToolRequest) -> ToolResult {
        count += 1
        var result = ToolResult(requestID: request.id, content: "Request submitted; final state unknown")
        result.actionOutcome = .unknown
        return result
    }
    func cancel(requestID: String) {}
}

private actor FailingJournalRepository: WorkspaceRunRepository {
    let failOnResult: Bool
    var finalState: WorkspaceRunState?
    init(failOnResult: Bool) { self.failOnResult = failOnResult }
    func begin(_ run: WorkspaceRun) {}
    func launched(runID: String, callID: String) {}
    func requested(_ call: WorkspaceCall) throws {
        if !failOnResult { throw WorkspaceHistoryError.persistence }
    }
    func returned(runID: String, output: ModelToolOutput) throws { throw WorkspaceHistoryError.persistence }
    func finish(runID: String, state: WorkspaceRunState) { finalState = state }
    func history(conversationID: UUID, limit: Int) -> [WorkspaceRunHistory] { [] }
}

final class NativeWorkspaceTurnTests: XCTestCase {
    func testUncertainMutationCannotBeRepeatedBlindlyInSameRun() async throws {
        let executor = UncertainMutationExecutor()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "mutate",
            risk: .localMutation, requiredArguments: ["target"], executor: executor)],
            broker: ToolApprovalBroker(), policy: .autoApprove, workspacePath: nil)
        let first = ModelToolCall(id: "one", name: "mutate", arguments: ["target": "fixture"])
        let retry = ModelToolCall(id: "two", name: "mutate", arguments: ["target": "fixture"])
        // A blocked retry is refused with its reason; the run pauses if the model insists three times.
        let conversation = LoopConversation([ModelToolTurn(text: "", calls: [first]),
                                             ModelToolTurn(text: "", calls: [retry]),
                                             ModelToolTurn(text: "", calls: [ModelToolCall(id: "three", name: "mutate", arguments: ["target": "fixture"])]),
                                             ModelToolTurn(text: "", calls: [ModelToolCall(id: "four", name: "mutate", arguments: ["target": "fixture"])])])
        do {
            try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher,
                conversationID: UUID(), emit: { _ in })
            XCTFail("An uncertain effect must not be submitted twice")
        } catch {
            XCTAssertEqual(error as? ModelToolError, .repeatedFailures)
        }
        let count = await executor.count
        let rounds = await conversation.received
        XCTAssertEqual(count, 1)
        XCTAssertEqual(rounds.count, 4)
        XCTAssertTrue(rounds[1][0].metadata["recovery_required"]?.contains("reconcile") == true)
    }

    func testCorrectionArrivingDuringFinalResponseSuppressesObsoleteText() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Final race", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let missions = SQLiteAgentMissionRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Draft")
        let initial = try await missions.pendingInputs(missionID: mission.id)
        try await missions.consumeInput(id: try XCTUnwrap(initial.first).id, missionID: mission.id)
        let recordedRun = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                                       modelID: "fixture", workspacePath: "/fixture")
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: recordedRun.id)
        let provider = DelayedFinalConversation()
        let recorder = FinalTextRecorder()
        let journal = WorkspaceRunJournal(repository: SQLiteWorkspaceRunRepository(database: db), run: recordedRun)
        let dispatcher = try dispatcher(LoopExecutor(), ToolApprovalBroker(), policy: .plan)
        let missionID = mission.id
        let task = Task {
            try await NativeWorkspaceTurn.run(conversation: provider, dispatcher: dispatcher,
                                              conversationID: chat.id, journal: journal,
                                              missionRepository: missions, missionID: missionID,
                                              emit: { recorder.append($0) })
        }
        var waiting = false
        for _ in 0..<200 {
            waiting = await provider.isWaiting
            if waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(waiting)
        _ = try await missions.enqueueCorrection(conversationID: chat.id, message: "Change the ending")
        await provider.release()
        try await task.value
        let correction = await provider.correction
        XCTAssertEqual(correction, ["Change the ending"])
        XCTAssertEqual(recorder.texts, ["Revised final"])
    }

    func testLiveCorrectionFollowsPendingToolResultAndIsAcknowledged() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Steer", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let missions = SQLiteAgentMissionRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Read fixture")
        let initial = try await missions.pendingInputs(missionID: mission.id)
        try await missions.consumeInput(id: try XCTUnwrap(initial.first).id, missionID: mission.id)
        let recordedRun = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                                       modelID: "fixture", workspacePath: "/fixture")
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: recordedRun.id)
        let broker = ToolApprovalBroker()
        let dispatcher = try dispatcher(LoopExecutor(), broker)
        let provider = SteeringConversation()
        let missionID = mission.id
        let journal = WorkspaceRunJournal(repository: SQLiteWorkspaceRunRepository(database: db), run: recordedRun)
        let run = Task {
            try await NativeWorkspaceTurn.run(conversation: provider, dispatcher: dispatcher,
                                              conversationID: chat.id, journal: journal, missionRepository: missions,
                                              missionID: missionID, emit: { _ in })
        }
        let approval = try await pending(broker)
        let correction = try await missions.enqueueCorrection(conversationID: chat.id, message: "Emphasize the heading")
        await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: .allowOnce)
        try await run.value
        let delivered = await provider.delivered
        XCTAssertEqual(delivered?.0.map(\.id), ["read-1"])
        XCTAssertEqual(delivered?.1, ["Emphasize the heading"])
        let remaining = try await missions.pendingInputs(missionID: mission.id)
        XCTAssertTrue(remaining.isEmpty)
        let messages = try await SQLiteConversationRepository(database: db).messages(conversationID: chat.id)
        XCTAssertEqual(messages.map(\.id), [correction.id])
    }

    func testJournalFailureStopsBeforeExecutionOrBeforeResultUpload() async throws {
        for failOnResult in [false, true] {
            let broker = ToolApprovalBroker(), executor = LoopExecutor()
            let dispatcher = try dispatcher(executor, broker, policy: .plan)
            let conversation = LoopConversation([ModelToolTurn(text: "", calls: [call("1")]), ModelToolTurn(text: "Done", calls: [])])
            let repository = FailingJournalRepository(failOnResult: failOnResult)
            let id = UUID()
            let journal = WorkspaceRunJournal(repository: repository, run: WorkspaceRun(conversationID: id, provider: .openAI, modelID: "fixture", workspacePath: "/fixture"))
            do {
                try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: id, journal: journal, emit: { _ in })
                XCTFail("Persistence failure must stop the run")
            } catch { XCTAssertTrue(error is WorkspaceHistoryError) }
            let count = await executor.count
            let rounds = await conversation.received.count
            let state = await repository.finalState
            XCTAssertEqual(count, failOnResult ? 1 : 0)
            XCTAssertEqual(rounds, 1)
            XCTAssertEqual(state, .failed)
        }
    }
    private func call(_ id: String) -> ModelToolCall { ModelToolCall(id: id, name: "read_file", arguments: ["path": "README.md"]) }
    private func dispatcher(_ executor: LoopExecutor, _ broker: ToolApprovalBroker, policy: ApprovalPolicy = .alwaysAsk) throws -> ApprovedToolDispatcher {
        try ApprovedToolDispatcher(tools: [RegisteredTool(name: "read_file", risk: .readOnly, requiredArguments: ["path"], executor: executor)],
            broker: broker, policy: policy, workspacePath: "/fixture")
    }
    private func pending(_ broker: ToolApprovalBroker) async throws -> PendingToolApproval {
        for _ in 0..<200 {
            if let approval = await broker.snapshot().first { return approval }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ModelToolError.invalidProtocol
    }

    func testApprovedToolResultReachesNextModelRoundAndSessionCloses() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker)
        let conversation = LoopConversation([ModelToolTurn(text: "Checking", calls: [call("1")]), ModelToolTurn(text: "Done", calls: [])])
        let task = Task { try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in }) }
        let approval = try await pending(broker)
        let before = await executor.count
        XCTAssertEqual(before, 0)
        await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: .allowOnce)
        try await task.value
        let rounds = await conversation.received
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds[1], [ModelToolOutput(id: "1", content: "untrusted fixture text", isError: false)])
        let late = await dispatcher.execute(id: "late", name: "read_file", arguments: ["path": "README.md"])
        XCTAssertTrue(late.isError)
    }

    func testDenialReturnsErrorWithoutReadingFile() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker)
        let conversation = LoopConversation([ModelToolTurn(text: "", calls: [call("1")]), ModelToolTurn(text: "Access denied", calls: [])])
        let task = Task { try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in }) }
        let approval = try await pending(broker)
        await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: .deny)
        try await task.value
        let count = await executor.count
        let rounds = await conversation.received
        XCTAssertEqual(count, 0)
        XCTAssertEqual(rounds[1].first?.isError, true)
    }

    func testCancellationRejectsPendingApprovalAndNeverContinuesProvider() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker)
        let conversation = LoopConversation([ModelToolTurn(text: "", calls: [call("1")])])
        let task = Task { try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in }) }
        let approval = try await pending(broker)
        task.cancel()
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let remaining = await broker.snapshot()
        let count = await executor.count
        let rounds = await conversation.received
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(rounds.count, 1)
        let stale = await broker.decide(id: approval.id, sessionID: approval.sessionID, decision: .allowOnce)
        XCTAssertFalse(stale)
    }

    func testRepeatedCallsStopButLongSuccessfulRunsComplete() async throws {
        for repeatID in [true, false] {
            let broker = ToolApprovalBroker(), executor = LoopExecutor()
            let dispatcher = try dispatcher(executor, broker, policy: .plan)
            let conversation = LoopConversation((0..<80).map { ordinal in
                ModelToolTurn(text: "", calls: [ModelToolCall(id: repeatID ? "same" : String(ordinal),
                    name: "read_file", arguments: ["path": repeatID ? "README.md" : "fixture_\(ordinal).txt"])])
            } + [ModelToolTurn(text: "Done", calls: [])])
            do {
                try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in })
                XCTAssertFalse(repeatID)
            } catch { XCTAssertTrue(repeatID); XCTAssertEqual(error as? ModelToolError, .invalidProtocol) }
            let count = await executor.count
            XCTAssertEqual(count, repeatID ? 1 : 80)
        }
    }

    func testMoreThanEightDistinctCallsInOneTurnComplete() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker, policy: .plan)
        let calls = (0..<12).map { ordinal in
            ModelToolCall(id: "batch_\(ordinal)", name: "read_file", arguments: ["path": "fixture_\(ordinal).txt"])
        }
        let conversation = LoopConversation([
            ModelToolTurn(text: "", calls: calls),
            ModelToolTurn(text: "Done", calls: [])
        ])
        try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in })
        let count = await executor.count
        let rounds = await conversation.received
        XCTAssertEqual(count, 12)
        XCTAssertEqual(rounds[1].map(\.id), calls.map(\.id))
    }

    func testIdenticalSuccessfulCallsExposeStagnationBeforeBlockingRoute() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker, policy: .plan)
        let conversation = LoopConversation([
            ModelToolTurn(text: "", calls: [call("1")]),
            ModelToolTurn(text: "", calls: [call("2")]),
            ModelToolTurn(text: "", calls: [call("3")]),
            ModelToolTurn(text: "", calls: [call("4")]),
            ModelToolTurn(text: "", calls: [call("5")]),
            ModelToolTurn(text: "", calls: [call("6")])
        ])
        do {
            try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher,
                conversationID: UUID(), emit: { _ in })
            XCTFail("The fourth identical operation should be blocked")
        } catch { XCTAssertEqual(error as? ModelToolError, .repeatedFailures) }
        let count = await executor.count
        let rounds = await conversation.received
        XCTAssertEqual(count, 3)
        XCTAssertEqual(rounds.count, 6)
        XCTAssertNotNil(rounds[3].first?.metadata["stagnation_warning"])
        XCTAssertTrue(rounds[3].first?.content.contains("No observable progress") == true)
    }

    func testExplicitSubagentWaitDoesNotCountAsStagnation() async throws {
        let executor = WaitingExecutor()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(
            name: "await_subagents", risk: .readOnly, approvalExempt: true, executor: executor)],
            broker: ToolApprovalBroker(), policy: .plan, workspacePath: nil)
        let calls = (0..<4).map { ModelToolCall(id: "wait-\($0)", name: "await_subagents", arguments: [:]) }
        let conversation = LoopConversation(calls.map { ModelToolTurn(text: "", calls: [$0]) } +
            [ModelToolTurn(text: "Done", calls: [])])
        try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher,
                                          conversationID: UUID(), emit: { _ in })
        let count = await executor.count
        XCTAssertEqual(count, 4)
        let rounds = await conversation.received
        XCTAssertNil(rounds.last?.first?.metadata["stagnation_warning"])
    }

    func testAlternatingSuccessfulOperationsWithoutChangeAreDiagnosed() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker, policy: .plan)
        let calls = (0..<6).map { ordinal in
            ModelToolCall(id: "alternating_\(ordinal)", name: "read_file",
                          arguments: ["path": ordinal.isMultiple(of: 2) ? "a.txt" : "b.txt"])
        }
        let conversation = LoopConversation(calls.map { ModelToolTurn(text: "", calls: [$0]) } +
            [ModelToolTurn(text: "Another strategy", calls: [])])
        try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher,
            conversationID: UUID(), emit: { _ in })
        let rounds = await conversation.received
        let count = await executor.count
        XCTAssertEqual(count, 6)
        XCTAssertEqual(rounds.count, 7)
        XCTAssertNotNil(rounds[6].first?.metadata["stagnation_warning"])
        XCTAssertTrue(rounds[6].first?.content.contains("cycled") == true)
    }

    func testUnknownToolErrorsReachModelBeforeRepeatedRouteStops() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker)
        let calls = (0..<6).map { ModelToolCall(id: String($0), name: "shell", arguments: [:]) }
        let conversation = LoopConversation([ModelToolTurn(text: "", calls: calls)] + (0..<3).map { index in
            ModelToolTurn(text: "", calls: [ModelToolCall(id: "retry\(index)", name: "shell", arguments: [:])]) })
        do { try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? ModelToolError, .repeatedFailures) }
        let count = await executor.count
        let approvals = await broker.snapshot()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(approvals.isEmpty)
        let rounds = await conversation.received
        XCTAssertEqual(rounds.count, 4)
        XCTAssertEqual(rounds[1].count, 6)
        XCTAssertTrue(rounds[1].allSatisfy(\.isError))
        XCTAssertNotNil(rounds[1].last?.metadata["recovery_required"])
    }

    func testModelCanRecoverAfterThreeErrorsByChangingTool() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker, policy: .plan)
        let conversation = LoopConversation([
            ModelToolTurn(text: "", calls: (0..<3).map { ModelToolCall(id: "bad\($0)", name: "unknown", arguments: [:]) }),
            ModelToolTurn(text: "Recover", calls: [call("good")]),
            ModelToolTurn(text: "Done", calls: [])
        ])
        try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in })
        let count = await executor.count
        XCTAssertEqual(count, 1)
    }

    func testLongerCyclesWithoutChangeAreDiagnosed() async throws {
        let broker = ToolApprovalBroker(), executor = LoopExecutor()
        let dispatcher = try dispatcher(executor, broker, policy: .plan)
        let calls = (0..<9).map { ordinal in
            ModelToolCall(id: "cycle_\(ordinal)", name: "read_file", arguments: ["path": ["a.txt", "b.txt", "c.txt"][ordinal % 3]])
        }
        let conversation = LoopConversation(calls.map { ModelToolTurn(text: "", calls: [$0]) } +
            [ModelToolTurn(text: "Changed approach", calls: [])])
        try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in })
        let rounds = await conversation.received
        XCTAssertEqual(rounds.count, 10)
        XCTAssertNil(rounds[8].first?.metadata["stagnation_warning"], "two repetitions are not yet a loop")
        XCTAssertTrue(rounds[9].first?.content.contains("same 3 operations cycled") == true)
    }

    func testIndependentReadsOfOneTurnRunConcurrentlyInOrder() async throws {
        let broker = ToolApprovalBroker(), executor = SlowReadExecutor()
        let dispatcher = try ApprovedToolDispatcher(tools: [
            RegisteredTool(name: "read_file", risk: .readOnly, requiredArguments: ["path"], executor: executor)
        ], broker: broker, policy: .plan, workspacePath: FileManager.default.temporaryDirectory.path)
        let calls = (0..<3).map { ModelToolCall(id: "parallel_\($0)", name: "read_file", arguments: ["path": "f\($0).txt"]) }
        let conversation = LoopConversation([ModelToolTurn(text: "", calls: calls), ModelToolTurn(text: "Done", calls: [])])
        try await NativeWorkspaceTurn.run(conversation: conversation, dispatcher: dispatcher, conversationID: UUID(), emit: { _ in })
        let rounds = await conversation.received
        XCTAssertEqual(rounds[1].map(\.id), ["parallel_0", "parallel_1", "parallel_2"], "results keep the call order")
        XCTAssertEqual(rounds[1].map(\.content), ["f0.txt", "f1.txt", "f2.txt"])
        let peak = await executor.peak
        XCTAssertGreaterThanOrEqual(peak, 2, "independent reads overlap")
    }
}

private actor SlowReadExecutor: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["read_file"]
    private var running = 0
    private(set) var peak = 0
    func execute(_ request: ToolRequest) async -> ToolResult {
        running += 1
        peak = max(peak, running)
        try? await Task.sleep(for: .milliseconds(150))
        running -= 1
        return ToolResult(requestID: request.id, content: request.arguments["path"] ?? "")
    }
    func cancel(requestID: String) {}
}
