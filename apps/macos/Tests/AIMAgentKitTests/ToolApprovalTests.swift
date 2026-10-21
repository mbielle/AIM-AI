import AIMAgentKit
import AIMApplication
import XCTest

final class ToolApprovalTests: XCTestCase {
    func testSensitiveMissionIntentAlwaysGetsOneExactApproval() async throws {
        let database = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Delete fixture", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        let missions = SQLiteAgentMissionRepository(database: database)
        let mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Delete fixture item")
        let resource = try MissionResource(kind: .application, identifier: "com.apple.reminders")
        _ = try await missions.replaceAuthorization(missionID: mission.id, expectedRevision: nil,
            rules: [try MissionAuthorizationRule(resource: resource, operations: [.edit])])
        let executor = SensitiveFixtureTool()
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "delete_fixture",
            risk: .computerAction, requiredArguments: ["id"], allowsSessionDecision: true,
            executor: executor)], broker: broker, policy: .autoApprove, workspacePath: nil,
            missionRepository: missions, missionID: mission.id)
        let task = Task { await dispatcher.execute(id: "delete-1", name: "delete_fixture",
            arguments: ["id": "fixture-item"]) }
        let approval = try await nextApproval(broker)
        XCTAssertEqual(approval.arguments["id"], "fixture-item")
        XCTAssertFalse(approval.allowsSessionDecision)
        let before = await executor.executed
        XCTAssertFalse(before)
        let sessionGrant = await broker.decide(id: approval.id, sessionID: dispatcher.sessionID,
            decision: .allowForSession)
        XCTAssertFalse(sessionGrant)
        let once = await broker.decide(id: approval.id, sessionID: dispatcher.sessionID,
            decision: .allowOnce)
        XCTAssertTrue(once)
        let result = await task.value
        XCTAssertFalse(result.isError)
        let after = await executor.executed
        XCTAssertTrue(after)
    }

    func testSensitiveIntentStillRequiresApprovalWithoutMigratedMissionScope() async throws {
        let executor = SensitiveFixtureTool()
        let broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "delete_fixture",
            risk: .computerAction, requiredArguments: ["id"], allowsSessionDecision: true,
            executor: executor)], broker: broker, policy: .autoApprove, workspacePath: nil)
        let task = Task { await dispatcher.execute(id: "legacy-delete", name: "delete_fixture",
            arguments: ["id": "fixture-item"]) }
        let approval = try await nextApproval(broker)
        XCTAssertFalse(approval.allowsSessionDecision)
        let before = await executor.executed
        XCTAssertFalse(before)
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
        let result = await task.value
        XCTAssertTrue(result.isError)
        let after = await executor.executed
        XCTAssertFalse(after)
    }

    func testReviewedUncertainActionNeedsExactApprovalEvenInAutoMode() async throws {
        let db = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Replay guard", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(chat)
        let missions = SQLiteAgentMissionRepository(database: db)
        let runs = SQLiteWorkspaceRunRepository(database: db)
        var mission = try await missions.beginOrSteer(conversationID: chat.id, message: "Write file")
        let run = WorkspaceRun(conversationID: chat.id, provider: .openAI,
                               modelID: "fixture", workspacePath: "")
        try await runs.begin(run)
        mission = try await missions.transition(missionID: mission.id, expectedRevision: mission.revision,
                                                to: .executing, reason: nil, activeRunID: run.id)
        try await runs.requested(WorkspaceCall(runID: run.id, ordinal: 0,
            call: ModelToolCall(id: "old", name: "write", jsonArguments: ["path": .string("a"), "note": .null])))
        try await runs.launched(runID: run.id, callID: "old")
        try await runs.finish(runID: run.id, state: .failed)
        mission = try await missions.finalizeRun(missionID: mission.id,
                                                expectedRevision: mission.revision, runID: run.id)
        mission = try await missions.recordReconciliation(missionID: mission.id,
            expectedRevision: mission.revision, callID: "old", assessment: .observed,
            note: "The file is already present")
        mission = try await missions.completeReview(missionID: mission.id,
            expectedRevision: mission.revision, note: "Inspect before another write")

        let executor = RecordingTool(), broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "write",
            risk: .localMutation, requiredArguments: ["path"], optionalArguments: ["note"], executor: executor)],
            broker: broker, policy: .autoApprove, workspacePath: nil,
            missionRepository: missions, missionID: mission.id)
        let repeated = Task { await dispatcher.execute(id: "new-1", name: "write", arguments: ["path": "a"]) }
        let approval = try await nextApproval(broker)
        XCTAssertTrue(approval.priorUncertainAction)
        XCTAssertFalse(approval.allowsSessionDecision)
        let before = await executor.calls
        XCTAssertTrue(before.isEmpty)
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
        let denied = await repeated.value
        XCTAssertTrue(denied.isError)
        let other = await dispatcher.execute(id: "new-2", name: "write", arguments: ["path": "b"])
        XCTAssertFalse(other.isError)
        let calls = await executor.calls
        XCTAssertEqual(calls.map { $0.arguments["path"] }, ["b"])
    }

    func testTypedJSONIsValidatedBeforeLegacyExecutorAndOptionalNullIsOmitted() async throws {
        let executor = RecordingTool()
        let tool = RegisteredTool(name: "write", risk: .readOnly,
            requiredArguments: ["path", "count", "enabled", "values"], optionalArguments: ["note"],
            argumentKinds: ["count": .integer, "enabled": .boolean, "values": .array], executor: executor)
        let dispatcher = try ApprovedToolDispatcher(tools: [tool], broker: ToolApprovalBroker(),
            policy: .plan, workspacePath: nil)
        let good = await dispatcher.executeJSON(id: "typed", name: "write", arguments: [
            "path": .string("fixture"), "count": .integer(3), "enabled": .boolean(true),
            "values": .array([.string("a"), .string("b")]), "note": .null
        ])
        XCTAssertFalse(good.isError)
        let calls = await executor.calls
        XCTAssertEqual(calls.first?.arguments, ["path": "fixture", "count": "3", "enabled": "true", "values": #"["a","b"]"#])
        let bad = await dispatcher.executeJSON(id: "invalid", name: "write", arguments: [
            "path": .string("fixture"), "count": .string("3"), "enabled": .boolean(true),
            "values": .array([.string("a")])
        ])
        XCTAssertTrue(bad.isError)
        let finalCalls = await executor.calls
        XCTAssertEqual(finalCalls.count, 1)
    }

    func testAutoSkipsOrdinaryMutationApprovalButNotDestructiveApproval() async throws {
        let executor = RecordingTool(), broker = ToolApprovalBroker()
        let dispatcher = try makeDispatcher(executor, broker: broker, policy: .autoApprove)
        let result = await dispatcher.execute(id: "auto", name: "write", arguments: ["path": "a"])
        XCTAssertFalse(result.isError)
        let approvals = await broker.snapshot()
        XCTAssertTrue(approvals.isEmpty)
        let calls = await executor.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testPlanRejectsMutationWithoutPromptOrExecution() async throws {
        let executor = RecordingTool(), broker = ToolApprovalBroker()
        let dispatcher = try makeDispatcher(executor, broker: broker, policy: .plan)
        let result = await dispatcher.execute(id: "1", name: "write", arguments: ["path": "a"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Plan mode"))
        let calls = await executor.calls
        let approvals = await broker.snapshot()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(approvals.isEmpty)
    }

    func testApprovalIsExactAndCannotBeDecidedByAnotherSession() async throws {
        let executor = RecordingTool(), broker = ToolApprovalBroker()
        let dispatcher = try makeDispatcher(executor, broker: broker)
        let task = Task { await dispatcher.execute(id: "1", name: "write", arguments: ["path": "a"]) }
        let approval = try await nextApproval(broker)
        XCTAssertEqual(approval.arguments, ["path": "a"])
        XCTAssertEqual(approval.workspacePath, "/trusted/workspace")
        let before = await executor.calls
        XCTAssertTrue(before.isEmpty)
        let wrongSession = await broker.decide(id: approval.id, sessionID: UUID(), decision: .allowOnce)
        XCTAssertFalse(wrongSession)
        let accepted = await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .allowOnce)
        XCTAssertTrue(accepted)
        let result = await task.value
        XCTAssertFalse(result.isError)
        let calls = await executor.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].risk, .localMutation)
        XCTAssertEqual(calls[0].workspacePath, "/trusted/workspace")
        let stale = await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .allowOnce)
        XCTAssertFalse(stale)
        let duplicate = await dispatcher.execute(id: "1", name: "write", arguments: ["path": "different"])
        XCTAssertTrue(duplicate.isError)
    }

    func testDenyCancellationAndClosedSessionsNeverExecute() async throws {
        let executor = RecordingTool(), broker = ToolApprovalBroker()
        let dispatcher = try makeDispatcher(executor, broker: broker)
        let denied = Task { await dispatcher.execute(id: "1", name: "write", arguments: ["path": "a"]) }
        let approval = try await nextApproval(broker)
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
        let deniedResult = await denied.value
        XCTAssertTrue(deniedResult.isError)
        let cancelled = Task { await dispatcher.execute(id: "2", name: "write", arguments: ["path": "a"]) }
        _ = try await nextApproval(broker)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertTrue(cancelledResult.isError)
        let closing = Task { await dispatcher.execute(id: "3", name: "write", arguments: ["path": "a"]) }
        _ = try await nextApproval(broker)
        await dispatcher.close()
        let closedResult = await closing.value
        XCTAssertTrue(closedResult.isError)
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
        let remaining = await broker.snapshot()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSessionGrantOnlyMatchesExactArgumentsAndDisappearsOnClose() async throws {
        let broker = ToolApprovalBroker(), session = UUID()
        let request = ToolRequest(name: "read", arguments: ["path": "a"], risk: .readOnly, workspacePath: "/workspace")
        let task = Task { await broker.request(request, sessionID: session, allowsSessionDecision: true) }
        let approval = try await nextApproval(broker)
        await broker.decide(id: approval.id, sessionID: session, decision: .allowForSession)
        let first = await task.value
        XCTAssertTrue(first)
        let cached = await broker.request(request, sessionID: session, allowsSessionDecision: true)
        XCTAssertTrue(cached)
        var changed = request
        changed.arguments["path"] = "b"
        let second = Task { [changed] in await broker.request(changed, sessionID: session, allowsSessionDecision: true) }
        _ = try await nextApproval(broker)
        await broker.close(sessionID: session)
        let closed = await second.value
        XCTAssertFalse(closed)
        let revoked = await broker.request(request, sessionID: session, allowsSessionDecision: true)
        XCTAssertFalse(revoked)
    }

    func testValidationAndCallBudgetPrecedeExecution() async throws {
        let executor = RecordingTool(), broker = ToolApprovalBroker()
        let dispatcher = try makeDispatcher(executor, broker: broker, policy: .autoApprove, limit: 3)
        let unknown = await dispatcher.execute(id: "1", name: "unknown", arguments: [:])
        let missing = await dispatcher.execute(id: "2", name: "write", arguments: [:])
        let injected = await dispatcher.execute(id: "3", name: "write", arguments: ["path": "a", "workspacePath": "/other"])
        let exhausted = await dispatcher.execute(id: "4", name: "write", arguments: ["path": "a"])
        XCTAssertTrue([unknown, missing, injected, exhausted].allSatisfy(\.isError))
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(exhausted.content.contains("configured tool-call budget"))
    }

    func testDestructiveActionsCannotReceiveSessionGrantsEvenInAutoMode() async throws {
        let executor = RecordingTool(), broker = ToolApprovalBroker()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "write", risk: .destructive,
            requiredArguments: ["path"], allowsSessionDecision: true, executor: executor)], broker: broker,
            policy: .autoApprove, workspacePath: "/workspace")
        let task = Task { await dispatcher.execute(id: "1", name: "write", arguments: ["path": "a"]) }
        let approval = try await nextApproval(broker)
        XCTAssertFalse(approval.allowsSessionDecision)
        let invalid = await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .allowForSession)
        XCTAssertFalse(invalid)
        await broker.decide(id: approval.id, sessionID: dispatcher.sessionID, decision: .deny)
        _ = await task.value
    }

    func testCloseWaitsForActiveExecutionAndRejectsFutureCalls() async throws {
        let executor = HoldingTool()
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "hold", risk: .readOnly, executor: executor)],
            broker: ToolApprovalBroker(), policy: .smart, workspacePath: nil)
        let task = Task { await dispatcher.execute(id: "running", name: "hold", arguments: [:]) }
        for _ in 0..<200 {
            if await executor.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await dispatcher.close()
        let finished = await executor.finished
        XCTAssertTrue(finished)
        let result = await task.value
        XCTAssertTrue(result.isError)
        let next = await dispatcher.execute(id: "late", name: "hold", arguments: [:])
        XCTAssertTrue(next.isError)
    }

    func testToolResultsAreBoundedAndRequireMatchingIDs() async throws {
        let large = ReturningTool(content: String(repeating: "x", count: 200_000), wrongID: false)
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "result", risk: .readOnly, executor: large)],
            broker: ToolApprovalBroker(), policy: .plan, workspacePath: nil)
        let result = await dispatcher.execute(id: "bounded", name: "result", arguments: [:])
        XCTAssertEqual(result.metadata["truncated"], "true")
        XCTAssertLessThan(result.content.utf8.count, 132_000)
        let wrong = ReturningTool(content: "answer", wrongID: true)
        let invalid = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "result", risk: .readOnly, executor: wrong)],
            broker: ToolApprovalBroker(), policy: .smart, workspacePath: nil)
        let bad = await invalid.execute(id: "expected", name: "result", arguments: [:])
        XCTAssertTrue(bad.isError)
    }

    private func makeDispatcher(_ executor: RecordingTool, broker: ToolApprovalBroker,
                                policy: ApprovalPolicy = .smart, limit: Int = 64) throws -> ApprovedToolDispatcher {
        try ApprovedToolDispatcher(tools: [RegisteredTool(name: "write", risk: .localMutation,
            requiredArguments: ["path"], executor: executor)], broker: broker, policy: policy,
            workspacePath: "/trusted/workspace", maximumCalls: limit)
    }
    private func nextApproval(_ broker: ToolApprovalBroker) async throws -> PendingToolApproval {
        for _ in 0..<200 {
            if let pending = await broker.snapshot().first { return pending }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "Approval did not appear", code: 1)
    }
}

private actor SensitiveFixtureTool: ToolExecutor, MissionIntentProviding {
    nonisolated let supportedTools: Set<String> = ["delete_fixture"]
    var executed = false
    nonisolated func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        MissionToolIntent(operation: .permanentDelete,
            target: try MissionResource(kind: .application, identifier: "com.apple.reminders"))
    }
    func execute(_ request: ToolRequest) -> ToolResult {
        executed = true
        return ToolResult(requestID: request.id, content: "deleted")
    }
    func cancel(requestID: String) {}
}

private actor RecordingTool: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["write"]
    var calls: [ToolRequest] = []
    func execute(_ request: ToolRequest) -> ToolResult {
        calls.append(request)
        return ToolResult(requestID: request.id, content: "done")
    }
    func cancel(requestID: String) { }
}

private actor HoldingTool: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["hold"]
    var started = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func execute(_ request: ToolRequest) async -> ToolResult {
        await withCheckedContinuation { continuation = $0; started = true }
        finished = true
        return ToolResult(requestID: request.id, content: "stopped")
    }
    func cancel(requestID: String) { continuation?.resume(); continuation = nil }
}

private struct ReturningTool: ToolExecutor {
    let supportedTools: Set<String> = ["result"]
    let content: String
    let wrongID: Bool
    func execute(_ request: ToolRequest) async -> ToolResult {
        ToolResult(requestID: wrongID ? "wrong" : request.id, content: content)
    }
    func cancel(requestID: String) async { }
}
