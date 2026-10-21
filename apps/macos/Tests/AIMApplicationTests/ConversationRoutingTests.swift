import AIMApplication
import XCTest

final class ConversationRoutingTests: XCTestCase {
    func testEachConversationRetainsItsOwnProviderAndWorkspace() async throws {
        let repository = SQLiteConversationRepository(database: try AIMDatabase(inMemory: true))
        let a = Conversation(title: "Project A", mode: .code, provider: .anthropic, modelID: "claude-fixture", workspacePath: "/tmp/project-a")
        let b = Conversation(title: "Project B", mode: .code, provider: .google, modelID: "models/fixture", workspacePath: "/tmp/project-b")
        try await repository.save(a)
        try await repository.save(b)
        let loadedA = try await repository.conversation(id: a.id)
        let loadedB = try await repository.conversation(id: b.id)
        XCTAssertEqual(loadedA?.provider, a.provider)
        XCTAssertEqual(loadedA?.modelID, a.modelID)
        XCTAssertEqual(loadedA?.workspacePath, a.workspacePath)
        XCTAssertEqual(loadedB?.provider, b.provider)
        XCTAssertEqual(loadedB?.modelID, b.modelID)
        XCTAssertEqual(loadedB?.workspacePath, b.workspacePath)
        var renamed = a
        renamed.title = "Renamed A"
        try await repository.save(renamed)
        let final = try await repository.conversation(id: a.id)
        XCTAssertEqual(final?.provider, .anthropic)
        XCTAssertEqual(final?.workspacePath, "/tmp/project-a")
    }

    func testV1DatabaseUpgradePreservesConversationsAndSearch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("migration.sqlite").path
        let conversation = Conversation(title: "Legacy")
        do {
            let database = try AIMDatabase(path: path)
            let repository = SQLiteConversationRepository(database: database)
            try await repository.save(conversation)
            try await repository.append(ConversationMessage(conversationID: conversation.id, role: .user, content: "Migration sentinel", sequence: 0))
            // Reconstruct the exact v1 columns on this disposable test database.
            try await database.pool.write { db in
                try db.execute(sql: "ALTER TABLE conversations DROP COLUMN provider")
                try db.execute(sql: "ALTER TABLE conversations DROP COLUMN modelID")
                try db.execute(sql: "ALTER TABLE conversations DROP COLUMN workspacePath")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-conversation-routing'")
            }
        }
        let migrated = SQLiteConversationRepository(database: try AIMDatabase(path: path))
        let restored = try await migrated.conversation(id: conversation.id)
        XCTAssertEqual(restored?.title, "Legacy")
        XCTAssertNil(restored?.provider)
        XCTAssertNil(restored?.workspacePath)
        let matches = try await migrated.search("sentinel", limit: 10)
        XCTAssertEqual(matches.map(\.id), [conversation.id])
        var updated = try XCTUnwrap(restored)
        updated.provider = .openAI; updated.modelID = "fixture"
        try await migrated.save(updated)
        let saved = try await migrated.conversation(id: conversation.id)
        XCTAssertEqual(saved?.provider, .openAI)
    }

    func testLegacyConversationJSONDecodesWithoutRouting() throws {
        let original = Conversation(title: "Legacy JSON")
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["provider"])
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
