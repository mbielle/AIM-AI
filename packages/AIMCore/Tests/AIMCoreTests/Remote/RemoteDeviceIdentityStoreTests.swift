import Foundation
import XCTest
@testable import AIMCore

final class RemoteDeviceIdentityStoreTests: XCTestCase {
    func testPairingDiagnosticReferenceCannotExposeArbitraryErrorText() {
        let failure = RemotePairingFailure(
            stage: .request,
            code: "PGRST202 token@example.com / very-long-sensitive-description"
        )

        XCTAssertTrue(failure.reference.hasPrefix("PAIR-RPC-PGRST202"))
        XCTAssertFalse(failure.reference.contains("@"))
        XCTAssertFalse(failure.reference.contains("/"))
        XCTAssertFalse(failure.reference.contains(" "))
        XCTAssertLessThanOrEqual(failure.code.count, 32)
    }

    func testIdentityIsStableAndPrivateKeyIsCommittedOnlyAfterPairingSucceeds() throws {
        let secureStore = RemoteMemorySecureStore()
        let store = RemoteDeviceIdentityStore(secureStore: secureStore)

        let initial = try store.identity()
        let prepared = try store.preparePairing()
        let beforeCommit = try store.identity()

        XCTAssertEqual(initial.deviceID, prepared.deviceID)
        XCTAssertEqual(initial.secret, prepared.secret)
        XCTAssertEqual(initial.secret.count, 64)
        XCTAssertNil(initial.privateKey)
        XCTAssertNil(beforeCommit.privateKey)
        XCTAssertEqual(Data(base64Encoded: prepared.publicKey)?.count, 65)

        try store.commit(prepared)
        let persisted = try store.identity()

        XCTAssertEqual(persisted.deviceID, prepared.deviceID)
        XCTAssertEqual(persisted.privateKey?.publicKeyBase64, prepared.publicKey)
    }

    func testInvalidLegacyIdentityIsRepairedInsteadOfBlockingPairing() throws {
        let secureStore = RemoteMemorySecureStore()
        secureStore.store(Data("not-a-uuid".utf8), forKey: "device-id")
        secureStore.store(Data("short".utf8), forKey: "device-secret")
        secureStore.store(Data([0x00, 0x01]), forKey: "device-private-key")
        let store = RemoteDeviceIdentityStore(secureStore: secureStore)

        let identity = try store.identity()

        XCTAssertNotNil(UUID(uuidString: identity.deviceID))
        XCTAssertEqual(identity.secret.count, 64)
        XCTAssertNil(identity.privateKey)
        XCTAssertNil(secureStore.readData(forKey: "device-private-key"))
        XCTAssertEqual(try store.preparePairing().deviceID, identity.deviceID)
    }
}

private final class RemoteMemorySecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(_ data: Data, forKey key: String) {
        lock.withLock { values[key] = data }
    }

    func readData(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func removeData(forKey key: String) {
        lock.withLock { _ = values.removeValue(forKey: key) }
    }
}
