import Foundation

/// Executes one claimed run of a scheduled task and reports how it ended.
public protocol ScheduledRunExecuting: Sendable {
    func execute(task: ScheduledTask, conversationID: UUID) async -> (ScheduledRunStatus, String?)
    func execute(task: ScheduledTask, conversationID: UUID, context: ScheduledRunContext) async -> (ScheduledRunStatus, String?)
}

/// Why a run started, and whether it continues an earlier run's conversation.
public struct ScheduledRunContext: Equatable, Sendable {
    public let reason: String
    /// Untrusted data that came with the trigger (a webhook body, a new mail's sender and subject…).
    public let payload: String?
    public let continuing: Bool

    public init(reason: String, payload: String? = nil, continuing: Bool = false) {
        self.reason = reason; self.payload = payload; self.continuing = continuing
    }
}

public extension ScheduledRunExecuting {
    func execute(task: ScheduledTask, conversationID: UUID, context: ScheduledRunContext) async -> (ScheduledRunStatus, String?) {
        await execute(task: task, conversationID: conversationID)
    }
}

/// Dispatches due and triggered tasks. A task never overlaps itself; missed
/// occurrences while AIM was closed coalesce into one run; unfinished runs
/// found at start are recorded as interrupted and never replayed.
public actor TaskScheduler {
    public typealias Notify = @Sendable (_ title: String, _ body: String) async -> Void

    private let repository: SQLiteSchedulerRepository
    private let executor: any ScheduledRunExecuting
    private let clock: @Sendable () -> Date
    private let notify: Notify
    private let maximumConcurrentRuns: Int
    private var running: [UUID: Task<Void, Never>] = [:]
    private var loop: Task<Void, Never>?

    public init(repository: SQLiteSchedulerRepository, executor: any ScheduledRunExecuting,
                maximumConcurrentRuns: Int = 2, clock: @escaping @Sendable () -> Date = { .now },
                notify: @escaping Notify = { _, _ in }) {
        self.repository = repository
        self.executor = executor
        self.maximumConcurrentRuns = maximumConcurrentRuns
        self.clock = clock
        self.notify = notify
    }

    public func start(interval: Duration = .seconds(30)) async {
        guard loop == nil else { return }
        let repaired = (try? await repository.repairInterrupted(at: clock())) ?? 0
        if repaired > 0 {
            await notify("Scheduled tasks interrupted", "\(repaired) run(s) stopped when AIM quit. They were not replayed.")
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() async {
        loop?.cancel()
        loop = nil
        for task in running.values { task.cancel() }
        for task in running.values { await task.value }
        running.removeAll()
    }

    /// Starts every due task that is not already running. Returns started IDs.
    @discardableResult
    public func tick() async -> [UUID] {
        let now = clock()
        guard let due = try? await repository.due(before: now) else { return [] }
        var started: [UUID] = []
        for task in due where task.spec?.schedule != nil {
            guard running.count < maximumConcurrentRuns else { break }
            // Coalesce: the next slot is computed from now, not from the missed time.
            if await dispatch(task, reason: "schedule", nextRunAt: task.spec?.nextRun(after: now)) {
                started.append(task.id)
            }
        }
        return started
    }

    /// Runs a task now because of a trigger or a person's request.
    @discardableResult
    public func fire(taskID: UUID, reason: String, payload: String? = nil) async -> Bool {
        guard running.count < maximumConcurrentRuns, let task = try? await repository.task(id: taskID) else { return false }
        return await dispatch(task, reason: reason, payload: payload, nextRunAt: task.nextRunAt)
    }

    public func isRunning(_ id: UUID) -> Bool { running[id] != nil }

    public func waitForIdle() async {
        while let task = running.values.first { await task.value }
    }

    private func dispatch(_ task: ScheduledTask, reason: String, payload: String? = nil, nextRunAt: Date?) async -> Bool {
        guard running[task.id] == nil, let spec = task.spec, spec.isValid else { return false }
        // Heartbeat re-entry continues the latest run's conversation.
        let previous = spec.continuesConversation == true
            ? (try? await repository.executions(taskID: task.id, limit: 1))?.first?.conversationID : nil
        let conversationID = previous ?? UUID()
        let context = ScheduledRunContext(reason: reason, payload: payload, continuing: previous != nil)
        guard let executionID = try? await repository.claim(id: task.id, at: clock(), nextRunAt: nextRunAt,
                                                             conversationID: conversationID) else { return false }
        let executor = self.executor
        let repository = self.repository
        let clock = self.clock
        let notify = self.notify
        running[task.id] = Task { [weak self] in
            let (status, detail) = await executor.execute(task: task, conversationID: conversationID, context: context)
            let updated = try? await repository.finish(id: task.id, executionID: executionID, status: status,
                                                       detail: detail, at: clock())
            switch status {
            case .needsPerson:
                await notify("“\(task.title)” needs you", detail ?? "The task paused before an action outside its approved scope.")
            case .spendCapped:
                await notify("“\(task.title)” stopped at its spending cap", detail ?? "")
            default:
                break
            }
            if updated?.state == .disabled, updated?.consecutiveFailures ?? 0 >= ScheduledTask.failureLimit {
                await notify("“\(task.title)” was turned off", updated?.pausedReason ?? "Too many consecutive failures.")
            }
            await self?.finished(task.id)
        }
        return true
    }

    private func finished(_ id: UUID) { running.removeValue(forKey: id) }
}
