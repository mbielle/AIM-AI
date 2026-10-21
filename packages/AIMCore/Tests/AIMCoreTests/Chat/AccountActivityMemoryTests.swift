import Foundation
import XCTest
@testable import AIMCore

final class AccountActivityMemoryTests: XCTestCase {
    private let account = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    func testMirrorAndCorrectionNeverDoubleCountOrChangeDevice() {
        let id = UUID(), date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = AccountActivityRecord(id: id, accountID: account, deviceID: "mac", deviceName: "Mac", provider: "openrouter", modelID: "test", mode: "agent", startedAt: date, totalTokens: 120, costUSD: 0.04, costState: .estimated, updatedAt: date)
        var correction = first; correction.costState = .confirmed; correction.costUSD = 0.035; correction.updatedAt = date.addingTimeInterval(60)
        var copied = first; copied.deviceID = "phone"; copied.updatedAt = date.addingTimeInterval(120)
        let merged = AccountActivityRecord.merge([first, first, correction, copied], accountID: account)
        XCTAssertEqual(merged.count, 1); XCTAssertEqual(merged[0].deviceID, "mac")
        XCTAssertEqual(merged[0].costUSD, 0.035); XCTAssertEqual(merged[0].costState, .confirmed)
        XCTAssertEqual(AccountActivitySummary(records: merged, accountID: account).tokens, 120)
        XCTAssertEqual(DeviceBudgetRules.committedUSD(records: merged, accountID: account, deviceID: "phone", now: date), 0)
        XCTAssertEqual(DeviceBudgetRules.committedUSD(records: merged, accountID: account, deviceID: "mac", now: date), 0.035)
    }
    func testUnknownTokensCostsAndLegacyTaskDurationStayUnavailable() {
        let response = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "phone", deviceName: "iPhone", provider: "test", modelID: "unknown", mode: "chat", startedAt: .now)
        let task = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "phone", deviceName: "iPhone", kind: .task, provider: "test", modelID: "unknown", mode: "agent", startedAt: .now)
        let s = AccountActivitySummary(records: [response, task], accountID: account)
        XCTAssertNil(s.peakTokens); XCTAssertNil(s.longestTask); XCTAssertEqual(s.unknownCosts, 1)
        XCTAssertEqual(s.confirmedUSD, 0); XCTAssertEqual(s.estimatedUSD, 0)
        XCTAssertEqual(s.unmeasuredResponses, 1)
    }
    func testCommonFiltersUseSelectedZoneAndDeduplicateBeforeSumming() throws {
        let formatter = ISO8601DateFormatter()
        let request = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", provider: "fixture", modelID: "m", mode: "agent", startedAt: try XCTUnwrap(formatter.date(from: "2026-09-30T23:30:00Z")), totalTokens: 20, costUSD: 0.1, costState: .confirmed)
        let now = try XCTUnwrap(formatter.date(from: "2026-10-01T09:00:00Z"))
        let paris = AccountActivityFilter(period: .month, timeZoneID: "Europe/Paris", deviceID: "mac", provider: "fixture", modelID: "m", mode: "agent")
        let utc = AccountActivityFilter(period: .month, timeZoneID: "UTC")
        let rows = paris.apply([request, request], accountID: account, now: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(AccountActivitySummary(records: rows, accountID: account).confirmedUSD, 0.1)
        XCTAssertTrue(utc.apply([request], accountID: account, now: now).isEmpty)
        XCTAssertTrue(paris.apply([request], accountID: UUID(), now: now).isEmpty)
        var mirrored = request; mirrored.costTrackedSeparately = true
        XCTAssertEqual(AccountActivitySummary(records: [mirrored], accountID: account).confirmedUSD, 0)
    }
    func testAccountIsolationAndMeasuredRootTaskIncludesWaitAndChildren() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let root = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", kind: .task, provider: "test", modelID: "m", mode: "agent", startedAt: start, completedAt: start.addingTimeInterval(300), waitingSeconds: 80)
        let child = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", parentTaskID: root.id, kind: .task, provider: "test", modelID: "m", mode: "agent", startedAt: start, completedAt: start.addingTimeInterval(900))
        var alien = root; alien.accountID = UUID()
        let summary = AccountActivitySummary(records: [root, child, alien], accountID: account)
        XCTAssertEqual(summary.records.count, 2); XCTAssertEqual(summary.longestTask, 300)
        XCTAssertEqual(summary.records.first { $0.id == root.id }?.waitingSeconds, 80)
    }
    func testStreakUsesSelectedTimeZone() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        let now = Date(timeIntervalSince1970: 1_790_000_000), today = calendar.startOfDay(for: now)
        let dates = [-2,-1,0].map { calendar.date(byAdding: .day, value: $0, to: today)!.addingTimeInterval(120) }
        let rows = dates.map { AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", provider: "test", modelID: "m", mode: "chat", startedAt: $0, totalTokens: 5) }
        let summary = AccountActivitySummary(records: rows, accountID: account, calendar: calendar, now: now)
        XCTAssertEqual(summary.currentStreak, 3); XCTAssertEqual(summary.longestStreak, 3); XCTAssertEqual(summary.dailyTokens[today], 5)
    }
    func testMemoryDocumentHasItsOwnIDAndDeletedActivityIsNotUploadedAgain() async throws {
        // Round 36: memory shared C103 with the favorites/pins document; every write conflicted.
        let fixed = ["C49C4ED4-1E53-4A29-92C7-39A4D8D3C101", "C49C4ED4-1E53-4A29-92C7-39A4D8D3C102",
                     "C49C4ED4-1E53-4A29-92C7-39A4D8D3C103", ConversationReadReceiptSync.documentID.uuidString]
        XCTAssertFalse(fixed.contains(AccountMemoryService.documentID.uuidString))
        let transport = MemoryCASFixture()
        let memory = AccountMemoryService(accountID: account, service: transport)
        await transport.put(AccountDocument(id: UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C103")!, kind: "favorites", payload: "[]", revision: 1))
        var snapshot = try await memory.load(); snapshot.entries = [.init(subject: "Editor", content: "Zed")]
        _ = try await memory.save(snapshot)
        let reloaded = try await memory.load()
        XCTAssertEqual(reloaded.entries.map(\.content), ["Zed"])
        // A record deleted on another device is neither merged nor uploaded again.
        let id = UUID(), date = Date(timeIntervalSince1970: 1_790_000_000)
        let record = AccountActivityRecord(id: id, accountID: account, deviceID: "mac", deviceName: "Mac", provider: "p", modelID: "m", mode: "agent", startedAt: date)
        await transport.put(AccountDocument(id: id, kind: "activity", payload: "{}", revision: 3, deleted: true))
        let merged = try await AccountActivityService(accountID: account, service: transport).synchronize([record])
        XCTAssertTrue(merged.isEmpty)
        let row = await transport.row(id)
        XCTAssertEqual(row?.revision, 3)
    }
    func testEachDeviceSendsItsActivityAsMonthlyBatchesOnlyWhenTheyChange() async throws {
        let transport = MemoryCASFixture(), september = Date(timeIntervalSince1970: 1_788_000_000), october = Date(timeIntervalSince1970: 1_790_700_000)
        func row(_ device: String, _ start: Date) -> AccountActivityRecord {
            AccountActivityRecord(id: UUID(), accountID: account, deviceID: device, deviceName: device, kind: .tool,
                                  provider: "openrouter", modelID: "m", mode: "agent", startedAt: start, toolName: "web_search")
        }
        let legacy = row("phone", september)
        await transport.put(AccountDocument(id: legacy.id, kind: "activity", payload: String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self), revision: 1))
        let mac = (0..<40).map { row("mac", $0 < 30 ? september : october) }
        let service = AccountActivityService(accountID: account, service: transport)
        let merged = try await service.synchronize(mac, deviceID: "mac")
        XCTAssertEqual(merged.count, 41, "earlier single-record documents are still read")
        let afterFirst = await transport.allRows()
        XCTAssertEqual(afterFirst.count, 3, "40 records went up as 2 monthly documents")
        let septemberID = AccountActivityBatch.id(accountID: account, deviceID: "mac", month: AccountActivityBatch.month(of: september))
        XCTAssertEqual(afterFirst.first { $0.id == septemberID }?.revision, 1)
        _ = try await service.synchronize(mac, deviceID: "mac")
        let unchanged = await transport.allRows()
        XCTAssertEqual(unchanged.map(\.revision).reduce(0, +), afterFirst.map(\.revision).reduce(0, +), "nothing is rewritten when nothing changed")
        // Another device sees the Mac's records and writes only its own month documents.
        let phone = try await AccountActivityService(accountID: account, service: transport).synchronize([row("phone", october)], deviceID: "phone")
        XCTAssertEqual(phone.count, 42)
        let after = await transport.allRows()
        XCTAssertEqual(after.first { $0.id == septemberID }?.revision, 1, "the phone never rewrites the Mac's batches")
    }
    func testRefreshingServiceDoesNotMakeStaleMemoryDraftWritable() async throws {
        let transport = MemoryCASFixture(), service = AccountMemoryService(accountID: account, service: transport)
        var initial = try await service.load(); initial.enabled = true; initial.entries = [.init(subject: "Preference", content: "Original")]
        let saved = try await service.save(initial)
        var stale = saved; stale.entries[0].content = "Phone draft"
        var remote = saved; remote.entries[0].content = "Mac edit"; _ = try await service.save(remote)
        _ = try await service.load() // A refresh must never advance the revision attached to stale.
        do { _ = try await service.save(stale); XCTFail("A stale draft overwrote another device") } catch AccountServiceError.conflict {}
        let actual = try await service.load(); XCTAssertEqual(actual.entries[0].content, "Mac edit")
        var disabled = actual; disabled.enabled = false; _ = try await service.save(disabled)
        XCTAssertEqual(AccountMemoryService.context(disabled, query: "Preference", projectID: nil), "")
        XCTAssertEqual(disabled.entries.count, 1)
    }
    func testMemoryScopeAndOldPreferencesDecode() throws {
        var snapshot = AccountMemorySnapshot(); snapshot.enabled = true
        snapshot.entries = [.init(subject: "General", content: "A", pinned: true), .init(subject: "Project", content: "B", projectID: UUID(), pinned: true), .init(subject: "Archived", content: "C", pinned: true, archived: true)]
        let context = AccountMemoryService.context(snapshot, query: "hello", projectID: nil)
        XCTAssertTrue(context.contains("General")); XCTAssertFalse(context.contains("Project")); XCTAssertFalse(context.contains("Archived"))
        let old = try JSONDecoder().decode(AccountChatPreferences.self, from: Data(#"{"responseStyle":"concise","responseLanguage":"French"}"#.utf8))
        XCTAssertNil(old.automaticWebSearch); XCTAssertTrue(old.instructions.contains("French"))
    }
    func testMemoryMetadataKeepsReviewStateAndEarlierEntriesDecode() throws {
        let legacy = try JSONDecoder().decode(AccountMemoryEntry.self, from: Data(#"{"id":"10000000-0000-0000-0000-000000000002","subject":"Earlier","content":"Kept","reviewed":true,"pinned":false,"archived":false}"#.utf8))
        XCTAssertNil(legacy.reviewStatus); XCTAssertNil(legacy.createdAt)
        var snapshot = AccountMemorySnapshot(); snapshot.enabled = true
        snapshot.entries = [legacy, .init(subject: "Provisional", content: "Unreviewed", pinned: true, reviewStatus: "provisional")]
        let context = AccountMemoryService.context(snapshot, query: "Earlier", projectID: nil)
        // AI-extracted entries are offered too, with their review status.
        XCTAssertTrue(context.contains("Kept")); XCTAssertTrue(context.contains("Unreviewed")); XCTAssertTrue(context.contains("provisional"))
        let restored = try JSONDecoder().decode(AccountMemorySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
    }
}
private actor MemoryCASFixture: AccountContentSyncing {
    var rows: [UUID: AccountDocument] = [:]
    func documents(accountID: UUID) async throws -> [AccountDocument] { Array(rows.values) }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        guard (rows[document.id]?.revision ?? 0) == document.revision else { throw AccountServiceError.conflict }
        var next = document; next.revision += 1; rows[next.id] = next; return next
    }
    func put(_ document: AccountDocument) { rows[document.id] = document }
    func allRows() -> [AccountDocument] { Array(rows.values) }
    func row(_ id: UUID) -> AccountDocument? { rows[id] }
}
