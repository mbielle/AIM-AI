import AIMApplication
import XCTest

final class LocalModelSettingsTests: XCTestCase {
    func testPersonalValuesOverrideRecommendations() throws {
        var settings = LocalModelSettings()
        settings.temperature = 0.2
        settings.seed = 42
        settings.maxResponseTokens = 900
        settings.stopStrings = ["###"]
        settings.systemPrompt = "  Réponds en vers.  "
        let fields = settings.requestFields(modelID: "Qwen3-8B-4bit", thinking: false)
        XCTAssertEqual(fields["temperature"] as? Double, 0.2)
        XCTAssertEqual(fields["top_p"] as? Double, 0.8, "Unset values keep Qwen's recommendation")
        XCTAssertEqual(fields["seed"] as? Int, 42)
        XCTAssertEqual(fields["max_tokens"] as? Int, 900)
        XCTAssertEqual(fields["stop"] as? [String], ["###"])
        XCTAssertEqual(settings.customSystemPrompt, "Réponds en vers.")
        XCTAssertNil(LocalModelSettings().requestFields(modelID: "Qwen3-8B", thinking: false)["max_tokens"])
    }

    func testStoreKeepsOneEntryPerModel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalModelSettingsStore(url: url)
        var first = LocalModelSettings(); first.contextTokens = 32_768
        var second = LocalModelSettings(); second.contextTokens = 65_536
        store.save(first, for: "Qwen3-8B-4bit")
        store.save(second, for: "Qwen3-14B-4bit")
        let reloaded = LocalModelSettingsStore(url: url)
        XCTAssertEqual(reloaded.settings(for: "Qwen3-8B-4bit").contextTokens, 32_768)
        XCTAssertEqual(reloaded.settings(for: "Qwen3-14B-4bit").contextTokens, 65_536)
        store.save(LocalModelSettings(), for: "Qwen3-8B-4bit")
        XCTAssertTrue(LocalModelSettingsStore(url: url).settings(for: "Qwen3-8B-4bit").isDefault)
    }

    func testLocalPromptAsksForDepthNotBrevity() {
        let prompt = LocalModelTuning.systemPrompt(mode: .chat)
        XCTAssertFalse(prompt.contains("concise"))
        XCTAssertTrue(prompt.contains("complete, well-structured"))
    }

    func testLocalLengthLimitEndsTheAnswerNormally() throws {
        let payload = #"{"choices":[{"index":0,"delta":{"content":" fin"},"finish_reason":"length"}]}"#
        let chunk = try ProviderWireFormat.decode(payload, provider: .local)
        XCTAssertTrue(chunk.isComplete)
        XCTAssertEqual(chunk.text, " fin")
        XCTAssertThrowsError(try ProviderWireFormat.decode(payload, provider: .openRouter), "Online truncation is still reported")
    }
}
