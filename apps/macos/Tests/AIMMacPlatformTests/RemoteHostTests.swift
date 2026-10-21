import AIMCore
@testable import AIMMacPlatform
import XCTest

private final class MemorySecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
}

private actor FakeRelay: RemoteHostBackend {
    var authorizationAllowed = true
    var authorizationFails = false
    var stops: [RemoteAccountStopRequest] = []
    var stopAcknowledgements: [String] = []
    func setAuthorization(allowed: Bool, fails: Bool = false) { authorizationAllowed = allowed; authorizationFails = fails }
    func setStops(_ value: [RemoteAccountStopRequest]) { stops = value }
    func authorizeCommand(machineID: String, secret: String, commandID: String, conversationID: String?) async throws -> Bool {
        if authorizationFails { throw RemoteHostError.server("missing_authorization_rpc") }
        return authorizationAllowed
    }
    func stopRequests(machineID: String, secret: String) async throws -> [RemoteAccountStopRequest] { stops }
    func acknowledgeStop(machineID: String, secret: String, requestID: String) async throws {
        stopAcknowledgements.append(requestID); stops.removeAll { $0.id == requestID }
    }
    var devicesList: [RemoteHostDevice] = []
    var envelopes: [(version: Int, deviceID: String, envelope: RemoteKeyEnvelope)] = []
    var sessions: [RemoteSessionRow] = []
    var messages: [RemoteMessageRow] = []
    var commands: [RemoteHostCommand] = []
    var transitions: [(id: String, status: String, error: String?, result: RemoteJSONValue?)] = []
    var registered = 0
    var publicationCountOverride: Int?
    var publicationCalls = 0
    var pollingFails = false
    var publicationDelay: Duration = .zero

    func setDevices(_ devices: [RemoteHostDevice]) { devicesList = devices }
    func add(_ command: RemoteHostCommand) { commands.append(command) }
    func setPublicationCount(_ count: Int?) { publicationCountOverride = count }
    func setPublicationDelay(_ delay: Duration) { publicationDelay = delay }
    func setPollingFails(_ value: Bool) { pollingFails = value }

    func register(machineID: String, secret: String, name: String, appVersion: String, capabilities: String?) async throws { registered += 1 }
    func createPairingCode(machineID: String, secret: String) async throws -> RemotePairingCode {
        RemotePairingCode(code: "ABC234", expiresAt: .now.addingTimeInterval(300))
    }
    func devices() async throws -> [RemoteHostDevice] { devicesList }
    func revoke(deviceID: String) async throws {
        devicesList = devicesList.map { $0.id == deviceID ? RemoteHostDevice(id: $0.id, name: $0.name, paired_at: $0.paired_at,
            last_used_at: nil, expires_at: nil, revoked_at: .now, public_key: $0.public_key) : $0 }
    }
    func putKeys(machineID: String, secret: String, version: Int, envelopes: [(deviceID: String, envelope: RemoteKeyEnvelope)]) async throws {
        try await Task.sleep(for: publicationDelay)
        publicationCalls += 1
        try RemoteKeyPublicationReceipt(ok: true, error: nil, stored: publicationCountOverride ?? envelopes.count).requireComplete(expected: envelopes.count)
        self.envelopes += envelopes.map { (version, $0.deviceID, $0.envelope) }
    }
    func pendingCommands(machineID: String) async throws -> [RemoteHostCommand] {
        if pollingFails { throw RemoteHostError.server("fixture_poll_refused") }
        return commands.filter { $0.status == "pending" }
    }
    func updateCommand(machineID: String, secret: String, commandID: String, status: String, error: String?, result: RemoteJSONValue?) async throws {
        guard let index = commands.firstIndex(where: { $0.id == commandID }) else { throw RemoteHostError.server("transition_refused") }
        let current = commands[index].status
        guard (current == "pending" && status == "ack") || (current == "ack" && ["done", "error"].contains(status)) else {
            throw RemoteHostError.server("transition_refused")
        }
        let old = commands[index]
        commands[index] = RemoteHostCommand(id: old.id, machine_id: old.machine_id, session_id: old.session_id, type: old.type,
                                            payload: old.payload, status: status, created_at: old.created_at)
        transitions.append((commandID, status, error, result))
    }
    func upsert(sessions: [RemoteSessionRow], messages: [RemoteMessageRow]) async throws {
        self.sessions += sessions
        self.messages += messages
    }
    func deleteMessages(sessionID: String, beforeSequence: Int) async throws {}
    func deleteSessions(machineID: String, keeping ids: Set<String>) async throws {}
    func commandSignals(machineID: String) async -> AsyncStream<Void> { AsyncStream { _ in } }
    var transfers: [String: RemoteHostTransfer] = [:]
    var blocks: [String: Data] = [:]
    var deletedTransfers: [String] = []
    func setTransfer(_ transfer: RemoteHostTransfer, blocks: [String: Data]) {
        transfers[transfer.id] = transfer
        self.blocks.merge(blocks) { $1 }
    }
    func tamper(_ path: String) { if var data = blocks[path] { data[data.count - 1] ^= 0xFF; blocks[path] = data } }
    func userID() async throws -> String { "user-1" }
    func transfer(id: String) async throws -> RemoteHostTransfer? { transfers[id] }
    func downloadBlock(path: String) async throws -> Data {
        guard let data = blocks[path] else { throw RemoteHostError.server("not_found") }
        return data
    }
    func deleteTransfer(id: String, paths: [String]) async throws { deletedTransfers.append(id) }
}

private actor FakeApp: RemoteHostDelegate {
    var stopFails = false
    var stopped: [Set<String>] = []
    func setStopFails(_ value: Bool) { stopFails = value }
    func remoteStop(commandIDs: Set<String>, conversationIDs: Set<String>) async throws {
        if stopFails { throw RemoteHostCommandFailure("fixture_stop_pending") }
        stopped.append(commandIDs.union(conversationIDs))
    }
    var snapshots: [RemoteHostSessionSnapshot] = []
    var executed: [(type: String, payload: RemoteJSONValue)] = []
    func set(_ snapshots: [RemoteHostSessionSnapshot]) { self.snapshots = snapshots }
    func remoteSnapshots() async -> [RemoteHostSessionSnapshot] { snapshots }
    func remoteCapabilities() async -> RemoteCapabilities {
        RemoteCapabilities(version: 1, models: [RemoteModelAnnouncement(id: "m", name: "M", provider: "openrouter")],
                           engines: [RemoteEngineAnnouncement(id: "aim", state: "ready")], features: ["chat": false])
    }
    func remoteExecute(type: String, sessionID: String?, payload: RemoteJSONValue,
                       attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        executed.append((type, payload))
        if type == "stop_generation" { throw RemoteHostCommandFailure("aucune_generation_en_cours") }
        return .object(["echo": payload])
    }
}

final class RemoteHostTests: XCTestCase {
    private func make() -> (RemoteHost, FakeRelay, FakeApp, RemoteHostIdentityStore) {
        let relay = FakeRelay(), app = FakeApp()
        let store = RemoteHostIdentityStore(store: MemorySecureStore())
        let host = RemoteHost(backend: relay, store: store, delegate: app, machineName: "Test Mac", appVersion: "1.0",
                              heartbeat: .seconds(3_600), poll: .seconds(3_600))
        return (host, relay, app, store)
    }

    private func device(_ id: String, key: RemoteDevicePrivateKey) -> RemoteHostDevice {
        RemoteHostDevice(id: id, name: "iPhone", paired_at: .now, last_used_at: nil, expires_at: nil, revoked_at: nil,
                         public_key: key.publicKeyBase64)
    }

    func testPhonesReceiveAMirrorKeyTheyCanOpenAndRevocationRotatesIt() async throws {
        let (host, relay, _, store) = make()
        let phone = RemoteDevicePrivateKey(), tablet = RemoteDevicePrivateKey()
        await relay.setDevices([device("phone", key: phone), device("tablet", key: tablet)])
        await host.start()
        let identity = try XCTUnwrap(try store.load())
        let first = await relay.envelopes
        XCTAssertEqual(Set(first.map(\.deviceID)), ["phone", "tablet"])
        let phoneEnvelope = try XCTUnwrap(first.first { $0.deviceID == "phone" }?.envelope)
        let opened = try RemoteCrypto.openEnvelope(phoneEnvelope, devicePrivateKey: phone, machineID: identity.machineID, deviceID: "phone")
        XCTAssertEqual(opened, identity.currentKey)

        try await host.revoke(deviceID: "tablet")
        let rotated = try XCTUnwrap(try store.load())
        XCTAssertEqual(rotated.keyVersion, 2, "revoking a keyed device rotates the mirror key")
        XCTAssertNotEqual(rotated.currentKey, identity.currentKey)
        let latest = await relay.envelopes.filter { $0.version == 2 }
        XCTAssertEqual(latest.map(\.deviceID), ["phone"], "the revoked tablet gets nothing new")
        await host.stop()
    }

    func testConcurrentHeartbeatAndKeyRequestCannotPublishDifferentKeysForOneRotation() async throws {
        let (host, relay, _, store) = make()
        let phone = RemoteDevicePrivateKey(), tablet = RemoteDevicePrivateKey()
        await relay.setDevices([device("phone", key: phone), device("tablet", key: tablet)])
        await host.start()
        await relay.setDevices([device("phone", key: phone)])
        await relay.setPublicationDelay(.milliseconds(80))
        async let heartbeat = host.syncKeys()
        async let request = host.syncKeys(forceRepublish: true)
        _ = try await (heartbeat, request)
        let identity = try XCTUnwrap(try store.load())
        XCTAssertEqual(identity.keyVersion, 2)
        let envelopes = await relay.envelopes.filter { $0.version == 2 && $0.deviceID == "phone" }
        XCTAssertFalse(envelopes.isEmpty)
        for row in envelopes {
            XCTAssertEqual(try RemoteCrypto.openEnvelope(row.envelope, devicePrivateKey: phone,
                machineID: identity.machineID, deviceID: "phone"), identity.currentKey)
        }
        let report = await host.diagnosticReport()
        XCTAssertTrue(report.entries.contains { $0.status == "stored_complete" })
        XCTAssertEqual(report.links?.first?.openedVersions, [], "Host acceptance is not iPhone opening proof")
        await host.stop()
    }

    func testSameDeviceIDWithNewPublicKeyRepublishesAndExplicitRequestRepublishesAgain() async throws {
        let (host, relay, _, store) = make()
        let original = RemoteDevicePrivateKey(), repaired = RemoteDevicePrivateKey()
        await relay.setDevices([device("phone", key: original)])
        await host.start()
        let before = try XCTUnwrap(try store.load())
        await relay.setDevices([device("phone", key: repaired)])
        _ = try await host.syncKeys()
        let after = try XCTUnwrap(try store.load())
        XCTAssertEqual(after.keyVersion, before.keyVersion, "repair republishes without revocation rotation")
        XCTAssertEqual(after.currentKey, before.currentKey)
        XCTAssertEqual(after.keyedDeviceFingerprints["phone"], RemoteHostIdentity.publicKeyFingerprint(repaired.publicKeyBase64))
        let returnedEnvelopes = await relay.envelopes
        let envelope = try XCTUnwrap(returnedEnvelopes.last?.envelope)
        XCTAssertEqual(try RemoteCrypto.openEnvelope(envelope, devicePrivateKey: repaired,
            machineID: after.machineID, deviceID: "phone"), after.currentKey)
        let count = await relay.envelopes.count
        _ = try await host.syncKeys()
        let unchangedCount = await relay.envelopes.count
        XCTAssertEqual(unchangedCount, count, "unchanged heartbeat remains idempotent")
        _ = try await host.syncKeys(forceRepublish: true)
        let forcedCount = await relay.envelopes.count
        XCTAssertEqual(forcedCount, count + 1)
        await host.stop()
    }

    func testLegacyIdentityDecodePreservesMaterialAndDefaultsFingerprintsToEmpty() throws {
        var identity = RemoteHostIdentity.fresh()
        identity.keyedDevices = ["already-served-phone"]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
        object.removeValue(forKey: "keyedDeviceFingerprints")
        let restored = try JSONDecoder().decode(RemoteHostIdentity.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, identity)
        XCTAssertTrue(restored.keyedDeviceFingerprints.isEmpty)
    }

    func testPublicationRequiresExactStoredCountAndBatchesDoNotDropDevices() throws {
        for count in [nil, 0, 1, -1, 3] as [Int?] {
            XCTAssertThrowsError(try RemoteKeyPublicationReceipt(ok: true, error: nil, stored: count).requireComplete(expected: 2))
        }
        try RemoteKeyPublicationReceipt(ok: true, error: nil, stored: 2).requireComplete(expected: 2)
        XCTAssertThrowsError(try RemoteKeyPublicationReceipt(ok: false, error: "machine_secret_mismatch", stored: 2).requireComplete(expected: 2))
        let envelope = RemoteKeyEnvelope(version: 1, keyVersion: 1, ephemeralPublicKey: "fixture", nonce: "fixture", ciphertext: "fixture")
        let input = (0..<21).map { (deviceID: "phone-\($0)", envelope: envelope) }
        let batches = SupabaseRemoteHostBackend.keyPublicationBatches(input)
        XCTAssertEqual(batches.map(\.count), [10, 10, 1])
        XCTAssertEqual(batches.flatMap { $0.map(\.deviceID) }, input.map(\.deviceID))
    }

    func testRequestKeysPartialReceiptReportsFailureAndHeartbeatRetriesWithoutFingerprintChange() async throws {
        let (host, relay, _, store) = make()
        await relay.setDevices([device("phone", key: RemoteDevicePrivateKey())])
        await host.start()
        let identity = try XCTUnwrap(try store.load())
        let beforeCalls = await relay.publicationCalls
        await relay.setPublicationCount(0)
        let command = RemoteHostCommand(id: "key-request", machine_id: identity.machineID, session_id: nil,
            type: "request_keys", payload: .object([:]), status: "pending", created_at: .now)
        await relay.add(command)
        await host.run(command)
        let transitions = await relay.transitions
        XCTAssertEqual(transitions.last?.status, "error")
        XCTAssertEqual(transitions.last?.error, "key_publication_incomplete")
        let failedStatus = await host.status
        XCTAssertEqual(failedStatus, .failed(RemoteHostError.server("key_publication_incomplete").localizedDescription))
        XCTAssertEqual(try store.load(), identity, "unaccepted publication must not mutate historical identity material")
        await relay.setPublicationCount(nil)
        _ = try await host.syncKeys()
        let afterCalls = await relay.publicationCalls
        XCTAssertEqual(afterCalls, beforeCalls + 2, "failed force remains pending even with unchanged fingerprints")
        await host.stop()
    }

    func testStartRevalidatesPersistedFingerprintsAndPollingFailureIsVisible() async throws {
        let (host, relay, _, store) = make()
        await relay.setDevices([device("phone", key: RemoteDevicePrivateKey())])
        await host.start()
        let firstCount = await relay.publicationCalls
        await host.stop()
        await host.start()
        let restartedCount = await relay.publicationCalls
        XCTAssertEqual(restartedCount, firstCount + 1, "persisted fingerprints alone do not prove current relay storage")
        let identity = try XCTUnwrap(try store.load())
        XCTAssertEqual(identity.keyedDevices, ["phone"])
        await relay.setPollingFails(true)
        await host.processCommands()
        let failedStatus = await host.status
        XCTAssertEqual(failedStatus, .failed(RemoteHostError.server("remote_commands_poll_failed").localizedDescription))
        await host.stop()
    }

    func testMirrorIsEncryptedPerFieldAndOnlyChangesAreSent() async throws {
        let (host, relay, app, store) = make()
        let snapshot = RemoteHostSessionSnapshot(id: "conv-1", mode: "agent", title: "Fix the build", workspace: "/Users/example/app",
            modelID: "anthropic/claude-sonnet-5.5", approvalMode: "smart", agentSystem: "aim", status: "idle", updatedAt: Date(timeIntervalSince1970: 10),
            messages: [RemoteHostMessageSnapshot(id: "m1", sequence: 0, role: "user", content: "Make tests pass", createdAt: .now),
                       RemoteHostMessageSnapshot(id: "m2", sequence: 1, role: "assistant", content: "Done.", model: "m", createdAt: .now)])
        await app.set([snapshot])
        await host.start()
        let identity = try XCTUnwrap(try store.load())
        let sentSessions = await relay.sessions
        let session = try XCTUnwrap(sentSessions.first)
        XCTAssertTrue(RemoteCrypto.isEncrypted(session.title))
        XCTAssertEqual(try RemoteCrypto.decryptField(session.title, keys: identity.keys,
            context: RemoteFieldContext(table: "remote_sessions", column: "title", rowID: "conv-1")), "Fix the build")
        XCTAssertEqual(session.message_count, 2)
        let sentMessages = await relay.messages
        let reply = try XCTUnwrap(sentMessages.first { $0.id == "m2" })
        XCTAssertEqual(try RemoteCrypto.decryptField(reply.content, keys: identity.keys,
            context: RemoteFieldContext(table: "remote_messages", column: "content", rowID: "m2")), "Done.")
        XCTAssertThrowsError(try RemoteCrypto.decryptField(reply.content, keys: identity.keys,
            context: RemoteFieldContext(table: "remote_messages", column: "content", rowID: "m1")), "a value moved to another row does not open")

        await host.publish()
        let afterSecond = await (relay.sessions.count, relay.messages.count)
        XCTAssertEqual(afterSecond.0, 1, "nothing changed, nothing re-sent")
        XCTAssertEqual(afterSecond.1, 2)

        var updated = snapshot
        updated.status = "running"
        updated.messages.append(RemoteHostMessageSnapshot(id: "m3", sequence: 2, role: "user", content: "Again", createdAt: .now))
        await app.set([updated])
        await host.publish()
        let afterThird = await (relay.sessions.count, relay.messages.map(\.id))
        XCTAssertEqual(afterThird.0, 2)
        XCTAssertEqual(afterThird.1, ["m1", "m2", "m3"], "only the new message is sent")
        await host.stop()
    }

    func testCommandsRunOnceWithEncryptedPayloadsAndResults() async throws {
        let (host, relay, app, store) = make()
        await host.start()
        let identity = try XCTUnwrap(try store.load())
        func sealed(_ id: String, _ type: String, _ value: RemoteJSONValue) throws -> RemoteJSONValue {
            let command = RemoteCommandIdentity(id: id, type: type, sessionID: "conv-1", machineID: identity.machineID)
            return try RemoteHostMirror.result(value, command: command, key: identity.currentKey, version: identity.keyVersion)
                .objectValue.map { _ in
                    .object(["e": .string(try RemoteCrypto.encryptField(RemoteHostMirror.json(value), key: identity.currentKey,
                        version: identity.keyVersion, context: command.context(for: .payload)))])
                }!
        }
        await relay.add(RemoteHostCommand(id: "c1", machine_id: identity.machineID, session_id: "conv-1", type: "user_message",
                                          payload: try sealed("c1", "user_message", .object(["text": .string("Hello")])), status: "pending", created_at: .now))
        await relay.add(RemoteHostCommand(id: "c2", machine_id: identity.machineID, session_id: "conv-1", type: "user_message",
                                          payload: .object(["text": .string("clear")]), status: "pending", created_at: .now))
        await relay.add(RemoteHostCommand(id: "c3", machine_id: identity.machineID, session_id: "conv-1", type: "stop_generation",
                                          payload: try sealed("c3", "stop_generation", .object([:])), status: "pending", created_at: .now))
        // A payload copied from c1 onto another command id does not open.
        await relay.add(RemoteHostCommand(id: "c4", machine_id: identity.machineID, session_id: "conv-1", type: "user_message",
                                          payload: try sealed("c1", "user_message", .object(["text": .string("replay")])), status: "pending", created_at: .now))
        await host.processCommands()
        try await Task.sleep(for: .milliseconds(500))
        await host.processCommands()
        let transitions = await relay.transitions
        func final(_ id: String) -> (String, String?, RemoteJSONValue?)? {
            transitions.last { $0.id == id }.map { ($0.status, $0.error, $0.result) }
        }
        XCTAssertEqual(final("c1")?.0, "done")
        let result = try XCTUnwrap(final("c1")?.2?.objectValue?["e"]?.stringValue)
        let clear = try RemoteCrypto.decryptField(result, keys: identity.keys,
            context: RemoteCommandIdentity(id: "c1", type: "user_message", sessionID: "conv-1", machineID: identity.machineID).context(for: .result))
        XCTAssertTrue(clear.contains("Hello"))
        XCTAssertEqual(final("c2")?.1, "charge_non_chiffree")
        XCTAssertEqual(final("c3")?.1, "aucune_generation_en_cours")
        XCTAssertEqual(final("c4")?.1, "charge_illisible")
        XCTAssertEqual(transitions.filter { $0.id == "c1" && $0.status == "ack" }.count, 1, "each command runs once")
        let executed = await app.executed.map(\.type)
        XCTAssertEqual(executed.sorted(), ["stop_generation", "user_message"])
        await host.stop()
    }

    func testMissingOrRefusedServerAuthorizationNeverAcknowledgesOrExecutes() async throws {
        let (host, relay, app, store) = make(); await host.start()
        let identity = try XCTUnwrap(try store.load())
        let command = RemoteHostCommand(id: "refused", machine_id: identity.machineID, session_id: "conversation", type: "user_message", payload: nil, status: "pending", created_at: .now)
        for fails in [false, true] {
            await relay.setAuthorization(allowed: false, fails: fails)
            await host.run(command)
        }
        let transitions = await relay.transitions, executed = await app.executed
        XCTAssertTrue(transitions.isEmpty); XCTAssertTrue(executed.isEmpty)
        await host.stop()
    }

    func testStopAcknowledgementWaitsForDelegateAndRetriesFailure() async throws {
        let (host, relay, app, _) = make(); await host.start()
        await relay.setStops([.init(id: "stop-request", command_ids: ["command"], conversation_ids: ["conversation"])])
        await app.setStopFails(true)
        do { try await host.processAccountStopRequests(); XCTFail("Failed stop must remain pending") } catch { }
        let first = await relay.stopAcknowledgements; XCTAssertTrue(first.isEmpty)
        await app.setStopFails(false)
        try await host.processAccountStopRequests()
        let confirmed = await relay.stopAcknowledgements, stopped = await app.stopped
        XCTAssertEqual(confirmed, ["stop-request"]); XCTAssertEqual(stopped, [Set(["command", "conversation"])])
        await host.stop()
    }

    func testFoldersStayInsideHomeAndSkipHiddenOnes() throws {
        let roots = try RemoteHostFolders.list(nil)
        XCTAssertFalse((roots.objectValue?["roots"]?.arrayValue ?? []).isEmpty)
        XCTAssertThrowsError(try RemoteHostFolders.list("/etc"))
        XCTAssertThrowsError(try RemoteHostFolders.list("~/.ssh"))
        XCTAssertThrowsError(try RemoteHostFolders.create(parent: "~", name: "../escape"))
        XCTAssertThrowsError(try RemoteHostFolders.create(parent: "/tmp", name: "x"))
    }
}

final class RemotePairingLinkTests: XCTestCase {
    func testQRCodeCarriesOnlyTheOneTimeCode() throws {
        let url = RemotePairingLink.url(code: "ABC234", machineName: "Example MacBook")
        XCTAssertEqual(url.scheme, "aim")
        XCTAssertEqual(url.host, "remote")
        XCTAssertEqual(url.path, "/pair")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Set(items.map(\.name)), ["code", "name", "v"], "never the machine secret")
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "ABC234")
        XCTAssertNotNil(RemotePairingLink.image(for: url))
    }
}


final class RemoteHostAttachmentTests: XCTestCase {
    private let machineID = "11111111-1111-1111-1111-111111111111"
    private let key = Data(repeating: 7, count: 32)

    /// Uploads like the iPhone does (AIMCore's own encryption), into the fake relay.
    private func upload(_ data: Data, name: String, session: String, relay: FakeRelay) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let transfer = try RemoteTransferCrypto.prepareAttachment(data: data, key: key, keyVersion: 1, transferID: id,
            machineID: machineID, sessionID: session, filename: name, mimeType: "text/plain")
        var blocks: [String: Data] = [:]
        for block in transfer.blocks {
            blocks[try RemoteTransferCrypto.storagePath(userID: "user-1", manifest: transfer.manifest, index: block.index)] = block.encrypted
        }
        await relay.setTransfer(RemoteHostTransfer(id: id, machine_id: machineID, session_id: session, kind: "attachment",
            key_version: 1, manifest: try RemoteTransferCrypto.sealManifest(transfer.manifest, key: key),
            chunk_count: transfer.manifest.chunkCount, status: "ready"), blocks: blocks)
        return id
    }

    private func payload(_ ids: [String]) -> RemoteJSONValue {
        .object(["text": .string("see attached"), "attachments": .array(ids.map { .object(["transfer_id": .string($0), "name": .string("notes.txt"), "mime": .string("text/plain"), "size": .number(5)]) })])
    }

    func testVerifiedAttachmentsAreReturnedAndRelayCopiesDeleted() async throws {
        let relay = FakeRelay()
        let content = Data(repeating: 65, count: 1_500_000) // two blocks
        let id = try await upload(content, name: "notes.txt", session: "conv-1", relay: relay)
        let files = try await RemoteHostAttachments.fetch(payload: payload([id]), sessionID: "conv-1", machineID: machineID,
                                                          keys: [1: key], backend: relay)
        XCTAssertEqual(files.first?.data, content)
        XCTAssertEqual(files.first?.name, "notes.txt")
        let deleted = await relay.deletedTransfers
        XCTAssertEqual(deleted, [id])
    }

    func testForeignTamperedOrMissingAttachmentsAreRefused() async throws {
        let relay = FakeRelay()
        let other = try await upload(Data("hello".utf8), name: "a.txt", session: "conv-2", relay: relay)
        await assertFails(relay, [other], "piece_jointe_etrangere")
        let good = try await upload(Data("hello".utf8), name: "b.txt", session: "conv-1", relay: relay)
        let bad = try await upload(Data("world".utf8), name: "c.txt", session: "conv-1", relay: relay)
        await relay.tamper("user-1/\(machineID)/\(bad)/000000.bin")
        await assertFails(relay, [good, bad], "piece_jointe_illisible")
        let kept = await relay.deletedTransfers
        XCTAssertTrue(kept.isEmpty, "all or nothing: the good one is not consumed either")
        await assertFails(relay, [UUID().uuidString], "piece_jointe_introuvable")
        await assertFails(relay, Array(repeating: good, count: 5), "trop_de_pieces_jointes")
    }

    private func assertFails(_ relay: FakeRelay, _ ids: [String], _ code: String, line: UInt = #line) async {
        do {
            _ = try await RemoteHostAttachments.fetch(payload: payload(ids), sessionID: "conv-1", machineID: machineID,
                                                      keys: [1: key], backend: relay)
            XCTFail("expected \(code)", line: line)
        } catch let failure as RemoteHostCommandFailure {
            XCTAssertEqual(failure.code, code, line: line)
        } catch {
            XCTFail("\(error)", line: line)
        }
    }

    func testSavingIntoTheWorkspaceNeverOverwrites() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("aim-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let file = RemoteHostAttachment(name: "../../photo.png", mimeType: "image/png", data: Data(repeating: 1, count: 2_048))
        let first = try RemoteHostAttachments.save([file], workspace: workspace.path, now: date)
        let second = try RemoteHostAttachments.save([file], workspace: workspace.path, now: date)
        XCTAssertNotEqual(first.urls, second.urls)
        XCTAssertTrue(first.urls[0].path.hasPrefix(workspace.appendingPathComponent(".aim/pieces-jointes").path), "never outside")
        XCTAssertTrue(first.note.hasPrefix("Pièce jointe envoyée depuis le téléphone, enregistrée dans le dossier de travail :"))
        XCTAssertTrue(first.note.contains("photo.png (image/png"))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent(".aim/pieces-jointes/.gitignore"), encoding: .utf8), "*\n")
    }
}

extension RemoteHostTests {
    func testContinuityMetadataIsEncryptedAndChangesMirrorFingerprint() throws {
        let key = Data(repeating: 3, count: 32), response = ConversationResponseVersion(id: "stable-answer", completedAt: .now)
        let original = RemoteHostSessionSnapshot(id: "conversation", mode: "code", title: "test", updatedAt: .now, messages: [])
        var announced = original; announced.executionDeviceIDs = ["mac"]; announced.latestResponseVersion = response
        XCTAssertNotEqual(RemoteHost.hash(original, includeMessages: false), RemoteHost.hash(announced, includeMessages: false))
        let row = try RemoteHostMirror.sessionRow(announced, machineID: "mac", key: key, version: 1)
        let encrypted = try XCTUnwrap(row.phase)
        XCTAssertFalse(encrypted.contains("stable-answer"))
        let clear = try RemoteCrypto.decryptField(encrypted, keys: [1: key], context: RemoteFieldContext(table: "remote_sessions", column: "phase", rowID: "conversation"))
        let decoded = RemoteConversationAnnouncement.decode(phase: clear)
        XCTAssertEqual(decoded.executionDeviceIDs, ["mac"]); XCTAssertEqual(decoded.latestResponseVersion, response)
        XCTAssertNil(original.latestResponseVersion)
    }
}
