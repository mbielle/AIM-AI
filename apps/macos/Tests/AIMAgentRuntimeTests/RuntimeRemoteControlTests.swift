import AIMAgentKit
import AIMApplication
import AIMMacPlatform
@testable import AIMAgentRuntime
import XCTest

private actor RemoteControlFixture {
    var received: [AgentHostCommand] = []
    func reply(_ command: AgentHostCommand) throws -> Data {
        received.append(command)
        let control = try JSONDecoder().decode(RuntimeRemoteControl.self, from: XCTUnwrap(command.payload))
        try control.validate()
        return try JSONEncoder().encode(RuntimeRemoteState(accountID: command.accountID,
            enabled: control.enabled ?? true, hostAvailable: control.enabled ?? true,
            status: control.enabled == false ? .stopped : .online(devices: 2)))
    }
    func lostAcknowledgement(_ command: AgentHostCommand) throws -> Data {
        received.append(command); throw AgentHostTransportError.disconnected
    }
    func commands() -> [AgentHostCommand] { received }
}
private actor RemoteUnusedDriver: ContinuityTurnDriving {
    func run(_ request: AgentRequest, context: RuntimeExecutionContext,
        event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
        throw ExecutionStoreError.invalidTransition
    }
    func cancel(conversationID: UUID) async {}
}
final class RuntimeRemoteControlTests: XCTestCase {
    func testEmbeddedRemoteCallbackCarriesEnableAndObservableStatus() async throws {
        let database = try AIMDatabase(inMemory: true)
        let file = URL(fileURLWithPath: "/private/tmp/remote-control-\(UUID()).lock")
        let lease = try RuntimeLease(url: file)
        defer { lease.release(); try? FileManager.default.removeItem(at: file) }
        let coordinator = RunCoordinator(repository: SQLiteAgentExecutionRepository(database: database),
            driver: RemoteUnusedDriver(), lease: lease, authorized: { _ in false })
        let fixture = RemoteControlFixture(), account = UUID()
        let client = EmbeddedAgentHostClient(coordinator: coordinator, onRemote: { try await fixture.reply($0) })
        for enabled in [true, false] {
            let command = AgentHostCommand(action: .remote, accountID: account,
                payload: try JSONEncoder().encode(RuntimeRemoteControl(action: .setEnabled, enabled: enabled)))
            let response = try JSONDecoder().decode(RuntimeRemoteState.self, from: await client.send(command))
            XCTAssertEqual(response.accountID, account); XCTAssertEqual(response.enabled, enabled)
            XCTAssertEqual(response.hostAvailable, enabled)
            XCTAssertEqual(response.status, enabled ? RemoteHost.Status.online(devices: 2) : RemoteHost.Status.stopped)
        }
        let commands = await fixture.commands(); XCTAssertEqual(commands.count, 2)
    }
    func testRemoteMutationsAreNotReplayedAfterLostAcknowledgement() async throws {
        let fixture = RemoteControlFixture()
        let policy = AgentHostReadRetryPolicy(timeout: .milliseconds(30), attemptTimeout: .milliseconds(5), delay: .milliseconds(1))
        for control in [RuntimeRemoteControl(action: .setEnabled, enabled: true), .init(action: .pairingCode), .init(action: .revoke, deviceID: "explicit-device")] {
            let command = AgentHostCommand(action: .remote, accountID: UUID(), payload: try JSONEncoder().encode(control))
            do { _ = try await policy.send(command) { command, _ in try await fixture.lostAcknowledgement(command) }; XCTFail("Unknown mutation must not replay") }
            catch { XCTAssertEqual(error as? AgentHostTransportError, .disconnected) }
        }
        let commands = await fixture.commands(); XCTAssertEqual(commands.count, 3)
        XCTAssertThrowsError(try RuntimeRemoteControl(action: .setEnabled).validate())
    }
    func testPrivateDirectoryRestartPreservesDataAndRejectsFilesAndSymlinks() throws {
        let root = URL(fileURLWithPath: "/private/tmp/remote-private-directory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = try RemotePeerPrivateDirectory.ensureChild(parent: root, name: "Commands")
        let marker = commands.appendingPathComponent("existing-receipt-fixture")
        try Data("preserve".utf8).write(to: marker)
        XCTAssertEqual(try RemotePeerPrivateDirectory.ensureChild(parent: root, name: "Commands"), commands)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "preserve")
        try Data().write(to: root.appendingPathComponent("file"))
        XCTAssertThrowsError(try RemotePeerPrivateDirectory.ensureChild(parent: root, name: "file"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: commands)
        XCTAssertThrowsError(try RemotePeerPrivateDirectory.ensureChild(parent: root, name: "link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: root.appendingPathComponent("absent").path)
        XCTAssertThrowsError(try RemotePeerPrivateDirectory.ensureChild(parent: root, name: "dangling"))
    }
}
