@testable import AIMApplication
import Foundation
import XCTest

private final class DesktopScreenshotFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            // The Messages request first reads the model's published output capacity.
            if request.httpMethod == "GET", request.url?.path.hasPrefix("/v1/models/") == true {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: ["id": request.url!.lastPathComponent, "max_tokens": 64_000]))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
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
            let anthropic = request.url?.host == "api.anthropic.com"
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            let toolName = try XCTUnwrap(tools.first?["name"] as? String)
            let history = try XCTUnwrap((body[anthropic ? "messages" : "input"]) as? [[String: Any]])
            let followup = history.contains { $0["type"] as? String == "function_call_output" ||
                (($0["content"] as? [[String: Any]])?.first?["type"] as? String) == "tool_result" }
            if followup {
                let imageParts: [[String: Any]]
                if anthropic {
                    let result = try XCTUnwrap(history.last?["content"] as? [[String: Any]])
                    imageParts = try XCTUnwrap(result.first?["content"] as? [[String: Any]])
                    XCTAssertEqual(imageParts.last?["type"] as? String, "image")
                    let source = try XCTUnwrap(imageParts.last?["source"] as? [String: Any])
                    XCTAssertEqual(Data(base64Encoded: source["data"] as? String ?? ""), DesktopScreenshotToolTests.png)
                } else {
                    let result = try XCTUnwrap(history.last?["content"] as? [[String: Any]])
                    XCTAssertEqual(result.last?["type"] as? String, "input_image")
                    let url = try XCTUnwrap(result.last?["image_url"] as? String)
                    XCTAssertEqual(Data(base64Encoded: String(url.split(separator: ",").last ?? "")), DesktopScreenshotToolTests.png)
                    XCTAssertEqual(history[history.count - 2]["type"] as? String, "function_call_output")
                }
            }
            let response: [String: Any]
            if anthropic {
                response = ["type": "message", "role": "assistant", "stop_reason": followup ? "end_turn" : "tool_use",
                    "content": followup ? [["type": "text", "text": "Saw the screenshot."]] :
                        [["type": "tool_use", "id": "shot_1", "name": toolName, "input": ["window_id": "1"]]]]
            } else {
                response = ["object": "response", "status": "completed", "error": NSNull(),
                    "output": followup ? [["type": "message", "status": "completed", "role": "assistant",
                        "content": [["type": "output_text", "text": "Saw the screenshot."]]]] :
                        [["type": "function_call", "id": "fc_1", "status": "completed", "call_id": "shot_1",
                          "name": toolName, "arguments": "{\"window_id\":\"1\"}"]]]
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class DesktopScreenshotToolTests: XCTestCase {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    func testScreenshotPixelsReachOpenAIAndAnthropicToolFollowups() async throws {
        for provider in [ChatProvider.openAI, .anthropic] {
            for toolName in ["desktop_screenshot", "desktop_observe_window"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DesktopScreenshotFixture.self]
            let conversation = try ProviderToolConversation(provider: provider, modelID: "fixture", messages: [], apiKey: "fixture-key",
                tools: [ModelToolDefinition(name: toolName, description: "Capture", requiredArguments: ["window_id"])],
                session: URLSession(configuration: config), modelSupportsImages: true)
            let first = try await conversation.next(outputs: [])
            XCTAssertEqual(first.calls.first?.name, toolName)
            let final = try await conversation.next(outputs: [ModelToolOutput(id: "shot_1", content: "OCR", isError: false, imagePNG: Self.png)])
            XCTAssertEqual(final.text, "Saw the screenshot.")
            }
        }
    }
}
