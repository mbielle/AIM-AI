import AIMApplication
import XCTest

private actor ScriptedExecutor: ScheduledRunExecuting {
    var outcomes: [ScheduledRunStatus]
    private(set) var runs: [UUID] = []
    private(set) var contexts: [(UUID, ScheduledRunContext)] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false

    init(_ outcomes: [ScheduledRunStatus]) { self.outcomes = outcomes }

    func hold() { holding = true }
    func release() { holding = false; gate?.resume(); gate = nil }

    func execute(task: ScheduledTask, conversationID: UUID, context: ScheduledRunContext) async -> (ScheduledRunStatus, String?) {
        contexts.append((conversationID, context))
        return await execute(task: task, conversationID: conversationID)
    }

    func execute(task: ScheduledTask, conversationID: UUID) async -> (ScheduledRunStatus, String?) {
        runs.append(task.id)
        if holding { await withCheckedContinuation { gate = $0 } }
        let status = outcomes.isEmpty ? .succeeded : outcomes.removeFirst()
        return (status, status == .needsPerson ? "Approval needed for mail_send" : nil)
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class TaskSchedulerTests: XCTestCase {
    private func make(_ outcomes: [ScheduledRunStatus], schedule: ScheduledTaskSpec.Schedule = .interval(seconds: 3_600),
                      start: Date = Date(timeIntervalSince1970: 1_800_000_000))
        async throws -> (SQLiteSchedulerRepository, TaskScheduler, ScriptedExecutor, FakeClock, ScheduledTask) {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteSchedulerRepository(database: database)
        let clock = FakeClock(start)
        let executor = ScriptedExecutor(outcomes)
        let scheduler = TaskScheduler(repository: repository, executor: executor, clock: { clock.now })
        let task = ScheduledTask(title: "Digest", prompt: "Summarize", nextRunAt: start.addingTimeInterval(-1),
            spec: ScheduledTaskSpec(schedule: schedule, modelID: "anthropic/claude-sonnet-5.5"))
        try await repository.save(task)
        return (repository, scheduler, executor, clock, task)
    }

    func testScheduleComputationAndValidation() {
        let spec = ScheduledTaskSpec(schedule: .daily(hour: 9, minute: 30), modelID: "m", timeZoneID: "Europe/Paris")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 10))!
        let next = spec.nextRun(after: base)!
        XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: next), DateComponents(day: 3, hour: 9, minute: 30))
        XCTAssertTrue(spec.isValid)
        XCTAssertFalse(ScheduledTaskSpec(schedule: .interval(seconds: 10), modelID: "m").isValid, "At least one minute")
        XCTAssertFalse(ScheduledTaskSpec(modelID: "m").isValid, "A schedule or a trigger is required")
        XCTAssertFalse(ScheduledTaskSpec(schedule: .daily(hour: 9, minute: 0), modelID: "m", maxSpendUSD: "0").isValid)
        XCTAssertNil(ScheduledTaskSpec(schedule: .once(at: base), modelID: "m").nextRun(after: base))
    }

    func testDueTaskRunsOnceAndNeverOverlapsItself() async throws {
        let (repository, scheduler, executor, clock, task) = try await make([.succeeded])
        await executor.hold()
        let first = await scheduler.tick()
        XCTAssertEqual(first, [task.id])
        clock.advance(7_200) // due again while the first run is still going
        let second = await scheduler.tick()
        let fired = await scheduler.fire(taskID: task.id, reason: "trigger")
        XCTAssertTrue(second.isEmpty)
        XCTAssertFalse(fired)
        await executor.release()
        await scheduler.waitForIdle()
        let runs = await executor.runs
        XCTAssertEqual(runs.count, 1)
        let stored = try await repository.task(id: task.id)
        XCTAssertEqual(stored?.state, .enabled)
        XCTAssertEqual(stored?.lastStatus, ScheduledRunStatus.succeeded.rawValue)
        XCTAssertNotNil(stored?.nextRunAt)
        let history = try await repository.executions(taskID: task.id)
        XCTAssertEqual(history.first?.status, .succeeded)
    }

    func testMissedSlotsCoalesceIntoOneRun() async throws {
        let (repository, scheduler, executor, clock, task) = try await make([.succeeded, .succeeded])
        clock.advance(10 * 3_600) // ten hourly slots missed while AIM was closed
        _ = await scheduler.tick()
        await scheduler.waitForIdle()
        _ = await scheduler.tick()
        await scheduler.waitForIdle()
        let runs = await executor.runs
        XCTAssertEqual(runs.count, 1, "Missed occurrences are not replayed one by one")
        let stored = try await repository.task(id: task.id)
        XCTAssertGreaterThan(stored?.nextRunAt ?? .distantPast, clock.now)
    }

    func testTenConsecutiveFailuresDisableTheTask() async throws {
        let (repository, scheduler, _, clock, task) = try await make(Array(repeating: .failed, count: 12))
        for _ in 0..<12 {
            _ = await scheduler.fire(taskID: task.id, reason: "test")
            await scheduler.waitForIdle()
            clock.advance(60)
        }
        let stored = try await repository.task(id: task.id)
        XCTAssertEqual(stored?.state, .disabled)
        XCTAssertEqual(stored?.consecutiveFailures, ScheduledTask.failureLimit)
        let history = try await repository.executions(taskID: task.id, limit: 50)
        XCTAssertEqual(history.count, ScheduledTask.failureLimit)
    }

    func testSuccessResetsTheFailureStreakAndNeedsPersonPauses() async throws {
        let (repository, scheduler, _, _, task) = try await make([.failed, .failed, .succeeded, .needsPerson])
        for _ in 0..<4 {
            _ = await scheduler.fire(taskID: task.id, reason: "test")
            await scheduler.waitForIdle()
        }
        let stored = try await repository.task(id: task.id)
        XCTAssertEqual(stored?.consecutiveFailures, 0)
        XCTAssertEqual(stored?.state, .paused)
        XCTAssertEqual(stored?.pausedReason, "Approval needed for mail_send")
        let refired = await scheduler.fire(taskID: task.id, reason: "test")
        XCTAssertFalse(refired, "A paused task waits for a person")
    }

    func testInterruptedRunIsRecordedNotReplayed() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteSchedulerRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = ScheduledTask(title: "Crash", prompt: "x", nextRunAt: now.addingTimeInterval(3_600),
            spec: ScheduledTaskSpec(schedule: .interval(seconds: 3_600), modelID: "m"))
        try await repository.save(task)
        let execution = try await repository.claim(id: task.id, at: now, nextRunAt: now.addingTimeInterval(3_600),
                                                   conversationID: UUID())
        XCTAssertNotNil(execution)
        // AIM quits here; on the next start:
        let executor = ScriptedExecutor([])
        let scheduler = TaskScheduler(repository: repository, executor: executor, clock: { now.addingTimeInterval(60) })
        await scheduler.start(interval: .seconds(3_600))
        await scheduler.stop()
        let stored = try await repository.task(id: task.id)
        XCTAssertNil(stored?.runningSince)
        XCTAssertEqual(stored?.state, .enabled)
        XCTAssertEqual(stored?.lastStatus, ScheduledRunStatus.interrupted.rawValue)
        let history = try await repository.executions(taskID: task.id)
        XCTAssertEqual(history.first?.status, .interrupted)
        let runs = await executor.runs
        XCTAssertTrue(runs.isEmpty, "Nothing is replayed automatically")
    }

    func testOneShotTaskDisablesAfterItsRun() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (repository, scheduler, _, _, task) = try await make([.succeeded], schedule: .once(at: start.addingTimeInterval(-1)),
                                                                  start: start)
        _ = await scheduler.tick()
        await scheduler.waitForIdle()
        let stored = try await repository.task(id: task.id)
        XCTAssertEqual(stored?.state, .disabled)
        XCTAssertNil(stored?.nextRunAt)
    }

    func testRunBudgetStopsAdmissionAtTheCap() async throws {
        let database = try AIMDatabase(inMemory: true)
        let global = SQLiteGlobalSpendLedger(database: database)
        let budget = RunBudgetLedger(inner: global, capUSD: Decimal(string: "0.10")!)
        let first = UUID()
        _ = try await budget.admit(id: first, provider: "openrouter", modelID: "m", feature: "scheduled",
            conversationID: nil, maximumUSD: "0.10", exception: false, at: .now)
        try await budget.markSent(id: first, at: .now)
        try await budget.reconcile(id: first, actualUSD: "0.12", at: .now)
        do {
            _ = try await budget.admit(id: UUID(), provider: "openrouter", modelID: "m", feature: "scheduled",
                conversationID: nil, maximumUSD: nil, exception: false, at: .now)
            XCTFail("The run's cap is reached")
        } catch SpendAdmissionError.limitReached {}
        let snapshot = try await global.snapshot(at: .now)
        XCTAssertEqual(snapshot.confirmedUSD, "0.12", "The global ledger still records the run")
    }

    func testTriggerDataReachesRunAndHeartbeatContinuesConversation() async throws {
        let (repository, scheduler, executor, _, task) = try await make([.succeeded, .succeeded])
        var heartbeat = task
        heartbeat.spec?.continuesConversation = true
        heartbeat.spec?.trigger = .webhook(tokenSHA256: String(repeating: "ab", count: 32))
        try await repository.save(heartbeat)
        XCTAssertTrue(heartbeat.spec?.isValid == true)
        let first = await scheduler.fire(taskID: task.id, reason: "its webhook", payload: "build 42 failed")
        XCTAssertTrue(first)
        await scheduler.waitForIdle()
        let second = await scheduler.fire(taskID: task.id, reason: "its webhook")
        XCTAssertTrue(second)
        await scheduler.waitForIdle()
        let contexts = await executor.contexts
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts[0].1, ScheduledRunContext(reason: "its webhook", payload: "build 42 failed", continuing: false))
        XCTAssertTrue(contexts[1].1.continuing)
        XCTAssertEqual(contexts[0].0, contexts[1].0, "a heartbeat run continues the same conversation")
        XCTAssertFalse(ScheduledTaskSpec(trigger: .webhook(tokenSHA256: "short"), modelID: "m").isValid)
        XCTAssertFalse(ScheduledTaskSpec(trigger: .scriptResultChanged(source: "return 1", intervalSeconds: 5), modelID: "m").isValid)
        XCTAssertTrue(ScheduledTaskSpec(trigger: .newMail, modelID: "m").isValid)
    }
}
