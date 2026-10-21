@testable import AIMApplication
import Foundation
import XCTest

private final class BrowserVisionFixture: URLProtocol, @unchecked Sendable {
    static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
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
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let hasToolOutput = input.contains { $0["type"] as? String == "function_call_output" }
            let response: [String: Any]
            if hasToolOutput {
                let output = try XCTUnwrap(input.first { $0["type"] as? String == "function_call_output" })
                XCTAssertEqual(output["call_id"] as? String, "capture_1")
                let visual = try XCTUnwrap(input.last { $0["role"] as? String == "user" && $0["content"] is [[String: Any]] })
                let parts = try XCTUnwrap(visual["content"] as? [[String: Any]])
                let url = try XCTUnwrap(parts.first { $0["type"] as? String == "input_image" }?["image_url"] as? String)
                XCTAssertEqual(Data(base64Encoded: String(url.split(separator: ",").last ?? "")), Self.pixel)
                response = ["object": "response", "status": "completed", "error": NSNull(),
                            "output": [["type": "message", "status": "completed", "role": "assistant",
                                        "content": [["type": "output_text", "text": "I can see the browser pixels."]]]]]
            } else {
                response = ["object": "response", "status": "completed", "error": NSNull(),
                            "output": [["type": "function_call", "id": "fc_1", "status": "completed",
                                        "call_id": "capture_1", "name": "browser_take_screenshot", "arguments": "{}"]]]
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class BrowserVisionFollowupTests: XCTestCase {
    func testBrowserScreenshotPixelsReachTheNextModelRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserVisionFixture.self]
        let service = try ProviderToolConversation(provider: .openAI, modelID: "browser-vision",
            messages: [ConversationMessage(conversationID: UUID(), role: .user, content: "Inspect the page", sequence: 0)],
            apiKey: "fixture-key", tools: [ModelToolDefinition(name: "browser_take_screenshot", description: "Capture")],
            session: URLSession(configuration: configuration), modelSupportsImages: true)
        let first = try await service.next(outputs: [])
        XCTAssertEqual(first.calls.first?.name, "browser_take_screenshot")
        let final = try await service.next(outputs: [ModelToolOutput(id: "capture_1", content: "Screenshot returned",
            isError: false, imagePNG: BrowserVisionFixture.pixel)])
        XCTAssertEqual(final.text, "I can see the browser pixels.")
    }
}
