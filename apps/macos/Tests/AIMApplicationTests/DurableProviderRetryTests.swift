import XCTest
@testable import AIMApplication

private final class RetryAfterFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "7200"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"error\":\"temporarily rate limited\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class DurableProviderRetryTests: XCTestCase {
    func testNativeAndTextPreserveLongRetryAfter() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryAfterFixture.self]
        let session = URLSession(configuration: configuration)
        let messages = [ConversationMessage(conversationID: UUID(), role: .user, content: "fixture", sequence: 0)]
        let tool = ModelToolDefinition(name: "fixture_read", description: "read")
        let conversations: [any ModelToolConversation] = [
            try ProviderToolConversation(provider: .openRouter, modelID: "fixture", messages: messages, apiKey: "fixture",
                                         tools: [tool], session: session, retryPolicy: .persistent),
            try TextProtocolToolConversation(modelID: "fixture", messages: messages, apiKey: "fixture", tools: [tool],
                                             session: session, retryPolicy: .persistent)]
        for conversation in conversations {
            let before = Date.now
            do { _ = try await conversation.next(outputs: []); XCTFail("429 accepted") }
            catch let error as ProviderRetryDeferral {
                XCTAssertEqual(error.status, 429)
                XCTAssertGreaterThan(try XCTUnwrap(error.notBefore).timeIntervalSince(before), 7190)
            }
        }
    }
}
