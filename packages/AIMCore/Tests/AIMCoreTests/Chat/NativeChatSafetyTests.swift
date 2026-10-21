import Foundation
import XCTest
@testable import AIMCore

final class NativeChatSafetyTests: XCTestCase {
    func testRequestsFixProviderAndModelAndNeverEnableTools() throws {
        for provider in ChatProvider.allCases where provider != .local && provider != .chatgpt {
            let request = try NativeChatTransport.request(provider: provider, modelID: "fixture-model", messages: [.init(role: .user, text: "hello")], key: "fixture-key", catalogMaximum: 64000)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-key"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNil(body["tools"])
            XCTAssertNil(body["tool_choice"])
            if provider != .google { XCTAssertEqual(body["model"] as? String, "fixture-model") }
        }
        for provider in [ChatProvider.local, .chatgpt] {
            XCTAssertThrowsError(try NativeChatTransport.request(provider: provider, modelID: "model", messages: [], key: "key"))
        }
        for id in ["../unsafe", "model?key=unsafe", "model\nunsafe"] {
            XCTAssertThrowsError(try NativeChatTransport.request(provider: .openAI, modelID: id, messages: [], key: "key"))
        }
    }
    func testProviderSpecificHeadersAndInstructions() throws {
        let request = try NativeChatTransport.request(provider: .anthropic, modelID: "claude-fixture", messages: [.init(role: .user, text: "hello")], key: "fixture-key", instructions: "concise", catalogMaximum: 64000)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "concise")
        XCTAssertThrowsError(try NativeChatTransport.request(provider: .openAI, modelID: "model", messages: [], key: "key\nInjected: header"))
    }
    func testToolsAndIncompleteResponsesAreNeverNormalChatAnswers() throws {
        XCTAssertThrowsError(try ProviderWireFormat.decode(#"{"choices":[{"delta":{"tool_calls":[{"id":"tool"}]}}]}"#, provider: .openRouter))
        XCTAssertThrowsError(try ProviderWireFormat.decode(#"{"type":"response.output_item.added","item":{"type":"function_call"}}"#, provider: .openAI))
        XCTAssertThrowsError(try ProviderWireFormat.decode(#"{"type":"response.incomplete","response":{"status":"incomplete"}}"#, provider: .openAI))
        let delta = try ProviderWireFormat.decode(#"{"type":"response.output_text.delta","delta":"Readable"}"#, provider: .openAI)
        XCTAssertEqual(delta.text, "Readable"); XCTAssertFalse(delta.isComplete)
        XCTAssertTrue(try ProviderWireFormat.decode("[DONE]", provider: .openRouter).isComplete)
    }
    func testPKCERejectsForeignAmbiguousAndExpiredCallbacks() throws {
        let now = Date(timeIntervalSince1970: 100)
        let flow = try OpenRouterPKCE(callbackURL: URL(string: "https://aim-ai.tech/auth/openrouter/ios")!, now: now)
        XCTAssertEqual(flow.verifier.count, 64)
        let auth = try XCTUnwrap(URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(auth.queryItems?.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(flow.authorizationURL.absoluteString.contains(flow.verifier))
        for callback in ["https://foreign.example/auth/openrouter/ios?code=a", "https://aim-ai.tech/other?code=a", "https://aim-ai.tech/auth/openrouter/ios?code=a&code=b", "https://aim-ai.tech/auth/openrouter/ios?error=denied&code=a"] {
            XCTAssertThrowsError(try flow.exchangeRequest(callback: URL(string: callback)!, now: now))
        }
        let callback = URL(string: "https://aim-ai.tech/auth/openrouter/ios?code=fixture")!
        XCTAssertThrowsError(try flow.exchangeRequest(callback: callback, now: now.addingTimeInterval(301)))
        let request = try flow.exchangeRequest(callback: callback, now: now)
        XCTAssertEqual(request.url?.host, "openrouter.ai")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["code_verifier"], flow.verifier)
    }
    func testMergeKeepsPartialHistoryAndCountsCompletedTurnOnce() {
        let message = NativeChatMessage(role: .assistant, text: "Partial")
        let turn = NativeChatTurn(id: message.id)
        let a = NativeChatConversation(title: "Title", provider: .openRouter, modelID: "model", messages: [message], turns: [turn])
        var b = a; b.messages[0].text += " answer"; b.turns[0].completedAt = .now; b.updatedAt = a.updatedAt.addingTimeInterval(1)
        let merged = a.merging(b).merging(b)
        XCTAssertEqual(merged.messages.count, 1); XCTAssertEqual(merged.turns.count, 1)
        XCTAssertEqual(merged.messages[0].text, "Partial answer"); XCTAssertNotNil(merged.turns[0].completedAt)
        XCTAssertEqual(a.merging(b), b.merging(a))
    }
    func testCostsRequireActualCountsAndNeverFabricateChatGPTAllowance() throws {
        let pricing = try JSONDecoder().decode(ChatModel.Pricing.self, from: Data(#"{"prompt":"0.000002","completion":"0.000006"}"#.utf8))
        XCTAssertNil(ChatCostRules.estimateUSD(usage: .init(inputTokens: 100), pricing: pricing))
        XCTAssertEqual(try XCTUnwrap(ChatCostRules.estimateUSD(usage: .init(inputTokens: 1_000_000, outputTokens: 1_000_000), pricing: pricing)), 8, accuracy: 0.00001)
        var integration = ChatGPTIntegration(accountConnected: true, planAccess: .granted)
        XCTAssertFalse(integration.mayUsePlan); integration.integrationApproved = true; XCTAssertTrue(integration.mayUsePlan)
        // Supplier cost budgets remain independent of AIM commercial access.
    }
}
