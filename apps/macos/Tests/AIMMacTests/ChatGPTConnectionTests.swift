@testable import AIMAgentRuntime
@testable import AIMMac
import XCTest
import AIMApplication
import AIMCore

final class ChatGPTConnectionTests: XCTestCase {
    func testCallbackAcceptsOnlyTheExactPathAndState() {
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback?code=abc&state=s1&client_id=issued HTTP/1.1", state: "s1"),
                       .code("abc", clientID: "issued"))
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback?code=abc&state=s1 HTTP/1.1", state: "s1"), .code("abc", clientID: nil))
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback?code=abc&state=other HTTP/1.1", state: "s1"), .invalid)
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback/x?code=abc&state=s1 HTTP/1.1", state: "s1"), .invalid)
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "POST /callback?code=abc&state=s1 HTTP/1.1", state: "s1"), .invalid)
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback?error=access_denied&state=s1 HTTP/1.1", state: "s1"), .denied)
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback?error=access_denied&state=x HTTP/1.1", state: "s1"), .invalid)
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback?state=s1 HTTP/1.1", state: "s1"), .invalid)
    }

    func testCallbackRejectsDuplicateSecurityParameters() {
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback?code=abc&state=s1&state=s1 HTTP/1.1", state: "s1"), .invalid)
        XCTAssertEqual(ChatGPTConnection.parse(requestLine: "GET /callback?code=abc&state=s1&client_id=a&client_id=b HTTP/1.1", state: "s1"), .invalid)
    }

    @MainActor func testCancellationStopsAttemptWithoutOpeningBrowser() {
        let connection = ChatGPTConnection()
        connection.cancel()
        XCTAssertFalse(connection.connecting)
        connection.credentialReadFailed()
        XCTAssertTrue(connection.status?.contains("preserved") == true)
    }

    @MainActor func testPrivateModePreventsListenerBrowserAndSave() throws {
        let preparation = AIMNetworkPrivacyPreparation(ownerGeneration: nil)
        try AIMNetworkPrivacyAdmission.begin(preparation)
        defer { try? AIMNetworkPrivacyAdmission.abort(preparation) }
        let connection = ChatGPTConnection()
        connection.start { _ in XCTFail("Private mode must not save credentials") }
        XCTAssertFalse(connection.connecting)
        XCTAssertTrue(connection.status?.contains("private mode") == true)
    }

    func testMarkdownCacheServesParsedBlocksWithoutWaiting() {
        let source = "# Title \(UUID())\n\n- **Bold** item\n- Second"
        XCTAssertNil(MarkdownBlockCache.shared.cached(source))
        let parsed = MarkdownBlockCache.shared.parse(source)
        XCTAssertFalse(parsed.isEmpty)
        XCTAssertEqual(MarkdownBlockCache.shared.cached(source)?.count, parsed.count)
    }
}
