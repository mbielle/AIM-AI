import AIMApplication
import Foundation

public protocol ScheduledTaskRunning: Sendable {
    func run(_ task: ScheduledTask) async throws
}

public actor BoundedScheduler {
    public static let maximumConsecutiveFailures = 10

    private let repository: any SchedulerRepository
    private let runner: any ScheduledTaskRunning
    private var runningIDs: Set<UUID> = []

    public init(repository: any SchedulerRepository, runner: any ScheduledTaskRunning) {
        self.repository = repository
        self.runner = runner
    }

    public func tick(now: Date = .now) async {
        guard let tasks = try? await repository.due(before: now) else { return }
        for task in tasks where !runningIDs.contains(task.id) {
            runningIDs.insert(task.id)
            Task { await execute(task) }
        }
    }

    public func isRunning(_ id: UUID) -> Bool { runningIDs.contains(id) }

    private func execute(_ task: ScheduledTask) async {
        var updated = task
        updated.state = .running
        updated.updatedAt = .now
        try? await repository.save(updated)
        do {
            try await runner.run(task)
            updated.consecutiveFailures = 0
            updated.state = task.recurrenceRule == nil ? .disabled : .enabled
        } catch {
            updated.consecutiveFailures += 1
            updated.state = updated.consecutiveFailures >= Self.maximumConsecutiveFailures ? .disabled : .enabled
        }
        updated.updatedAt = .now
        try? await repository.save(updated)
        runningIDs.remove(task.id)
    }
}
