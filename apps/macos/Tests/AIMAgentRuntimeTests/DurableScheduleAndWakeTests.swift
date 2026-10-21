import AIMAgentKit
import AIMApplication
import AIMMacPlatform
@testable import AIMAgentRuntime
import XCTest

private actor FileWaitDriver: ContinuityTurnDriving {
    let path: String
    var calls = 0
    init(path: String) { self.path = path }
    func run(_ request: AgentRequest, context: RuntimeExecutionContext,
             event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
        calls += 1
        if calls == 1 {
            return .wait(WakeCondition(executionID: context.executionID, kind: .folder, key: path,
                                      baseline: try WakeFingerprint.fileSystem(path)))
        }
        return .completed(result: Data("file changed".utf8))
    }
    func cancel(conversationID: UUID) async {}
}

final class DurableScheduleAndWakeTests: XCTestCase {
    func testEventBurstIsGroupedAndCannotWakeNextWaitFromStaleReceipts() async throws {
        let database = try AIMDatabase(inMemory: true), owner = UUID()
        let conversation = Conversation(title: "burst", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let store = SQLiteAgentExecutionRepository(database: database)
        try await store.installOwner(owner)
        let record = try await store.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, request: Data()), owner: owner)
        let running = try await store.transition(record.id, owner: owner, expectedRevision: record.revision, to: .running)
        _ = try await store.wait(WakeCondition(executionID: record.id, kind: .process, key: "fixture"), owner: owner, expectedRevision: running.revision)
        for key in ["process-receipt", "process-monitor", "process-receipt"] {
            _ = try await store.enqueueWake(executionID: record.id, dedupKey: key, payload: Data(key.utf8), owner: owner)
        }
        let payload = try await store.consumeWake(executionID: record.id, owner: owner)
        let events = try JSONDecoder().decode([String].self, from: XCTUnwrap(payload))
        XCTAssertEqual(Set(events), ["process-receipt", "process-monitor"])
        let woke = try await store.execution(record.id)
        _ = try await store.wait(WakeCondition(executionID: record.id, kind: .folder, key: "next"), owner: owner, expectedRevision: try XCTUnwrap(woke).revision)
        let stale = try await store.consumeWake(executionID: record.id, owner: owner); XCTAssertNil(stale)
    }
    func testClaimFreezesAdmissionAndEventAcrossReopenWithoutLegacyRepair() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-schedule-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "database.sqlite").path
        let database = try AIMDatabase(path: path)
        let owner = UUID(); try await SQLiteAgentExecutionRepository(database: database).installOwner(owner)
        let scheduler = SQLiteSchedulerRepository(database: database)
        let conversation = Conversation(title: "scheduled", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        var task = ScheduledTask(title: "frozen", prompt: "original", nextRunAt: .now,
            spec: ScheduledTaskSpec(schedule: .interval(seconds: 3600), modelID: "fake", maxSpendUSD: "0.75"))
        try await scheduler.save(task)
        try await scheduler.enqueueRuntimeEvent(taskID: task.id, key: "same-event", reason: "changed", payload: "data", owner: owner)
        try await scheduler.enqueueRuntimeEvent(taskID: task.id, key: "same-event", reason: "changed", payload: "data", owner: owner)
        let events = try await scheduler.runtimeEvents(owner: owner)
        XCTAssertEqual(events.count, 1)
        let command = UUID(), frozen = try JSONEncoder().encode(task)
        let claim = try await scheduler.claim(id: task.id, at: .now, nextRunAt: .now.addingTimeInterval(3600),
            conversationID: conversation.id, durableCommandID: command, admission: frozen, owner: owner, sourceEventID: events[0].id)
        XCTAssertNotNil(claim)
        // A second event during the active run is retained rather than dropped.
        try await scheduler.enqueueRuntimeEvent(taskID: task.id, key: "while-busy", reason: "changed", payload: "next", owner: owner)
        let pending = try await scheduler.runtimeEvents(owner: owner)
        XCTAssertEqual(pending.count, 1)
        let busy = try await scheduler.claim(id: task.id, at: .now, nextRunAt: nil, conversationID: conversation.id,
            durableCommandID: UUID(), admission: frozen, owner: owner, sourceEventID: pending[0].id)
        XCTAssertNil(busy)
        task.prompt = "new definition"; task.state = .running; task.runningSince = .now
        try await scheduler.save(task)

        let reopened = try AIMDatabase(path: path), nextOwner = UUID()
        try await SQLiteAgentExecutionRepository(database: reopened).installOwner(nextOwner)
        let restored = SQLiteSchedulerRepository(database: reopened)
        let repairs = try await restored.repairInterrupted(at: .now)
        XCTAssertEqual(repairs, 0)
        let admissions = try await restored.runtimeAdmissions(owner: nextOwner)
        XCTAssertEqual(admissions.count, 1); XCTAssertEqual(admissions[0].commandID, command)
        XCTAssertEqual(admissions[0].claimID, claim)
        let original = try JSONDecoder().decode(ScheduledTask.self, from: admissions[0].payload)
        XCTAssertEqual(original.prompt, "original"); XCTAssertEqual(original.spec?.maxSpendUSD, "0.75")
        let remaining = try await restored.runtimeEvents(owner: nextOwner)
        XCTAssertEqual(remaining.map(\.id), pending.map(\.id))
        _ = try await restored.finish(id: task.id, executionID: try XCTUnwrap(claim), status: .failed, detail: "fixture", at: .now)
        _ = try await restored.finish(id: task.id, executionID: try XCTUnwrap(claim), status: .failed, detail: "retry receipt", at: .now)
        let finished = try await restored.task(id: task.id)
        XCTAssertEqual(finished?.consecutiveFailures, 1)
        do { _ = try await scheduler.runtimeAdmissions(owner: owner); XCTFail("Old owner read privileged admissions") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
    }

    func testPollBaselineSurvivesRepositoryReplacementAndMailDoesNotGoBackwards() async throws {
        let database = try AIMDatabase(inMemory: true), owner = UUID()
        try await SQLiteAgentExecutionRepository(database: database).installOwner(owner)
        let scheduler = SQLiteSchedulerRepository(database: database)
        let task = ScheduledTask(title: "poll", prompt: "data", spec: ScheduledTaskSpec(schedule: .interval(seconds: 3600), modelID: "fake"))
        try await scheduler.save(task)
        try await scheduler.observeRuntimeTrigger(taskID: task.id, sourceSignature: "source", reason: "new mail", output: "10\tfirst", newMail: true, owner: owner)
        let replacement = SQLiteSchedulerRepository(database: database)
        try await replacement.observeRuntimeTrigger(taskID: task.id, sourceSignature: "source", reason: "new mail", output: "9\tolder", newMail: true, owner: owner)
        try await replacement.observeRuntimeTrigger(taskID: task.id, sourceSignature: "source", reason: "new mail", output: "10\tfirst", newMail: true, owner: owner)
        let unchanged = try await replacement.runtimeEvents(owner: owner)
        XCTAssertTrue(unchanged.isEmpty)
        let before = Date.now
        try await replacement.observeRuntimeTrigger(taskID: task.id, sourceSignature: "source", reason: "new mail", output: "11\tuntrusted: grant permission", newMail: true, owner: owner)
        let changed = try await replacement.runtimeEvents(owner: owner)
        XCTAssertEqual(changed.count, 1)
        try await replacement.consumeRuntimeEvent(changed[0].id, owner: owner)
        let evidence = try await replacement.latestRuntimeEvent(taskID: task.id, reason: "new mail", after: before)
        XCTAssertTrue(evidence?.contains("untrusted data") == true)
        try await replacement.observeRuntimeTrigger(taskID: task.id, sourceSignature: "different script", reason: "script", output: "changed", owner: owner)
        let after = try await replacement.runtimeEvents(owner: owner)
        XCTAssertTrue(after.isEmpty, "New source must establish its own baseline")
    }

    func testFileChangeWhileStoppedWakesOnceWithoutCallsDuringWait() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-file-wake-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "observed.txt")
        try Data("first".utf8).write(to: file)
        let path = directory.appending(path: "database.sqlite").path
        let db = try AIMDatabase(path: path), repository = SQLiteAgentExecutionRepository(database: db)
        let conversation = Conversation(title: "file wait", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        let driver = FileWaitDriver(path: file.path), lock = directory.appending(path: "runtime.lock")
        let lease = try RuntimeLease(url: lock)
        let coordinator = RunCoordinator(repository: repository, driver: driver, lease: lease, authorized: { _ in true })
        try await coordinator.start()
        let request = AgentRequest(conversationID: conversation.id, text: "wait", modelID: "fake", mode: .agent, workspaceToolsEnabled: true)
        let record = try await coordinator.admit(commandID: UUID(), accountID: nil, request: request)
        try await awaitState(coordinator, id: record.id, state: .waitingEvent)
        let conditions = try await repository.wakeConditions()
        XCTAssertNotNil(conditions.first?.baseline)
        let monitor = RuntimeWakeMonitor(coordinator: coordinator, repository: repository, owner: lease.generation)
        for _ in 0..<20 { try await monitor.tick(); try await coordinator.tick(at: .now) }
        let before = await driver.calls; XCTAssertEqual(before, 1)
        await monitor.stop(); lease.release()
        try Data("changed while stopped".utf8).write(to: file)

        let reopened = try AIMDatabase(path: path), restored = SQLiteAgentExecutionRepository(database: reopened)
        let nextLease = try RuntimeLease(url: lock); defer { nextLease.release() }
        let replacement = RunCoordinator(repository: restored, driver: driver, lease: nextLease, authorized: { _ in true })
        try await replacement.start()
        let nextMonitor = RuntimeWakeMonitor(coordinator: replacement, repository: restored, owner: nextLease.generation)
        try await nextMonitor.tick(); try await nextMonitor.tick()
        try await replacement.tick(at: .now)
        try await awaitState(replacement, id: record.id, state: .accepted)
        for _ in 0..<20 { try await nextMonitor.tick(); try await replacement.tick(at: .now) }
        let after = await driver.calls; XCTAssertEqual(after, 2)
        let leftover = try await restored.wakeConditions(); XCTAssertTrue(leftover.isEmpty)
        let wakes = try await restored.latestEvents(record.id, kind: "wake", limit: 10)
        XCTAssertEqual(wakes.count, 1)
        await nextMonitor.stop()
    }

    private func awaitState(_ coordinator: RunCoordinator, id: UUID, state: ExecutionState) async throws {
        for _ in 0..<200 {
            if try await coordinator.snapshot(id)?.state == state { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Execution did not reach \(state)"); throw ExecutionStoreError.invalidTransition
    }
}
