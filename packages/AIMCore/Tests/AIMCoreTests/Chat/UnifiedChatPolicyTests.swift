import Foundation
import XCTest
@testable import AIMCore

final class UnifiedChatPolicyTests: XCTestCase {
    func testEffortDoesNotSelectTheFirstProviderForAnAmbiguousModel() {
        let capabilities = RemoteCapabilities(models: [
            .init(id: "shared", name: "Direct", provider: "anthropic", effortLevels: ["low"], currentEffort: "low"),
            .init(id: "shared", name: "Routed", provider: "openrouter", effortLevels: ["high"], currentEffort: "high"),
        ], features: ["effort": true])
        XCTAssertNil(RemoteEffortRules.effort(capabilities: capabilities, modelID: "shared").currentValue)
        XCTAssertEqual(RemoteEffortRules.effort(capabilities: capabilities, modelID: "shared", provider: "openrouter").currentValue, "high")
        let request = RemoteSessionCreationRequest(machineID: "mac", mode: .chat, modelID: "shared", text: "Hello", provider: "openrouter")
        XCTAssertEqual(request.provider, "openrouter")
    }
    func testIdentityIsAccountScopedUUIDBasedAndNotTitleBased() {
        let id = UUID()
        XCTAssertEqual(AccountConversationIdentity(accountID: "one", conversationID: id.uuidString),
                       AccountConversationIdentity(accountID: "one", conversationID: id.uuidString.lowercased()))
        XCTAssertNotEqual(AccountConversationIdentity(accountID: "one", conversationID: id.uuidString),
                          AccountConversationIdentity(accountID: "two", conversationID: id.uuidString))
        XCTAssertFalse(AccountConversationIdentity.matches(UUID().uuidString, UUID().uuidString))
        // Opaque non-UUID identifiers stay exact rather than merging by accident.
        XCTAssertFalse(AccountConversationIdentity.matches("Opaque", "opaque"))
    }
    func testAutomaticOutputOmitsOptionalLimitAndUsesRequiredPublishedCapacity() throws {
        for provider in [ChatProvider.openRouter, .openAI, .google, .deepSeek] {
            let request = try NativeChatTransport.request(provider: provider, modelID: "fixture", messages: [], key: "fixture")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNil(body["max_tokens"]); XCTAssertNil(body["max_output_tokens"])
            XCTAssertNil(body["generationConfig"])
        }
        let request = try NativeChatTransport.request(provider: .anthropic, modelID: "claude-fixture", messages: [], key: "fixture", catalogMaximum: 128_000)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 128_000)
        XCTAssertThrowsError(try NativeChatTransport.request(provider: .anthropic, modelID: "claude-fixture", messages: [], key: "fixture"))
    }
    func testCustomOutputCanExceedFormerAIMCapsButNotPublishedCapacity() throws {
        XCTAssertEqual(try ModelOutputPolicy.resolve(provider: .openRouter, modelID: "fixture", userLimit: 64_000), 64_000)
        XCTAssertThrowsError(try ModelOutputPolicy.resolve(provider: .anthropic, modelID: "fixture", catalogMaximum: 64_000, userLimit: 65_000))
        XCTAssertThrowsError(try ModelOutputPolicy.resolve(provider: .anthropic, modelID: "fixture", catalogMaximum: 64_000, userLimit: 0))
    }
    func testUnsetWebPreferenceUsesSearchAndExplicitOffSurvivesCoding() throws {
        XCTAssertTrue(AccountChatPreferences().usesAutomaticWebSearch)
        var preferences = AccountChatPreferences(); preferences.automaticWebSearch = false
        XCTAssertFalse(try JSONDecoder().decode(AccountChatPreferences.self, from: JSONEncoder().encode(preferences)).usesAutomaticWebSearch)
    }
    func testLibraryMetadataAndSearchUsageSurviveReopening() throws {
        let old = Data(#"{"id":"model","name":"Model","provider":"openrouter"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteModelAnnouncement.self, from: old).isAdded)
        let model = RemoteModelAnnouncement(id: "model", name: "Model", provider: "openrouter", isAdded: true, isPinned: true, detail: ChatModel(id: "model", name: "Model", contextLength: 200_000, maxOutputTokens: 64_000), isReferencePricing: true)
        XCTAssertEqual(try JSONDecoder().decode(RemoteModelAnnouncement.self, from: JSONEncoder().encode(model)), model)
        let message = NativeChatMessage(role: .assistant, text: "Answer [source](https://example.com)", webSearchUsage: .init(requests: 7, additionalCostUSD: nil))
        XCTAssertEqual(try JSONDecoder().decode(NativeChatMessage.self, from: JSONEncoder().encode(message)), message)
    }
    func testOnlyProviderEventsCreateSearchActivities() {
        XCTAssertTrue(NativeWebSearchRules.activities(#"{"choices":[{"delta":{"content":"I searched online"}}]}"#, provider: .openRouter).isEmpty)
        let started = NativeWebSearchRules.activities(#"{"type":"content_block_start","content_block":{"type":"server_tool_use","name":"web_search","id":"tool-1"}}"#, provider: .anthropic)
        XCTAssertEqual(started, [.init(id: "tool-1", status: .running)])
        let failed = NativeWebSearchRules.activities(#"{"type":"content_block_start","content_block":{"type":"web_search_tool_result","tool_use_id":"tool-1","content":{"type":"web_search_tool_result_error"}}}"#, provider: .anthropic)
        XCTAssertEqual(failed.map(\.id), ["tool-1"])
        XCTAssertEqual(failed.map(\.status), [.failed])
        XCTAssertTrue(failed.first?.output?.contains("web_search_tool_result_error") == true)
    }
    func testManySearchSourcesRemainReadableWithoutProductQuota() throws {
        var decoder = NativeWebSearchDecoder()
        for index in 0..<125 {
            let payload: [String: Any] = ["choices": [["delta": ["annotations": [["type": "url_citation", "url_citation": ["url": "https://example.com/\(index)", "title": "Source \(index)"]]]]]]]
            _ = try decoder.decode(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self), provider: .openRouter)
        }
        _ = try decoder.decode(#"{"choices":[{"delta":{"content":"Answer with sources"}}]}"#, provider: .openRouter)
        let final = try decoder.decode("[DONE]", provider: .openRouter)
        let sources = try XCTUnwrap(final.sources)
        XCTAssertEqual(sources.count, 125)
        XCTAssertTrue(sources.contains { $0.url == "https://example.com/124" })
    }
}
