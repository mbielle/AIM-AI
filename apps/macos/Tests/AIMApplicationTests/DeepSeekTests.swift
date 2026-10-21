import AIMApplication
import XCTest

final class DeepSeekTests: XCTestCase {
    func testStreamingIgnoresReasoningAndRejectsTruncation() throws {
        XCTAssertEqual(try ProviderWireFormat.decode(#"{"choices":[{"delta":{"reasoning_content":"internal fixture"}}]}"#, provider: .deepSeek).text, "")
        XCTAssertEqual(try ProviderWireFormat.decode(#"{"choices":[{"delta":{"content":"Visible"}}]}"#, provider: .deepSeek).text, "Visible")
        XCTAssertThrowsError(try ProviderWireFormat.decode(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#, provider: .deepSeek))
        XCTAssertThrowsError(try ProviderWireFormat.decode(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, provider: .deepSeek))
        XCTAssertTrue(try ProviderWireFormat.decode("[DONE]", provider: .deepSeek).isComplete)
    }

    func testToolRoundTripUsesDirectEndpointAndNoRouterParameters() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekToolFixture.self]
        let conversation = try ProviderToolConversation(provider: .deepSeek, modelID: "fixture", messages: [], apiKey: "deepseek-fixture-key",
            tools: [ModelToolDefinition(name: "read_file", description: "Read", requiredArguments: ["path"])], session: URLSession(configuration: configuration))
        let call = try await conversation.next(outputs: [])
        XCTAssertEqual(call.calls.first?.name, "read_file")
        XCTAssertEqual(call.calls.first?.arguments, ["path": "README.md"])
        let response = try await conversation.next(outputs: [ModelToolOutput(id: "ds-1", content: "Approved file text", isError: false)])
        XCTAssertEqual(response.text, "Finished")
        XCTAssertTrue(response.calls.isEmpty)
    }
}

private final class DeepSeekToolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(body["max_tokens"])
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer deepseek-fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            XCTAssertNil(body["provider"])
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            XCTAssertEqual(body["stream"] as? Bool, true)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.first?["role"] as? String, "system")
            let followup = messages.last?["role"] as? String == "tool"
            let message: [String: Any]
            if followup {
                XCTAssertEqual(messages.last?["tool_call_id"] as? String, "ds-1")
                XCTAssertTrue((messages.last?["content"] as? String ?? "").contains("Approved file text"))
                XCTAssertEqual(messages[messages.count - 2]["reasoning_content"] as? String, "opaque fixture")
                message = ["role": "assistant", "content": "Finished"]
            } else {
                message = ["role": "assistant", "content": NSNull(), "reasoning_content": "opaque fixture",
                           "tool_calls": [["id": "ds-1", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"README.md\"}"]]]]
            }
            let response = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": followup ? "stop" : "tool_calls", "message": message]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
