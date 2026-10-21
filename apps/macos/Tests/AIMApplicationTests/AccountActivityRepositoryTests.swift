import AIMApplication
import AIMCore
import XCTest

final class AccountActivityRepositoryTests: XCTestCase {
    func testOnlyAttributedNewRequestsEnterAccountAndProviderCorrectionsKeepIdentity() async throws {
        let db = try AIMDatabase(inMemory: true)
        let repository = SQLiteAccountActivityRepository(database: db)
        let ledger = SQLiteGlobalSpendLedger(database: db)
        let account = UUID(), conversation = UUID()
        let now = Date()
        let old = try await ledger.admit(provider: "fixture", modelID: "model", feature: "agent", conversationID: conversation, maximumUSD: "0.4", at: now.addingTimeInterval(-10))
        try await ledger.markSent(id: old.id)
        try await ledger.reconcile(id: old.id, actualUSD: "0.3")
        try await repository.ownConversation(conversation, accountID: account, since: now)
        // Opening or syncing the same conversation must not move its ownership boundary.
        try await repository.ownConversation(conversation, accountID: account, since: now.addingTimeInterval(-100))
        let new = try await ledger.admit(provider: "fixture", modelID: "model", feature: "agent", conversationID: conversation, maximumUSD: "0.4", at: now.addingTimeInterval(1))
        try await ledger.markSent(id: new.id)
        try await ledger.reconcile(id: new.id, actualUSD: "0.3", at: now.addingTimeInterval(2))
        let first = try await repository.records(accountID: account)
        XCTAssertEqual(first.map(\.id), [new.id])
        XCTAssertEqual(first.first?.costUSD, 0.3)
        _ = try await ledger.correctConfirmed(id: new.id, correctedUSD: "0.2", sourceID: "fixture-receipt", at: now.addingTimeInterval(3))
        let corrected = try await repository.records(accountID: account)
        XCTAssertEqual(corrected.map(\.id), [new.id])
        XCTAssertEqual(corrected.first?.costUSD, 0.2)
        XCTAssertEqual(try XCTUnwrap(corrected.first?.updatedAt).timeIntervalSince1970, now.addingTimeInterval(3).timeIntervalSince1970, accuracy: 0.001)
    }

    func testUnknownCostRemainsUnknownAndCancelledBeforeSendDoesNotCount() async throws {
        let db = try AIMDatabase(inMemory: true)
        let repository = SQLiteAccountActivityRepository(database: db)
        let ledger = SQLiteGlobalSpendLedger(database: db)
        let account = UUID(), conversation = UUID(), now = Date()
        try await repository.ownConversation(conversation, accountID: account, since: now)
        let uncertain = try await ledger.admit(provider: "fixture", modelID: "model", feature: "chat", conversationID: conversation, maximumUSD: nil, at: now.addingTimeInterval(1))
        try await ledger.markSent(id: uncertain.id)
        try await ledger.markUnknown(id: uncertain.id)
        let cancelled = try await ledger.admit(provider: "fixture", modelID: "model", feature: "chat", conversationID: conversation, maximumUSD: "0.1", at: now.addingTimeInterval(2))
        try await ledger.markNotSent(id: cancelled.id)
        let rows = try await repository.records(accountID: account)
        XCTAssertEqual(rows.map(\.id), [uncertain.id])
        XCTAssertNil(rows.first?.costUSD)
        XCTAssertEqual(rows.first?.costState, .unknown)
        XCTAssertEqual(AccountActivitySummary(records: rows, accountID: account).unknownCosts, 1)
    }

    func testAccountSwitchAndRemoteMirrorCannotReassignOrDoubleCountExecution() async throws {
        let repository = SQLiteAccountActivityRepository(database: try AIMDatabase(inMemory: true))
        let account = UUID(), another = UUID(), conversation = UUID()
        try await repository.ownConversation(conversation, accountID: account)
        do { try await repository.ownConversation(conversation, accountID: another); XCTFail("Ownership cannot cross accounts") }
        catch AccountServiceError.conflict {}
        var row = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "origin", deviceName: "Mac", provider: "fixture", modelID: "model", mode: "agent", startedAt: Date(), totalTokens: 120)
        try await repository.record(row)
        row.deviceID = "mirror"; row.updatedAt = row.updatedAt.addingTimeInterval(1)
        try await repository.record(row)
        let rows = try await repository.records(accountID: account)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.deviceID, "origin")
        XCTAssertEqual(AccountActivitySummary(records: rows, accountID: account).tokens, 120)
        row.accountID = another
        do { try await repository.record(row); XCTFail("Activity cannot cross accounts") }
        catch AccountServiceError.conflict {}
        let isolated = try await repository.records(accountID: another)
        XCTAssertTrue(isolated.isEmpty)
    }
    func testExplicitLegacySelectionPreservesOriginalsDeduplicatesAndFollowsCorrections() async throws {
        let db = try AIMDatabase(inMemory: true), account = UUID(), other = UUID()
        let repository = SQLiteAccountActivityRepository(database: db)
        let metrics = SQLiteMessageMetricsRepository(database: db)
        let conversations = SQLiteConversationRepository(database: db)
        let conversation = Conversation(title: "Earlier Agent with attachment", mode: .agent)
        try await conversations.save(conversation)
        let at = Date().addingTimeInterval(-600), first = UUID(), second = UUID()
        try await metrics.save(.init(provider: "fixture", modelID: "m", mode: "agent", startedAt: at, usage: .init(inputTokens: 10, outputTokens: 20), totalSeconds: 3), messageID: first, conversationID: conversation.id)
        try await metrics.save(.init(provider: "fixture", modelID: "m", mode: "agent", startedAt: at.addingTimeInterval(10), totalSeconds: 4, characters: 100), messageID: second, conversationID: conversation.id)
        let ledger = SQLiteGlobalSpendLedger(database: db)
        let cost = try await ledger.admit(provider: "fixture", modelID: "m", feature: "agent", conversationID: conversation.id, maximumUSD: "0.4", at: at)
        try await ledger.markSent(id: cost.id); try await ledger.reconcile(id: cost.id, actualUSD: "0.3", at: at.addingTimeInterval(1))
        let preview = try await repository.legacyPreview(accountID: account)
        XCTAssertEqual(preview.count, 3)
        XCTAssertNil(preview.first { $0.id == second }?.record.totalTokens)
        XCTAssertNil(preview.first { $0.id == first }?.record.completedAt)
        let count = try await repository.importLegacy(preview, selectedIDs: [first, cost.id], accountID: account)
        XCTAssertEqual(count, 2)
        let rows = try await repository.records(accountID: account)
        XCTAssertEqual(Set(rows.map(\.id)), [first, cost.id])
        XCTAssertEqual(AccountActivitySummary(records: rows, accountID: account).tokens, 30)
        XCTAssertEqual(AccountActivitySummary(records: rows, accountID: account).confirmedUSD, 0.3)
        let original = try await metrics.metrics(conversationID: conversation.id)
        XCTAssertEqual(original.count, 2)
        let preserved = try await conversations.conversation(id: conversation.id)
        XCTAssertNotNil(preserved)
        let anotherPreview = try await repository.legacyPreview(accountID: other)
        XCTAssertTrue(anotherPreview.isEmpty)
        do { _ = try await repository.importLegacy(preview, selectedIDs: [first], accountID: account); XCTFail("Duplicate import must fail") } catch AccountServiceError.conflict {}
        _ = try await ledger.correctConfirmed(id: cost.id, correctedUSD: "0.2", sourceID: "supplier-receipt", at: Date())
        let corrected = try await repository.records(accountID: account)
        XCTAssertEqual(AccountActivitySummary(records: corrected, accountID: account).confirmedUSD, 0.2)
    }
    func testLegacyImportRechecksSourceWithinTransaction() async throws {
        let db = try AIMDatabase(inMemory: true), account = UUID()
        let repository = SQLiteAccountActivityRepository(database: db), metrics = SQLiteMessageMetricsRepository(database: db)
        let conversations = SQLiteConversationRepository(database: db), conversation = Conversation(title: "Earlier")
        try await conversations.save(conversation)
        let id = UUID(), at = Date().addingTimeInterval(-10)
        var metric = TurnMetrics(provider: "fixture", modelID: "m", mode: "chat", startedAt: at, usage: .init(inputTokens: 10, outputTokens: 20), totalSeconds: 1)
        try await metrics.save(metric, messageID: id, conversationID: conversation.id)
        let preview = try await repository.legacyPreview(accountID: account)
        metric.usage.outputTokens = 30; try await metrics.save(metric, messageID: id, conversationID: conversation.id)
        do { _ = try await repository.importLegacy(preview, selectedIDs: [id], accountID: account); XCTFail("Stale source must fail") } catch AccountServiceError.conflict {}
        let rows = try await repository.records(accountID: account)
        XCTAssertTrue(rows.isEmpty)
    }

    func testLegacyPreviewExcludesConversationsOwnedInChatSyncKeychain() async throws {
        let db = try AIMDatabase(inMemory: true), owner = UUID(), another = UUID()
        let secrets = ActivityImportSecrets(), conversation = Conversation(title: "Private other account")
        try secrets.store(JSONEncoder().encode([conversation.id: owner]), forKey: "account-chat-owners.v1")
        let repository = SQLiteAccountActivityRepository(database: db, importOwnersStore: secrets)
        try await SQLiteConversationRepository(database: db).save(conversation)
        try await SQLiteMessageMetricsRepository(database: db).save(.init(provider: "fixture", modelID: "m", mode: "chat", startedAt: Date().addingTimeInterval(-60), totalSeconds: 1), messageID: UUID(), conversationID: conversation.id)
        let denied = try await repository.legacyPreview(accountID: another)
        XCTAssertTrue(denied.isEmpty)
        let allowed = try await repository.legacyPreview(accountID: owner)
        XCTAssertEqual(allowed.count, 1)
    }

}

private final class ActivityImportSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func readData(forKey key: String) throws -> Data? { lock.withLock { data[key] } }
    func store(_ value: Data, forKey key: String) throws { lock.withLock { data[key] = value } }
    func removeData(forKey key: String) throws { lock.withLock { data[key] = nil } }
}
