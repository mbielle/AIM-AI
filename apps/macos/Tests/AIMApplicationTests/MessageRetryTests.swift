import AIMApplication
import XCTest

final class MessageRetryTests: XCTestCase {
    func testExactRetryIsIdempotentButConflictingIDIsRejected() async throws {
        let repository = SQLiteConversationRepository(database: try AIMDatabase(inMemory: true))
        let conversation = Conversation(title: "Retry")
        try await repository.save(conversation)
        let message = ConversationMessage(conversationID: conversation.id, role: .assistant, content: "Retained response", sequence: 0)
        try await repository.append(message)
        try await repository.append(message)
        var conflict = message
        conflict.content = "Must not overwrite"
        do { try await repository.append(conflict); XCTFail("Conflicting ID overwrote original") } catch {}
        let saved = try await repository.messages(conversationID: conversation.id)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.content, message.content)
        let found = try await repository.search("Retained", limit: 10)
        XCTAssertEqual(found.count, 1)
    }
}
