import AIMApplication
import XCTest

private final class ChatFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let status = scenario.contains("denied") ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = ": keepalive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hello 🌍\"}}]}\n\n" + (scenario.contains("truncated") ? "" : "data: [DONE]\n\n")
        // Split inside UTF-8 sequences as a real network transport may do.
        for byte in body.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ChatTransportTests: XCTestCase {
    private func service() -> OpenRouterChatService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatFixtureProtocol.self]
        return OpenRouterChatService(session: URLSession(configuration: configuration))
    }

    func testFragmentedSSEPreservesUnicode() async throws {
        var result = ""
        for try await text in service().stream(modelID: "fixture", messages: [], apiKey: "fixture", mode: .chat) { result += text }
        XCTAssertEqual(result, "Hello 🌍")
    }

    func testTruncatedStreamKeepsPartialTextButFails() async {
        var result = ""
        do {
            for try await text in service().stream(modelID: "fixture", messages: [], apiKey: "truncated", mode: .chat) { result += text }
            XCTFail("Truncated stream must not report completion")
        } catch ChatServiceError.incompleteResponse {
            XCTAssertEqual(result, "Hello 🌍")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUnauthorizedResponseIsActionable() async {
        do {
            for try await _ in service().stream(modelID: "fixture", messages: [], apiKey: "denied", mode: .chat) {}
            XCTFail("Expected authentication failure")
        } catch ChatServiceError.http(let code) { XCTAssertEqual(code, 401) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
