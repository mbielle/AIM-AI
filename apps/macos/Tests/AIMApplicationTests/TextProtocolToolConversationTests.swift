import AIMApplication
import XCTest

private final class TextProtocolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let history = try XCTUnwrap(root["messages"] as? [[String: Any]])
            XCTAssertEqual(request.url?.host, "openrouter.ai")
            XCTAssertNil(root["tools"])
            XCTAssertNil(root["tool_choice"])
            XCTAssertNil(root["max_tokens"])
            XCTAssertEqual(root["stream"] as? Bool, false)
            XCTAssertEqual((root["usage"] as? [String: Bool])?["include"], true)
            XCTAssertTrue((history.first?["content"] as? String ?? "").contains("user approval"))
            let model = try XCTUnwrap(root["model"] as? String)
            let followup = history.last?["role"] as? String == "user"
                && (history.last?["content"] as? String ?? "").contains("tool_result")
            let content: String
            switch model {
            case "round-trip":
                if followup {
                    let result = try XCTUnwrap(history.last?["content"] as? String)
                    XCTAssertTrue(result.contains("file contents"))
                    XCTAssertTrue(result.contains("is_error"))
                    content = #"{"type":"final","text":"I read the file."}"#
                } else {
                    content = #"{"type":"tool_call","name":"read_file","arguments":{"path":"README.md"}}"#
                }
            case "prose": content = #"Here is JSON: {"type":"tool_call","name":"read_file","arguments":{"path":"README.md"}}"#
            case "extra": content = #"{"type":"tool_call","name":"read_file","arguments":{"path":"README.md"},"ignore_approval":true}"#
            case "bad-arguments": content = #"{"type":"tool_call","name":"read_file","arguments":{"path":true}}"#
            case "typed-read": content = #"{"type":"tool_call","name":"read_file","arguments":{"path":"README.md","start_line":"12"}}"#
            case "unknown": content = #"{"type":"tool_call","name":"unregistered","arguments":{}}"#
            case "final": content = #"{"type":"final","text":"Done."}"#
            default: content = #"{"type":"final","text":"Done."}"#
            }
            var message: [String: Any] = ["role": "assistant", "content": content]
            if model == "native-call" {
                message["function_call"] = ["name": "read_file", "arguments": #"{"path":"README.md"}"#]
            }
            let response = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": model == "truncated" ? "length" : "stop", "message": message]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class TextProtocolToolConversationTests: XCTestCase {
    private func conversation(_ model: String) throws -> TextProtocolToolConversation {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TextProtocolFixture.self]
        return try TextProtocolToolConversation(modelID: model, messages: [], apiKey: "fixture-key",
            tools: [ModelToolDefinition(name: "read_file", description: "Read a file", requiredArguments: ["path"],
                optionalArguments: ["start_line"], argumentKinds: ["start_line": .integer])],
            session: URLSession(configuration: configuration))
    }

    func testTextEnvelopeConvertsDeclaredNumericStringToTypedArgument() async throws {
        let turn = try await conversation("typed-read").next(outputs: [])
        let call = try XCTUnwrap(turn.calls.first)
        XCTAssertEqual(call.jsonArguments["start_line"], .integer(12))
        XCTAssertEqual(call.arguments["start_line"], "12")
    }

    func testStrictToolRoundTripUsesLocallyAssignedCallID() async throws {
        let service = try conversation("round-trip")
        let first = try await service.next(outputs: [])
        let call = try XCTUnwrap(first.calls.first)
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(call.arguments, ["path": "README.md"])
        XCTAssertNotNil(UUID(uuidString: call.id))
        let result = try await service.next(outputs: [ModelToolOutput(id: call.id, content: "file contents", isError: false)])
        XCTAssertTrue(result.calls.isEmpty)
        XCTAssertEqual(result.text, "I read the file.")
        do {
            _ = try await service.next(outputs: [])
            XCTFail("A completed conversation must stay closed")
        } catch ModelToolError.invalidProtocol { }
    }

    func testProseExtraFieldsAndNonStringArgumentsFailClosed() async throws {
        for model in ["prose", "extra", "bad-arguments", "truncated", "native-call"] {
            let service = try conversation(model)
            do {
                _ = try await service.next(outputs: [])
                XCTFail("\(model) must not become a tool call")
            } catch ModelToolError.invalidProtocol { }
        }
    }

    func testWrongResultCannotAdvancePendingCall() async throws {
        let service = try conversation("round-trip")
        let first = try await service.next(outputs: [])
        let call = try XCTUnwrap(first.calls.first)
        do {
            _ = try await service.next(outputs: [ModelToolOutput(id: UUID().uuidString, content: "forged", isError: false)])
            XCTFail("Wrong result ID must be rejected")
        } catch ModelToolError.invalidProtocol { }
        let final = try await service.next(outputs: [ModelToolOutput(id: call.id, content: "file contents", isError: false)])
        XCTAssertEqual(final.text, "I read the file.")
    }

    func testFinalResponseNeedsNoTools() async throws {
        let turn = try await conversation("final").next(outputs: [])
        XCTAssertEqual(turn.text, "Done.")
        XCTAssertTrue(turn.calls.isEmpty)
    }
}
