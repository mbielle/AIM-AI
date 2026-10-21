@testable import AIMApplication
import Foundation
import XCTest

private final class VisionToolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            if request.httpMethod == "GET", request.url?.host == "api.anthropic.com" {
                let response: [String: Any] = ["id": request.url!.lastPathComponent, "max_tokens": 32_768]
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
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
            let host = try XCTUnwrap(request.url?.host)
            let history = try XCTUnwrap((body[host == "generativelanguage.googleapis.com" ? "contents" : host == "api.openai.com" || host == "api.x.ai" ? "input" : "messages"]) as? [[String: Any]])
            let user = try XCTUnwrap(history.first { $0["role"] as? String == "user" })
            let dataURL: String
            let followup = history.last?["type"] as? String == "function_call_output"
            let imageOnly = body["model"] as? String == "image-only" || request.url?.path.contains("image-only") == true
            switch host {
            case "api.openai.com", "api.x.ai":
                let parts = try XCTUnwrap(user["content"] as? [[String: Any]])
                XCTAssertEqual(parts.count, imageOnly ? 1 : 2)
                if !imageOnly { XCTAssertEqual(parts[0]["type"] as? String, "input_text") }
                let image = try XCTUnwrap(parts.last)
                XCTAssertEqual(image["type"] as? String, "input_image")
                dataURL = try XCTUnwrap(image["image_url"] as? String)
            case "api.anthropic.com":
                let parts = try XCTUnwrap(user["content"] as? [[String: Any]])
                if imageOnly { XCTAssertEqual(parts.count, 1) }
                XCTAssertEqual(parts[0]["type"] as? String, "image")
                let source = try XCTUnwrap(parts[0]["source"] as? [String: Any])
                dataURL = "data:\(source["media_type"] as? String ?? "");base64,\(source["data"] as? String ?? "")"
            case "generativelanguage.googleapis.com":
                let parts = try XCTUnwrap(user["parts"] as? [[String: Any]])
                if imageOnly { XCTAssertEqual(parts.count, 1) }
                let inline = try XCTUnwrap(parts[0]["inline_data"] as? [String: Any])
                dataURL = "data:\(inline["mime_type"] as? String ?? "");base64,\(inline["data"] as? String ?? "")"
            case "openrouter.ai":
                let parts = try XCTUnwrap(user["content"] as? [[String: Any]])
                XCTAssertEqual(parts.count, imageOnly ? 1 : 2)
                if !imageOnly { XCTAssertEqual(parts[0]["type"] as? String, "text") }
                let image = try XCTUnwrap(parts.last?["image_url"] as? [String: Any])
                dataURL = try XCTUnwrap(image["url"] as? String)
            default: throw ChatServiceError.invalidResponse
            }
            let payload = try XCTUnwrap(dataURL.components(separatedBy: ",").last)
            XCTAssertEqual(Data(base64Encoded: payload), ToolVisionTests.png)
            XCTAssertNotNil(body["tools"])

            let response: [String: Any]
            switch host {
            case "api.openai.com", "api.x.ai":
                let output: [[String: Any]]
                if body["model"] as? String == "tool-vision" && !followup {
                    output = [["type": "function_call", "id": "fc_vision", "status": "completed", "call_id": "call_vision", "name": "read_file", "arguments": "{\"path\":\"README.md\"}"]]
                } else {
                    output = [["type": "message", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": "Saw image."]]]]
                }
                response = ["object": "response", "status": "completed", "error": NSNull(), "output": output]
            case "api.anthropic.com":
                response = ["type": "message", "role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "Saw image."]]]
            case "generativelanguage.googleapis.com":
                response = ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [["text": "Saw image."]]]]]]
            default:
                response = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Saw image."]]]]
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class ToolVisionTests: XCTestCase {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    private func message() throws -> ConversationMessage {
        ConversationMessage(conversationID: UUID(), role: .user, content: "Inspect this image and the project", sequence: 0,
                            images: [try ImageAttachment(name: "pixel.png", mimeType: "image/png", data: Self.png)])
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VisionToolFixture.self]
        return URLSession(configuration: configuration)
    }

    func testAllVisionToolTransportsKeepImageAndToolSchemas() async throws {
        for provider in [ChatProvider.openAI, .xAI, .anthropic, .google, .openRouter] {
            let conversation = try ProviderToolConversation(provider: provider, modelID: "fixture", messages: [message()], apiKey: "fixture-key",
                tools: [ModelToolDefinition(name: "read_file", description: "Read", requiredArguments: ["path"])], session: session())
            let response = try await conversation.next(outputs: [])
            XCTAssertEqual(response.text, "Saw image.", provider.rawValue)
            XCTAssertTrue(response.calls.isEmpty)
        }
    }

    func testImageSurvivesApprovedToolFollowup() async throws {
        let conversation = try ProviderToolConversation(provider: .openAI, modelID: "tool-vision", messages: [message()], apiKey: "fixture-key",
            tools: [ModelToolDefinition(name: "read_file", description: "Read", requiredArguments: ["path"])], session: session())
        let first = try await conversation.next(outputs: [])
        XCTAssertEqual(first.calls.first?.id, "call_vision")
        let final = try await conversation.next(outputs: [ModelToolOutput(id: "call_vision", content: "Approved text", isError: false)])
        XCTAssertEqual(final.text, "Saw image.")
    }

    func testImageOnlyToolTransportsDoNotAddEmptyTextPart() async throws {
        for provider in [ChatProvider.openAI, .xAI, .anthropic, .google, .openRouter] {
            var imageOnly = try message()
            imageOnly.content = ""
            let conversation = try ProviderToolConversation(provider: provider, modelID: "image-only", messages: [imageOnly], apiKey: "fixture-key",
                tools: [ModelToolDefinition(name: "read_file", description: "Read", requiredArguments: ["path"])], session: session())
            let response = try await conversation.next(outputs: [])
            XCTAssertEqual(response.text, "Saw image.", provider.rawValue)
        }
    }

    func testDeepSeekRejectsNewImageBeforeRequest() throws {
        XCTAssertThrowsError(try ProviderToolConversation(provider: .deepSeek, modelID: "fixture", messages: [message()], apiKey: "fixture-key",
            tools: [ModelToolDefinition(name: "read_file", description: "Read", requiredArguments: ["path"])]))
    }
}
