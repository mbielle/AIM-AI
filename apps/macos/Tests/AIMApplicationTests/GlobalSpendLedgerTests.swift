import AIMApplication
import XCTest

final class GlobalSpendLedgerTests: XCTestCase {
    func testEstimatedProtectionKeepsCompletedUnknownHistoryVisibleWithoutBlockingPricedRequests() async throws {
        let db = try AIMDatabase(inMemory: true), ledger = SQLiteGlobalSpendLedger(database: db)
        let unknown = try await ledger.admit(provider: "fixture", modelID: "legacy", feature: "chat", maximumUSD: nil)
        try await ledger.markSent(id: unknown.id); try await ledger.markUnknown(id: unknown.id)
        let known = try await ledger.admit(provider: "fixture", modelID: "known", feature: "chat", maximumUSD: "0.1")
        try await ledger.markSent(id: known.id); try await ledger.reconcile(id: known.id, actualUSD: "0.0602")
        try await ledger.configure(.init(enabled: true, limitUSD: "5", period: .envelope))
        let next = try await ledger.admit(provider: "fixture", modelID: "known", feature: "chat", maximumUSD: "0.2")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.policy.protection, .estimated)
        XCTAssertEqual(snapshot.countedUSD, "0.2602"); XCTAssertEqual(snapshot.reservedUSD, "0.2")
        XCTAssertEqual(snapshot.unknownAttempts, 1)
        let retained = try await ledger.recentAttempts().first(where: { $0.id == unknown.id })
        XCTAssertEqual(retained?.state, .unknown); XCTAssertNil(retained?.actualUSD); XCTAssertNil(retained?.maximumUSD)
        // Switching protection changes admission only, never historical accounting.
        try await ledger.configure(.init(enabled: true, limitUSD: "5", period: .envelope, requiresVerifiedWebSearch: true))
        do {
            _ = try await ledger.admit(provider: "fixture", modelID: "known", feature: "chat", maximumUSD: "0.01")
            XCTFail("Strict mode must still require reconciliation")
        } catch SpendAdmissionError.unknownBound {}
        try await ledger.configure(.init(enabled: true, limitUSD: "5", period: .envelope))
        try await ledger.markSent(id: next.id); try await ledger.reconcile(id: next.id, actualUSD: "6")
        do {
            _ = try await ledger.admit(provider: "fixture", modelID: "known", feature: "chat", maximumUSD: "0.01")
            XCTFail("Known charges still enforce the estimated limit")
        } catch SpendAdmissionError.limitReached {}
        let reopened = SQLiteGlobalSpendLedger(database: db)
        let final = try await reopened.snapshot()
        XCTAssertEqual(final.policy.protection, .estimated); XCTAssertEqual(final.unknownAttempts, 1)
    }

    func testEstimatedProtectionStillBlocksUnsettledUnpricedRequests() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let unknown = try await ledger.admit(provider: "fixture", modelID: "running", feature: "chat", maximumUSD: nil)
        try await ledger.configure(.init(enabled: true, limitUSD: "5"))
        for reserved in [true, false] {
            if !reserved { try await ledger.markSent(id: unknown.id) }
            do {
                _ = try await ledger.admit(provider: "fixture", modelID: "priced", feature: "chat", maximumUSD: "0.01")
                XCTFail("An unsettled unknown reservation must not be ignored")
            } catch SpendAdmissionError.unknownBound {}
        }
        try await ledger.markUnknown(id: unknown.id)
        _ = try await ledger.admit(provider: "fixture", modelID: "priced", feature: "chat", maximumUSD: "0.01")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.unknownAttempts, 1); XCTAssertEqual(snapshot.countedUSD, "0.01")
    }

    func testRunCeilingCannotInheritEstimatedPersonalUnknownHistory() async throws {
        let global = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let unknown = try await global.admit(provider: "fixture", modelID: "legacy", feature: "chat", maximumUSD: nil)
        try await global.markSent(id: unknown.id); try await global.markUnknown(id: unknown.id)
        try await global.configure(.init(enabled: true, limitUSD: "5"))
        let run = RunBudgetLedger(inner: global, capUSD: 1)
        do {
            _ = try await run.admit(id: UUID(), provider: "fixture", modelID: "priced", feature: "scheduled",
                conversationID: nil, maximumUSD: "0.01", exception: false, at: .now)
            XCTFail("A run ceiling must still require historical reconciliation")
        } catch SpendAdmissionError.unknownBound {}
        let snapshot = try await global.snapshot()
        XCTAssertEqual(snapshot.unknownAttempts, 1); XCTAssertEqual(snapshot.countedUSD, "0")
    }

    func testEstimatedWebPolicyPersistsStrictOptInWithoutIgnoringUnknownHistory() async throws {
        let db = try AIMDatabase(inMemory: true), ledger = SQLiteGlobalSpendLedger(database: db)
        try await ledger.configure(.init(enabled: true, limitUSD: "5"))
        let estimated = try await ledger.allowsEstimatedWebSearch(at: .now)
        XCTAssertTrue(estimated)
        var strictPolicy = GlobalSpendPolicy(enabled: true, limitUSD: "5")
        strictPolicy.protection = .strict
        try await ledger.configure(strictPolicy)
        let strict = try await ledger.allowsEstimatedWebSearch(at: .now)
        XCTAssertFalse(strict)
        let policy = try await ledger.policy()
        XCTAssertEqual(policy.requiresVerifiedWebSearch, true)
    }

    func testV52MigrationPreservesExistingPolicyAndFinancialAttempts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("budget-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("fixture.sqlite").path
        let first = try AIMDatabase(path: path)
        let ledger = SQLiteGlobalSpendLedger(database: first)
        try await ledger.configure(.init(enabled: true, limitUSD: "5", period: .envelope))
        let attempt = try await ledger.admit(provider: "fixture", modelID: "fixture", feature: "chat", maximumUSD: "0.2")
        try await ledger.markSent(id: attempt.id)
        try await ledger.reconcile(id: attempt.id, actualUSD: "0.0602")
        // Recreate only the immediately preceding schema in this disposable database.
        try await first.pool.write { db in
            try db.execute(sql: "ALTER TABLE globalSpendPolicy DROP COLUMN requiresVerifiedWebSearch")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v52-estimated-web-budget'")
        }
        let reopened = SQLiteGlobalSpendLedger(database: try AIMDatabase(path: path))
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.policy.limitUSD, "5")
        XCTAssertEqual(snapshot.policy.period, .envelope)
        XCTAssertEqual(snapshot.confirmedUSD, "0.0602")
        XCTAssertEqual(snapshot.policy.requiresVerifiedWebSearch, false)
    }

    func testDefaultHasNoLimitAndUnknownSentCostIsRetained() async throws {
        let db = try AIMDatabase(inMemory: true)
        let ledger = SQLiteGlobalSpendLedger(database: db)
        let policy = try await ledger.policy()
        XCTAssertFalse(policy.enabled)
        let attempt = try await ledger.admit(provider: "fixture", modelID: "model", feature: "agent", maximumUSD: nil)
        try await ledger.markSent(id: attempt.id)
        try await ledger.markUnknown(id: attempt.id)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.unknownAttempts, 1)
        XCTAssertEqual(snapshot.countedUSD, "0")
        XCTAssertEqual(snapshot.confirmedUSD, "0")
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00", period: .envelope,
                                                     timeZoneID: "Europe/Paris", requiresVerifiedWebSearch: true))
        do {
            _ = try await ledger.admit(provider: "fixture", modelID: "model", feature: "agent", maximumUSD: "0.01")
            XCTFail("An unknown prior charge prevents strict admission")
        } catch SpendAdmissionError.unknownBound {}
        try await ledger.reconcile(id: attempt.id, actualUSD: "0.25")
        let afterReceipt = try await ledger.snapshot()
        XCTAssertEqual(afterReceipt.countedUSD, "0.25")
        XCTAssertEqual(afterReceipt.confirmedUSD, "0.25")
        XCTAssertEqual(afterReceipt.unknownAttempts, 0)
    }

    func testConcurrentReservationsShareOneGlobalAvailableBalance() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00", period: .envelope,
                                                     timeZoneID: "Europe/Paris"))
        let firstID = UUID(), secondID = UUID()
        async let first: SpendAttempt? = try? ledger.admit(id: firstID, provider: "fixture", modelID: "a", feature: "chat", maximumUSD: "0.70")
        async let second: SpendAttempt? = try? ledger.admit(id: secondID, provider: "fixture", modelID: "b", feature: "subagent", maximumUSD: "0.70")
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        let admitted = try XCTUnwrap(results.compactMap { $0 }.first)
        let reserved = try await ledger.snapshot()
        XCTAssertEqual(reserved.countedUSD, "0.7")
        XCTAssertEqual(reserved.confirmedUSD, "0")
        do {
            _ = try await ledger.admit(id: admitted.id, provider: "fixture", modelID: "a", feature: "chat", maximumUSD: "0.01")
            XCTFail("The same attempt cannot be admitted twice")
        } catch SpendAdmissionError.duplicateAttempt {}
        try await ledger.markNotSent(id: admitted.id)
        let released = try await ledger.snapshot()
        XCTAssertEqual(released.countedUSD, "0")
        XCTAssertEqual(released.reservedUSD, "0")
    }

    func testExceptionIsOneAttemptAndTimeoutDoesNotReleaseReservation() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "0.50", period: .envelope,
                                                     timeZoneID: "Europe/Paris", requiresVerifiedWebSearch: true))
        do {
            _ = try await ledger.admit(provider: "fixture", modelID: "unknown", feature: "voice", maximumUSD: nil)
            XCTFail("Unknown bound requires an exception")
        } catch SpendAdmissionError.unknownBound {}
        let exception = try await ledger.admit(provider: "fixture", modelID: "unknown", feature: "voice",
                                               maximumUSD: nil, exception: true)
        try await ledger.markSent(id: exception.id)
        try await ledger.markUnknown(id: exception.id)
        do { try await ledger.markNotSent(id: exception.id); XCTFail("A sent request cannot be freed") }
        catch SpendAdmissionError.invalidTransition {}
        do {
            _ = try await ledger.admit(provider: "fixture", modelID: "unknown", feature: "voice", maximumUSD: "0.01")
            XCTFail("The exception must not authorize later attempts")
        } catch SpendAdmissionError.unknownBound {}
        try await ledger.reconcile(id: exception.id, actualUSD: "0.60")
        do {
            _ = try await ledger.admit(provider: "fixture", modelID: "known", feature: "chat", maximumUSD: "0.01")
            XCTFail("A confirmed overrun must stop ordinary admissions")
        } catch SpendAdmissionError.limitReached {}
    }

    func testMonthlyPeriodAndConversationDeletionPreserveAccounting() async throws {
        let db = try AIMDatabase(inMemory: true)
        let ledger = SQLiteGlobalSpendLedger(database: db)
        let conversation = Conversation(title: "Billable")
        let conversations = SQLiteConversationRepository(database: db)
        try await conversations.save(conversation)
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00", period: .calendarMonth,
                                                     timeZoneID: "Europe/Paris"))
        let september = ISO8601DateFormatter().date(from: "2026-09-30T21:00:00Z")!
        let october = ISO8601DateFormatter().date(from: "2026-09-30T23:00:00Z")!
        let attempt = try await ledger.admit(provider: "fixture", modelID: "model", feature: "chat",
                                             conversationID: conversation.id, maximumUSD: "0.75", at: september)
        try await ledger.markSent(id: attempt.id)
        try await ledger.reconcile(id: attempt.id, actualUSD: "0.75")
        try await conversations.delete(id: conversation.id)
        let first = try await ledger.snapshot(at: september)
        let second = try await ledger.snapshot(at: october)
        XCTAssertEqual(first.countedUSD, "0.75")
        XCTAssertEqual(second.countedUSD, "0")
        XCTAssertNotEqual(first.periodStart, second.periodStart)
    }

    func testRecentAttemptsReturnsBillingMetadataWithoutConversationDependency() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        let conversationID = UUID()
        let first = try await ledger.admit(provider: "fixture", modelID: "a", feature: "chat",
            conversationID: conversationID, maximumUSD: nil,
            at: ISO8601DateFormatter().date(from: "2026-09-28T10:00:00Z")!)
        try await ledger.markSent(id: first.id)
        try await ledger.markUnknown(id: first.id)
        let second = try await ledger.admit(provider: "fixture", modelID: "b", feature: "subagent",
            maximumUSD: "0.25", at: ISO8601DateFormatter().date(from: "2026-09-29T10:00:00Z")!)
        let recent = try await ledger.recentAttempts(limit: 1)
        XCTAssertEqual(recent.map(\.id), [second.id])
        XCTAssertEqual(recent.first?.state, .reserved)
        let both = try await ledger.recentAttempts(limit: 2)
        XCTAssertEqual(both.last?.conversationID, conversationID)
    }

    func testBreakdownUsesWholeConfiguredPeriodAndKeepsUnknownCostsSeparate() async throws {
        let ledger = SQLiteGlobalSpendLedger(database: try AIMDatabase(inMemory: true))
        try await ledger.configure(GlobalSpendPolicy(enabled: false, period: .day,
                                                     timeZoneID: "Europe/Paris"))
        let today = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
        let yesterday = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
        for _ in 0..<101 {
            let attempt = try await ledger.admit(provider: "alpha", modelID: "m1",
                feature: "chat", maximumUSD: "0.01", at: today)
            try await ledger.markSent(id: attempt.id)
            try await ledger.reconcile(id: attempt.id, actualUSD: "0.01")
        }
        let reserved = try await ledger.admit(provider: "alpha", modelID: "m2",
            feature: "subagent", maximumUSD: "0.20", at: today)
        try await ledger.markSent(id: reserved.id)
        let unknown = try await ledger.admit(provider: "beta", modelID: "m1",
            feature: "voice", maximumUSD: nil, exception: true, at: today)
        try await ledger.markSent(id: unknown.id)
        try await ledger.markUnknown(id: unknown.id)
        let unsent = try await ledger.admit(provider: "gamma", modelID: "m3",
            feature: "chat", maximumUSD: "9.00", at: today)
        try await ledger.markNotSent(id: unsent.id)
        let old = try await ledger.admit(provider: "old", modelID: "m4",
            feature: "chat", maximumUSD: "50.00", at: yesterday)
        try await ledger.markSent(id: old.id)
        try await ledger.reconcile(id: old.id, actualUSD: "50.00")

        let snapshot = try await ledger.snapshot(at: today)
        let report = try await ledger.breakdown(at: today)
        XCTAssertEqual(snapshot.confirmedUSD, "1.01")
        XCTAssertEqual(snapshot.reservedUSD, "0.2")
        XCTAssertEqual(snapshot.unknownAttempts, 1)
        XCTAssertEqual(report.providers.map(\.label), ["alpha", "beta"])
        let alpha = try XCTUnwrap(report.providers.first)
        XCTAssertEqual(alpha.confirmedUSD, "1.01")
        XCTAssertEqual(alpha.reservedUSD, "0.2")
        XCTAssertEqual(alpha.attemptCount, 102)
        XCTAssertEqual(report.providers.last?.unknownAttempts, 1)
        XCTAssertEqual(report.providers.last?.exceptionCount, 1)
        XCTAssertEqual(Set(report.models.map(\.label)), ["alpha · m1", "alpha · m2", "beta · m1"])
        XCTAssertEqual(Set(report.features.map(\.label)), ["chat", "subagent", "voice"])
        XCTAssertEqual(report.features.first(where: { $0.label == "chat" })?.attemptCount, 101)
        XCTAssertEqual(report.periodStart, snapshot.periodStart)
        XCTAssertEqual(report.periodEnd, snapshot.periodEnd)
    }

    func testProviderCostCorrectionsAreAuditedAndChangeFutureAdmissions() async throws {
        let db = try AIMDatabase(inMemory: true)
        let ledger = SQLiteGlobalSpendLedger(database: db)
        try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00",
            period: .envelope, timeZoneID: "Europe/Paris"))
        let conversation = Conversation(title: "Delete without resetting spending")
        try await SQLiteConversationRepository(database: db).save(conversation)
        let attempt = try await ledger.admit(provider: "provider", modelID: "model",
            feature: "agent", conversationID: conversation.id, maximumUSD: "0.50")
        try await ledger.markSent(id: attempt.id)
        try await ledger.reconcile(id: attempt.id, actualUSD: "0.50")
        let firstCorrectionAt = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
        let secondCorrectionAt = firstCorrectionAt.addingTimeInterval(1)

        let increase = try await ledger.correctConfirmed(id: attempt.id,
            correctedUSD: "1.20", sourceID: "receipt-revision-1", at: firstCorrectionAt)
        XCTAssertEqual(increase.previousUSD, "0.50")
        let afterIncrease = try await ledger.snapshot()
        XCTAssertEqual(afterIncrease.confirmedUSD, "1.2")
        do {
            _ = try await ledger.admit(provider: "provider", modelID: "next",
                feature: "chat", maximumUSD: "0.01")
            XCTFail("A corrected overrun must block admission")
        } catch SpendAdmissionError.limitReached {}
        do {
            _ = try await ledger.correctConfirmed(id: attempt.id,
                correctedUSD: "0.80", sourceID: "receipt-revision-1")
            XCTFail("The same source cannot be applied twice")
        } catch SpendAdmissionError.duplicateCorrection {}

        let decrease = try await ledger.correctConfirmed(id: attempt.id,
            correctedUSD: "0.20", sourceID: "receipt-revision-2", at: secondCorrectionAt)
        XCTAssertEqual(decrease.previousUSD, "1.20")
        let afterDecrease = try await ledger.snapshot()
        XCTAssertEqual(afterDecrease.confirmedUSD, "0.2")
        _ = try await ledger.admit(provider: "provider", modelID: "next",
            feature: "chat", maximumUSD: "0.70")
        try await SQLiteConversationRepository(database: db).delete(id: conversation.id)
        let history = try await ledger.recentCorrections()
        XCTAssertEqual(history.map(\.id), [decrease.id, increase.id])
        XCTAssertEqual(history.map(\.attemptID), [attempt.id, attempt.id])
        XCTAssertEqual(history.map(\.sourceID),
                       ["receipt-revision-2", "receipt-revision-1"])
        XCTAssertEqual(history.first?.provider, "provider")
    }
}
