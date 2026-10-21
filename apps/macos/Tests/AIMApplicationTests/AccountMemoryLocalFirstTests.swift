import AIMApplication
import AIMCore
import XCTest

final class AccountMemoryLocalFirstTests: XCTestCase {
    func testMemoryIsReadAndWrittenOnThisMacWhileTheAccountIsUnreachableThenSent() async throws {
        let database = try AIMDatabase(inMemory: true)
        let account = UUID(), server = FlakyMemoryServer()
        let repository = AccountMemoryRepository(legacy: SQLiteMemoryRepository(database: database),
            binding: { .init(accountID: account, service: server) }, cache: SQLiteAccountMemoryCache(database: database))
        let editor = MemoryItem(kind: .preference, scope: "global", scopeKey: "self", subjectKey: "Editor", content: "Uses Zed.", status: .verified)
        try await repository.save(editor)
        // Fresh copy: agents read it without asking the account again.
        let callsBefore = await server.reads
        let first = try await repository.contextCandidates("editor", projectID: nil, includeGlobal: true)
        XCTAssertEqual(first.map(\.content), ["Uses Zed."])
        let callsAfter = await server.reads
        XCTAssertEqual(callsAfter, callsBefore, "a fresh copy is read without the network")

        await server.setReachable(false)
        let offline = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "City", content: "Lives in Lyon.")
        try await repository.save(offline)                       // kept on this Mac
        let captured = try await repository.saveCaptured([MemoryItem(kind: .preference, scope: "global", scopeKey: "self",
            subjectKey: "Language", content: "Prefers French.", status: .provisional)], expectedOwner: .account(account))
        XCTAssertEqual(captured, 1)
        let listed = try await repository.list(status: nil).map(\.subjectKey).sorted()
        XCTAssertEqual(listed, ["City", "Editor", "Language"], "unsent changes are visible on this Mac")
        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot?.entries.count, 3, "Settings shows this Mac's copy while unreachable")

        // Meanwhile the phone changed the editor; it stays the phone's newer version.
        await server.edit { $0.entries[0].content = "Uses Xcode."; $0.entries[0].updatedAt = .now.addingTimeInterval(60) }
        await server.setReachable(true)
        await repository.flushPending()
        let remote = await server.snapshot()
        XCTAssertEqual(remote.entries.map(\.subject).sorted(), ["City", "Editor", "Language"])
        XCTAssertEqual(remote.entries.first { $0.subject == "Editor" }?.content, "Uses Xcode.")
        let cache = try await SQLiteAccountMemoryCache(database: database).record(accountID: account)
        XCTAssertEqual(cache?.pending, [], "sent changes are no longer pending")
    }

    func testAConflictIsStillRefusedAndTheCopyIsReadAgain() async throws {
        let database = try AIMDatabase(inMemory: true)
        let account = UUID(), server = FlakyMemoryServer()
        let repository = AccountMemoryRepository(legacy: SQLiteMemoryRepository(database: database),
            binding: { .init(accountID: account, service: server) }, cache: SQLiteAccountMemoryCache(database: database))
        let item = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "Plan", content: "One", status: .verified)
        try await repository.save(item, expectedRevision: 0)
        await server.edit { $0.entries[0].content = "Phone" }
        var stale = item; stale.content = "Mac"
        do { try await repository.save(stale, expectedRevision: 1); XCTFail("A stale editor overwrote the phone") } catch AccountServiceError.conflict {}
        let cached = try await SQLiteAccountMemoryCache(database: database).record(accountID: account)
        XCTAssertEqual(cached?.snapshot?.entries.first?.content, "Phone", "this Mac's copy holds the phone's version, not the stale edit")
        let reread = try await repository.list(status: nil)
        XCTAssertEqual(reread.first?.content, "Phone")
    }
}

private actor FlakyMemoryServer: AccountContentSyncing {
    private var document: AccountDocument?
    private var reachable = true
    private(set) var reads = 0
    func setReachable(_ value: Bool) { reachable = value }
    func documents(accountID: UUID) async throws -> [AccountDocument] {
        guard reachable else { throw AccountServiceError.unavailable }
        reads += 1
        return document.map { [$0] } ?? []
    }
    func save(_ next: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        guard reachable else { throw AccountServiceError.unavailable }
        guard (document?.revision ?? 0) == next.revision else { throw AccountServiceError.conflict }
        var saved = next; saved.revision += 1; document = saved; return saved
    }
    func snapshot() -> AccountMemorySnapshot {
        document.flatMap { try? JSONDecoder().decode(AccountMemorySnapshot.self, from: Data($0.payload.utf8)) } ?? .init()
    }
    func edit(_ change: (inout AccountMemorySnapshot) -> Void) {
        guard var current = document, var value = try? JSONDecoder().decode(AccountMemorySnapshot.self, from: Data(current.payload.utf8)) else { return }
        change(&value); value.revision = nil
        current.payload = String(decoding: try! JSONEncoder().encode(value), as: UTF8.self); current.revision += 1; document = current
    }
}
