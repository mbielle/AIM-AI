import AIMApplication
import AIMCore
import XCTest

final class AccountMemoryRepositoryTests: XCTestCase {
    func testSelectionPreservesProvenanceAndOriginalsAndDisabledMemoryDoesNotRun() async throws {
        let legacy = SQLiteMemoryRepository(database: try AIMDatabase(inMemory: true))
        let project = UUID(), source = UUID(), account = UUID(), service = AccountMemoryCASFixture()
        let timestamp = Date(timeIntervalSince1970: 1_791_312_000)
        let item = MemoryItem(kind: .decision, scope: "project", scopeKey: project.uuidString,
            subjectKey: "Architecture", content: "A selected fixture fact", evidenceQuote: "Original evidence", sourceMessageID: source,
            status: .verified, confidence: 0.9, isPinned: true, createdAt: timestamp, updatedAt: timestamp)
        try await legacy.save(item)
        let repository = AccountMemoryRepository(legacy: legacy, binding: { .init(accountID: account, service: service) })
        let before = try await repository.list(status: nil)
        XCTAssertTrue(before.isEmpty, "Legacy memory is not silently attributed")
        let fresh = try await repository.snapshot()
        XCTAssertEqual(fresh?.enabled, true, "memory is on for a new account")
        try await repository.importSelected([item.id], expectedRevision: 0)
        try await repository.setEnabled(false, expectedRevision: 1)
        let imported = try await repository.list(status: nil)
        XCTAssertEqual(imported, [item])
        let original = try await legacy.list(status: nil)
        XCTAssertEqual(original, [item])
        let off = try await repository.searchScoped("Architecture", projectID: project, includeGlobal: true, limit: 8)
        XCTAssertTrue(off.isEmpty)
        do { try await repository.save(MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "Capture", content: "Automatic capture")); XCTFail("Disabled memory must not capture") }
        catch AccountServiceError.unavailable {}
        try await repository.setEnabled(true, expectedRevision: 2)
        let enabled = try await repository.searchScoped("Architecture", projectID: project, includeGlobal: true, limit: 8)
        XCTAssertEqual(enabled.map(\.id), [item.id])
        let anotherProject = try await repository.searchScoped("Architecture", projectID: UUID(), includeGlobal: true, limit: 8)
        XCTAssertTrue(anotherProject.isEmpty)
    }

    func testStaleEditorCannotOverwritePhoneAndOfflineAccountCannotUseLegacy() async throws {
        let legacy = SQLiteMemoryRepository(database: try AIMDatabase(inMemory: true))
        let account = UUID(), service = AccountMemoryCASFixture(), binding = AccountMemoryBindingFixture()
        await binding.configure(account: account, service: service)
        let repository = AccountMemoryRepository(legacy: legacy, binding: { try await binding.resolve() })
        let item = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "Preference", content: "Original", status: .verified)
        try await repository.save(item, expectedRevision: 0)
        let phone = AccountMemoryService(accountID: account, service: service)
        var changed = try await phone.load(); changed.entries[0].content = "Phone edit"; _ = try await phone.save(changed)
        var stale = item; stale.content = "Stale Mac edit"
        do { try await repository.save(stale, expectedRevision: 1); XCTFail("A stale draft overwrote the phone") }
        catch AccountServiceError.conflict {}
        let preserved = try await phone.load(); XCTAssertEqual(preserved.entries[0].content, "Phone edit")
        await binding.configure(account: UUID(), service: service)
        do { try await repository.save(stale, expectedRevision: 0, expectedOwner: .account(account)); XCTFail("An editor crossed accounts") }
        catch AccountServiceError.conflict {}
        let isolated = try await repository.list(status: nil); XCTAssertTrue(isolated.isEmpty)
        await binding.makeUnavailable()
        do { _ = try await repository.searchScoped("Preference", projectID: nil, includeGlobal: true, limit: 8); XCTFail("An offline account fell back to unattributed local data") }
        catch AccountServiceError.unavailable {}
    }

    func testAutomaticCapturePreservesReviewedArchivedAndCorrectionFactsAndCapturedAccount() async throws {
        let legacy = SQLiteMemoryRepository(database: try AIMDatabase(inMemory: true))
        let account = UUID(), service = AccountMemoryCASFixture(), binding = AccountMemoryBindingFixture()
        await binding.configure(account: account, service: service)
        let repository = AccountMemoryRepository(legacy: legacy, binding: { try await binding.resolve() })
        try await repository.setEnabled(true, expectedRevision: 0, expectedOwner: .account(account))
        let subjects: [(String, MemoryStatus, MemoryKind)] = [("Reviewed", .verified, .preference), ("Archived", .archived, .fact), ("Correction", .provisional, .correction)]
        for (subject, status, kind) in subjects {
            let fact = MemoryItem(kind: kind, scope: "global", scopeKey: "self", subjectKey: subject,
                content: "User-owned " + subject, status: status == .archived ? .provisional : status)
            try await repository.save(fact, expectedRevision: nil, expectedOwner: .account(account))
            if status == .archived { try await repository.archive(id: fact.id) }
        }
        var proposals = subjects.map { MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: $0.0,
            content: "Automatic replacement", status: .provisional) }
        let source = UUID(), project = UUID()
        proposals.append(.init(kind: .preference, scope: "project", scopeKey: project.uuidString, subjectKey: "New preference",
            content: "A new proposed fact", evidenceQuote: "Exact evidence", sourceMessageID: source, status: .provisional))
        let count = try await repository.saveCaptured(proposals, expectedOwner: .account(account))
        XCTAssertEqual(count, 1)
        let saved = try await repository.list(status: nil)
        XCTAssertTrue(saved.filter { $0.subjectKey != "New preference" }.allSatisfy { $0.content.hasPrefix("User-owned") })
        let proposed = try XCTUnwrap(saved.first { $0.subjectKey == "New preference" })
        XCTAssertEqual(proposed.sourceMessageID, source); XCTAssertEqual(proposed.scopeKey, project.uuidString)
        XCTAssertEqual(proposed.status, .provisional)
        await binding.configure(account: UUID(), service: service)
        do { _ = try await repository.saveCaptured(proposals, expectedOwner: .account(account)); XCTFail("Capture crossed accounts") }
        catch AccountServiceError.conflict {}
        let isolated = try await repository.list(status: nil); XCTAssertTrue(isolated.isEmpty)
    }

    func testAutomaticCaptureDoesNotRetryOverConcurrentArchive() async throws {
        let account = UUID(), service = AccountMemoryCASFixture()
        let legacy = SQLiteMemoryRepository(database: try AIMDatabase(inMemory: true))
        let repository = AccountMemoryRepository(legacy: legacy, binding: { .init(accountID: account, service: service) })
        try await repository.setEnabled(true, expectedRevision: 0)
        let fact = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "Preference", content: "Original proposed fact", status: .provisional)
        try await repository.save(fact)
        await service.archiveOnNextSave(accountID: account)
        var replacement = fact; replacement.content = "Stale automatic update"; replacement.updatedAt = .now.addingTimeInterval(1)
        do { _ = try await repository.saveCaptured([replacement], expectedOwner: .account(account)); XCTFail("Capture overwrote a concurrent archive") }
        catch AccountServiceError.conflict {}
        let saved = try await repository.list(status: nil)
        XCTAssertEqual(saved.first?.content, fact.content); XCTAssertEqual(saved.first?.status, .archived)
    }
}

private actor AccountMemoryCASFixture: AccountContentSyncing {
    var documentsByAccount: [UUID: [UUID: AccountDocument]] = [:]
    private var archiveAccount: UUID?
    func archiveOnNextSave(accountID: UUID) { archiveAccount = accountID }
    func documents(accountID: UUID) async throws -> [AccountDocument] { Array((documentsByAccount[accountID] ?? [:]).values) }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        if archiveAccount == accountID, let existing = documentsByAccount[accountID]?[document.id],
           var snapshot = try? JSONDecoder().decode(AccountMemorySnapshot.self, from: Data(existing.payload.utf8)), !snapshot.entries.isEmpty {
            archiveAccount = nil
            snapshot.entries[0].archived = true; snapshot.entries[0].reviewStatus = "archived"
            var archived = existing; archived.revision += 1
            archived.payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            documentsByAccount[accountID]?[document.id] = archived
        }
        guard (documentsByAccount[accountID]?[document.id]?.revision ?? 0) == document.revision else { throw AccountServiceError.conflict }
        var next = document; next.revision += 1; documentsByAccount[accountID, default: [:]][next.id] = next; return next
    }
}
private actor AccountMemoryBindingFixture {
    var current: AccountMemoryBinding?
    var available = true
    func configure(account: UUID, service: any AccountContentSyncing) { current = .init(accountID: account, service: service); available = true }
    func makeUnavailable() { available = false }
    func resolve() throws -> AccountMemoryBinding? { guard available else { throw AccountServiceError.unavailable }; return current }
}
