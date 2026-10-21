import AIMApplication
import XCTest
import AIMCore

private final class NativeProviderFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let provider = ChatProvider.allCases.first { $0.host == request.url?.host }!
        let catalog = request.httpMethod != "POST"
        let body: String
        if catalog {
            let secondPage = request.url?.query != nil && request.url!.query!.contains("next")
            switch provider {
            case .openAI: body = #"{"data":[{"id":"gpt-fixture"},{"id":"text-embedding-fixture"},{"id":"gpt-audio-fixture"}]}"#
            case .xAI:
                XCTAssertEqual(request.url?.path, "/v1/language-models")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake")
                body = #"{"models":[{"id":"grok-fixture","input_modalities":["text","image"],"output_modalities":["text"]},{"id":"image-fixture","output_modalities":["image"]},{"id":"audio-fixture","input_modalities":["audio"],"output_modalities":["text"]}]}"#
            case .anthropic:
                body = request.url?.path == "/v1/models/native-transport-fixture"
                    ? #"{"id":"native-transport-fixture","display_name":"Fixture","max_tokens":512}"#
                    : (secondPage ? #"{"data":[{"id":"claude-second","display_name":"Second"}],"has_more":false}"# : #"{"data":[{"id":"claude-first","display_name":"First"}],"has_more":true,"last_id":"next"}"#)
            case .google:
                body = secondPage ? #"{"models":[{"name":"models/second","displayName":"Second","supportedGenerationMethods":["generateContent"]}]}"# : #"{"models":[{"name":"models/first","displayName":"First","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next"}"#
            case .openRouter: body = #"{"data":[{"id":"provider/model","name":"Fixture","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},{"id":"provider/text","name":"Text Fixture","architecture":{"input_modalities":["text"],"output_modalities":["text"]}}]}"#
            case .perplexity:
                XCTAssertEqual(request.url?.path, "/router/v1/models")
                body = #"{"data":[{"id":"perplexity/sonar","name":"Sonar","input_modalities":["text","image"]},{"id":"other/model"},{"id":"perplexity/image-model"}]}"#
            case .deepSeek:
                XCTAssertEqual(request.url?.path, "/models")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake")
                body = #"{"data":[{"id":"deepseek-fixture","name":"DeepSeek Fixture","context_window":100000,"output_modalities":["text"]},{"id":"image-fixture","output_modalities":["image"]}]}"#
            case .local: body = #"{"data":[{"id":"local--model","max_model_len":32768},{"id":"text-embedding-local"}]}"#
            default: body = #"{"data":[{"id":"compatible-fixture"}]}"#
            }
        } else {
            switch provider {
            case .openAI, .xAI:
                // URLSession may move httpBody into a stream before URLProtocol sees it.
                let model = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
                let terminal: String
                if model == "malformed-terminal" { terminal = #"{"type":"response.completed"}"# }
                else if model == "unexpected-tool" { terminal = #"{"type":"response.output_item.added","item":{"type":"function_call"}}"# }
                else { terminal = #"{"type":"response.completed","response":{"object":"response","status":"completed","error":null,"output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}]}}"# }
                body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\ndata: \(terminal)\n\n"
            case .perplexity:
                let sourceItem = request.value(forHTTPHeaderField: "Authorization") == "Bearer sources-key"
                    ? #",{"type":"search_results","results":[{"id":3,"title":"Verified source","url":"https://example.org/source"}]}"# : ""
                body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"status\":\"completed\",\"error\":null,\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}\(sourceItem)]}}\n\n"
            case .anthropic: body = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            case .google: body = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello\"}]},\"finishReason\":\"STOP\"}]}\n\n"
            default: body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n"
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": catalog ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class NativeProviderTransportTests: XCTestCase {
    private func service() -> ProviderChatService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NativeProviderFixture.self]
        return ProviderChatService(session: URLSession(configuration: config))
    }

    func testEachProviderStreamsThroughItsNativeProtocol() async throws {
        for provider in ChatProvider.allCases {
            var text = ""
            for try await chunk in service().stream(provider: provider, modelID: "native-transport-fixture", messages: [], apiKey: "fake-key", mode: .chat) { text += chunk }
            XCTAssertEqual(text, "Hello", provider.name)
        }
    }

    func testBillableInferenceProbeUsesEachNativeTransportWithoutSavingHistory() async throws {
        let probe = ProviderInferenceProbe(service: service())
        for provider in ChatProvider.allCases {
            let answer = try await probe.run(provider: provider, modelID: "native-transport-fixture", apiKey: "fake-key")
            XCTAssertEqual(answer, "Hello", provider.name)
        }
        let request = try ProviderChatService.request(provider: .perplexity, modelID: "perplexity/sonar",
                                                      messages: [ConversationMessage(conversationID: UUID(), role: .user,
                                                                                     content: "Reply with the single word READY.", sequence: 0)],
                                                      apiKey: "fake-key", mode: .chat, useWebSearch: false)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["tools"])
    }

    func testPerplexityTransportKeepsAnswerAndStructuredSources() async throws {
        var answer = ""
        var sources: [ConversationSource]?
        for try await event in service().events(provider: .perplexity, modelID: "perplexity/sonar", messages: [], apiKey: "sources-key", mode: .chat) {
            if case .text(let text) = event { answer += text }
            if case .metrics(let metrics) = event { sources = metrics.sources }
        }
        XCTAssertEqual(answer, "Hello")
        XCTAssertEqual(sources?.map(\.url), ["https://example.org/source"])
        XCTAssertEqual(sources?.first?.title, "Verified source")
        XCTAssertEqual(sources?.first?.references, [3])
    }

    func testCatalogPaginationAndNonChatFiltering() async throws {
        let service = service()
        let openAI = try await service.models(provider: .openAI, apiKey: "fake")
        XCTAssertEqual(openAI.map(\.id), ["gpt-fixture"])
        let anthropic = try await service.models(provider: .anthropic, apiKey: "fake")
        XCTAssertEqual(anthropic.map(\.id), ["claude-first", "claude-second"])
        let google = try await service.models(provider: .google, apiKey: "fake")
        XCTAssertEqual(google.map(\.id), ["models/first", "models/second"])
        let router = try await service.models(provider: .openRouter, apiKey: nil)
        XCTAssertEqual(router.map(\.id), ["provider/model", "provider/text"])
        XCTAssertEqual(router.first?.supportsImageInput, true)
        XCTAssertEqual(router.last?.supportsImageInput, false)
        let deepSeek = try await service.models(provider: .deepSeek, apiKey: "fake")
        XCTAssertEqual(deepSeek.map(\.id), ["deepseek-fixture"])
        XCTAssertEqual(deepSeek.first?.name, "DeepSeek Fixture")
        XCTAssertEqual(deepSeek.first?.contextLength, 100000)
        let xAI = try await service.models(provider: .xAI, apiKey: "fake")
        XCTAssertEqual(xAI.map(\.id), ["grok-fixture"])
        XCTAssertEqual(xAI.first?.supportsImageInput, true)
        let perplexity = try await service.models(provider: .perplexity, apiKey: "fake")
        XCTAssertEqual(perplexity.map(\.id), ["perplexity/sonar"])
        XCTAssertEqual(perplexity.first?.supportsImageInput, true)
        XCTAssertNil(openAI.first?.supportsImageInput)
    }

    func testPartialTextDoesNotTurnProtocolFailureIntoSuccess() async {
        for provider in [ChatProvider.openAI, .xAI] {
            for model in ["malformed-terminal", "unexpected-tool"] {
                var text = ""
                do {
                    for try await chunk in service().stream(provider: provider, modelID: "native-transport-fixture", messages: [], apiKey: model, mode: .chat) { text += chunk }
                    XCTFail("Invalid terminal must fail")
                } catch {
                    XCTAssertEqual(text, "Hello")
                    XCTAssertTrue(error is ChatServiceError)
                }
            }
        }
    }
}
