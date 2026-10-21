import AIMApplication
import XCTest

final class AnthropicOutputSettingsTests: XCTestCase {
    func testExplicitValueReachesRequestWithoutClamping() throws {
        for tokens in [1, 32_768, 200_000] {
            let request = try ProviderChatService.request(provider: .anthropic, modelID: "fixture", messages: [], apiKey: "fixture", mode: .chat, anthropicOutputTokens: tokens)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["max_tokens"] as? Int, tokens)
        }
        for tokens in [0, -1] {
            XCTAssertThrowsError(try ProviderChatService.request(provider: .anthropic, modelID: "fixture", messages: [], apiKey: "fixture", mode: .chat, anthropicOutputTokens: tokens))
        }
    }

    func testSettingsAreOptionalAndPreserveModelIdentity() throws {
        let old = try JSONEncoder().encode(AppSettings())
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: old).anthropicOutputTokensByModel)
        var settings = AppSettings()
        settings.anthropicOutputTokensByModel = ["model-a": 32_768, "model-b": 16_384]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
