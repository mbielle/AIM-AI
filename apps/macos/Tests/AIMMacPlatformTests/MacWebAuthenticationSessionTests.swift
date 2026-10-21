@testable import AIMMacPlatform
import XCTest

@MainActor
final class MacWebAuthenticationSessionTests: XCTestCase {
    func testRejectsNonHTTPSAuthorizationWithoutOpeningBrowser() async {
        let browser = MacWebAuthenticationSession()
        for url in ["http://example.com/authorize", "aimmac://auth-callback"] {
            do {
                _ = try await browser.authenticate(at: URL(string: url)!, callbackScheme: "aimmac")
                XCTFail("Expected the browser route to reject \(url)")
            } catch {
                XCTAssertEqual(error as? MacWebAuthenticationError, .couldNotStart)
            }
        }
    }

    func testRejectsAnotherAppsCallbackScheme() async {
        let browser = MacWebAuthenticationSession()
        do {
            _ = try await browser.authenticate(at: URL(string: "https://example.com/authorize")!, callbackScheme: "aim")
            XCTFail("Expected rejection before opening a browser")
        } catch {
            XCTAssertEqual(error as? MacWebAuthenticationError, .couldNotStart)
        }
    }
}
