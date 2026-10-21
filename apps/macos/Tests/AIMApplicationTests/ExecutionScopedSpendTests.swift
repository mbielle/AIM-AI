import XCTest
@testable import AIMApplication

final class ExecutionScopedSpendTests: XCTestCase {
    private func fixture() async throws -> (AIMDatabase, UUID, UUID) {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Budget", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let repository = SQLiteAgentExecutionRepository(database: database)
        let owner = UUID(); try await repository.installOwner(owner)
        let execution = try await repository.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, request: Data()), owner: owner)
        _ = try await repository.transition(execution.id, owner: owner, expectedRevision: 0, to: .running)
        return (database, execution.id, owner)
    }
    func testManagedExecutionStillRefusesCompletedGlobalUnknownHistoryInEstimatedPersonalMode() async throws {
        let (database, executionID, owner) = try await fixture()
        let ledger = SQLiteGlobalSpendLedger(database: database)
        let unknown = try await ledger.admit(provider: "fixture", modelID: "legacy", feature: "chat", maximumUSD: nil)
        try await ledger.markSent(id: unknown.id); try await ledger.markUnknown(id: unknown.id)
        // A scoped cap also stays strict when the optional personal budget is off.
        let cappedWithPersonalOff = ExecutionScopedSpendLedger(ledger: ledger, executionID: executionID, owner: owner, capUSD: "1")
        do {
            _ = try await cappedWithPersonalOff.admit(id: UUID(), provider: "fixture", modelID: "priced", feature: "remote",
                conversationID: nil, maximumUSD: "0.01", exception: false, at: .now)
            XCTFail("A scoped ceiling remains strict with the personal budget off")
        } catch SpendAdmissionError.unknownBound {}
        try await ledger.configure(.init(enabled: true, limitUSD: "5"))
        for cap in ["1"] {
            let scoped = ExecutionScopedSpendLedger(ledger: ledger, executionID: executionID, owner: owner, capUSD: cap)
            do {
                _ = try await scoped.admit(id: UUID(), provider: "fixture", modelID: "priced", feature: "remote",
                    conversationID: nil, maximumUSD: "0.01", exception: false, at: .now)
                XCTFail("Personal estimated mode must not widen managed execution authorization")
            } catch SpendAdmissionError.unknownBound {}
        }
    }

    func testUncappedExecutionCountsEstimatedAnthropicCallsAndRetainsOwnerFence() async throws {
        let (database, executionID, owner) = try await fixture()
        let ledger = SQLiteGlobalSpendLedger(database: database)
        try await ledger.configure(.init(enabled: true, limitUSD: "10"))
        let scoped = ExecutionScopedSpendLedger(ledger: ledger, executionID: executionID, owner: owner, capUSD: nil)
        let meter = BillableRequestMeter(ledger: scoped)
        let result = try await meter.perform(provider: "anthropic", modelID: "fixture-haiku", feature: "memory",
            estimatedUSD: "0.2", estimatedReceiptUSD: { _ in "0.00012" }) { "fixture-response" }
        XCTAssertEqual(result, "fixture-response")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.countedUSD, "0.00012")
        XCTAssertEqual(snapshot.estimatedUSD, "0.00012")
        XCTAssertEqual(snapshot.confirmedUSD, "0")
        XCTAssertEqual(snapshot.reservedUSD, "0")
        let capped = ExecutionScopedSpendLedger(ledger: ledger, executionID: executionID, owner: owner, capUSD: "1")
        do {
            _ = try await capped.admitEstimated(id: UUID(), provider: "anthropic", modelID: "fixture", feature: "chat", conversationID: nil, estimatedUSD: "0.01", at: .now)
            XCTFail("An explicit execution cap must not accept an estimate")
        } catch SpendAdmissionError.unknownBound {}
        let stale = ExecutionScopedSpendLedger(ledger: ledger, executionID: executionID, owner: UUID(), capUSD: nil)
        do {
            _ = try await stale.admitEstimated(id: UUID(), provider: "anthropic", modelID: "fixture", feature: "chat", conversationID: nil, estimatedUSD: "0.01", at: .now)
            XCTFail("Stale owner must not admit an estimate")
        } catch ExecutionStoreError.staleOwner {}
    }

    func testMissionCapDoesNotInheritEstimatedSearchPersonalPolicy() async throws {
        let (database, executionID, owner) = try await fixture()
        let ledger = SQLiteGlobalSpendLedger(database: database)
        try await ledger.configure(.init(enabled: true, limitUSD: "5", requiresVerifiedWebSearch: false))
        let capped = ExecutionScopedSpendLedger(ledger: ledger, executionID: executionID, owner: owner, capUSD: "1")
        let uncapped = ExecutionScopedSpendLedger(ledger: ledger, executionID: executionID, owner: owner, capUSD: nil)
        let capAllows = try await capped.allowsEstimatedWebSearch(at: .now)
        let personalAllows = try await uncapped.allowsEstimatedWebSearch(at: .now)
        XCTAssertFalse(capAllows); XCTAssertTrue(personalAllows)
    }

    func testParentAndChildReservationsShareCapAndSurviveRestart() async throws {
        let (database, executionID, owner) = try await fixture()
        let ledger = SQLiteGlobalSpendLedger(database: database)
        let scoped = ExecutionScopedSpendLedger(ledger: ledger, executionID: executionID, owner: owner, capUSD: "1.00")
        let attempt = UUID()
        _ = try await scoped.admit(id: attempt, provider: "fixture", modelID: "model", feature: "parent", conversationID: nil, maximumUSD: "0.60", exception: false, at: .now)
        do {
            _ = try await scoped.admit(id: UUID(), provider: "fixture", modelID: "model", feature: "subagent", conversationID: nil, maximumUSD: "0.60", exception: false, at: .now)
            XCTFail("Aggregate reservation exceeded budget")
        } catch { XCTAssertEqual(error as? SpendAdmissionError, .limitReached) }
        try await scoped.markSent(id: attempt, at: .now)
        let nextOwner = UUID(); try await SQLiteAgentExecutionRepository(database: database).installOwner(nextOwner)
        let restarted = ExecutionScopedSpendLedger(ledger: SQLiteGlobalSpendLedger(database: database), executionID: executionID, owner: nextOwner, capUSD: "1.00")
        let snapshot = try await restarted.snapshot(at: .now)
        XCTAssertEqual(snapshot.countedUSD, "0.6"); XCTAssertEqual(snapshot.unknownAttempts, 1)
        do { try await scoped.markSent(id: attempt, at: .now); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
        do { try await scoped.reconcile(id: attempt, actualUSD: "0", at: .now); XCTFail("Old worker changed the cost") }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
        try await restarted.reconcile(id: attempt, actualUSD: "0.40", at: .now)
        _ = try await restarted.admit(id: UUID(), provider: "fixture", modelID: "model", feature: "active_compaction", conversationID: nil, maximumUSD: "0.60", exception: false, at: .now)
        let exact = try await restarted.snapshot(at: .now)
        XCTAssertEqual(exact.countedUSD, "1"); XCTAssertEqual(exact.confirmedUSD, "0.4")
    }
    func testNoOptionalCapDoesNotConvertUnboundedUnknownSpendToZero() async throws {
        let (database, executionID, owner) = try await fixture()
        let scoped = ExecutionScopedSpendLedger(ledger: SQLiteGlobalSpendLedger(database: database), executionID: executionID, owner: owner, capUSD: nil)
        for _ in 0..<8 {
            let id = UUID()
            _ = try await scoped.admit(id: id, provider: "fixture", modelID: "model", feature: "subagent", conversationID: nil, maximumUSD: nil, exception: false, at: .now)
            try await scoped.markSent(id: id, at: .now); try await scoped.markUnknown(id: id)
        }
        let snapshot = try await scoped.snapshot(at: .now)
        XCTAssertEqual(snapshot.unknownAttempts, 8)
        XCTAssertEqual(snapshot.confirmedUSD, "0")
        let capped = ExecutionScopedSpendLedger(ledger: SQLiteGlobalSpendLedger(database: database), executionID: executionID, owner: owner, capUSD: "1000")
        do {
            _ = try await capped.admit(id: UUID(), provider: "fixture", modelID: "model", feature: "parent", conversationID: nil, maximumUSD: "0.01", exception: false, at: .now); XCTFail()
        } catch { XCTAssertEqual(error as? SpendAdmissionError, .unknownBound) }
    }
}
