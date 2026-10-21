import Foundation
import XCTest
@testable import AIMCore

final class AuthenticationCallbackDeduplicatorTests: XCTestCase {
    func testWarmAndColdDeliveryOfSameCallbackIsClaimedOnce() async throws {
        let deduplicator = AuthenticationCallbackDeduplicator()
        let url = try XCTUnwrap(URL(string: "aim://auth-callback?code=one"))

        let firstClaim = await deduplicator.claim(url)
        let duplicateClaim = await deduplicator.claim(url)
        XCTAssertTrue(firstClaim)
        XCTAssertFalse(duplicateClaim)
    }

    func testFailedCallbackCanBeReleasedAndRetried() async throws {
        let deduplicator = AuthenticationCallbackDeduplicator()
        let url = try XCTUnwrap(URL(string: "aimai://auth-callback?code=retry"))

        let firstClaim = await deduplicator.claim(url)
        await deduplicator.release(url)
        let retryClaim = await deduplicator.claim(url)
        XCTAssertTrue(firstClaim)
        XCTAssertTrue(retryClaim)
    }
}
