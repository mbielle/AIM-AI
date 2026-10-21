import AIMCore
@testable import AIMMacPlatform
import XCTest

private final class AccountIdentityMemoryStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
}
private actor IdentityRegistrationProbe {
    var identities: [RemoteHostIdentity] = []
    let error: RemoteHostError?
    var current = true
    let changeAfterACK: Bool
    init(_ error: RemoteHostError? = nil, changeAfterACK: Bool = false) {
        self.error = error; self.changeAfterACK = changeAfterACK
    }
    func requireCurrent() throws { if !current { throw RemoteHostError.accountChanged } }
    func register(_ identity: RemoteHostIdentity) throws {
        identities.append(identity)
        if identities.count == 1, let error { throw error }
        if changeAfterACK { current = false }
    }
}

final class RemoteHostIdentityAccountTests: XCTestCase {
    private func resolve(_ store: RemoteHostIdentityStore, _ probe: IdentityRegistrationProbe) async throws -> RemoteHostIdentity {
        try await store.resolveForRegistration(isCurrent: { try await probe.requireCurrent() },
            register: { try await probe.register($0) })
    }
    func testLegacyOwnerACKPreservesExactIdentityAndLegacyBlob() async throws {
        let memory = AccountIdentityMemoryStore()
        let legacy = RemoteHostIdentityStore(store: memory)
        var identity = RemoteHostIdentity.fresh(); identity.rotate(); identity.keyedDevices = ["existing-phone"]
        try legacy.save(identity)
        let blob = try memory.readData(forKey: "remote-host-identity")
        let scoped = RemoteHostIdentityStore(accountID: UUID(), store: memory)
        let probe = IdentityRegistrationProbe()
        let resolved = try await resolve(scoped, probe)
        XCTAssertEqual(resolved, identity); XCTAssertEqual(try scoped.load(), identity)
        XCTAssertEqual(try memory.readData(forKey: "remote-host-identity"), blob)
        let calls = await probe.identities; XCTAssertEqual(calls, [identity])
    }
    func testForeignLegacyConflictCreatesOneStableScopedIdentityAndPreservesOldAccount() async throws {
        let memory = AccountIdentityMemoryStore()
        let legacy = RemoteHostIdentityStore(store: memory)
        let identity = try legacy.loadOrCreate()
        let oldAccount = RemoteHostIdentityStore(accountID: UUID(), store: memory)
        _ = try await resolve(oldAccount, IdentityRegistrationProbe())
        let newAccount = RemoteHostIdentityStore(accountID: UUID(), store: memory)
        let probe = IdentityRegistrationProbe(.server("machine_conflict"))
        let resolved = try await resolve(newAccount, probe)
        let calls = await probe.identities
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls.first, identity)
        XCTAssertNotEqual(resolved.machineID, identity.machineID)
        XCTAssertEqual(calls.last, resolved); XCTAssertEqual(try newAccount.load(), resolved)
        XCTAssertEqual(try oldAccount.load(), identity); XCTAssertEqual(try legacy.load(), identity)
    }
    func testLegacySecretMismatchAndNetworkFailureNeverMigrateOrRotate() async throws {
        for failure in [RemoteHostError.server("machine_secret_mismatch"), .server("network_unavailable")] {
            let memory = AccountIdentityMemoryStore()
            let legacy = RemoteHostIdentityStore(store: memory)
            let identity = try legacy.loadOrCreate()
            let scoped = RemoteHostIdentityStore(accountID: UUID(), store: memory)
            let probe = IdentityRegistrationProbe(failure)
            do { _ = try await resolve(scoped, probe); XCTFail("Expected registration refusal") } catch {}
            XCTAssertNil(try scoped.load()); XCTAssertEqual(try legacy.load(), identity)
            let calls = await probe.identities; XCTAssertEqual(calls, [identity])
        }
    }
    func testScopedConflictNeverCreatesReplacementIdentity() async throws {
        let memory = AccountIdentityMemoryStore()
        let scoped = RemoteHostIdentityStore(accountID: UUID(), store: memory)
        let identity = try scoped.loadOrCreate()
        let probe = IdentityRegistrationProbe(.server("machine_conflict"))
        do { _ = try await resolve(scoped, probe); XCTFail("Expected scoped conflict") } catch {}
        XCTAssertEqual(try scoped.load(), identity)
        let calls = await probe.identities; XCTAssertEqual(calls, [identity])
    }
    func testAccountChangeAfterLegacyACKDoesNotCommitMigration() async throws {
        let memory = AccountIdentityMemoryStore()
        let legacy = RemoteHostIdentityStore(store: memory)
        let identity = try legacy.loadOrCreate()
        let scoped = RemoteHostIdentityStore(accountID: UUID(), store: memory)
        do { _ = try await resolve(scoped, IdentityRegistrationProbe(changeAfterACK: true)); XCTFail("Expected stale account rejection") }
        catch RemoteHostError.accountChanged {}
        XCTAssertNil(try scoped.load()); XCTAssertEqual(try legacy.load(), identity)
    }
    func testFreshIdentitySurvivesLostRegistrationACKWithoutReplacement() async throws {
        let memory = AccountIdentityMemoryStore()
        let scoped = RemoteHostIdentityStore(accountID: UUID(), store: memory)
        let failed = IdentityRegistrationProbe(.server("network_unavailable"))
        do { _ = try await resolve(scoped, failed); XCTFail("Expected lost ACK") } catch {}
        let persisted = try XCTUnwrap(scoped.load())
        let retry = IdentityRegistrationProbe()
        let resolved = try await resolve(scoped, retry)
        XCTAssertEqual(resolved, persisted)
        let calls = await retry.identities; XCTAssertEqual(calls, [persisted])
        XCTAssertNil(try RemoteHostIdentityStore(store: memory).load())
    }
}
