import GRDB
@testable import AIMApplication
import XCTest

final class HybridMemoryRepositoryTests: XCTestCase {
    func testScopedSearchPreservesEvidenceRefreshesIndexAndDeletesBothIndexes() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteMemoryRepository(database: database)
        let project = UUID(), other = UUID(), source = UUID()
        var local = MemoryItem(kind: .fact, scope: "project", scopeKey: project.uuidString,
            subjectKey: "nebula", content: "Nebula uses a violet palette.", evidenceQuote: "violet palette",
            sourceMessageID: source, status: .verified)
        let global = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "nebula",
            content: "Nebula is a preferred theme.", status: .verified, isPinned: true)
        let foreign = MemoryItem(kind: .fact, scope: "project", scopeKey: other.uuidString,
            subjectKey: "nebula", content: "Nebula belongs to another project.", status: .verified, isPinned: true)
        let archived = MemoryItem(kind: .fact, scope: "project", scopeKey: project.uuidString,
            subjectKey: "nebula", content: "Nebula old version.", status: .archived)
        for item in [local, global, foreign, archived] { try await repository.save(item) }
        let scoped = try await repository.searchScoped("nebula", projectID: project, includeGlobal: false, limit: 1)
        XCTAssertEqual(scoped.map(\.id), [local.id], "Scope filtering must precede a pinned result or limit")
        XCTAssertEqual(scoped.first?.evidenceQuote, "violet palette")
        XCTAssertEqual(scoped.first?.sourceMessageID, source)
        let combined = try await repository.searchScoped("nebula", projectID: project, includeGlobal: true, limit: 10)
        XCTAssertEqual(Set(combined.map(\.id)), [local.id, global.id])

        let id = local.id
        let oldHash = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT contentHash FROM memorySemanticIndex WHERE memoryID=?", arguments: [id.uuidString])
        }
        local.content = "Nebula now uses an amber palette."
        local.evidenceQuote = "amber palette"
        try await repository.save(local)
        let revised = try await repository.searchScoped("amber", projectID: project, includeGlobal: false, limit: 10)
        XCTAssertEqual(revised.first?.content, local.content)
        XCTAssertEqual(revised.first?.evidenceQuote, "amber palette")
        XCTAssertEqual(revised.first?.sourceMessageID, source)
        let expectedHash = HybridMemorySearch.fingerprint(local.subjectKey + " " + local.content)
        let refreshedHash = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT contentHash FROM memorySemanticIndex WHERE memoryID=?", arguments: [id.uuidString])
        }
        XCTAssertNotEqual(oldHash, refreshedHash)
        XCTAssertEqual(refreshedHash, expectedHash)
        try await repository.delete(id: id)
        let remaining = try await repository.searchScoped("nebula", projectID: project, includeGlobal: false, limit: 10)
        XCTAssertTrue(remaining.isEmpty)
        let indexCounts = try await database.pool.read { db in
            [try Int.fetchOne(db, sql: "SELECT count(*) FROM memorySemanticIndex WHERE memoryID=?", arguments: [id.uuidString]),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM memorySearch WHERE memoryID=?", arguments: [id.uuidString])]
        }
        XCTAssertEqual(indexCounts, [0, 0], "Delete must remove semantic and lexical entries")
    }

    func testConsolidationRetainsArchivedProvenanceAndRejectsCrossScopeProposal() async throws {
        let database = try AIMDatabase(inMemory: true)
        let concrete = SQLiteMemoryRepository(database: database)
        let repository: any MemoryRepository = concrete
        let project = UUID(), keeperSource = UUID(), duplicateSource = UUID()
        let keeper = MemoryItem(kind: .preference, scope: "project", scopeKey: project.uuidString,
            subjectKey: "length", content: "Keep answers concise.", evidenceQuote: "concise",
            sourceMessageID: keeperSource)
        let duplicate = MemoryItem(kind: .preference, scope: "project", scopeKey: project.uuidString,
            subjectKey: "style", content: "  KEEP answers concise. ", evidenceQuote: "short answers",
            sourceMessageID: duplicateSource, isPinned: true)
        let foreign = MemoryItem(kind: .preference, scope: "global", scopeKey: "self",
            subjectKey: "length", content: "Keep answers concise.")
        for item in [keeper, duplicate, foreign] { try await repository.save(item) }
        do {
            try await concrete.consolidateDuplicates(keeping: keeper.id, archiving: [duplicate.id, foreign.id])
            XCTFail("Consolidation must not cross visibility scopes")
        } catch MemoryConsolidationError.staleProposal {
            // The concrete actor must dispatch to the same implementation as the protocol.
        } catch { XCTFail("Unexpected concrete consolidation refusal: \(error)") }
        let untouched = try await repository.list(status: nil)
        XCTAssertEqual(untouched.first(where: { $0.id == keeper.id })?.status, .provisional)
        XCTAssertEqual(untouched.first(where: { $0.id == duplicate.id })?.status, .provisional)
        try await repository.consolidateDuplicates(keeping: keeper.id, archiving: [duplicate.id])
        let stored = try await repository.list(status: nil)
        let survivor = try XCTUnwrap(stored.first(where: { $0.id == keeper.id }))
        XCTAssertEqual(survivor.status, .verified)
        XCTAssertTrue(survivor.isPinned)
        XCTAssertEqual(survivor.evidenceQuote, keeper.evidenceQuote)
        XCTAssertEqual(survivor.sourceMessageID, keeperSource)
        let preserved = try XCTUnwrap(stored.first(where: { $0.id == duplicate.id }))
        XCTAssertEqual(preserved.status, .archived)
        XCTAssertEqual(preserved.content, duplicate.content)
        XCTAssertEqual(preserved.evidenceQuote, duplicate.evidenceQuote)
        XCTAssertEqual(preserved.sourceMessageID, duplicateSource)
        let duplicateID = duplicate.id
        let indexCounts = try await database.pool.read { db in
            [try Int.fetchOne(db, sql: "SELECT count(*) FROM memorySemanticIndex WHERE memoryID=?", arguments: [duplicateID.uuidString]),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM memorySearch WHERE memoryID=?", arguments: [duplicateID.uuidString])]
        }
        XCTAssertEqual(indexCounts, [0, 0])
        let searchable = try await repository.searchScoped("concise", projectID: project, includeGlobal: false, limit: 10)
        XCTAssertEqual(searchable.map(\.id), [keeper.id])
        var secondDuplicate = duplicate
        secondDuplicate.id = UUID()
        secondDuplicate.isPinned = false
        try await repository.save(secondDuplicate)
        try await concrete.consolidateDuplicates(keeping: keeper.id, archiving: [secondDuplicate.id])
        let afterConcrete = try await repository.list(status: nil)
        XCTAssertEqual(afterConcrete.first(where: { $0.id == secondDuplicate.id })?.status, .archived)
        XCTAssertEqual(afterConcrete.first(where: { $0.id == keeper.id })?.sourceMessageID, keeperSource)
    }

    func testProfileIsAlwaysOfferedAndRelatedWordsFindTheRest() async throws {
        // Apple's embedding finds few paraphrases (1 in 5 in the Round 36 audit): the person's profile
        // is always in the context and the conversation's model picks among word-matched candidates.
        let repository = SQLiteMemoryRepository(database: try AIMDatabase(inMemory: true))
        let style = MemoryItem(kind: .preference, scope: "global", scopeKey: "self", subjectKey: "reply style",
                               content: "Keep messages concise.", status: .provisional, confidence: 0.8)
        let editor = MemoryItem(kind: .fact, scope: "global", scopeKey: "self", subjectKey: "editor",
                                content: "Mathieu préfère Zed pour éditer le code.", status: .verified)
        let unrelated = MemoryItem(kind: .decision, scope: "global", scopeKey: "self", subjectKey: "landing",
                                   content: "The landing page uses a blue logo.", status: .verified)
        for item in [style, editor, unrelated] { try await repository.save(item) }
        let candidates = try await repository.contextCandidates("I prefer short explanations.", projectID: nil, includeGlobal: true)
        XCTAssertTrue(candidates.contains { $0.id == style.id }, "profile entry offered without shared words")
        XCTAssertFalse(candidates.contains { $0.id == unrelated.id })
        let stems = try await repository.contextCandidates("Quelles sont mes préférences d'éditeur ?", projectID: nil, includeGlobal: true)
        XCTAssertTrue(stems.contains { $0.id == editor.id }, "préférences finds préfère, éditeur finds éditer")
        let context = MemoryContext.messages([], items: candidates, query: "I prefer short explanations.", projectID: nil, conversationID: UUID())
        XCTAssertTrue(try XCTUnwrap(context.first).content.contains("profile, AI-extracted"))
        // An explicit search stays a search: the profile is not added to its results.
        let searched = try await repository.searchScoped("landing", projectID: nil, includeGlobal: true, limit: 8)
        XCTAssertEqual(searched.map(\.id), [unrelated.id])
    }
}
