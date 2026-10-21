import AIMApplication
import XCTest

private final class ToolWireFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            if request.url?.path == "/api/v1/models" {
                let catalog = Data(#"{"data":[{"id":"receipt","context_length":4096,"supported_parameters":["max_tokens"],"top_provider":{"max_completion_tokens":128},"pricing":{"prompt":"0.00001","completion":"0.00002","request":"0"}}]}"#.utf8)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: catalog)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
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
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let model = try XCTUnwrap(root["model"] as? String)
            let history = try XCTUnwrap(root["messages"] as? [[String: Any]])
            if model == "long" {
                let round = history.filter { $0["role"] as? String == "tool" }.count
                let message: [String: Any] = round == 32
                    ? ["role": "assistant", "content": "Done"]
                    : ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "long_\(round)", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"README.md\"}"]]]]
                let response = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": round == 32 ? "stop" : "tool_calls", "message": message]]])
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            // Tool runs are streamed; the fixture answers in one piece, which the assembler passes through.
            XCTAssertEqual(root["stream"] as? Bool, true)
            XCTAssertEqual((root["usage"] as? [String: Bool])?["include"], true)
            XCTAssertNotNil(root["tools"])
            if model == "receipt" {
                XCTAssertEqual(root["max_tokens"] as? Int, 128)
                XCTAssertEqual((root["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool, false)
            } else { XCTAssertNil(root["max_tokens"]) }
            XCTAssertNil(root["max_completion_tokens"])
            let isFollowup = history.last?["role"] as? String == "tool"
            var message: [String: Any] = ["role": "assistant", "content": NSNull(),
                "reasoning_details": [["type": "reasoning.encrypted", "data": "opaque-fixture"]],
                "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"README.md\"}"]]]]
            var finish = "tool_calls"
            if model == "malformed" { message["tool_calls"] = [["id": "bad", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":true}"]]] }
            if model == "truncated" { finish = "length" }
            if model == "duplicate" {
                let calls = message["tool_calls"] as! [[String: Any]]
                message["tool_calls"] = calls + calls
            }
            if model == "many-calls" {
                message["tool_calls"] = (0..<12).map { index in
                    ["id": "batch_\(index)", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"README.md\"}"]]
                }
            }
            if model == "typed" {
                message["tool_calls"] = [["id": "typed", "type": "function", "function": [
                    "name": "typed_action", "arguments": #"{"accept":true,"count":2,"choices":["A","B"]}"#]]]
            }
            if isFollowup {
                XCTAssertEqual(history.last?["tool_call_id"] as? String, "call_1")
                let preceding = history[history.count - 2]
                XCTAssertEqual((preceding["reasoning_details"] as? [[String: String]])?.first?["data"], "opaque-fixture")
                let result = try XCTUnwrap(history.last?["content"] as? String)
                XCTAssertTrue(result.contains("fixture result"))
                message = ["role": "assistant", "content": "Verified fixture result.", "tool_calls": NSNull()]
                finish = "stop"
            }
            if model == "text-only" {
                message = ["role": "assistant", "content": "{\"name\":\"read_file\",\"path\":\"secret\"}"]
                finish = "stop"
            }
            if model == "receipt" {
                message = ["role": "assistant", "content": "Done"]
                finish = "stop"
            }
            // Keep monetary JSON lexical: JSONSerialization round-trips an
            // in-memory Double such as 0.015 as 0.014999999999999999.
            let body = model == "receipt"
                ? Data(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Done"}}],"usage":{"cost":0.015}}"#.utf8)
                : try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": message]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class OpenRouterToolConversationTests: XCTestCase {
    func testProviderCostReceiptClosesTheBillableAttempt() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolWireFixture.self]
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "2", period: .envelope, timeZoneID: "UTC"))
        let conversation = try ProviderToolConversation(modelID: "receipt", messages: [], apiKey: "fixture-key",
            tools: [ModelToolDefinition(name: "read_file", description: "Read file", requiredArguments: ["path"])],
            session: URLSession(configuration: config), meter: BillableRequestMeter(ledger: ledger))
        let turn = try await conversation.next(outputs: [])
        XCTAssertEqual(turn.text, "Done")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.confirmedUSD, "0.015")
        XCTAssertEqual(snapshot.unknownAttempts, 0)
    }

    func testProviderConversationContinuesPastFormerRoundQuota() async throws {
        let service = try conversation("long")
        var outputs: [ModelToolOutput] = []
        for round in 0...32 {
            let turn = try await service.next(outputs: outputs)
            if round == 32 {
                XCTAssertEqual(turn.text, "Done")
                XCTAssertTrue(turn.calls.isEmpty)
            } else {
                XCTAssertEqual(turn.calls.first?.id, "long_\(round)")
                outputs = turn.calls.map { ModelToolOutput(id: $0.id, content: "fixture", isError: false) }
            }
        }
    }

    private func conversation(_ model: String = "fixture") throws -> ProviderToolConversation {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolWireFixture.self]
        let tools = model == "typed"
            ? [ModelToolDefinition(name: "typed_action", description: "Fixture", requiredArguments: ["accept", "count", "choices"],
                argumentKinds: ["accept": .boolean, "count": .integer, "choices": .array])]
            : [ModelToolDefinition(name: "read_file", description: "Read file", requiredArguments: ["path"])]
        return try ProviderToolConversation(modelID: model, messages: [], apiKey: "fixture-key",
            tools: tools,
            session: URLSession(configuration: config))
    }

    func testOpenRouterTypedArgumentsRemainTyped() async throws {
        let turn = try await conversation("typed").next(outputs: [])
        let call = try XCTUnwrap(turn.calls.first)
        XCTAssertEqual(call.jsonArguments["accept"], .boolean(true))
        XCTAssertEqual(call.jsonArguments["count"], .integer(2))
        XCTAssertEqual(call.jsonArguments["choices"], .array([.string("A"), .string("B")]))
    }

    func testNativeCallsAndOpaqueReasoningSurviveRoundTrip() async throws {
        let service = try conversation()
        let first = try await service.next(outputs: [])
        XCTAssertEqual(first.calls, [ModelToolCall(id: "call_1", name: "read_file", arguments: ["path": "README.md"])])
        let second = try await service.next(outputs: [ModelToolOutput(id: "call_1", content: "fixture result", isError: false)])
        XCTAssertEqual(second.text, "Verified fixture result.")
        XCTAssertTrue(second.calls.isEmpty)
        do { _ = try await service.next(outputs: []); XCTFail("Completed conversation must not restart") } catch { }
    }

    func testMoreThanEightDistinctCallsDecode() async throws {
        let service = try conversation("many-calls")
        let turn = try await service.next(outputs: [])
        XCTAssertEqual(turn.calls.map(\.id), (0..<12).map { "batch_\($0)" })
    }

    func testWrongResultsCannotAdvanceTranscript() async throws {
        let service = try conversation()
        _ = try await service.next(outputs: [])
        do { _ = try await service.next(outputs: [ModelToolOutput(id: "wrong", content: "x", isError: false)]); XCTFail() } catch { }
        let second = try await service.next(outputs: [ModelToolOutput(id: "call_1", content: "fixture result", isError: true)])
        XCTAssertTrue(second.calls.isEmpty)
    }

    func testTruncatedMalformedAndDuplicateCallsFailClosed() async throws {
        // Arguments of the wrong type reach the dispatcher, which refuses them with an
        // explanation; the conversation itself does not end.
        let malformed = try await conversation("malformed").next(outputs: [])
        XCTAssertEqual(malformed.calls.first?.jsonArguments["path"], .boolean(true))
        for model in ["truncated", "duplicate"] {
            let service = try conversation(model)
            do { _ = try await service.next(outputs: []); XCTFail(model) } catch { XCTAssertTrue(error is ModelToolError) }
            do { _ = try await service.next(outputs: []); XCTFail("Failed request must not replay") } catch { }
        }
    }

    func testJSONInTextIsNotAToolCall() async throws {
        let service = try conversation("text-only")
        let turn = try await service.next(outputs: [])
        XCTAssertTrue(turn.calls.isEmpty)
        XCTAssertTrue(turn.text.contains("secret"))
    }
}
