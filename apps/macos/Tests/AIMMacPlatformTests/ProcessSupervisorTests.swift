import AIMAgentKit
@testable import AIMMacPlatform
import XCTest

final class ProcessSupervisorTests: XCTestCase {
    func testShutdownStopsMultipleRunnersAndRejectsNewLaunches() async throws {
        let supervisor = ProcessSupervisor()
        let first = MacProcessRunner(supervisor: supervisor)
        let second = MacProcessRunner(supervisor: supervisor)
        let command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: .seconds(3))
        let a = Task { try await first.run(command) }
        let b = Task { try await second.run(command) }
        defer { a.cancel(); b.cancel() }
        for _ in 0..<100 where supervisor.activeCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(supervisor.activeCount, 2)
        supervisor.beginShutdown()
        XCTAssertTrue(supervisor.isShuttingDown)
        do { _ = try await first.run(command); XCTFail("Must reject new launches") }
        catch ProcessExecutionError.shuttingDown { }
        async let waiterA: Void = supervisor.waitForIdle()
        async let waiterB: Void = supervisor.waitForIdle()
        _ = await (waiterA, waiterB)
        XCTAssertEqual(supervisor.activeCount, 0)
        do { _ = try await a.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        do { _ = try await b.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(supervisor.resumeAfterCancelledShutdown())
        let recovered = try await first.run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["recovered"]))
        XCTAssertEqual(recovered.stdout, "recovered\n")
    }

    func testGateCannotReopenBeforeAllLeasesFinishAndCallbacksAreReentrant() async throws {
        let supervisor = ProcessSupervisor()
        let first = UUID(), second = UUID()
        try supervisor.register(id: first) { supervisor.finish(id: first) }
        try supervisor.register(id: second) { }
        supervisor.beginShutdown()
        XCTAssertEqual(supervisor.activeCount, 1)
        XCTAssertFalse(supervisor.resumeAfterCancelledShutdown())
        supervisor.finish(id: second)
        await supervisor.waitForIdle()
        XCTAssertTrue(supervisor.resumeAfterCancelledShutdown())
    }
}
