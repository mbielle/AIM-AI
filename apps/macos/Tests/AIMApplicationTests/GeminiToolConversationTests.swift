@testable import AIMApplication
import XCTest

private final class GeminiToolFixture: URLProtocol, @unchecked Sendable {
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
            XCTAssertNil((body["generationConfig"] as? [String: Any])?["maxOutputTokens"])
            XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/fixture:generateContent")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.url?.query)
            XCTAssertNil(body["messages"])
            XCTAssertNil(body["model"])
            XCTAssertEqual(body["store"] as? Bool, false)
            let declarations = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]])
            XCTAssertNotNil(declarations.first?["parametersJsonSchema"])
            let history = try XCTUnwrap(body["contents"] as? [[String: Any]])
            let parts: [[String: Any]]
            if let results = history.last?["parts"] as? [[String: Any]], results.first?["functionResponse"] != nil {
                let first = try XCTUnwrap(results[0]["functionResponse"] as? [String: Any])
                let second = try XCTUnwrap(results[1]["functionResponse"] as? [String: Any])
                XCTAssertEqual(first["id"] as? String, "wire_id")
                XCTAssertNil(second["id"], "Local correlation IDs must never be invented on the wire")
                XCTAssertEqual(first["name"] as? String, "list_dir")
                XCTAssertEqual(second["name"] as? String, "list_dir")
                XCTAssertEqual((first["response"] as? [String: String])?["output"], "fixture result")
                XCTAssertEqual((second["response"] as? [String: String])?["error"], "Denied")
                let previous = try XCTUnwrap(history[history.count - 2]["parts"] as? [[String: Any]])
                XCTAssertEqual(previous[1]["thoughtSignature"] as? String, "opaque-fixture")
                XCTAssertNil((previous[2]["functionCall"] as? [String: Any])?["id"])
                parts = [["text": "Inspected fixture."]]
            } else {
                XCTAssertEqual(history.first?["role"] as? String, "user")
                parts = [
                    ["thought": true, "text": "private fixture"],
                    ["functionCall": ["name": "list_dir", "args": [:], "id": "wire_id"], "thoughtSignature": "opaque-fixture"],
                    ["functionCall": ["name": "list_dir", "args": ["path": "src"]]]
                ]
            }
            let response = try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": parts]]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GeminiToolConversationTests: XCTestCase {
    func testRoundTripPreservesSignedPartsAndOptionalIDs() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiToolFixture.self]
        let message = ConversationMessage(conversationID: UUID(), role: .user, content: "Inspect fixture", sequence: 0)
        let service = try ProviderToolConversation(provider: .google, modelID: "models/fixture", messages: [message], apiKey: "fixture-key",
            tools: [ModelToolDefinition(name: "list_dir", description: "List", optionalArguments: ["path"])], session: URLSession(configuration: config))
        let first = try await service.next(outputs: [])
        XCTAssertTrue(first.text.isEmpty)
        XCTAssertEqual(first.calls.count, 2)
        XCTAssertEqual(first.calls[0].id, "wire_id")
        XCTAssertNotEqual(first.calls[1].id, first.calls[0].id)
        let final = try await service.next(outputs: [
            ModelToolOutput(id: first.calls[0].id, content: "fixture result", isError: false),
            ModelToolOutput(id: first.calls[1].id, content: "Denied", isError: true)
        ])
        XCTAssertEqual(final.text, "Inspected fixture.")
        XCTAssertTrue(final.calls.isEmpty)
    }

    func testBlockedTruncatedAndAmbiguousResponsesCannotExecute() throws {
        for reason in ["MAX_TOKENS", "SAFETY", "MALFORMED_FUNCTION_CALL", "OTHER"] {
            XCTAssertThrowsError(try decode([call()], reason: reason))
        }
        let blocked: [String: Any] = ["promptFeedback": ["blockReason": "SAFETY"], "candidates": []]
        XCTAssertThrowsError(try GeminiToolWire.decode(JSONSerialization.data(withJSONObject: blocked)))
        let candidate: [String: Any] = ["finishReason": "STOP", "content": ["role": "model", "parts": [call()]]]
        XCTAssertThrowsError(try GeminiToolWire.decode(JSONSerialization.data(withJSONObject: ["candidates": [candidate, candidate]])))
    }

    func testDuplicateIDsMalformedArgumentsAndServerToolsFailClosed() throws {
        XCTAssertThrowsError(try decode([call(), call()]))
        for part: [String: Any] in [
            ["functionCall": ["id": "a", "name": "list_dir", "args": ["path": true]]],
            ["functionCall": ["id": "", "name": "list_dir", "args": [:]]],
            ["functionCall": "invalid", "thoughtSignature": "signed"],
            ["executableCode": ["code": "danger"]],
            ["text": "hello", "functionCall": ["name": "list_dir"]]
        ] { XCTAssertThrowsError(try decode([part])) }
    }

    func testMoreThan256DistinctCallsDecode() throws {
        let calls = (0..<300).map { index -> [String: Any] in
            ["functionCall": ["name": "list_dir", "id": "call_\(index)", "args": [:]]]
        }
        let result = try decode(calls)
        XCTAssertEqual(result.turn.calls.map(\.id), (0..<300).map { "call_\($0)" })
    }

    func testModelPathsCannotChangeEndpointAndJSONTextNeverExecutes() throws {
        for id in ["../other", "models/", "models/a/b", "a:generateContent", "a?key=x", "a#fragment"] {
            XCTAssertThrowsError(try GeminiToolWire.endpoint(modelID: id))
        }
        let text = try decode([["text": "{\"functionCall\":{\"name\":\"list_dir\"}}"]])
        XCTAssertTrue(text.turn.calls.isEmpty)
        XCTAssertEqual(try GeminiToolWire.endpoint(modelID: "fixture"), try GeminiToolWire.endpoint(modelID: "models/fixture"))
    }

    private func call() -> [String: Any] { ["functionCall": ["name": "list_dir", "id": "a", "args": [:]]] }
    private func decode(_ parts: [[String: Any]], reason: String = "STOP") throws -> (turn: ModelToolTurn, content: [String: Any], references: [GeminiToolWire.CallReference]) {
        try GeminiToolWire.decode(JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": reason, "content": ["role": "model", "parts": parts]]]]))
    }
}
