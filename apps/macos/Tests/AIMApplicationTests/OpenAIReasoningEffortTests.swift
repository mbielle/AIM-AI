import AIMApplication
import XCTest

final class OpenAIReasoningEffortTests: XCTestCase {
    func testTextRequestIncludesOnlyExplicitOpenAIEffort() throws {
        let standard = try ProviderChatService.request(provider: .openAI, modelID: "gpt-fixture", messages: [], apiKey: "fixture", mode: .chat)
        XCTAssertNil(try body(standard)["reasoning"])
        for effort in OpenAIReasoningEffort.allCases {
            let request = try ProviderChatService.request(provider: .openAI, modelID: "gpt-fixture", messages: [], apiKey: "fixture", mode: .chat, openAIReasoningEffort: effort)
            XCTAssertEqual((try body(request)["reasoning"] as? [String: String])?["effort"], effort.rawValue)
            XCTAssertEqual(try body(request)["store"] as? Bool, false)
        }
        let xai = try ProviderChatService.request(provider: .xAI, modelID: "grok-fixture", messages: [], apiKey: "fixture", mode: .chat)
        XCTAssertNil(try body(xai)["reasoning"])
        let xaiHigh = try ProviderChatService.request(provider: .xAI, modelID: "grok-3-mini", messages: [], apiKey: "fixture", mode: .chat, openAIReasoningEffort: .xhigh)
        XCTAssertEqual((try body(xaiHigh)["reasoning"] as? [String: String])?["effort"], "high", "xAI only knows low and high")
        XCTAssertThrowsError(try ProviderChatService.request(provider: .google, modelID: "gemini-fixture", messages: [], apiKey: "fixture", mode: .chat, openAIReasoningEffort: .high))
    }

    func testAnthropicEffortBecomesAThinkingBudget() throws {
        // Messages requires the model's published capacity; AIM never invents one.
        XCTAssertThrowsError(try ProviderChatService.request(provider: .anthropic, modelID: "claude-sonnet-4-5", messages: [], apiKey: "fixture", mode: .chat))
        let plain = try body(ProviderChatService.request(provider: .anthropic, modelID: "claude-sonnet-4-5", messages: [], apiKey: "fixture", mode: .chat, catalogMaximumOutputTokens: 64_000))
        XCTAssertNil(plain["thinking"])
        XCTAssertEqual(plain["max_tokens"] as? Int, 64_000)
        let medium = try body(ProviderChatService.request(provider: .anthropic, modelID: "claude-sonnet-4-5", messages: [], apiKey: "fixture", mode: .chat, openAIReasoningEffort: .medium, catalogMaximumOutputTokens: 64_000))
        XCTAssertEqual((medium["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 8_192)
        let off = try body(ProviderChatService.request(provider: .anthropic, modelID: "claude-sonnet-4-5", messages: [], apiKey: "fixture", mode: .chat, openAIReasoningEffort: OpenAIReasoningEffort.none, catalogMaximumOutputTokens: 64_000))
        XCTAssertNil(off["thinking"])
        // Claude 4.6+ rejects budget_tokens: adaptive thinking, a visible summary and the effort level instead.
        let modern = try body(ProviderChatService.request(provider: .anthropic, modelID: "claude-sonnet-5-5", messages: [], apiKey: "fixture", mode: .chat, openAIReasoningEffort: .high, catalogMaximumOutputTokens: 128_000))
        XCTAssertEqual(modern["thinking"] as? [String: String], ["type": "adaptive", "display": "summarized"])
        XCTAssertEqual((modern["output_config"] as? [String: String])?["effort"], "high")
        let openAI = try body(ProviderChatService.request(provider: .openAI, modelID: "gpt-6-sol", messages: [], apiKey: "fixture", mode: .chat, openAIReasoningEffort: .high))
        XCTAssertEqual(openAI["reasoning"] as? [String: String], ["effort": "high", "summary": "auto"])
        XCTAssertTrue(OpenAIReasoningEffort.offered(provider: .anthropic, modelID: "claude-opus-4-5"))
        XCTAssertTrue(OpenAIReasoningEffort.offered(provider: .anthropic, modelID: "claude-3-7-sonnet-latest"))
        XCTAssertFalse(OpenAIReasoningEffort.offered(provider: .anthropic, modelID: "claude-3-5-haiku-latest"))
        XCTAssertTrue(OpenAIReasoningEffort.offered(provider: .xAI, modelID: "grok-3-mini"))
        XCTAssertFalse(OpenAIReasoningEffort.offered(provider: .xAI, modelID: "grok-4"))
    }

    func testSettingsRemainBackwardCompatible() throws {
        let oldSettings = try JSONEncoder().encode(AppSettings())
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: oldSettings).openAIReasoningEffortByModel)
        var settings = AppSettings()
        settings.openAIReasoningEffortByModel = ["gpt-fixture": .xhigh]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}
