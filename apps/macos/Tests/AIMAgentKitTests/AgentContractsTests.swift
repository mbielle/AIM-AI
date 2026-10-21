import AIMAgentKit
import AIMApplication
import XCTest

final class AgentContractsTests: XCTestCase {
    func testApprovalPolicies() {
        XCTAssertFalse(ApprovalPolicy.smart.requiresApproval(for: .readOnly))
        XCTAssertTrue(ApprovalPolicy.smart.requiresApproval(for: .localMutation))
        XCTAssertTrue(ApprovalPolicy.plan.requiresApproval(for: .externalEffect))
        XCTAssertTrue(ApprovalPolicy.autoApprove.requiresApproval(for: .destructive))
    }

    func testEngineLeasesPreventStopUntilReleased() async {
        let registry = AgentEngineRegistry()
        let lease = await registry.acquire(.aim, kind: .interactive)
        let canStopWhileLeased = await registry.canStop(.aim)
        XCTAssertFalse(canStopWhileLeased)
        await registry.release(.aim, leaseID: lease)
        let canStopAfterRelease = await registry.canStop(.aim)
        XCTAssertTrue(canStopAfterRelease)
    }

    func testSchedulerDisablesAfterTenFailures() async throws {
        let task = ScheduledTask(title: "Failing", prompt: "test", nextRunAt: .distantPast, consecutiveFailures: 9)
        let repository = SchedulerStub(task: task)
        let scheduler = BoundedScheduler(repository: repository, runner: FailingRunner())
        await scheduler.tick()
        for _ in 0..<100 {
            guard await scheduler.isRunning(task.id) else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = await repository.list().first
        XCTAssertEqual(saved?.consecutiveFailures, 10)
        XCTAssertEqual(saved?.state, .disabled)
    }
}

private actor SchedulerStub: SchedulerRepository {
    private var task: ScheduledTask
    init(task: ScheduledTask) { self.task = task }
    func list() -> [ScheduledTask] { [task] }
    func due(before date: Date) -> [ScheduledTask] { task.nextRunAt.map { $0 <= date } == true ? [task] : [] }
    func save(_ task: ScheduledTask) { self.task = task }
    func delete(id: UUID) {}
}

private struct FailingRunner: ScheduledTaskRunning {
    struct ExpectedFailure: Error {}
    func run(_ task: ScheduledTask) async throws { throw ExpectedFailure() }
}
