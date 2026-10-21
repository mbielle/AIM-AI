import Foundation
import XCTest
@testable import AIMCore

final class SupabaseAuthLocalStorageTests: XCTestCase {
    func testSessionStorageKeyDoesNotReuseSupabaseLegacyMigrationSource() {
        XCTAssertEqual(
            SupabaseAuthStorageConfiguration.sessionKey,
            "com.aimai.ios.supabase.session"
        )
        XCTAssertNotEqual(SupabaseAuthStorageConfiguration.sessionKey, "supabase.session")
    }

    func testDelegatesSessionBytesToSecureStoreWithoutTransformation() throws {
        let secureStore = MemorySecureStore()
        let storage = SupabaseAuthLocalStorage(secureStore: secureStore)
        let session = Data("opaque-session".utf8)

        try storage.store(key: "session", value: session)
        XCTAssertEqual(try storage.retrieve(key: "session"), session)

        try storage.remove(key: "session")
        XCTAssertNil(try storage.retrieve(key: "session"))
    }
}

private final class MemorySecureStore: SecureStoring, @unchecked Sendable {
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
