import AIMAgentKit
import AIMApplication
import AIMMacPlatform
@testable import AIMAgentRuntime
import XCTest

private actor HostAttemptFixture {
    var commands: [AgentHostCommand] = []
    var failures: Int
    let error: AgentHostTransportError
    init(failures: Int, error: AgentHostTransportError = .disconnected) { self.failures = failures; self.error = error }
    func send(_ command: AgentHostCommand, timeout: Duration) throws -> Data {
        commands.append(command)
        if failures > 0 { failures -= 1; throw error }
        return Data("[]".utf8)
    }
    func count() -> Int { commands.count }
    func ids() -> [UUID] { commands.map(\.commandID) }
}
private actor HostServiceFixture: AgentHostClient {
    var commands: [AgentHostCommand.Action] = []
    var stopContinuation: CheckedContinuation<Void, Never>?
    func send(_ command: AgentHostCommand) async throws -> Data {
        commands.append(command.action)
        if command.action == .stop { await withCheckedContinuation { stopContinuation = $0 } }
        return Data("{}".utf8)
    }
    func releaseStop() { stopContinuation?.resume(); stopContinuation = nil }
    func waitingForStop() -> Bool { stopContinuation != nil }
    func actions() -> [AgentHostCommand.Action] { commands }
}
private actor UnauthorizedHostDriver: ContinuityTurnDriving {
    var calls = 0
    func run(_ request: AgentRequest, context: RuntimeExecutionContext,
             event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
        calls += 1; return .completed(result: Data())
    }
    func cancel(conversationID: UUID) async {}
    func count() -> Int { calls }
}
final class AgentHostLifecycleTests: XCTestCase {
    private var policy: AgentHostReadRetryPolicy {
        AgentHostReadRetryPolicy(timeout: .milliseconds(80), attemptTimeout: .milliseconds(10), delay: .milliseconds(1))
    }
    func testDisconnectedReadReconnectsWithSameObservationalCommand() async throws {
        let fixture = HostAttemptFixture(failures: 2)
        let command = AgentHostCommand(action: .list)
        let data = try await policy.send(command) { try await fixture.send($0, timeout: $1) }
        XCTAssertEqual(data, Data("[]".utf8))
        let ids = await fixture.ids()
        XCTAssertEqual(ids, [command.commandID, command.commandID, command.commandID])
    }
    func testMutationsAndOpaqueControlsAreNeverReplayed() async throws {
        let actions: [AgentHostCommand.Action] = [.privacy, .peers, .virtualMachine, .ambientAudio, .channels,
            .admit, .pause, .resume, .cancel, .correct, .accept, .approve, .answer, .stop, .logout,
            .fireSchedule, .acknowledgeProcess]
        for action in actions {
            let fixture = HostAttemptFixture(failures: 2)
            do { _ = try await policy.send(AgentHostCommand(action: action)) { try await fixture.send($0, timeout: $1) }; XCTFail("A mutation must propagate its lost ACK") }
            catch { XCTAssertEqual(error as? AgentHostTransportError, .disconnected) }
            let count = await fixture.count(); XCTAssertEqual(count, 1, action.rawValue)
        }
    }
    func testIdentityAndProtocolFailuresAreNotRetried() async throws {
        for failure in [AgentHostTransportError.invalidSignature, .wrongIdentity, .invalidMessage] {
            let fixture = HostAttemptFixture(failures: 2, error: failure)
            do { _ = try await policy.send(AgentHostCommand(action: .list)) { try await fixture.send($0, timeout: $1) }; XCTFail() }
            catch { XCTAssertEqual(error as? AgentHostTransportError, failure) }
            let count = await fixture.count(); XCTAssertEqual(count, 1)
        }
    }
    func testUnavailableServiceWaitHasBoundedDeadline() async throws {
        let fixture = HostAttemptFixture(failures: 1000, error: .notReady)
        let clock = ContinuousClock(), before = ContinuousClock.now
        do { _ = try await policy.send(AgentHostCommand(action: .list)) { try await fixture.send($0, timeout: $1) }; XCTFail() }
        catch { XCTAssertEqual(error as? AgentHostTransportError, .notReady) }
        let count = await fixture.count()
        XCTAssertGreaterThan(count, 1)
        XCTAssertLessThan(clock.now - before, .seconds(1), "Readiness cannot become an infinite startup wait")
    }
    func testCancellationEndsReadinessWithoutAnotherRequest() async throws {
        let fixture = HostAttemptFixture(failures: 1000)
        let retryPolicy = policy
        let task = Task {
            try await retryPolicy.send(AgentHostCommand(action: .list)) { try await fixture.send($0, timeout: $1) }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testStartingServiceRejectsCommandsUntilOwnerReady() async throws {
        let backend = HostServiceFixture()
        let service = AgentHostServiceClient(client: backend, initiallyReady: false)
        for action in [AgentHostCommand.Action.list, .admit] {
            do { _ = try await service.send(AgentHostCommand(action: action)); XCTFail() }
            catch { XCTAssertEqual(error as? AgentHostTransportError, .notReady) }
        }
        let before = await backend.actions(); XCTAssertTrue(before.isEmpty)
        await service.markReady()
        _ = try await service.send(AgentHostCommand(action: .list))
        let after = await backend.actions(); XCTAssertEqual(after, [.list])
    }
    func testStopReceiptKeepsReadsAliveButClosesMutationAdmission() async throws {
        let backend = HostServiceFixture()
        let service = AgentHostServiceClient(client: backend)
        let stop = Task { try await service.send(AgentHostCommand(action: .stop)) }
        for _ in 0..<100 {
            if await backend.waitingForStop() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let waiting = await backend.waitingForStop(); XCTAssertTrue(waiting)
        do { _ = try await service.send(AgentHostCommand(action: .admit)); XCTFail() }
        catch { XCTAssertEqual(error as? AgentHostTransportError, .serviceQuiescent) }
        _ = try await service.send(AgentHostCommand(action: .list))
        await backend.releaseStop()
        let receipt = try await stop.value; XCTAssertEqual(receipt, Data("{}".utf8))
        _ = try await service.send(AgentHostCommand(action: .list))
        // An explicit second Stop observes existing quiescence; no automatic resend.
        _ = try await service.send(AgentHostCommand(action: .stop))
        do { _ = try await service.send(AgentHostCommand(action: .resume)); XCTFail() }
        catch { XCTAssertEqual(error as? AgentHostTransportError, .serviceQuiescent) }
        let actions = await backend.actions(); XCTAssertEqual(actions, [.stop, .list, .list])
    }
    func testReadyTransportDoesNotGrantAccountAuthorization() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteAgentExecutionRepository(database: database)
        let driver = UnauthorizedHostDriver()
        let path = FileManager.default.temporaryDirectory.appending(path: "aim-host-readiness-\(UUID()).lock")
        let lease = try RuntimeLease(url: path)
        defer { lease.release(); try? FileManager.default.removeItem(at: path) }
        let coordinator = RunCoordinator(repository: repository, driver: driver, lease: lease, authorized: { _ in false })
        try await coordinator.start()
        let service = AgentHostServiceClient(client: EmbeddedAgentHostClient(coordinator: coordinator))
        let request = AgentRequest(conversationID: UUID(), text: "Fixture", modelID: "fixture", mode: .agent)
        do { _ = try await service.send(AgentHostCommand(action: .admit, accountID: UUID(), request: request)); XCTFail() }
        catch { XCTAssertTrue(error is ExecutionStoreError) }
        let records = try await repository.list(); XCTAssertTrue(records.isEmpty)
        let calls = await driver.count(); XCTAssertEqual(calls, 0)
        try await coordinator.shutdown()
    }
}
