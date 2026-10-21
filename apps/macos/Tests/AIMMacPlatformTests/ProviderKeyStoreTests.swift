@testable import AIMMacPlatform
import AIMApplication
import AIMCore
import Foundation
import XCTest

final class ProviderKeyStoreTests: XCTestCase {
    func testInventoryNeverDecryptsKeysAndSuccessfulReadsAreCached() throws {
        let backing = CountingProviderStore()
        let store = MacProviderKeyStore(backing: backing, inventory: { [.openRouter, .openAI] })
        XCTAssertEqual(try store.configuredProviders(), [.openRouter, .openAI])
        XCTAssertEqual(backing.readCount, 0)
        for _ in 0..<20 { XCTAssertEqual(try store.readData(forKey: "openrouter"), Data("fixture".utf8)) }
        XCTAssertEqual(backing.readCount, 1)
        try store.store(Data("replacement".utf8), forKey: "openrouter")
        XCTAssertEqual(try store.readData(forKey: "openrouter"), Data("replacement".utf8))
        XCTAssertEqual(backing.readCount, 1)
        try store.removeData(forKey: "openrouter")
        XCTAssertNil(try store.readData(forKey: "openrouter"))
        XCTAssertEqual(backing.readCount, 2)
    }
}

private final class CountingProviderStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var data: Data? = Data("fixture".utf8)
    var readCount: Int { lock.withLock { count } }
    func store(_ data: Data, forKey key: String) throws { lock.withLock { self.data = data } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { count += 1; return data } }
    func removeData(forKey key: String) throws { lock.withLock { data = nil } }
}
