@testable import AIMApplication
import XCTest

private final class ResponsesToolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
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
            let isXAI = body["model"] as? String == "grok-fixture"
            if body["model"] as? String == "chatgpt-fixture" { XCTAssertEqual(body["stream"] as? Bool, true) }
            let hasSelectedEffort = body["model"] as? String == "reasoning-fixture"
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], hasSelectedEffort ? "high" : nil)
            XCTAssertEqual(request.url?.absoluteString, isXAI ? "https://api.x.ai/v1/responses" : "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), isXAI ? "Bearer xai-fixture-key" : "Bearer fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            XCTAssertNil(body["messages"])
            XCTAssertNil(body["previous_response_id"])
            XCTAssertNil(body["provider"])
            XCTAssertNil(body["max_output_tokens"])
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
            XCTAssertNotNil(body["instructions"])
            let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
            XCTAssertEqual(tool["strict"] as? Bool, true)
            XCTAssertNil(tool["function"])
            let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
            XCTAssertEqual(schema["required"] as? [String], ["path"])
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            XCTAssertEqual(properties["path"]?["type"] as? [String], ["string", "null"])
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let output: [[String: Any]]
            if input.last?["type"] as? String == "function_call_output" {
                XCTAssertEqual(input.last?["call_id"] as? String, "call_fixture")
                XCTAssertTrue((input.last?["output"] as? String)?.contains("fixture result") == true)
                XCTAssertEqual(input[input.count - 2]["id"] as? String, "fc_fixture")
                XCTAssertEqual(input[input.count - 3]["encrypted_content"] as? String, "opaque-fixture")
                output = [["type": "message", "id": "msg_fixture", "status": "completed", "role": "assistant", "phase": "final_answer",
                    "content": [["type": "output_text", "text": "Inspected fixture.", "annotations": []]]]]
            } else {
                output = [
                    ["type": "reasoning", "id": "rs_fixture", "summary": [], "encrypted_content": "opaque-fixture"],
                    ["type": "function_call", "id": "fc_fixture", "status": "completed", "call_id": "call_fixture", "name": "list_dir", "arguments": "{\"path\":null}"]
                ]
            }
            let response = try JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed", "error": NSNull(), "output": output])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            let streamed = body["stream"] as? Bool == true
            let wire = streamed ? Data("data: {\"type\":\"response.completed\",\"response\":\(String(decoding: response, as: UTF8.self))}\n\n".utf8) : response
            client?.urlProtocol(self, didLoad: wire)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class OpenAIToolConversationTests: XCTestCase {
    private let tools = [ModelToolDefinition(name: "list_dir", description: "List a directory", optionalArguments: ["path"])]

    func testStatelessRoundTripRetainsReasoningAndUsesCallIDNotItemID() async throws {
        try await assertRoundTrip(provider: .openAI)
    }

    func testChatGPTPlanStatelessToolRoundTripUsesStreamWithoutStoring() async throws {
        XCTAssertTrue(ChatProvider.chatgpt.supportsWorkspaceTools)
        try await assertRoundTrip(provider: .chatgpt)
    }

    func testXAIStatelessRoundTripUsesOwnCredentialsAndRetainsOpaqueReasoning() async throws {
        try await assertRoundTrip(provider: .xAI)
    }

    func testExplicitReasoningEffortIsRetainedOnToolFollowUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponsesToolFixture.self]
        let conversation = try ProviderToolConversation(provider: .openAI, modelID: "reasoning-fixture", messages: [], apiKey: "fixture-key",
            tools: tools, session: URLSession(configuration: config), openAIReasoningEffort: .high)
        let first = try await conversation.next(outputs: [])
        XCTAssertEqual(first.calls.count, 1)
        let final = try await conversation.next(outputs: [ModelToolOutput(id: "call_fixture", content: "fixture result", isError: false)])
        XCTAssertEqual(final.text, "Inspected fixture.")
        XCTAssertThrowsError(try ProviderToolConversation(provider: .google, modelID: "gemini-fixture", messages: [], apiKey: "fixture-key", tools: tools, openAIReasoningEffort: .high))
    }

    private func assertRoundTrip(provider: ChatProvider) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponsesToolFixture.self]
        let conversation = try ProviderToolConversation(provider: provider, modelID: provider == .xAI ? "grok-fixture" : provider == .chatgpt ? "chatgpt-fixture" : "fixture", messages: [], apiKey: provider == .xAI ? "xai-fixture-key" : "fixture-key",
            tools: tools, session: URLSession(configuration: config))
        let first = try await conversation.next(outputs: [])
        XCTAssertEqual(first.calls, [ModelToolCall(id: "call_fixture", name: "list_dir", arguments: [:])])
        XCTAssertTrue(first.text.isEmpty)
        let final = try await conversation.next(outputs: [ModelToolOutput(id: "call_fixture", content: "fixture result", isError: false)])
        XCTAssertEqual(final.text, "Inspected fixture.")
        XCTAssertTrue(final.calls.isEmpty)
    }

    func testIncompleteResponseAndIncompleteCallsCannotExecute() throws {
        for status in ["incomplete", "in_progress", "failed", "cancelled"] {
            let data = try JSONSerialization.data(withJSONObject: ["object": "response", "status": status, "output": [call()]])
            XCTAssertThrowsError(try OpenAIToolWire.decode(data, tools: tools))
            var incompleteCall = call()
            incompleteCall["status"] = status
            XCTAssertThrowsError(try decode([incompleteCall]))
        }
    }

    func testUnknownItemsDuplicateCallsAndInvalidArgumentsFailClosed() throws {
        XCTAssertThrowsError(try decode([["type": "shell_call"]]))
        XCTAssertThrowsError(try decode([call(), call()]))
        for arguments in ["{\"path\":42}", "{\"unregistered\":null}", "[]", "invalid"] {
            var bad = call(); bad["arguments"] = arguments
            XCTAssertThrowsError(try decode([bad]))
        }
        let required = [ModelToolDefinition(name: "list_dir", description: "List", requiredArguments: ["path"])]
        let data = try JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed", "output": [call()]])
        XCTAssertThrowsError(try OpenAIToolWire.decode(data, tools: required))
    }

    func testMoreThan256DistinctCallsDecode() throws {
        let calls = (0..<300).map { index -> [String: Any] in
            var item = call()
            item["call_id"] = "call_\(index)"
            return item
        }
        let result = try decode(calls)
        XCTAssertEqual(result.turn.calls.map(\.id), (0..<300).map { "call_\($0)" })
    }

    func testRefusalRendersAndOpaqueOutputRemainsUnchanged() throws {
        let item: [String: Any] = ["type": "message", "role": "assistant", "status": "completed", "phase": "final_answer",
            "content": [["type": "refusal", "refusal": "I cannot do that."]]]
        let result = try decode([item])
        XCTAssertEqual(result.turn.text, "I cannot do that.")
        XCTAssertTrue(result.turn.calls.isEmpty)
        XCTAssertEqual(result.items.first?["phase"] as? String, "final_answer")
    }

    private func call() -> [String: Any] {
        ["type": "function_call", "call_id": "call_fixture", "name": "list_dir", "arguments": "{\"path\":null}"]
    }
    private func decode(_ items: [[String: Any]]) throws -> (turn: ModelToolTurn, items: [[String: Any]]) {
        try OpenAIToolWire.decode(JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed", "output": items]), tools: tools)
    }
}
