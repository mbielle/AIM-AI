import Foundation
import XCTest
@testable import AIMCore

final class RemoteSecurityTransportTests: XCTestCase {
    func testGatewayFailureKeepsHTTPDiagnosticWithoutLeakingBody() {
        let data = Data(#"{"code":"UNAUTHORIZED_NO_AUTH_HEADER","message":"private server detail"}"#.utf8)
        XCTAssertThrowsError(try RemoteSecurityTransport.decode(data: data, status: 401)) { error in
            XCTAssertEqual(error as? RemoteSecurityServiceError, .transport(code: "edge_http_401"))
        }
    }

    func testWrongPINAndRateLimitRemainDomainFailures() throws {
        let response = try RemoteSecurityTransport.decode(
            data: Data(#"{"ok":false,"error":"wrong_pin","attempts":3,"locked_until":null}"#.utf8), status: 403)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "wrong_pin")
        XCTAssertEqual(response.attempts, 3)
        let blocked = try RemoteSecurityTransport.decode(
            data: Data(#"{"ok":false,"error":"locked","locked_until":"2026-10-05T12:00:00Z"}"#.utf8), status: 403)
        XCTAssertEqual(blocked.lockedUntil, "2026-10-05T12:00:00Z")
    }

    func testValidatorAlternateFormatAndOpaqueFailuresAreSafe() {
        for (body, expected) in [
            (#"{"success":false,"error":"device_not_paired"}"#, RemoteSecurityServiceError.server(code: "device_not_paired")),
            (#"{"success":false,"error":"Invalid or expired token"}"#, .transport(code: "edge_http_401")),
            (#"{"ok":false,"error":"private arbitrary detail"}"#, .transport(code: "edge_http_401")),
            ("<html>Private failure</html>", .transport(code: "edge_http_401"))
        ] {
            XCTAssertThrowsError(try RemoteSecurityTransport.decode(data: Data(body.utf8), status: 401)) {
                XCTAssertEqual($0 as? RemoteSecurityServiceError, expected)
            }
        }
    }

    func testHTTPFailureNeverGrantsUnlockEvenWithSuccessBody() {
        let data = Data(#"{"ok":true,"unlock":{"token":"test-token","expiresAt":"2099-10-05T12:00:00.000Z","method":"pin"}}"#.utf8)
        XCTAssertThrowsError(try RemoteSecurityTransport.decode(data: data, status: 503)) {
            XCTAssertEqual($0 as? RemoteSecurityServiceError, .transport(code: "edge_http_503"))
        }
    }

    func testSuccessRequiresWellFormedContractAndPreservesTokenExpiry() throws {
        let data = Data(#"{"ok":true,"unlock":{"token":"test-token","expiresAt":"2099-10-05T12:00:00.123Z","method":"pin"}}"#.utf8)
        let response = try RemoteSecurityTransport.decode(data: data, status: 200)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.unlock?.token, "test-token")
        XCTAssertEqual(response.unlock?.method, "pin")
        XCTAssertThrowsError(try RemoteSecurityTransport.decode(data: Data(#"{"ok":true,"unlock":{"token":"test-token","expiresAt":"invalid"}}"#.utf8), status: 200)) {
            XCTAssertEqual($0 as? RemoteSecurityServiceError, .invalidResponse)
        }
        XCTAssertThrowsError(try RemoteSecurityTransport.decode(data: Data(#"{"success":true}"#.utf8), status: 200))
    }

    func testIncompleteServerStateNeverOffersPINCreation() throws {
        for body in [#"{"ok":true}"#, #"{"ok":true,"pin":false,"enabled":true}"#, #"{"ok":true,"pin":false,"passkeys":0}"#] {
            let response = try JSONDecoder().decode(RemoteUnlockStateResponse.self, from: Data(body.utf8))
            XCTAssertThrowsError(try response.validatedValue) {
                XCTAssertEqual($0 as? RemoteSecurityServiceError, .invalidResponse)
            }
        }
        let valid = try JSONDecoder().decode(RemoteUnlockStateResponse.self,
            from: Data(#"{"ok":true,"pin":false,"passkeys":0,"enabled":true}"#.utf8))
        XCTAssertFalse(try valid.validatedValue.hasPIN)
        let denied = try JSONDecoder().decode(RemoteUnlockStateResponse.self,
            from: Data(#"{"ok":false,"error":"device_not_paired"}"#.utf8))
        XCTAssertFalse(try denied.validatedValue.succeeded)
    }

    func testPINMatchesServerASCIIContract() {
        XCTAssertTrue(RemoteLockRules.isValidPIN("123456"))
        XCTAssertFalse(RemoteLockRules.isValidPIN("١٢٣٤٥٦"))
        XCTAssertFalse(RemoteLockRules.isValidPIN("１２３４５６"))
        XCTAssertFalse(RemoteLockRules.isValidPIN("12345"))
    }
}
