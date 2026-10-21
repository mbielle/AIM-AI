import Foundation
import XCTest
@testable import AIMCore

final class AuthRedirectPolicyTests: XCTestCase {
    private let policy = AuthRedirectPolicy()

    func testCanonicalRedirectUsesAimScheme() {
        XCTAssertEqual(policy.canonicalURL?.absoluteString, "aim://auth-callback")
    }

    func testAcceptsCanonicalAndLegacyCallbacks() {
        XCTAssertTrue(policy.accepts(URL(string: "aim://auth-callback?code=123")!))
        XCTAssertTrue(policy.accepts(URL(string: "aimai://auth-callback?code=123")!))
    }

    func testRejectsUnexpectedHostsAndSchemes() {
        XCTAssertFalse(policy.accepts(URL(string: "aim://another-host?code=123")!))
        XCTAssertFalse(policy.accepts(URL(string: "https://auth-callback?code=123")!))
        XCTAssertFalse(policy.accepts(URL(string: "aim-evil://auth-callback?code=123")!))
    }
}
