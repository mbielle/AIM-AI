import AIMApplication
import XCTest

private final class AnthropicToolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let input = request.httpBodyStream {
                input.open(); defer { input.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while input.hasBytesAvailable {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let model = try XCTUnwrap(body["model"] as? String)
            XCTAssertEqual(body["max_tokens"] as? Int, 32_768)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(body["provider"])
            XCTAssertNotNil(body["system"])
            XCTAssertEqual((body["tool_choice"] as? [String: String])?["type"], "auto")
            let schema = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
            XCTAssertEqual(schema["name"] as? String, model == "typed" ? "typed_action" : "read_file")
            XCTAssertNotNil(schema["input_schema"])
            var content: [[String: Any]] = [
                ["type": "thinking", "thinking": "private fixture", "signature": "signed-fixture"],
                ["type": "redacted_thinking", "data": "opaque-fixture"],
                ["type": "tool_use", "id": "first", "name": "read_file", "input": ["path": "a.txt"]],
                ["type": "tool_use", "id": "second", "name": "read_file", "input": ["path": "b.txt"]]
            ]
            var reason = "tool_use"
            // Prompt caching may send text as cache-marked blocks.
            let lastText = (messages.last?["content"] as? String) ??
                (messages.last?["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if model == "steer", lastText == "Use a friendly tone" {
                XCTAssertEqual(messages.last?["role"] as? String, "user")
                let results = try XCTUnwrap(messages[messages.count - 2]["content"] as? [[String: Any]])
                XCTAssertEqual(results.map { $0["tool_use_id"] as? String }, ["first", "second"])
                reason = "end_turn"
                content = [["type": "text", "text": "Correction applied."]]
            }
            if let blocks = messages.last?["content"] as? [[String: Any]], blocks.first?["type"] as? String == "tool_result" {
                XCTAssertEqual(messages.last?["role"] as? String, "user")
                XCTAssertEqual(blocks.count, 2)
                XCTAssertEqual(blocks[0]["tool_use_id"] as? String, "first")
                XCTAssertEqual(blocks[1]["tool_use_id"] as? String, "second")
                XCTAssertEqual(blocks[0]["is_error"] as? Bool, false)
                XCTAssertEqual(blocks[1]["is_error"] as? Bool, true)
                XCTAssertEqual(blocks[0]["content"] as? String, "fixture content")
                let preceding = try XCTUnwrap(messages[messages.count - 2]["content"] as? [[String: Any]])
                XCTAssertEqual(preceding[0]["signature"] as? String, "signed-fixture")
                XCTAssertEqual(preceding[1]["data"] as? String, "opaque-fixture")
                reason = "end_turn"
                content = [["type": "text", "text": "Inspected one file; the other was denied."]]
            }
            switch model {
            case "typed": content = [["type": "tool_use", "id": "typed", "name": "typed_action",
                                      "input": ["accept": true, "count": 2, "choices": ["A", "B"]]]]
            case "many-calls":
                content = (0..<12).map { index in
                    ["type": "tool_use", "id": "batch_\(index)", "name": "read_file", "input": ["path": "README.md"]]
                }
            case "truncated": reason = "max_tokens"
            case "server": content = [["type": "server_tool_use", "id": "first", "name": "read_file", "input": [:]]]
            case "toolset": content[2]["toolset_name"] = "computer"
            case "malformed": content[2]["input"] = ["path": 123]
            case "duplicate": content[3]["id"] = "first"
            case "mismatch": reason = "end_turn"
            case "text": reason = "end_turn"; content = [["type": "text", "text": "{\"name\":\"read_file\"}"]]
            default: break
            }
            let response = try JSONSerialization.data(withJSONObject: ["type": "message", "role": "assistant", "stop_reason": reason, "content": content])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AnthropicToolConversationTests: XCTestCase {
    private func conversation(_ model: String = "fixture") throws -> ProviderToolConversation {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicToolFixture.self]
        let tools = model == "typed"
            ? [ModelToolDefinition(name: "typed_action", description: "Fixture", requiredArguments: ["accept", "count", "choices"],
                argumentKinds: ["accept": .boolean, "count": .integer, "choices": .array])]
            : [ModelToolDefinition(name: "read_file", description: "Read a text file", requiredArguments: ["path"])]
        return try ProviderToolConversation(provider: .anthropic, modelID: model, messages: [], apiKey: "fixture-key",
            tools: tools,
            session: URLSession(configuration: config), anthropicOutputTokens: 32_768)
    }

    func testAnthropicTypedArgumentsRemainTyped() async throws {
        let turn = try await conversation("typed").next(outputs: [])
        let call = try XCTUnwrap(turn.calls.first)
        XCTAssertEqual(call.jsonArguments["accept"], .boolean(true))
        XCTAssertEqual(call.jsonArguments["count"], .integer(2))
        XCTAssertEqual(call.jsonArguments["choices"], .array([.string("A"), .string("B")]))
    }

    func testNativeMultipleCallsPreserveSignedBlocksAndErrorResults() async throws {
        let conversation = try conversation()
        let first = try await conversation.next(outputs: [])
        XCTAssertEqual(first.calls.map(\.id), ["first", "second"])
        XCTAssertTrue(first.text.isEmpty, "Thinking blocks must not be shown as assistant text")
        let second = try await conversation.next(outputs: [
            ModelToolOutput(id: "first", content: "fixture content", isError: false),
            ModelToolOutput(id: "second", content: "Access denied", isError: true)
        ])
        XCTAssertTrue(second.calls.isEmpty)
        XCTAssertEqual(second.text, "Inspected one file; the other was denied.")
    }

    func testCorrectionIsSerializedAfterToolResults() async throws {
        let service = try conversation("steer")
        _ = try await service.next(outputs: [])
        let final = try await service.next(outputs: [
            ModelToolOutput(id: "first", content: "fixture content", isError: false),
            ModelToolOutput(id: "second", content: "Access denied", isError: true)
        ], userMessages: ["Use a friendly tone"])
        XCTAssertEqual(final.text, "Correction applied.")
    }

    func testMoreThanEightDistinctCallsDecode() async throws {
        let service = try conversation("many-calls")
        let turn = try await service.next(outputs: [])
        XCTAssertEqual(turn.calls.map(\.id), (0..<12).map { "batch_\($0)" })
    }

    func testIncompleteInvalidAndUnregisteredToolProtocolsFailClosed() async throws {
        for model in ["truncated", "server", "toolset", "malformed", "duplicate", "mismatch"] {
            let conversation = try conversation(model)
            do { _ = try await conversation.next(outputs: []); XCTFail(model) }
            catch { XCTAssertEqual(error as? ModelToolError, .invalidProtocol, model) }
        }
    }

    func testMissingOrReorderedResultsCannotAdvance() async throws {
        let conversation = try conversation()
        _ = try await conversation.next(outputs: [])
        for ids in [["first"], ["second", "first"]] {
            do {
                _ = try await conversation.next(outputs: ids.map { ModelToolOutput(id: $0, content: "x", isError: false) })
                XCTFail("Incomplete result set accepted")
            } catch { XCTAssertEqual(error as? ModelToolError, .invalidProtocol) }
        }
    }

    func testProseJSONIsNeverExecuted() async throws {
        let conversation = try conversation("text")
        let response = try await conversation.next(outputs: [])
        XCTAssertTrue(response.calls.isEmpty)
    }
}
