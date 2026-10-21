@testable import AIMAgentRuntime
import XCTest
@testable import AIMMac

@MainActor
final class BrowserPreviewSessionTests: XCTestCase {
    func testInvalidAddressDoesNotNavigate() {
        let session = BrowserPreviewSession()
        session.address = "file:///tmp/private-fixture"
        session.loadAddress()
        XCTAssertNotNil(session.errorMessage)
        XCTAssertNil(session.webView.url)
        XCTAssertFalse(session.isLoading)
    }

    func testNavigationFailureAndTerminationAreRecoverableWithoutRawErrorDetails() {
        let session = BrowserPreviewSession()
        session.webView(session.webView, didStartProvisionalNavigation: nil)
        XCTAssertTrue(session.isLoading)
        session.webView(session.webView, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                           userInfo: [NSLocalizedDescriptionKey: "private-fixture-url"]))
        XCTAssertFalse(session.isLoading)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.errorMessage!.contains("private-fixture-url"))
        session.webView(session.webView, didStartProvisionalNavigation: nil)
        XCTAssertNil(session.errorMessage)
        session.webViewWebContentProcessDidTerminate(session.webView)
        XCTAssertFalse(session.isLoading)
        XCTAssertNotNil(session.errorMessage)
        session.stop()
        XCTAssertFalse(session.isLoading)
    }
}
