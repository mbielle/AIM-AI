import Foundation
import XCTest
@testable import AIMCore

final class DirectRemoteTests: XCTestCase, @unchecked Sendable {
    private func fixture(store: any SecureStoring = DirectTestStore()) async throws -> (DirectRemoteIdentity, DirectRemoteIdentity, DirectRemotePairingHost, DirectRemoteInvite, DirectRemotePair) {
        let host = DirectRemoteIdentity(profile: .init(id: UUID()), role: .mac, name: "Synthetic Mac")
        let phone = DirectRemoteIdentity(profile: .init(id: UUID()), role: .phone, name: "Synthetic phone")
        let authority = try DirectRemotePairingHost(identity: host, store: store)
        let invite = try await authority.createInvite()
        let claim = try DirectRemoteClaim(invite: invite, client: phone.publicIdentity)
        _ = try await authority.propose(claim)
        let confirmation = try await authority.confirmDevice(phone.publicIdentity.id, permissions: [.read, .chat])
        return (host, phone, authority, invite, try confirmation.accept(invite: invite, client: phone))
    }
    func testPairingRequiresExplicitMacConfirmationConsumesInviteAndPinsIdentity() async throws {
        let host = DirectRemoteIdentity(profile: .init(id: UUID()), role: .mac, name: "Mac")
        let phone = DirectRemoteIdentity(profile: .init(id: UUID()), role: .phone, name: "Phone")
        let authority = try DirectRemotePairingHost(identity: host, store: DirectTestStore())
        let invite = try await authority.createInvite()
        let roundtrip = try DirectRemoteInvite.decodeQR(invite.qrURL())
        XCTAssertEqual(roundtrip, invite)
        let claim = try DirectRemoteClaim(invite: invite, client: phone.publicIdentity)
        _ = try await authority.propose(claim)
        do { _ = try await authority.pair(invite.id); XCTFail("A claim is not authorization") } catch { }
        let confirmation = try await authority.confirmDevice(phone.publicIdentity.id, permissions: [.read])
        let pair = try confirmation.accept(invite: invite, client: phone)
        XCTAssertEqual(try host.sessionKey(pair: pair), try phone.sessionKey(pair: pair))
        do { _ = try await authority.confirmDevice(phone.publicIdentity.id, permissions: [.terminal]); XCTFail() } catch { }
        let impostor = DirectRemoteIdentity(profile: .init(id: UUID()), role: .phone, name: "Phone")
        XCTAssertThrowsError(try confirmation.accept(invite: invite, client: impostor))
    }
    func testExpiredAndCancelledInvitationsFailClosed() async throws {
        let host = DirectRemoteIdentity(profile: .init(id: UUID()), role: .mac, name: "Mac")
        let phone = DirectRemoteIdentity(profile: .init(id: UUID()), role: .phone, name: "Phone")
        let authority = try DirectRemotePairingHost(identity: host, store: DirectTestStore())
        let invitation = try await authority.createInvite()
        XCTAssertThrowsError(try DirectRemoteClaim(invite: invitation, client: phone.publicIdentity, now: invitation.expiresAt))
        let claim = try DirectRemoteClaim(invite: invitation, client: phone.publicIdentity)
        try await authority.cancelInvitation()
        do { _ = try await authority.propose(claim); XCTFail() } catch { }
    }
    func testCipherBindsPairDirectionRevisionSequenceAndPurpose() async throws {
        let (host, phone, _, _, pair) = try await fixture()
        let packet = try DirectRemoteCipher.seal(Data("synthetic".utf8), identity: phone, pair: pair, id: UUID(), sequence: 1, kind: .request)
        XCTAssertEqual(try DirectRemoteCipher.open(packet, identity: host, pair: pair), Data("synthetic".utf8))
        XCTAssertThrowsError(try DirectRemoteCipher.open(packet, identity: phone, pair: pair))
        var revised = pair; revised.revision += 1
        XCTAssertThrowsError(try DirectRemoteCipher.open(packet, identity: host, pair: revised))
        let tampered = DirectRemotePacket(version: packet.version, pairID: packet.pairID, revision: packet.revision, sender: packet.sender,
            recipient: packet.recipient, id: packet.id, sequence: 2, kind: .reply, ciphertext: packet.ciphertext)
        XCTAssertThrowsError(try DirectRemoteCipher.open(tampered, identity: host, pair: pair))
    }
    func testDurableCommandRetriesDoNotRepeatEffectsAndConflictFails() async throws {
        let (host, _, authority, _, pair) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-direct-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = DirectCountingEndpoint()
        let dispatcher = try DirectRemoteHostDispatcher(identity: host, pairingHost: authority, endpoint: endpoint, journalDirectory: root)
        let id = UUID(), payload = RemoteJSONValue.object(["text": .string("synthetic")])
        let first = try await dispatcher.execute(operation: "createSession", payload: payload, commandID: id, pair: pair)
        let reloaded = try DirectRemoteHostDispatcher(identity: host, pairingHost: authority, endpoint: endpoint, journalDirectory: root)
        let second = try await reloaded.execute(operation: "createSession", payload: payload, commandID: id, pair: pair)
        XCTAssertEqual(first, second); let count = await endpoint.count; XCTAssertEqual(count, 1)
        do { _ = try await reloaded.execute(operation: "createSession", payload: .null, commandID: id, pair: pair); XCTFail() }
        catch { XCTAssertEqual(error as? DirectRemoteError, .conflictingCommand) }
        try await authority.revoke(pair.id)
        do { _ = try await reloaded.execute(operation: "overview", payload: .null, commandID: UUID(), pair: pair); XCTFail() } catch { }
    }
    func testAdmittedEffectWithUnknownOutcomeIsNotRetriedAfterRestart() async throws {
        let (host, _, authority, _, pair) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-direct-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = DirectCountingEndpoint(fail: true), id = UUID()
        let dispatcher = try DirectRemoteHostDispatcher(identity: host, pairingHost: authority, endpoint: endpoint, journalDirectory: root)
        do { _ = try await dispatcher.execute(operation: "command", payload: .null, commandID: id, pair: pair); XCTFail() } catch { }
        let reloaded = try DirectRemoteHostDispatcher(identity: host, pairingHost: authority, endpoint: endpoint, journalDirectory: root)
        do { _ = try await reloaded.execute(operation: "command", payload: .null, commandID: id, pair: pair); XCTFail() }
        catch { XCTAssertEqual(error as? DirectRemoteError, .outcomeUnknown) }
        let count = await endpoint.count; XCTAssertEqual(count, 1)
    }
    func testIdentityAndPairsAreScopedToRealLocalProfiles() throws {
        let store = DirectTestStore(), profile = LocalProfile(id: UUID())
        let first = try DirectRemoteIdentity.loadOrCreate(profile: profile, role: .phone, name: "Phone", store: store)
        let second = try DirectRemoteIdentity.loadOrCreate(profile: profile, role: .phone, name: "Renamed", store: store)
        XCTAssertEqual(first.publicIdentity, second.publicIdentity)
        let other = try DirectRemoteIdentity.loadOrCreate(profile: .init(id: UUID()), role: .phone, name: "Other", store: store)
        XCTAssertNotEqual(other.publicIdentity.id, first.publicIdentity.id)
    }
    func testFailedVisibleGrantPersistenceDoesNotCreateAnInvisibleAuthority() async throws {
        let store = DirectFailingGrantStore()
        let host = DirectRemoteIdentity(profile: .init(id: UUID()), role: .mac, name: "Mac")
        let phone = DirectRemoteIdentity(profile: .init(id: UUID()), role: .phone, name: "Phone")
        let authority = try DirectRemotePairingHost(identity: host, store: store)
        let invitation = try await authority.createInvite()
        _ = try await authority.propose(DirectRemoteClaim(invite: invitation, client: phone.publicIdentity))
        do { _ = try await authority.confirmDevice(phone.publicIdentity.id, permissions: [.read]); XCTFail() } catch { }
        do { _ = try await authority.pair(invitation.id); XCTFail("No invisible second grant store") } catch { }
        XCTAssertTrue(try DirectRemotePairStore(profile: .init(id: host.publicIdentity.localProfileID), store: store).pairs().isEmpty)
    }
    func testEventSubscriptionsAreIndependentAcrossUICancellation() async throws {
        let (_, phone, _, _, pair) = try await fixture()
        let channel = DirectEventChannel(), signalling = DirectEventSignalling()
        let session = try DirectRemoteSession(identity: phone, pair: pair, channel: channel, signalling: signalling, store: DirectTestStore())
        try await session.start(offerer: false)
        let old = await session.subscribeEvents()
        let cancelled = Task { for await _ in old { } }; cancelled.cancel()
        let first = await session.subscribeEvents(), second = await session.subscribeEvents()
        let a = expectation(description: "first fresh subscriber"), b = expectation(description: "second fresh subscriber")
        let t1 = Task { for await _ in first { a.fulfill(); break } }
        let t2 = Task { for await _ in second { b.fulfill(); break } }
        channel.continuation.yield(.state(.connected(.lan)))
        await fulfillment(of: [a,b], timeout: 2)
        t1.cancel(); t2.cancel(); await session.close()
    }
    func testPermissionEditPreservesPairKeysAndLocationAndRefreshesPinnedGrant() async throws {
        let store = DirectTestStore()
        let (host, phone, authority, _, initial) = try await fixture(store: store)
        let vault = DirectRemotePairStore(profile: .init(id: host.publicIdentity.localProfileID), store: store)
        let before = try XCTUnwrap(vault.pairs().first)
        let saved = try await authority.updatePermissions(initial.id, permissions: [.read, .terminal])
        XCTAssertEqual(saved.location, before.location)
        XCTAssertEqual(saved.pair.id, initial.id); XCTAssertEqual(saved.pair.confirmedAt, initial.confirmedAt)
        XCTAssertEqual(saved.pair.host, initial.host); XCTAssertEqual(saved.pair.client, initial.client)
        XCTAssertEqual(saved.pair.revision, 2)
        XCTAssertEqual(try host.sessionKey(pair: initial), try host.sessionKey(pair: saved.pair))
        let grant = try await authority.signedGrant(initial.id)
        let accepted = try grant.acceptUpdate(current: initial, client: phone)
        XCTAssertEqual(accepted, saved.pair)
        XCTAssertEqual(try grant.acceptUpdate(current: accepted, client: phone), accepted)
        let same = try await authority.updatePermissions(initial.id, permissions: [.terminal, .read])
        XCTAssertEqual(same, saved, "Saving unchanged access must not reconnect or increment the revision")
        do { _ = try await authority.updatePermissions(initial.id, permissions: [.terminal]); XCTFail("Read is mandatory") } catch { }
        try await authority.revoke(initial.id)
        do { _ = try await authority.updatePermissions(initial.id, permissions: [.read]); XCTFail("A revoked phone needs new pairing") } catch { }
        XCTAssertThrowsError(try vault.save(saved), "An older active grant cannot resurrect a revoked pair")
    }
    func testPinnedGrantRejectsRollbackEquivocationWrongSignerAndChangedDevices() async throws {
        let (host, phone, authority, _, initial) = try await fixture()
        let original = try await authority.signedGrant(initial.id)
        let changed = try await authority.updatePermissions(initial.id, permissions: [.read])
        XCTAssertThrowsError(try original.acceptUpdate(current: changed.pair, client: phone))
        func signed(_ pair: DirectRemotePair, signer: DirectRemoteIdentity = host) throws -> DirectRemotePairConfirmation {
            let bytes = try DirectRemoteCoding.encode(pair)
            return .init(pairBytes: bytes, hostSignature: try signer.sign(bytes))
        }
        let equivocal = DirectRemotePair(version: initial.version, id: initial.id, host: initial.host, client: initial.client,
            permissions: [.read, .terminal], revision: changed.pair.revision, revoked: false, confirmedAt: initial.confirmedAt)
        XCTAssertThrowsError(try signed(equivocal).acceptUpdate(current: changed.pair, client: phone))
        let impostor = DirectRemoteIdentity(profile: .init(id: UUID()), role: .mac, name: "Other Mac")
        XCTAssertThrowsError(try signed(changed.pair, signer: impostor).acceptUpdate(current: initial, client: phone))
        let replaced = DirectRemotePair(version: initial.version, id: initial.id, host: impostor.publicIdentity, client: initial.client,
            permissions: [.read], revision: 3, revoked: false, confirmedAt: initial.confirmedAt)
        XCTAssertThrowsError(try signed(replaced, signer: impostor).acceptUpdate(current: initial, client: phone))
        var revoked = initial; revoked.revoked = true
        XCTAssertThrowsError(try original.acceptUpdate(current: revoked, client: phone))
    }
    func testPermissionPersistenceFailureLeavesAuthoritativeGrantUnchanged() async throws {
        let store = DirectUpdateFailureStore()
        let (_, _, authority, _, initial) = try await fixture(store: store)
        store.failSaves = true
        do { _ = try await authority.updatePermissions(initial.id, permissions: [.read]); XCTFail("Save must fail") } catch { }
        let current = try await authority.pair(initial.id)
        XCTAssertEqual(current, initial)
    }
    func testUpdatedPermissionRevisionRejectsOldSessionAndKeepsCommandDeduplication() async throws {
        let (host, _, authority, _, initial) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-direct-edit-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = DirectCountingEndpoint(), id = UUID()
        let dispatcher = try DirectRemoteHostDispatcher(identity: host, pairingHost: authority, endpoint: endpoint, journalDirectory: root)
        let first = try await dispatcher.execute(operation: "createSession", payload: .null, commandID: id, pair: initial)
        let saved = try await authority.updatePermissions(initial.id, permissions: [.read])
        do { _ = try await dispatcher.execute(operation: "overview", payload: .null, commandID: UUID(), pair: initial); XCTFail("Old session fenced") }
        catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
        do {
            _ = try await dispatcher.execute(operation: "createSession", payload: .null, commandID: id, pair: saved.pair)
            XCTFail("A downgraded device cannot retrieve a cached result admitted under previous rights")
        } catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
        XCTAssertNotEqual(first, .null)
        let count = await endpoint.count; XCTAssertEqual(count, 1)
    }
    func testTURNExpiryAndSecureCoordinatorSchemesAreRequired() async throws {
        XCTAssertThrowsError(try DirectRemoteICEServer(url: "turn:localhost:3478", username: "user", credential: "secret", expiresAt: .distantPast).nativeURL())
        let host = DirectRemoteIdentity(profile: .init(id: UUID()), role: .mac, name: "Mac")
        let authority = try DirectRemotePairingHost(identity: host, store: DirectTestStore())
        do { _ = try await authority.createInvite(coordinatorURL: URL(string: "ws://example.com")); XCTFail() } catch { }
        _ = try await authority.createInvite(coordinatorURL: URL(string: "ws://127.0.0.1:4323"))
    }
}
private final class DirectTestStore: SecureStoring, @unchecked Sendable {
    let lock = NSLock(); var values: [String:Data] = [:]
    func store(_ data: Data, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = data }
    func readData(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func removeData(forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}
private actor DirectCountingEndpoint: DirectRemoteRequestHandling {
    var count = 0; let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func execute(operation: String, payload: RemoteJSONValue, commandID: UUID, pair: DirectRemotePair) async throws -> RemoteJSONValue {
        count += 1
        if fail { throw DirectRemoteError.unavailable("synthetic_interruption_after_effect") }
        return .object(["job_id": .string(commandID.uuidString), "count": .number(Double(count))])
    }
}

private final class DirectEventChannel: DirectRemoteDataChannel, @unchecked Sendable {
    let events: AsyncStream<DirectRemoteNativeEvent>; let continuation: AsyncStream<DirectRemoteNativeEvent>.Continuation
    init() { let stream = AsyncStream<DirectRemoteNativeEvent>.makeStream(); events = stream.stream; continuation = stream.continuation }
    func createOffer() throws {}
    func acceptDescription(sdp: String, type: String) throws {}
    func acceptCandidate(value: String, mid: String) throws {}
    func send(_ bytes: Data) throws {}
    func close() { continuation.finish() }
}
private final class DirectEventSignalling: DirectRemoteSignalling, Sendable {
    let signals: AsyncStream<Data> = AsyncStream { _ in }
    func send(_ encryptedSignal: Data) async throws {}
    func close() async {}
}

private final class DirectFailingGrantStore: SecureStoring, @unchecked Sendable {
    let lock = NSLock(); var values: [String:Data] = [:]
    func store(_ data: Data, forKey key: String) throws {
        if key.contains("saved-pairs") { throw DirectRemoteError.unavailable("synthetic_keychain_write_failure") }
        lock.lock(); defer { lock.unlock() }; values[key] = data
    }
    func readData(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func removeData(forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private final class DirectUpdateFailureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]
    var failSaves = false
    func store(_ data: Data, forKey key: String) throws {
        if failSaves { throw DirectRemoteError.unavailable("synthetic_keychain_failure") }
        lock.lock(); defer { lock.unlock() }; values[key] = data
    }
    func readData(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func removeData(forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}
