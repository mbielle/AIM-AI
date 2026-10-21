#if DEBUG
import AIMCore
@testable import AIMAgentRuntime
import XCTest

private final class QualificationSourceStore: SecureStoring, @unchecked Sendable {
    let lock = NSLock()
    var reads = 0, writes = 0, removals = 0
    func readData(forKey key: String) throws -> Data? { lock.withLock { reads += 1; return key == "session" ? Data("original-fixture".utf8) : nil } }
    func store(_ data: Data, forKey key: String) throws { lock.withLock { writes += 1 } }
    func removeData(forKey key: String) throws { lock.withLock { removals += 1 } }
}
final class QualificationAccountSnapshotTests: XCTestCase {
    func testRepeatedSDKReadsAndRefreshDoNotReenterOrRewriteLiveKeychain() throws {
        let source = QualificationSourceStore(), snapshot = QualificationAccountSnapshot(source: source)
        for _ in 0..<50 { XCTAssertEqual(try snapshot.readData(forKey: "session"), Data("original-fixture".utf8)) }
        XCTAssertEqual(source.reads, 1)
        try snapshot.store(Data("refreshed-fixture".utf8), forKey: "session")
        XCTAssertEqual(try snapshot.readData(forKey: "session"), Data("refreshed-fixture".utf8))
        try snapshot.removeData(forKey: "session")
        XCTAssertNil(try snapshot.readData(forKey: "session"))
        for _ in 0..<50 { XCTAssertNil(try snapshot.readData(forKey: "missing-legacy-session")) }
        XCTAssertEqual(source.reads, 2)
        XCTAssertEqual(source.writes, 0); XCTAssertEqual(source.removals, 0)
    }
}
#endif
