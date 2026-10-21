import AIMApplication
import XCTest

final class ProviderProtocolTests: XCTestCase {
    func testBYOKTextRequestsDoNotSetOptionalOutputCeilings() throws {
        for provider in ChatProvider.allCases where provider.requiresAPIKey {
            let request = try ProviderChatService.request(provider: provider, modelID: "fixture", messages: [], apiKey: "fixture-key", mode: .chat, catalogMaximumOutputTokens: provider == .anthropic ? 128_000 : nil)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            if provider == .anthropic {
                XCTAssertEqual(body["max_tokens"] as? Int, 128_000, "Messages uses the published model capacity")
            } else {
                XCTAssertNil(body["max_tokens"], provider.name)
                XCTAssertNil(body["max_completion_tokens"], provider.name)
                XCTAssertNil(body["max_output_tokens"], provider.name)
                XCTAssertNil((body["generationConfig"] as? [String: Any])?["maxOutputTokens"], provider.name)
            }
        }
    }

    private var history: [ConversationMessage] {
        let id = UUID()
        return [ConversationMessage(conversationID: id, role: .user, content: "Question", sequence: 0),
                ConversationMessage(conversationID: id, role: .assistant, content: "Answer", sequence: 1)]
    }

    func testProviderRoutingAndCredentialIsolation() throws {
        for provider in ChatProvider.allCases where provider.requiresAPIKey {
            let request = try ProviderChatService.request(provider: provider, modelID: "test-model", messages: history, apiKey: "fixture-secret", mode: .code, catalogMaximumOutputTokens: provider == .anthropic ? 128_000 : nil)
            XCTAssertEqual(request.url?.host, provider.host)
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-secret"))
            let data = try XCTUnwrap(request.httpBody)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-secret"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            switch provider {
            case .anthropic:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-secret")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual((json["messages"] as? [[String: Any]])?.count, 2)
                XCTAssertNotNil(json["system"])
            case .google:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-secret")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
                XCTAssertEqual(contents.last?["role"] as? String, "model")
                XCTAssertNotNil(json["systemInstruction"])
            case .openAI, .xAI, .chatgpt:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
                XCTAssertEqual(request.url?.path, "/v1/responses")
                XCTAssertEqual(json["store"] as? Bool, false)
                XCTAssertEqual((json["input"] as? [[String: Any]])?.count, 2)
                XCTAssertNotNil(json["instructions"])
            case .perplexity:
                XCTAssertEqual(request.url?.path, "/v1/agent")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
                XCTAssertEqual(json["store"] as? Bool, false)
                XCTAssertEqual((json["input"] as? [[String: Any]])?.count, 2)
                XCTAssertNil(json["tools"], "An unqualified fixture model must not receive an unsupported search tool")
                XCTAssertNotNil(json["instructions"])
                XCTAssertFalse(provider.supportsWorkspaceTools)
            case .openRouter:
                XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
            case .deepSeek:
                XCTAssertEqual(request.url?.path, "/chat/completions")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
                XCTAssertNil(json["provider"])
                XCTAssertEqual((json["messages"] as? [[String: Any]])?.first?["role"] as? String, "system")
            case .local: XCTFail("the keyless local provider is tested separately")
            default:
                XCTAssertTrue(provider.isCompatible)
                XCTAssertTrue(request.url?.path.hasSuffix("/chat/completions") == true)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
            }
        }
    }

    func testNativeStreamingCompletionSemantics() throws {
        let openAI = try ProviderWireFormat.decode(#"{"type":"response.output_text.delta","delta":"Hello 🌍"}"#, provider: .openAI)
        XCTAssertEqual(openAI.text, "Hello 🌍")
        XCTAssertFalse(openAI.isComplete)
        XCTAssertTrue(try ProviderWireFormat.decode(completedResponse, provider: .openAI).isComplete)
        XCTAssertThrowsError(try ProviderWireFormat.decode(#"{"type":"response.incomplete"}"#, provider: .openAI))
        XCTAssertEqual(try ProviderWireFormat.decode(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Bonjour"}}"#, provider: .anthropic).text, "Bonjour")
        XCTAssertTrue(try ProviderWireFormat.decode(#"{"type":"message_stop"}"#, provider: .anthropic).isComplete)
        XCTAssertThrowsError(try ProviderWireFormat.decode(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#, provider: .anthropic))
        let google = try ProviderWireFormat.decode(#"{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"Answer"}]},"finishReason":"STOP"}]}"#, provider: .google)
        XCTAssertEqual(google.text, "Answer")
        XCTAssertTrue(google.isComplete)
        XCTAssertThrowsError(try ProviderWireFormat.decode(#"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#, provider: .google))
    }

    func testTextOnlyResponsesAcceptMoreThan256ValidOutputItems() throws {
        let items = Array(repeating: ["type": "reasoning", "status": "completed"], count: 300)
            + [["type": "message", "role": "assistant", "status": "completed",
                "content": [["type": "output_text", "text": "Done"]]]]
        let payload: [String: Any] = ["type": "response.completed", "response": [
            "object": "response", "status": "completed", "error": NSNull(), "output": items
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        for provider in [ChatProvider.openAI, .xAI] {
            XCTAssertTrue(try ProviderWireFormat.decode(String(decoding: data, as: UTF8.self), provider: provider).isComplete)
        }
    }

    func testXAIStreamingDoesNotExposeReasoningAndRejectsFailedCompletion() throws {
        XCTAssertEqual(try ProviderWireFormat.decode(#"{"type":"response.reasoning_text.delta","delta":"opaque"}"#, provider: .xAI).text, "")
        XCTAssertEqual(try ProviderWireFormat.decode(#"{"type":"response.output_text.delta","delta":"Visible"}"#, provider: .xAI).text, "Visible")
        XCTAssertTrue(try ProviderWireFormat.decode(completedResponse, provider: .xAI).isComplete)
        for event in ["response.failed", "response.incomplete", "error"] {
            XCTAssertThrowsError(try ProviderWireFormat.decode("{\"type\":\"\(event)\"}", provider: .xAI))
        }
    }

    func testGoogleModelCannotChangeEndpoint() throws {
        for id in ["../escape", "foo/bar", "foo?key=bad", "foo#fragment", "foo:method"] {
            XCTAssertThrowsError(try ProviderChatService.request(provider: .google, modelID: id, messages: history, apiKey: "key", mode: .chat))
        }
        let valid = try ProviderChatService.request(provider: .google, modelID: "models/test-model", messages: history, apiKey: "key", mode: .chat)
        XCTAssertEqual(valid.url?.path, "/v1beta/models/test-model:streamGenerateContent")
    }

    private var completedResponse: String {
        #"{"type":"response.completed","response":{"object":"response","status":"completed","error":null,"output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}]}}"#
    }

    func testResponsesRejectMalformedOrContradictoryCompletion() throws {
        for provider in [ChatProvider.openAI, .xAI] {
            for payload in [#"{"type":"response.completed"}"#,
                            #"{"type":"response.completed","response":{"object":"response","status":"completed","output":[]}}"#,
                            completedResponse.replacingOccurrences(of: #""status":"completed""#, with: #""status":"incomplete""#),
                            completedResponse.replacingOccurrences(of: #""error":null"#, with: #""error":{"message":"private"}"#),
                            #"{"type":"response.output_text.delta","delta":42}"#] {
                XCTAssertThrowsError(try ProviderWireFormat.decode(payload, provider: provider))
            }
        }
    }

    func testTextOnlyResponsesRejectToolsAndKeepReasoningOpaque() throws {
        for provider in [ChatProvider.openAI, .xAI] {
            for type in ["function_call", "web_search_call", "mcp_call", "computer_call", "future_tool"] {
                for event in ["response.output_item.added", "response.output_item.done"] {
                    XCTAssertThrowsError(try ProviderWireFormat.decode("{\"type\":\"\(event)\",\"item\":{\"type\":\"\(type)\"}}", provider: provider))
                }
                let final = completedResponse.replacingOccurrences(of: #""type":"message""#, with: "\"type\":\"\(type)\"")
                XCTAssertThrowsError(try ProviderWireFormat.decode(final, provider: provider))
            }
            let reasoning = try ProviderWireFormat.decode(#"{"type":"response.output_item.done","item":{"type":"reasoning","encrypted_content":"opaque"}}"#, provider: provider)
            XCTAssertEqual(reasoning.text, "")
            XCTAssertFalse(reasoning.isComplete)
        }
    }

    func testProviderErrorsNeverSurfaceRawPayload() throws {
        for provider in ChatProvider.allCases where provider.requiresAPIKey {
            do {
                _ = try ProviderWireFormat.decode(#"{"error":{"message":"private-api-key"}}"#, provider: provider)
                XCTFail("Expected failure")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private-api-key")) }
        }
    }
}
