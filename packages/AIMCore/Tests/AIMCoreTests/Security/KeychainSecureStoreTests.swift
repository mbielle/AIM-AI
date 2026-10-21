import Foundation
import XCTest
@testable import AIMCore

final class KeychainSecureStoreTests: XCTestCase {
    func testMissingItemReturnsNil() throws {
        let keychain = FakeKeychain()
        let store = KeychainSecureStore(service: "tests", keychain: keychain)

        XCTAssertNil(try store.readData(forKey: "missing"))
    }

    func testStoresReadsAndUpdatesData() throws {
        let keychain = FakeKeychain()
        let store = KeychainSecureStore(service: "tests", keychain: keychain)

        try store.store(Data("first".utf8), forKey: "session")
        XCTAssertEqual(try store.readData(forKey: "session"), Data("first".utf8))

        try store.store(Data("second".utf8), forKey: "session")
        XCTAssertEqual(try store.readData(forKey: "session"), Data("second".utf8))
    }

    func testDeleteIsIdempotent() throws {
        let keychain = FakeKeychain()
        let store = KeychainSecureStore(service: "tests", keychain: keychain)

        try store.removeData(forKey: "session")
        try store.store(Data("value".utf8), forKey: "session")
        try store.removeData(forKey: "session")
        try store.removeData(forKey: "session")

        XCTAssertNil(try store.readData(forKey: "session"))
    }
}

private final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { values["\(service):\(account)"] }
    }

    func write(_ data: Data, service: String, account: String) throws {
        lock.withLock { values["\(service):\(account)"] = data }
    }

    func remove(service: String, account: String) throws {
        lock.withLock { _ = values.removeValue(forKey: "\(service):\(account)") }
    }
}
