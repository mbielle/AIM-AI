import Foundation
import XCTest
@testable import AIMCore

/// Wire fixtures follow the linked official APIs in web-search-validation-20261007.md.
/// These tests never contact a provider or submit a paid inference request.
final class NativeWebSearchTests: XCTestCase {
    private let providers: [(ChatProvider, String)] = [(.openRouter, "openai/gpt-4.1"), (.openAI, "gpt-4.1"),
        (.anthropic, "claude-sonnet-4-6"), (.xAI, "grok-4.7"), (.perplexity, "openai/gpt-5.6-sol")]
    private func body(_ provider: ChatProvider, _ model: String, webSearch: Bool = true, output: Int = 8192) throws -> [String: Any] {
        let request = try NativeChatTransport.request(provider: provider, modelID: model,
            messages: [.init(role: .user, text: "Search the latest news")], key: "fixture-key",
            instructions: "Be concise", maxOutputTokens: output, webSearch: webSearch)
        XCTAssertEqual(request.url?.host, provider.host)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func encoded(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func response(_ provider: ChatProvider, calls: [[String: Any]] = [], usage: [String: Any] = [:], citations: [[String: Any]] = []) throws -> String {
        try encoded(["type": "response.completed", "response": ["object": "response", "status": "completed", "output": calls + [
            ["type": "message", "status": "completed", "role": "assistant", "content": [
                ["type": "output_text", "text": "A readable answer", "annotations": citations]]]], "usage": usage]])
    }
    func testSearchIsOptInAndKeepsProviderModelAndOutputLimit() throws {
        for (provider, model) in providers {
            let plain = try body(provider, model, webSearch: false, output: 2048)
            XCTAssertNil(plain["tools"])
            let search = try body(provider, model, output: 2048)
            XCTAssertEqual(search["model"] as? String, model)
            XCTAssertEqual((search["tools"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual((search[provider == .anthropic || provider == .openRouter ? "max_tokens" : "max_output_tokens"] as? Int), 2048)
        }
    }
    func testOnlyHostedSearchToolsAreEnabledAndExaCannotFallback() throws {
        let router = try XCTUnwrap((try body(.openRouter, "openai/gpt-4.1")["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(router["type"] as? String, "openrouter:web_search")
        let params = try XCTUnwrap(router["parameters"] as? [String: Any])
        XCTAssertEqual(params["engine"] as? String, "exa")
        XCTAssertNil(params["max_uses"])
        XCTAssertNil(params["max_results"])
        let claude = try XCTUnwrap((try body(.anthropic, "claude-sonnet-4-6")["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(claude["type"] as? String, "web_search_20250305")
        XCTAssertEqual(claude["name"] as? String, "web_search")
        XCTAssertNil(claude["max_uses"])
        let grok = try XCTUnwrap((try body(.xAI, "grok-4.7")["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(grok["enable_image_understanding"] as? Bool, false)
        XCTAssertEqual(grok["enable_image_search"] as? Bool, false)
        let perplexity = try XCTUnwrap((try body(.perplexity, "openai/gpt-5.6-sol")["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(perplexity["search_type"] as? String, "web")
    }
    func testUnsupportedProvidersAndModelsFailBeforeAnyNetworkRequest() throws {
        for (provider, model) in [(ChatProvider.google, "gemini-2.5-flash"), (.deepSeek, "deepseek-chat"),
            (.openAI, "gpt-4.1-nano"), (.openAI, "gpt-5-codex"), (.xAI, "grok-3"), (.perplexity, "sonar"), (.local, "model")] {
            XCTAssertFalse(NativeWebSearchRules.supports(provider: provider, modelID: model))
            XCTAssertThrowsError(try body(provider, model))
        }
        XCTAssertTrue(NativeWebSearchRules.supports(provider: .openAI, modelID: "gpt-4.1-2025-04-14"))
        XCTAssertTrue(NativeWebSearchRules.supports(provider: .anthropic, modelID: "claude-haiku-4-5-20251001"))
        XCTAssertFalse(NativeWebSearchRules.supports(provider: .openAI, modelID: "gpt-4.1-anything"))
        XCTAssertFalse(NativeWebSearchRules.supports(provider: .openRouter, modelID: "openai/gpt-4.1:online"))
        XCTAssertTrue(NativeWebSearchRules.costDescription(provider: .google, modelID: "gemini-2.5-flash").contains("grounding"))
    }
    func testSearchWithBudgetProtectionRequiresVerifiedMaximum() {
        XCTAssertThrowsError(try NativeWebSearchRules.requireBudgetCompatibility(enabled: true, budgetEnabled: true)) { error in
            XCTAssertEqual((error as? ChatServiceError)?.errorDescription, ChatServiceError.webSearchBudgetUnavailable.errorDescription)
        }
        XCTAssertNoThrow(try NativeWebSearchRules.requireBudgetCompatibility(enabled: true, budgetEnabled: false))
        XCTAssertNoThrow(try NativeWebSearchRules.requireBudgetCompatibility(enabled: false, budgetEnabled: true))
    }
    func testOpenAIResponseCitationsAreReadablePersistableAndDeduplicated() throws {
        var decoder = NativeWebSearchDecoder()
        XCTAssertEqual(try decoder.decode(#"{"type":"response.output_text.delta","delta":"A readable answer"}"#, provider: .openAI).text, "A readable answer")
        let annotation: [String: Any] = ["type": "url_citation", "title": "Official [news]", "url": "https://example.com/news"]
        _ = try decoder.decode(try encoded(["type": "response.output_text.annotation.added", "annotation": annotation]), provider: .openAI)
        let completed = try response(.openAI, calls: [["type": "web_search_call", "status": "completed", "action": ["type": "search"]]], citations: [annotation])
        let tail = try decoder.decode(completed, provider: .openAI)
        XCTAssertTrue(tail.isComplete)
        XCTAssertEqual(tail.text, "")
        XCTAssertEqual(tail.sources?.first?.url, "https://example.com/news")
        XCTAssertEqual(tail.sources?.first?.references, [1])
        XCTAssertTrue(try decoder.decode(completed, provider: .openAI).text.isEmpty)
        XCTAssertThrowsError(try ProviderWireFormat.decode(completed, provider: .openAI))
    }
    func testFinalResponseWithoutDeltasRetainsAnswerInsteadOfOnlySources() throws {
        var decoder = NativeWebSearchDecoder()
        let result = try decoder.decode(response(.openAI, citations: [["type": "url_citation", "url": "https://example.com", "title": "Source"]]), provider: .openAI)
        XCTAssertEqual(result.text, "A readable answer")
        XCTAssertEqual(result.sources?.count, 1)
    }
    func testOpenRouterStreamingAnnotationsBecomeClickableSources() throws {
        var decoder = NativeWebSearchDecoder()
        let payload = #"{"choices":[{"delta":{"content":"A sourced answer","annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/router","title":"Router source","start_index":0,"end_index":15}}]}}]}"#
        XCTAssertEqual(try decoder.decode(payload, provider: .openRouter).text, "A sourced answer")
        XCTAssertEqual(try decoder.decode("[DONE]", provider: .openRouter).sources?.first?.url, "https://example.com/router")
    }
    func testAnthropicHostedSearchCitationsAndErrors() throws {
        var decoder = NativeWebSearchDecoder()
        _ = try decoder.decode(#"{"type":"content_block_start","content_block":{"type":"server_tool_use","name":"web_search","id":"srv_1"}}"#, provider: .anthropic)
        _ = try decoder.decode(#"{"type":"content_block_start","content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[{"type":"web_search_result","url":"https://example.com/claude","title":"Claude source"}]}}"#, provider: .anthropic)
        XCTAssertEqual(try decoder.decode(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"The answer"}}"#, provider: .anthropic).text, "The answer")
        _ = try decoder.decode(#"{"type":"content_block_delta","delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://example.com/claude","title":"Claude source"}}}"#, provider: .anthropic)
        XCTAssertEqual(try decoder.decode(#"{"type":"message_stop"}"#, provider: .anthropic).sources?.first?.url, "https://example.com/claude")
        var failed = NativeWebSearchDecoder()
        XCTAssertThrowsError(try failed.decode(#"{"type":"content_block_start","content_block":{"type":"web_search_tool_result","content":{"type":"web_search_tool_result_error","error_code":"unavailable"}}}"#, provider: .anthropic))
        XCTAssertThrowsError(try failed.decode(#"{"type":"message_delta","delta":{"stop_reason":"pause_turn"}}"#, provider: .anthropic))
    }
    func testDangerousToolsRemainRejectedInSearchMode() throws {
        for provider in [ChatProvider.openAI, .xAI, .perplexity] {
            for type in ["function_call", "computer_call", "code_interpreter_call", "mcp_call", "file_search_call"] {
                var decoder = NativeWebSearchDecoder()
                XCTAssertThrowsError(try decoder.decode(encoded(["type": "response.output_item.added", "item": ["type": type]]), provider: provider))
            }
        }
        for type in ["tool_use", "code_execution_tool_result", "web_fetch_tool_result"] {
            var decoder = NativeWebSearchDecoder()
            XCTAssertThrowsError(try decoder.decode(encoded(["type": "content_block_start", "content_block": ["type": type]]), provider: .anthropic))
        }
        var claude = NativeWebSearchDecoder()
        XCTAssertThrowsError(try claude.decode(#"{"type":"content_block_start","content_block":{"type":"server_tool_use","name":"code_execution"}}"#, provider: .anthropic))
        var router = NativeWebSearchDecoder()
        XCTAssertThrowsError(try router.decode(#"{"choices":[{"delta":{"tool_calls":[{"id":"danger"}]}}]}"#, provider: .openRouter))
    }
    func testMaliciousCitationURLsCannotBecomeMarkdownActions() throws {
        for url in ["javascript:alert(1)", "https://user:secret@example.com", "https://example.com/a)b", "https://example.com/a\nInjected", "https://example.com/\\escape"] {
            var decoder = NativeWebSearchDecoder()
            let annotation: [String: Any] = ["type": "url_citation", "url": url, "title": "source"]
            XCTAssertThrowsError(try decoder.decode(encoded(["type": "response.output_text.annotation.added", "annotation": annotation]), provider: .openAI))
        }
    }
    func testKnownSearchUsageAddsFeesAndUnknownNeverBecomesZero() throws {
        let fixtures: [(ChatProvider, String, Int, Double)] = [
            (.anthropic, #"{"type":"message_delta","usage":{"output_tokens":250,"server_tool_use":{"web_search_requests":1}}}"#, 1, 0.01),
            (.perplexity, try response(.perplexity, usage: ["tool_calls_details": ["search_web": ["invocation": 2]]]), 2, 0.005),
            (.xAI, try response(.xAI, usage: ["server_side_tool_usage_details": ["web_search_calls": 3]]), 3, 0.015)]
        let pricing = ChatModel.Pricing(prompt: "0.000002", completion: "0.000006")
        for (provider, fixture, count, fee) in fixtures {
            let usage = try XCTUnwrap(NativeWebSearchRules.usage(fixture, provider: provider))
            XCTAssertEqual(usage.requests, count)
            XCTAssertEqual(try XCTUnwrap(usage.additionalCostUSD), fee, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(ChatCostRules.estimateUSD(usage: .init(inputTokens: 1_000_000, outputTokens: 1_000_000), pricing: pricing, webSearch: usage)), 8 + fee, accuracy: 0.000001)
        }
        XCTAssertNil(ChatCostRules.estimateUSD(usage: .init(inputTokens: 100, outputTokens: 100), pricing: pricing, webSearch: .init()))
        XCTAssertNil(NativeWebSearchRules.usage(#"{"usage":{"server_tool_use":{"web_search_requests":true}}}"#, provider: .openRouter)?.requests)
        XCTAssertNil(NativeWebSearchRules.usage(#"{"usage":{"server_tool_use":{"web_search_requests":-1}}}"#, provider: .openRouter)?.requests)
        XCTAssertNil(NativeWebSearchRules.usage(try response(.xAI, calls: [["type": "web_search_call"]]), provider: .xAI)?.additionalCostUSD)
        XCTAssertNil(NativeWebSearchRules.usage(try response(.perplexity), provider: .perplexity)?.additionalCostUSD)
        let openAI = try XCTUnwrap(NativeWebSearchRules.usage(response(.openAI, calls: [
            ["type": "web_search_call", "action": ["type": "search"]], ["type": "web_search_call", "action": ["type": "open_page"]]]), provider: .openAI))
        XCTAssertEqual(openAI.requests, 1)
        XCTAssertNil(openAI.additionalCostUSD, "Search-content billing cannot be silently omitted from a total")
    }
    func testZeroSearchCountMustBeExplicitAndUsageMergesCumulativeCounts() throws {
        let zero = try XCTUnwrap(NativeWebSearchRules.usage(#"{"usage":{"server_tool_use":{"web_search_requests":0}}}"#, provider: .openRouter))
        XCTAssertEqual(zero.additionalCostUSD, 0)
        var merged = NativeWebSearchUsage()
        merged.merge(.init(requests: 1, additionalCostUSD: 0.005)); merged.merge(.init())
        merged.merge(.init(requests: 3, additionalCostUSD: 0.015))
        XCTAssertEqual(merged, .init(requests: 3, additionalCostUSD: 0.015))
    }
    func testPerplexitySearchSourcesAndUsageKeepOfficialResponseShape() throws {
        var decoder = NativeWebSearchDecoder()
        _ = try decoder.decode(#"{"type":"response.output_text.delta","delta":"The answer [1]"}"#, provider: .perplexity)
        let payload = try response(.perplexity, calls: [["type": "search_results", "results": [
            ["id": 1, "url": "https://example.com/perplexity", "title": "Perplexity source", "snippet": "Source text"]]]],
                                  usage: ["input_tokens": 1200, "output_tokens": 300, "tool_calls_details": ["search_web": ["invocation": 1]]])
        let tail = try decoder.decode(payload, provider: .perplexity)
        XCTAssertTrue(tail.isComplete)
        XCTAssertEqual(tail.sources?.first?.url, "https://example.com/perplexity")
        XCTAssertEqual(tail.sources?.first?.references, [1])
        XCTAssertEqual(TokenUsageParser.parse(payload)?.inputTokens, 1200)
        XCTAssertEqual(NativeWebSearchRules.usage(payload, provider: .perplexity)?.additionalCostUSD, 0.0025)
    }
}
