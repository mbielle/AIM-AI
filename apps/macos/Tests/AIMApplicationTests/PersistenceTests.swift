import AIMApplication
import XCTest

final class PersistenceTests: XCTestCase {
    func testConversationRoundTripAndSearch() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Native architecture")
        try await repository.save(conversation)
        try await repository.append(ConversationMessage(
            conversationID: conversation.id,
            role: .user,
            content: "Build the macOS application",
            sequence: 0
        ))

        let loaded = try await repository.conversation(id: conversation.id)
        let messages = try await repository.messages(conversationID: conversation.id)
        let searchResults = try await repository.search("macOS", limit: 10)
        XCTAssertEqual(loaded?.title, conversation.title)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(searchResults.map(\.id), [conversation.id])
    }

    func testDeletingConversationCascadesMessages() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Temporary")
        try await repository.save(conversation)
        try await repository.append(ConversationMessage(conversationID: conversation.id, role: .user, content: "Delete me", sequence: 0))
        try await repository.delete(id: conversation.id)
        let messages = try await repository.messages(conversationID: conversation.id)
        XCTAssertTrue(messages.isEmpty)
    }

    func testMemorySearchUsesFTS() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteMemoryRepository(database: database)
        let item = MemoryItem(kind: .architecture, scope: "project", scopeKey: "mac", subjectKey: "ui", content: "Use a native SwiftUI interface")
        try await repository.save(item)
        let results = try await repository.search("SwiftUI", limit: 10)
        XCTAssertEqual(results.first?.id, item.id)
    }
}
