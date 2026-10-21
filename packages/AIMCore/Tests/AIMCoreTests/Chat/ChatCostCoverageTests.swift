import Foundation
import XCTest
@testable import AIMCore

final class ChatCostCoverageTests: XCTestCase {
    private var usage: TokenUsage { .init(inputTokens: 100, outputTokens: 50) }
    private var pricing: ChatModel.Pricing { .init(prompt: "0.000001", completion: "0.000002") }
    func testProviderTotalOverridesCatalogAndAdditionalFeesWithoutDoubleCounting() {
        XCTAssertEqual(ChatCostRules.estimateUSD(usage: usage, pricing: pricing,
            webSearch: .init(requests: 3, additionalCostUSD: 0.03, providerTotalCostUSD: 0.125)), 0.125)
        XCTAssertEqual(ChatCostRules.estimateUSD(usage: .init(), pricing: nil,
            webSearch: .init(providerTotalCostUSD: 0.125)), 0.125)
    }
    func testAnExplicitZeroTotalIsValidButAnAbsentTotalIsNotZero() {
        XCTAssertEqual(ChatCostRules.estimateUSD(usage: .init(), pricing: nil,
            webSearch: .init(providerTotalCostUSD: 0)), 0)
        XCTAssertNil(ChatCostRules.estimateUSD(usage: .init(), pricing: nil, webSearch: .init()))
    }
    func testEstimatedModeReturnsKnownSubtotalWhileUnknownMetadataStaysUnknown() {
        let web = NativeWebSearchUsage()
        XCTAssertNil(ChatCostRules.estimateUSD(usage: usage, pricing: pricing, webSearch: web))
        XCTAssertEqual(ChatCostRules.estimateUSD(usage: usage, pricing: pricing, webSearch: web,
            allowPartialWebSearchCost: true), 0.0002)
        XCTAssertNil(web.additionalCostUSD); XCTAssertNil(web.providerTotalCostUSD)
        XCTAssertNil(ChatCostRules.estimateUSD(usage: usage, pricing: nil, webSearch: web, allowPartialWebSearchCost: true))
    }
    func testKnownSearchFeesAreStillIncludedAndInvalidNumbersCannotBecomeConfirmedTotals() {
        XCTAssertEqual(ChatCostRules.estimateUSD(usage: usage, pricing: pricing,
            webSearch: .init(requests: 1, additionalCostUSD: 0.01)), 0.0102)
        for total in [-1.0, Double.infinity, Double.nan] {
            XCTAssertNil(ChatCostRules.estimateUSD(usage: .init(), pricing: nil, webSearch: .init(providerTotalCostUSD: total)))
        }
    }
    func testOnlyExplicitEstimatedPolicyRelaxesWebAdmission() throws {
        XCTAssertThrowsError(try NativeWebSearchRules.requireBudgetCompatibility(enabled: true, budgetEnabled: true))
        XCTAssertNoThrow(try NativeWebSearchRules.requireBudgetCompatibility(enabled: true, budgetEnabled: true,
            allowEstimatedWebSearch: true))
    }
}
