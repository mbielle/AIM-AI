@testable import AIMApplication
import Foundation
import XCTest

private final class PlanPromptFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let host = try XCTUnwrap(request.url?.host)
            let instructions: String
            switch host {
            case "api.openai.com", "api.x.ai": instructions = try XCTUnwrap(body["instructions"] as? String)
            case "api.anthropic.com":
                instructions = try XCTUnwrap((body["system"] as? String) ??
                    (body["system"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined())
            case "generativelanguage.googleapis.com":
                let system = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
                instructions = try XCTUnwrap((system["parts"] as? [[String: Any]])?.first?["text"] as? String)
            default:
                let history = try XCTUnwrap(body["messages"] as? [[String: Any]])
                instructions = try XCTUnwrap((history.first?["content"] as? String) ??
                    (history.first?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined())
            }
            XCTAssertTrue(instructions.contains("read-only planning turn"), host)
            XCTAssertTrue(instructions.contains("Do not request commands"), host)

            let response: [String: Any]
            switch host {
            case "api.openai.com", "api.x.ai":
                response = ["object": "response", "status": "completed", "error": NSNull(), "output": [
                    ["type": "message", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": "Plan ready."]]]
                ]]
            case "api.anthropic.com":
                response = ["type": "message", "role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "Plan ready."]]]
            case "generativelanguage.googleapis.com":
                response = ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [["text": "Plan ready."]]]]]]
            default:
                response = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Plan ready."]]]]
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            let responseData = try JSONSerialization.data(withJSONObject: response)
            let streamed = (host == "api.openai.com" || host == "api.x.ai") && body["stream"] as? Bool == true
            let wire = streamed ? Data("data: {\"type\":\"response.completed\",\"response\":\(String(decoding: responseData, as: UTF8.self))}\n\n".utf8) : responseData
            client?.urlProtocol(self, didLoad: wire)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class PlanToolConversationTests: XCTestCase {
    func testAllProviderToolRequestsReceiveReadOnlyPlanningInstruction() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlanPromptFixture.self]
        for provider in ChatProvider.allCases where provider.supportsWorkspaceTools {
            let conversation = try ProviderToolConversation(provider: provider, modelID: "fixture",
                messages: [ConversationMessage(conversationID: UUID(), role: .user, content: "Plan it", sequence: 0)],
                apiKey: "fixture-key", tools: [ModelToolDefinition(name: "read_file", description: "Read a file", requiredArguments: ["path"])],
                session: URLSession(configuration: configuration), anthropicOutputTokens: 128, planOnly: true)
            let turn = try await conversation.next(outputs: [])
            XCTAssertEqual(turn.text, "Plan ready.", provider.rawValue)
            XCTAssertTrue(turn.calls.isEmpty)
        }
    }
}
