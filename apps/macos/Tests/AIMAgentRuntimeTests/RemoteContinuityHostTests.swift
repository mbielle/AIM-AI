import AIMApplication
import AIMAgentKit
import AIMCore
@testable import AIMMacPlatform
@testable import AIMAgentRuntime
import XCTest

private final class ContinuityRemoteSecrets: SecureStoring, @unchecked Sendable {
    let lock = NSLock(); var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
}
private actor DurableRemoteDelegate: RemoteHostDelegate {
    var calls = 0
    func remoteSnapshots() async -> [RemoteHostSessionSnapshot] { [] }
    func remoteCapabilities() async -> RemoteCapabilities { RemoteCapabilities(version: 1, models: [], engines: [], features: [:]) }
    func remoteExecute(type: String, sessionID: String?, payload: RemoteJSONValue, attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        calls += 1; return .object(["admitted": .bool(true)])
    }
}
private actor DurableRemoteRelay: RemoteHostBackend {
    func authorizeCommand(machineID: String, secret: String, commandID: String, conversationID: String?) async throws -> Bool { true }
    var states: [String: String] = [:]
    var failDone = true
    var delivered: RemoteJSONValue?
    func add(_ id: String) { states[id] = "pending" }
    func register(machineID: String, secret: String, name: String, appVersion: String, capabilities: String?) async throws {}
    func createPairingCode(machineID: String, secret: String) async throws -> RemotePairingCode { .init(code: "fake", expiresAt: .now) }
    func devices() async throws -> [RemoteHostDevice] { [] }
    func revoke(deviceID: String) async throws {}
    func putKeys(machineID: String, secret: String, version: Int, envelopes: [(deviceID: String, envelope: RemoteKeyEnvelope)]) async throws {}
    func pendingCommands(machineID: String) async throws -> [RemoteHostCommand] { [] }
    func commandStatus(commandID: String, machineID: String) async throws -> String? { states[commandID] }
    func updateCommand(machineID: String, secret: String, commandID: String, status: String, error: String?, result: RemoteJSONValue?) async throws {
        if status == "done", failDone { failDone = false; throw RemoteHostError.server("network") }
        guard (states[commandID] == "pending" && status == "ack") || (states[commandID] == "ack" && ["done", "error"].contains(status)) else {
            throw RemoteHostError.server("transition_refused")
        }
        states[commandID] = status; if status == "done" { delivered = result }
    }
    func upsert(sessions: [RemoteSessionRow], messages: [RemoteMessageRow]) async throws {}
    func deleteMessages(sessionID: String, beforeSequence: Int) async throws {}
    func deleteSessions(machineID: String, keeping ids: Set<String>) async throws {}
    func commandSignals(machineID: String) async -> AsyncStream<Void> { AsyncStream { _ in } }
    func userID() async throws -> String { "account-A" }
    func transfer(id: String) async throws -> RemoteHostTransfer? { nil }
    func downloadBlock(path: String) async throws -> Data { throw RemoteHostError.server("unused") }
    func deleteTransfer(id: String, paths: [String]) async throws {}
}
private actor AckCrashJournal: RemoteHostCommandJournal {
    let inner: SQLiteRemoteCommandJournal
    var failAck: Bool
    init(_ inner: SQLiteRemoteCommandJournal, failAck: Bool) { self.inner = inner; self.failAck = failAck }
    func prepare(_ command: RemoteHostCommand, accountID: String) async throws -> RemoteHostCommandReceipt { try await inner.prepare(command, accountID: accountID) }
    func complete(_ id: String, accountID: String, machineID: String, result: RemoteJSONValue?, error: String?) async throws -> RemoteHostCommandReceipt {
        try await inner.complete(id, accountID: accountID, machineID: machineID, result: result, error: error)
    }
    func acknowledge(_ id: String, accountID: String, machineID: String) async throws -> RemoteHostCommandReceipt {
        if failAck { failAck = false; throw RemoteHostError.server("simulated_crash") }
        return try await inner.acknowledge(id, accountID: accountID, machineID: machineID)
    }
    func delivered(_ id: String, accountID: String, machineID: String) async throws { try await inner.delivered(id, accountID: accountID, machineID: machineID) }
    func pending(accountID: String, machineID: String) async throws -> [RemoteHostCommandReceipt] { try await inner.pending(accountID: accountID, machineID: machineID) }
}

final class RemoteContinuityHostTests: XCTestCase {
    private func command(identity: RemoteHostIdentity) throws -> RemoteHostCommand {
        let id = UUID().uuidString, session = UUID().uuidString
        let commandIdentity = RemoteCommandIdentity(id: id, type: "goal_start", sessionID: session, machineID: identity.machineID)
        let clear = RemoteJSONValue.object(["text": .string("work"), "goal": RemoteContinuousGoalConfiguration().json])
        let cipher = try RemoteCrypto.encryptField(RemoteHostMirror.json(clear), key: identity.currentKey,
            version: identity.keyVersion, context: commandIdentity.context(for: .payload))
        let json = RemoteJSONValue.object(["id": .string(id), "machine_id": .string(identity.machineID),
            "session_id": .string(session), "type": .string("goal_start"), "payload": .object(["e": .string(cipher)]), "status": .string("pending")])
        return try JSONDecoder().decode(RemoteHostCommand.self, from: Data(RemoteHostMirror.json(json).utf8))
    }
    func testCompletionAndServerAckCrashesRecoverWithoutExecutingAgain() async throws {
        for ackCrash in [false, true] {
            let db = try AIMDatabase(inMemory: true), owner = UUID()
            let executions = SQLiteAgentExecutionRepository(database: db); try await executions.installOwner(owner)
            let journal = SQLiteRemoteCommandJournal(database: db, owner: owner)
            let crash = AckCrashJournal(journal, failAck: ackCrash)
            let relay = DurableRemoteRelay(), delegate = DurableRemoteDelegate()
            let store = RemoteHostIdentityStore(store: ContinuityRemoteSecrets())
            let identity = try store.loadOrCreate()
            let host = RemoteHost(backend: relay, store: store, delegate: delegate,
                heartbeat: .seconds(3600), poll: .seconds(3600), journal: crash)
            await host.start()
            let command = try command(identity: identity); await relay.add(command.id)
            await host.run(command)
            let firstCalls = await delegate.calls; XCTAssertEqual(firstCalls, 1)
            let persisted = try await journal.pending(accountID: "account-A", machineID: identity.machineID)
            XCTAssertEqual(persisted.count, 1); XCTAssertTrue(persisted[0].completed)
            XCTAssertEqual(persisted[0].acknowledged, !ackCrash)
            let wrongAccount = try await journal.pending(accountID: "account-B", machineID: identity.machineID)
            XCTAssertTrue(wrongAccount.isEmpty)
            await host.stop()
            // New adapter instance over the same database, as after process restart.
            let restored = SQLiteRemoteCommandJournal(database: db, owner: owner)
            let replacement = RemoteHost(backend: relay, store: store, delegate: delegate,
                heartbeat: .seconds(3600), poll: .seconds(3600), journal: restored)
            await replacement.start()
            for _ in 0..<3 { await replacement.run(command) }
            let calls = await delegate.calls; XCTAssertEqual(calls, 1)
            let pending = try await restored.pending(accountID: "account-A", machineID: identity.machineID)
            XCTAssertTrue(pending.isEmpty)
            let delivered = await relay.delivered
            let encrypted = try XCTUnwrap(delivered?.objectValue?["e"]?.stringValue)
            let decoded = try RemoteCrypto.decryptField(encrypted, keys: identity.keys, context: command.identity.context(for: .result))
            XCTAssertTrue(decoded.contains("admitted"))
            await replacement.stop()
        }
    }
    func testReceiptFencesOldOwnerAndRejectsChangedCommand() async throws {
        let db = try AIMDatabase(inMemory: true), owner = UUID()
        let repository = SQLiteAgentExecutionRepository(database: db); try await repository.installOwner(owner)
        let store = RemoteHostIdentityStore(store: ContinuityRemoteSecrets())
        let command = try command(identity: store.loadOrCreate())
        let journal = SQLiteRemoteCommandJournal(database: db, owner: owner)
        _ = try await journal.prepare(command, accountID: "account-A")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
        json["type"] = "goal_cancel"
        let changed = try JSONDecoder().decode(RemoteHostCommand.self, from: JSONSerialization.data(withJSONObject: json))
        do { _ = try await journal.prepare(changed, accountID: "account-A"); XCTFail("changed command accepted") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .commandConflict) }
        try await repository.installOwner(UUID())
        do { _ = try await journal.complete(command.id, accountID: "account-A", machineID: command.machine_id, result: nil, error: nil); XCTFail("old owner wrote") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
    }
}
