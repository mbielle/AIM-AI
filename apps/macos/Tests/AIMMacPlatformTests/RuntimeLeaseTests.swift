import XCTest
@testable import AIMMacPlatform

final class RuntimeLeaseTests: XCTestCase {
    func testOnlyOneOwnerAndReleaseAllowsReplacement() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aim-lease-\(UUID()).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        let lease = try RuntimeLease(url: url)
        XCTAssertThrowsError(try RuntimeLease(url: url)) { XCTAssertEqual($0 as? RuntimeLeaseError, .alreadyOwned) }
        lease.release()
        let replacement = try RuntimeLease(url: url)
        XCTAssertNotEqual(replacement.generation, lease.generation)
        replacement.release()
    }
}
