@testable import AIMApplication
import XCTest

final class ProviderExpansionTests: XCTestCase {
    private let message = ConversationMessage(conversationID: UUID(), role: .user, content: "Hello", sequence: 0)

    func testEveryCompatibleProviderPostsChatCompletionsUnderItsBaseURL() throws {
        let compatible = ChatProvider.allCases.filter(\.isCompatible)
        XCTAssertEqual(compatible.count, 17)
        for provider in compatible {
            let spec = try XCTUnwrap(CompatibleProviders.spec(provider))
            XCTAssertTrue(spec.baseURL.hasPrefix("https://"), provider.rawValue)
            let request = try ProviderChatService.request(provider: provider, modelID: "maker/model-1", messages: [message], apiKey: "test-key", mode: .chat)
            XCTAssertEqual(request.url?.absoluteString, spec.baseURL + "/chat/completions", provider.rawValue)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key", provider.rawValue)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual((body["messages"] as? [[String: Any]])?.last?["content"] as? String, "Hello")
        }
    }

    func testCompatibleModelListDecodesDataAndModelsShapes() throws {
        let openAIShape = Data(#"{"data":[{"id":"zeta-large","context_length":128000},{"id":"alpha-small"},{"object":"model"}]}"#.utf8)
        let models = try CompatibleProviders.decodeModels(openAIShape)
        XCTAssertEqual(models.map(\.id), ["alpha-small", "zeta-large"])
        XCTAssertEqual(models.last?.contextLength, 128_000)
        let otherShape = Data(#"{"models":[{"name":"command-a","context_window":256000}]}"#.utf8)
        XCTAssertEqual(try CompatibleProviders.decodeModels(otherShape).first?.contextLength, 256_000)
        XCTAssertThrowsError(try CompatibleProviders.decodeModels(Data("[]".utf8)))
    }

    func testHostedModelsAreAttributedToTheirMaker() {
        XCTAssertEqual(ModelIdentity.creator(for: ChatModel(id: "gpt-5.5", name: "GPT"), via: .chatgpt), "openai")
        XCTAssertEqual(ModelIdentity.creator(for: ChatModel(id: "mistral-large-latest", name: "M"), via: .mistral), "mistral")
    }

    func testFluxRequestAndPollingResult() throws {
        let request = try BlackForestLabsImageService.request(prompt: " A red fox ", model: .flux2Pro, size: .landscape, apiKey: "bfl-key")
        XCTAssertEqual(request.url?.absoluteString, "https://api.bfl.ai/v1/flux-2-pro")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-key"), "bfl-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["prompt"] as? String, "A red fox")
        XCTAssertEqual(body["width"] as? Int, 1536)
        XCTAssertEqual(body["height"] as? Int, 1024)
        XCTAssertThrowsError(try BlackForestLabsImageService.request(prompt: "  ", model: .flux2Pro, size: .square, apiKey: "k"))
        XCTAssertThrowsError(try BlackForestLabsImageService.request(prompt: "x", model: .flux2Pro, size: .square, apiKey: ""))

        XCTAssertNil(try BlackForestLabsImageService.readyImageURL(Data(#"{"status":"Pending"}"#.utf8)))
        let ready = Data(#"{"status":"Ready","result":{"sample":"https://delivery.bfl.ai/img.jpeg?sig=1"}}"#.utf8)
        XCTAssertEqual(try BlackForestLabsImageService.readyImageURL(ready)?.host, "delivery.bfl.ai")
        let insecure = Data(#"{"status":"Ready","result":{"sample":"http://example.com/a.jpeg"}}"#.utf8)
        XCTAssertThrowsError(try BlackForestLabsImageService.readyImageURL(insecure))
        XCTAssertThrowsError(try BlackForestLabsImageService.readyImageURL(Data(#"{"status":"Content Moderated"}"#.utf8)))
    }

    func testChatGPTAuthorizationURLFollowsTheOfficialFlow() throws {
        let first = ChatGPTPlanAuth.authorizationURL(clientID: nil, hostID: "urn:uuid:abc", redirectURI: "http://127.0.0.1:5000/callback",
                                                     state: "s", nonce: "n", codeChallenge: "c")
        XCTAssertEqual(first.host, "auth.openai.com")
        XCTAssertEqual(first.path, "/api/accounts/authorize")
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], "dynamic_agent_client")
        XCTAssertEqual(items["agent_name_hint"], "AIM AI")
        XCTAssertEqual(items["ext_agent_host_id"], "urn:uuid:abc")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:5000/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["resource"], "https://api.openai.com/v1")
        XCTAssertTrue(items["scope"]?.split(separator: " ").contains("chatgpt.tokens.use.direct") == true)
        XCTAssertEqual(items["state"], "s"); XCTAssertEqual(items["nonce"], "n")

        let again = ChatGPTPlanAuth.authorizationURL(clientID: "issued", hostID: "urn:uuid:abc", redirectURI: "r", state: "s", nonce: "n", codeChallenge: "c")
        let againItems = try XCTUnwrap(URLComponents(url: again, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(againItems.first { $0.name == "client_id" }?.value, "issued")
        XCTAssertNil(againItems.first { $0.name == "agent_name_hint" })
    }

    func testChatGPTTokenExchangeAndPlanScope() throws {
        let exchange = ChatGPTPlanAuth.exchangeRequest(code: "a+b", clientID: "client", verifier: "v", redirectURI: "http://127.0.0.1:1/callback")
        XCTAssertEqual(exchange.url, ChatGPTPlanAuth.tokenURL)
        let form = String(decoding: try XCTUnwrap(exchange.httpBody), as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=authorization_code"))
        XCTAssertTrue(form.contains("code=a%2Bb"))
        XCTAssertTrue(form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback"))

        let issuer = try ChatGPTTestIssuer()
        let session = try issuer.session()
        XCTAssertEqual(session.accessToken, "synthetic-access")
        XCTAssertEqual(session.expiresAt, issuer.now.addingTimeInterval(3600))
        XCTAssertTrue(session.canUsePlan)
        XCTAssertNotNil(ChatGPTPlanAuth.refreshRequest(session))
        let withoutPlan = try issuer.session(["scope": "openid profile email"])
        XCTAssertFalse(withoutPlan.canUsePlan)
    }

    func testChatGPTRequestsRespectThePlanConstraints() throws {
        let request = try ProviderChatService.request(provider: .chatgpt, modelID: "gpt-5.5", messages: [message], apiKey: "token", mode: .agent,
                                                      openAIReasoningEffort: .medium)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNotNil(body["instructions"])
        XCTAssertNil(body["temperature"]); XCTAssertNil(body["max_output_tokens"]); XCTAssertNil(body["tools"])
        XCTAssertFalse((body["input"] as? [[String: Any]] ?? []).contains { $0["role"] as? String == "system" })
    }

    func testChatGPTPlanLimitAndStreamedToolResponse() throws {
        XCTAssertTrue(ChatGPTPlanAuth.isPlanLimit(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#))
        XCTAssertFalse(ChatGPTPlanAuth.isPlanLimit(#"{"error":{"code":"rate_limit_exceeded"}}"#))
        let limited = Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n".utf8)
        XCTAssertThrowsError(try ProviderToolConversation.completedResponse(fromStream: limited)) {
            guard case .planLimitReached = $0 as? ChatServiceError else { return XCTFail("\($0)") }
        }
        let stream = Data("""
        event: response.created
        data: {"type":"response.created","response":{"id":"r1","status":"in_progress"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[]}}

        """.utf8)
        let response = try JSONSerialization.jsonObject(with: ProviderToolConversation.completedResponse(fromStream: stream)) as? [String: Any]
        XCTAssertEqual(response?["status"] as? String, "completed")
        let plain = Data(#"{"error":{"message":"bad"}}"#.utf8)
        XCTAssertEqual(try ProviderToolConversation.completedResponse(fromStream: plain), plain)
    }
}
