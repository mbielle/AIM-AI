import Foundation
import XCTest
@testable import AIMCore

final class NativeWebAccountingTests: XCTestCase {
    func testOpenRouterReportsWholeAccountChargeWithoutInventingAnExtraSearchFee() throws {
        let usage = try XCTUnwrap(NativeWebSearchRules.usage(#"{"usage":{"cost":0.077,"cost_details":{"upstream_inference_cost":0.03},"server_tool_use":{"web_search_requests":2}}}"#, provider: .openRouter))
        XCTAssertEqual(usage.providerTotalCostUSD, 0.077)
        XCTAssertEqual(usage.requests, 2)
        XCTAssertNil(usage.additionalCostUSD)
        let totalOnly = try XCTUnwrap(NativeWebSearchRules.usage(#"{"usage":{"cost":0.019}}"#, provider: .openRouter))
        XCTAssertEqual(totalOnly.providerTotalCostUSD, 0.019)
        XCTAssertNil(totalOnly.requests); XCTAssertNil(totalOnly.additionalCostUSD)
    }

    func testMissingAccountChargeNeverFallsBackToUpstreamCostOrAFixedExaRate() throws {
        let usage = try XCTUnwrap(NativeWebSearchRules.usage(#"{"usage":{"cost_details":{"upstream_inference_cost":9},"server_tool_use":{"web_search_requests":3}}}"#, provider: .openRouter))
        XCTAssertEqual(usage.requests, 3)
        XCTAssertNil(usage.providerTotalCostUSD); XCTAssertNil(usage.additionalCostUSD)
        XCTAssertNil(NativeWebSearchRules.usage(#"{"usage":{}}"#, provider: .openRouter)?.providerTotalCostUSD)
        XCTAssertNil(NativeWebSearchRules.usage(#"{"choices":[]}"#, provider: .openRouter))
    }

    func testInvalidCostAndCounterValuesCannotBecomeBilledDollarsOrFreeSearches() {
        for invalid in ["true", "false", "-0.01", "null", "\"0.01\"", "1e9999"] {
            let payload = "{\"usage\":{\"cost\":\(invalid),\"server_tool_use\":{\"web_search_requests\":2}}}"
            let usage = NativeWebSearchRules.usage(payload, provider: .openRouter)
            XCTAssertNil(usage?.providerTotalCostUSD, invalid)
            XCTAssertNil(usage?.additionalCostUSD, invalid)
        }
        for count in ["true", "-1", "1.5", "1000001"] {
            let payload = "{\"usage\":{\"server_tool_use\":{\"web_search_requests\":\(count)}}}"
            XCTAssertNil(NativeWebSearchRules.usage(payload, provider: .openRouter)?.requests)
            XCTAssertNil(NativeWebSearchRules.usage(payload, provider: .openRouter)?.additionalCostUSD)
        }
    }

    func testOnlyExplicitZeroIsAReportedZeroChargeOrNoSearch() throws {
        let total = try XCTUnwrap(NativeWebSearchRules.usage(#"{"usage":{"cost":0}}"#, provider: .openRouter))
        XCTAssertEqual(total.providerTotalCostUSD, 0)
        XCTAssertNil(total.requests); XCTAssertNil(total.additionalCostUSD)
        let noSearch = try XCTUnwrap(NativeWebSearchRules.usage(#"{"usage":{"server_tool_use":{"web_search_requests":0}}}"#, provider: .openRouter))
        XCTAssertNil(noSearch.providerTotalCostUSD)
        XCTAssertEqual(noSearch.requests, 0); XCTAssertEqual(noSearch.additionalCostUSD, 0)
    }

    func testAnthropicUsesOfficialCounterInCompleteAndStreamingMessagesWithoutClaimingAnInvoice() throws {
        for payload in [
            #"{"type":"message","usage":{"cost":2,"server_tool_use":{"web_search_requests":2}}}"#,
            #"{"type":"message_start","message":{"usage":{"server_tool_use":{"web_search_requests":2}}}}"#,
            #"{"type":"message_delta","usage":{"output_tokens":250,"server_tool_use":{"web_search_requests":2}}}"#
        ] {
            let usage = try XCTUnwrap(NativeWebSearchRules.usage(payload, provider: .anthropic))
            XCTAssertEqual(usage.requests, 2); XCTAssertEqual(usage.additionalCostUSD, 0.02)
            XCTAssertNil(usage.providerTotalCostUSD)
        }
        let unknown = try XCTUnwrap(NativeWebSearchRules.usage(#"{"type":"message_delta","usage":{"output_tokens":250}}"#, provider: .anthropic))
        XCTAssertNil(unknown.requests); XCTAssertNil(unknown.additionalCostUSD)
    }

    func testProviderChargeCodableRemainsCompatibleWithSavedLegacyUsage() throws {
        let old = try JSONDecoder().decode(NativeWebSearchUsage.self, from: Data(#"{"requests":1,"additionalCostUSD":0.005}"#.utf8))
        XCTAssertNil(old.providerTotalCostUSD); XCTAssertEqual(old.additionalCostUSD, 0.005)
        let current = NativeWebSearchUsage(requests: 2, providerTotalCostUSD: 0.023)
        XCTAssertEqual(try JSONDecoder().decode(NativeWebSearchUsage.self, from: JSONEncoder().encode(current)), current)
    }

    func testCumulativeEventsMergeOnceButDistinctRequestsAddExactlyOnce() {
        var sameRequest = NativeWebSearchUsage()
        sameRequest.merge(.init(requests: 1, providerTotalCostUSD: 0.01))
        sameRequest.merge(.init(requests: 1, providerTotalCostUSD: 0.01))
        sameRequest.merge(.init())
        XCTAssertEqual(sameRequest, .init(requests: 1, providerTotalCostUSD: 0.01))
        var rounds = NativeWebSearchUsageAccumulator()
        rounds.append(sameRequest)
        rounds.append(.init(requests: 2, providerTotalCostUSD: 0.02))
        XCTAssertEqual(rounds.usage.requests, 3)
        XCTAssertEqual(rounds.usage.providerTotalCostUSD ?? -1, 0.03, accuracy: 0.0000001)
        XCTAssertNil(rounds.usage.additionalCostUSD)
    }

    func testMissingRoundCannotBecomeAKnownPartialTotalRegardlessOfOrder() {
        for missingFirst in [true, false] {
            var rounds = NativeWebSearchUsageAccumulator()
            let known = NativeWebSearchUsage(requests: 1, additionalCostUSD: 0.01, providerTotalCostUSD: 0.02)
            var observed = NativeWebSearchUsage()
            rounds.append(missingFirst ? nil : known)
            observed.merge(rounds.usage)
            rounds.append(missingFirst ? known : nil)
            observed.merge(rounds.usage)
            XCTAssertEqual(observed.isRequestAggregate, true)
            XCTAssertNil(observed.providerTotalCostUSD, "Merging cannot retain a previous partial total as confirmed")
            XCTAssertNil(observed.additionalCostUSD)
            XCTAssertNil(rounds.usage.requests)
            XCTAssertNil(rounds.usage.additionalCostUSD); XCTAssertNil(rounds.usage.providerTotalCostUSD)
        }
        var mixed = NativeWebSearchUsageAccumulator()
        mixed.append(.init(requests: 1, additionalCostUSD: 0.01))
        mixed.append(.init(requests: 2, providerTotalCostUSD: 0.02))
        XCTAssertEqual(mixed.usage.requests, 3)
        XCTAssertNil(mixed.usage.additionalCostUSD); XCTAssertNil(mixed.usage.providerTotalCostUSD)
    }

    func testCostDescriptionsDoNotPromiseAHardcodedSearchRate() {
        for (provider, model) in [(ChatProvider.openRouter, "z-ai/glm-5.3"), (.anthropic, "claude-sonnet-4-6"),
                                  (.openAI, "gpt-4.1"), (.xAI, "grok-4.7"), (.perplexity, "openai/gpt-5.6-sol")] {
            XCTAssertFalse(NativeWebSearchRules.costDescription(provider: provider, modelID: model).contains("$"))
        }
    }
}
