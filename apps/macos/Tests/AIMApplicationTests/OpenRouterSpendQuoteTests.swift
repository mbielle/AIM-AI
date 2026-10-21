@testable import AIMApplication
import XCTest

final class OpenRouterSpendQuoteTests: XCTestCase {
    private func catalog(pricing: [String: String] = ["prompt": "0.001", "completion": "0.002", "request": "0"],
                         model: String = "fixture", parameters: [String] = ["max_tokens"]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": [["id": model, "pricing": pricing,
            "context_length": 1000, "supported_parameters": parameters,
            "top_provider": ["max_completion_tokens": 200]]]])
    }
    private func body(content: Any = "text", extra: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = ["model": "fixture", "messages": [["role": "user", "content": content]],
            "stream": true, "provider": ["allow_fallbacks": true], "tools": []]
        payload.merge(extra) { _, value in value }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    func testHostedWebToolRequiresExplicitEstimatedCoverageAndKeepsToolOnWire() throws {
        let quote = try OpenRouterSpendQuote.decode(catalog(), modelID: "fixture")
        let original = try body(extra: ["tools": [["type": "openrouter:web_search", "parameters": ["engine": "exa"]]]])
        XCTAssertThrowsError(try quote.bound(original, modelID: "fixture"))
        let estimated = try quote.bound(original, modelID: "fixture", allowEstimatedWebSearch: true)
        XCTAssertNotNil(estimated.maximumUSD)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: estimated.data) as? [String: Any])
        XCTAssertEqual((wire["tools"] as? [[String: Any]])?.first?["type"] as? String, "openrouter:web_search")
        XCTAssertThrowsError(try quote.bound(body(extra: ["tools": [["type": "openrouter:web_search", "parameters": ["engine": "auto"]]]]), modelID: "fixture", allowEstimatedWebSearch: true))
        XCTAssertThrowsError(try quote.bound(body(extra: ["tools": [["type": "unknown_hosted_tool"]]]), modelID: "fixture", allowEstimatedWebSearch: true))
    }

    func testBoundUsesFullContextAndReplacesUnboundedRouting() throws {
        let quote = try OpenRouterSpendQuote.decode(catalog(), modelID: "fixture")
        let bounded = try quote.bound(body(), modelID: "fixture")
        XCTAssertEqual(bounded.maximumUSD, "1.4")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bounded.data) as? [String: Any])
        XCTAssertEqual(payload["max_tokens"] as? Int, 200)
        let provider = try XCTUnwrap(payload["provider"] as? [String: Any])
        XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
        let prices = try XCTUnwrap(provider["max_price"] as? [String: NSNumber])
        XCTAssertEqual(prices["prompt"]?.decimalValue, 1000)
        XCTAssertEqual(prices["completion"]?.decimalValue, 2000)
        XCTAssertEqual((payload["stream_options"] as? [String: Bool])?["include_usage"], true)
    }

    func testMediaFeesVariablePricesAndWrongModelRefuseBeforeSend() throws {
        let quote = try OpenRouterSpendQuote.decode(catalog(), modelID: "fixture")
        XCTAssertThrowsError(try quote.bound(body(content: [["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]]]), modelID: "fixture"))
        XCTAssertThrowsError(try quote.bound(body(extra: ["plugins": [["id": "web"]]]), modelID: "fixture"))
        XCTAssertThrowsError(try OpenRouterSpendQuote.decode(catalog(pricing: ["prompt": "0.001", "completion": "0.002", "request": "0.2"]), modelID: "fixture"))
        XCTAssertThrowsError(try OpenRouterSpendQuote.decode(catalog(pricing: ["prompt": "-1", "completion": "0.002"]), modelID: "fixture"))
        XCTAssertThrowsError(try OpenRouterSpendQuote.decode(catalog(pricing: ["prompt": "0.001variable", "completion": "0.002"]), modelID: "fixture"))
        XCTAssertThrowsError(try OpenRouterSpendQuote.decode(catalog(), modelID: "different"))
        XCTAssertThrowsError(try OpenRouterSpendQuote.decode(catalog(parameters: []), modelID: "fixture"))
    }

    func testTextPartsAndExplicitLowerOutputKeepConservativeInputBound() throws {
        let quote = try OpenRouterSpendQuote.decode(catalog(), modelID: "fixture")
        let bounded = try quote.bound(body(content: [["type": "text", "text": "hi"]], extra: ["max_tokens": 50]), modelID: "fixture")
        XCTAssertEqual(bounded.maximumUSD, "1.1")
        XCTAssertThrowsError(try quote.bound(body(extra: ["max_tokens": 201]), modelID: "fixture"))
        // A cache write above the prompt price raises the input bound instead of refusing the request.
        XCTAssertEqual(try OpenRouterSpendQuote.decode(catalog(pricing: ["prompt": "0.001", "completion": "0.002", "input_cache_write": "0.00125"]), modelID: "fixture").inputUSD, Decimal(string: "0.00125"))
    }

    func testUnknownQuotePreservesOriginalMediaBodyAndLeavesAdmissionToLedger() async throws {
        let quote = try OpenRouterSpendQuote.decode(catalog(), modelID: "fixture")
        let original = try body(content: [["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]]])
        let prepared = try await OpenRouterSpendQuote.prepare(original, modelID: "fixture", quote: { quote })
        XCTAssertEqual(prepared.data, original)
        XCTAssertNil(prepared.maximumUSD)
        let unavailable = try await OpenRouterSpendQuote.prepare(original, modelID: "fixture", quote: { throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(unavailable.data, original)
        XCTAssertNil(unavailable.maximumUSD)
        do {
            _ = try await OpenRouterSpendQuote.prepare(original, modelID: "fixture", quote: { throw URLError(.cancelled) })
            XCTFail("Cancellation must never fall through to a model send")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
    }

    func testExplicitOutputAboveDefaultIsPreservedWhenWithinVerifiedLimit() throws {
        let quote = OpenRouterSpendQuote(inputUSD: Decimal(string: "0.000001")!, outputUSD: Decimal(string: "0.000002")!, contextTokens: 32000, outputTokens: 16000)
        let prepared = try quote.bound(body(extra: ["max_tokens": 8192]), modelID: "fixture")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.data) as? [String: Any])
        XCTAssertEqual(payload["max_tokens"] as? Int, 8192)
        XCTAssertEqual(prepared.maximumUSD, "0.01777")
    }

    private func assistantReplay() -> [String: Any] {
        ["role": "assistant", "model": "fixture-provider-model", "refusal": NSNull(), "annotations": [],
         "reasoning": NSNull(), "reasoning_details": [["type": "reasoning.encrypted", "data": "opaque-fixture"]],
         "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"README.md\"}"]]]]
    }

    func testAssistantReplayWithoutTextPreservesMetadataReasoningAndToolResults() throws {
        let quote = try OpenRouterSpendQuote.decode(catalog(), modelID: "fixture")
        // Primary response schema: OpenRouterTeam/typescript-sdk chatassistantmessage.ts.
        // Citation shape: https://openrouter.ai/docs/guides/features/plugins/web-search
        for absent in [false, true] {
            var assistant = assistantReplay()
            if !absent { assistant["content"] = NSNull() }
            assistant["refusal"] = "Fixture refusal metadata"
            assistant["annotations"] = [["type": "url_citation", "url_citation": [
                "url": "https://example.com/source", "title": "Fixture", "content": "Source excerpt", "start_index": 0, "end_index": 4]]]
            let messages: [[String: Any]] = [["role": "user", "content": "Inspect"], assistant,
                ["role": "tool", "tool_call_id": "call_1", "content": "Exact fixture result"]]
            let bounded = try quote.bound(body(extra: ["messages": messages]), modelID: "fixture")
            XCTAssertEqual(bounded.maximumUSD, "1.4", "Replay must retain the entire-context ceiling")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bounded.data) as? [String: Any])
            let replay = try XCTUnwrap(payload["messages"] as? [[String: Any]])
            var expected = assistant; expected["content"] = NSNull()
            XCTAssertEqual(replay[1] as NSDictionary, expected as NSDictionary)
            XCTAssertEqual(replay[2] as NSDictionary, messages[2] as NSDictionary)
        }
    }

    func testUnknownFieldsAndMediaCannotBecomeTextByReplayNormalization() async throws {
        let quote = try OpenRouterSpendQuote.decode(catalog(), modelID: "fixture")
        let extras: [[String: Any]] = [
            ["future_paid_input": "unknown"],
            ["audio": ["data": "opaque-audio"]], ["images": [["image_url": "https://example.com/image"]]],
            ["content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]]]],
            ["annotations": [["type": "image", "url": "https://example.com/image"]]],
            ["annotations": [["type": "url_citation", "url_citation": ["url": "https://example.com", "title": "x", "unknown_fee": 1]]]],
            ["refusal": ["type": "image"]], ["model": ["id": "other"]],
        ]
        for extra in extras {
            var assistant = assistantReplay(); assistant.merge(extra) { _, value in value }
            let original = try body(extra: ["messages": [assistant]])
            XCTAssertThrowsError(try quote.bound(original, modelID: "fixture")) { XCTAssertEqual($0 as? SpendAdmissionError, .unknownBound) }
            let prepared = try await OpenRouterSpendQuote.prepare(original, modelID: "fixture", quote: { quote })
            XCTAssertNil(prepared.maximumUSD)
            XCTAssertEqual(prepared.data, original, "Unknown replay data must not be silently stripped to obtain admission")
        }
    }

    func testOnlyStructuredAssistantCallsCanOmitContent() throws {
        let quote = try OpenRouterSpendQuote.decode(catalog(), modelID: "fixture")
        let invalid: [[String: Any]] = [
            ["role": "user"], ["role": "tool", "tool_call_id": "call_1"],
            ["role": "assistant"], ["role": "assistant", "tool_calls": []],
            ["role": "assistant", "tool_calls": [["type": "function", "function": ["name": "read_file", "arguments": "{}"]]]],
            ["role": "assistant", "tool_calls": [["id": "x", "type": "function", "function": ["name": "read_file", "arguments": [:]]]]],
            ["role": "user", "content": "text", "annotations": NSNull()],
        ]
        for message in invalid {
            XCTAssertThrowsError(try quote.bound(body(extra: ["messages": [message]]), modelID: "fixture")) {
                XCTAssertEqual($0 as? SpendAdmissionError, .unknownBound)
            }
        }
    }

    /// Excerpt of OpenRouter's public catalog on 2026-10-09 (Test 29 refused every request with these entries).
    private static let anthropicCatalog = #"{"data":[{"id":"anthropic/claude-haiku-5.5","pricing":{"prompt":"0.0000001","completion":"0.0000005","web_search":"0.01","input_cache_read":"0.00000001","input_cache_write":"0.000000125","input_cache_write_1h":"0.0000002","overrides":[{"min_prompt_tokens":100000,"prompt":"0.0000005","completion":"0.0000025","input_cache_read":"0.00000005","input_cache_write":"0.000000625","input_cache_write_1h":"0.000001"}]},"context_length":1000000,"supported_parameters":["include_reasoning","max_completion_tokens","max_tokens","reasoning","reasoning_effort","response_format","stop","structured_outputs","tool_choice","tools","verbosity"],"top_provider":{"context_length":1000000,"max_completion_tokens":128000,"is_moderated":true}},{"id":"anthropic/claude-sonnet-5.5","pricing":{"prompt":"0.000002","completion":"0.00001","web_search":"0.01","input_cache_read":"0.0000001","input_cache_write":"0.0000025","input_cache_write_1h":"0.000004"},"context_length":1000000,"supported_parameters":["include_reasoning","max_completion_tokens","max_tokens","reasoning","reasoning_effort","response_format","stop","structured_outputs","tool_choice","tools","verbosity"],"top_provider":{"context_length":1000000,"max_completion_tokens":128000,"is_moderated":true}}]}"#

    func testCurrentAnthropicEntriesAreBoundedWithTheirHighestInputPrice() throws {
        let data = Data(Self.anthropicCatalog.utf8)
        let sonnet = try OpenRouterSpendQuote.decode(data, modelID: "anthropic/claude-sonnet-5.5")
        // Writing the cache for an hour (0.000004) is the highest input price; web_search is never enabled.
        XCTAssertEqual(sonnet.inputUSD, Decimal(string: "0.000004"))
        XCTAssertEqual(sonnet.outputUSD, Decimal(string: "0.00001"))
        let haiku = try OpenRouterSpendQuote.decode(data, modelID: "anthropic/claude-haiku-5.5")
        // The long-prompt tier is more expensive: the bound takes the highest tier.
        XCTAssertEqual(haiku.inputUSD, Decimal(string: "0.000001"))
        XCTAssertEqual(haiku.outputUSD, Decimal(string: "0.0000025"))
        let bounded = try sonnet.bound(JSONSerialization.data(withJSONObject: ["model": "anthropic/claude-sonnet-5.5",
            "messages": [["role": "user", "content": "hi"]], "stream": true, "max_tokens": 64_000]), modelID: "anthropic/claude-sonnet-5.5")
        // Input bounded by the request size, not the 1M context: about $0.65 instead of $4.64.
        XCTAssertEqual(bounded.maximumUSD, "0.645584")
        // A web plugin would make the search fee apply: still refused before sending.
        XCTAssertThrowsError(try sonnet.bound(JSONSerialization.data(withJSONObject: ["model": "anthropic/claude-sonnet-5.5",
            "messages": [["role": "user", "content": "hi"]], "plugins": [["id": "web"]]]), modelID: "anthropic/claude-sonnet-5.5"))
    }
}
