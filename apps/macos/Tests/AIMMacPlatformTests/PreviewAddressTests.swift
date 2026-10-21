import AIMMacPlatform
import XCTest

final class PreviewAddressTests: XCTestCase {
    func testLocalPortsAndWebAddresses() {
        XCTAssertEqual(PreviewAddress.parse(" 3000 ")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(PreviewAddress.parse("localhost:5173/path?q=one")?.absoluteString, "http://localhost:5173/path?q=one")
        XCTAssertEqual(PreviewAddress.parse("https://example.com/path")?.scheme, "https")
        XCTAssertNotNil(PreviewAddress.parse("http://[::1]:3000"))
        XCTAssertNotNil(PreviewAddress.parse("example.com"))
    }

    func testRejectsCredentialsSchemesMalformedPortsAndControlCharacters() {
        for raw in ["", "0", "65536", "999999999999999999999", "http://localhost:0", "http://localhost:65536", "file:///tmp/private", "file:/tmp/private", "javascript:alert(1)", "mailto:a@example.com", "aim://action", "data:text/html,hello", "https://user:password@example.com", "https://user@example.com", "http://local host", "http://localhost\n/path", "http://localhost\\path"] {
            XCTAssertNil(PreviewAddress.parse(raw), raw)
        }
    }

    func testNavigationPolicyAlsoChecksAlreadyParsedURLs() throws {
        for raw in ["file:///tmp/private", "data:text/html,hello", "about:blank", "https://secret@example.com"] {
            XCTAssertFalse(PreviewAddress.allows(try XCTUnwrap(URL(string: raw))))
        }
        XCTAssertTrue(PreviewAddress.allows(try XCTUnwrap(URL(string: "http://127.0.0.1:8080/page"))))
    }
}
