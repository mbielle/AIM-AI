@testable import AIMApplication
import XCTest

final class ProviderSpendEstimateTests: XCTestCase {
    func testCatalogEstimateReservesOutputLimitAndUsesReportedTokensOnCompletion() throws {
        let quote = try XCTUnwrap(ProviderSpendEstimate(pricing: .init(prompt: "0.000003", completion: "0.000015")))
        let body = try JSONSerialization.data(withJSONObject: ["max_tokens": 100, "messages": [["role": "user", "content": "Fixture"]]])
        let reservation = try XCTUnwrap(quote.reservation(body: body)).flatMapDecimal
        XCTAssertGreaterThan(reservation, Decimal(string: "0.0015")!)
        XCTAssertEqual(quote.completed(usage: .init(inputTokens: 100, outputTokens: 2)), "0.00033")
        XCTAssertNil(quote.completed(usage: .init(outputTokens: 2)))
        XCTAssertNil(ProviderSpendEstimate(pricing: nil))
        XCTAssertNil(ProviderSpendEstimate(pricing: .init(prompt: "-1", completion: "0.1")))
    }

    func testDirectProviderUsesMatchingReferencePricesWithoutAnotherModelOrNetworkCall() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = ModelCatalogCache(directory: folder)
        try await cache.save([ChatModel(id: "claude-fixture", name: "Direct fixture")], for: .anthropic)
        var reference = ChatModel(id: "anthropic/claude-fixture", name: "Reference fixture")
        reference.pricing = .init(prompt: "0.000003", completion: "0.000015")
        try await cache.save([reference], for: .openRouter)
        let quote = await ProviderSpendEstimate.resolve(provider: .anthropic, modelID: "claude-fixture", cache: cache)
        XCTAssertEqual(quote?.completed(usage: .init(inputTokens: 100, outputTokens: 2)), "0.00033")
        let missing = await ProviderSpendEstimate.resolve(provider: .anthropic, modelID: "missing", cache: cache)
        XCTAssertNil(missing)
    }

    func testEstimatedBudgetAllowsMemoryAndChatButCountsThemAndRefusesOverLimit() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(.init(enabled: true, limitUSD: "10"))
        let meter = BillableRequestMeter(ledger: ledger)
        for feature in ["memory", "agent"] {
            let text = try await meter.perform(provider: "anthropic", modelID: "fixture", feature: feature,
                estimatedUSD: "0.6", estimatedReceiptUSD: { _ in "0.001" }) { "OK" }
            XCTAssertEqual(text, "OK")
        }
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.countedUSD, "0.002")
        XCTAssertEqual(snapshot.estimatedUSD, "0.002")
        XCTAssertEqual(snapshot.confirmedUSD, "0")
        let attempts = try await ledger.recentAttempts()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(attempts.allSatisfy { $0.actualUSD == nil && $0.maximumUSD == nil && $0.estimatedUSD == "0.001" })
        do {
            _ = try await meter.perform(provider: "anthropic", modelID: "fixture", feature: "chat", estimatedUSD: "10") { XCTFail("Must not send"); return "bad" }
            XCTFail("A real estimated excess must be refused")
        } catch SpendAdmissionError.limitReached {}
        let breakdown = try await ledger.breakdown()
        XCTAssertEqual(breakdown.providers.first?.estimatedUSD, "0.002")
    }

    func testStrictAndRunCapRefuseEstimatedChargesBeforeOperation() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(.init(enabled: true, limitUSD: "10", requiresVerifiedWebSearch: true))
        let strict = BillableRequestMeter(ledger: ledger)
        do {
            _ = try await strict.perform(provider: "anthropic", modelID: "fixture", feature: "chat", estimatedUSD: "0.001") { XCTFail("Strict must not send"); return "bad" }
            XCTFail()
        } catch SpendAdmissionError.unknownBound {}
        try await ledger.configure(.init(enabled: true, limitUSD: "10"))
        let capped = BillableRequestMeter(ledger: RunBudgetLedger(inner: ledger, capUSD: 1))
        do {
            _ = try await capped.perform(provider: "anthropic", modelID: "fixture", feature: "chat", estimatedUSD: "0.001") { XCTFail("Cap must not send"); return "bad" }
            XCTFail()
        } catch SpendAdmissionError.unknownBound {}
    }

    func testConcurrentEstimatesReserveAtomicallyAndReceiptsReplaceEstimates() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(.init(enabled: true, limitUSD: "1"))
        async let a: SpendAttempt? = try? ledger.admitEstimated(id: UUID(), provider: "anthropic", modelID: "fixture", feature: "chat", conversationID: nil, estimatedUSD: "0.7", at: .now)
        async let b: SpendAttempt? = try? ledger.admitEstimated(id: UUID(), provider: "anthropic", modelID: "fixture", feature: "chat", conversationID: nil, estimatedUSD: "0.7", at: .now)
        let admitted = await [a,b].compactMap { $0 }
        XCTAssertEqual(admitted.count, 1)
        let attempt = try XCTUnwrap(admitted.first)
        try await ledger.markSent(id: attempt.id)
        try await ledger.reconcile(id: attempt.id, actualUSD: "0.2")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.countedUSD, "0.2"); XCTAssertEqual(snapshot.confirmedUSD, "0.2")
        XCTAssertEqual(snapshot.estimatedUSD, "0"); XCTAssertEqual(snapshot.reservedUSD, "0")
    }
}
private extension String {
    var flatMapDecimal: Decimal { Decimal(string: self, locale: Locale(identifier: "en_US_POSIX"))! }
}
