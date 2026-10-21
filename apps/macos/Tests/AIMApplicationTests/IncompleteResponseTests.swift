import AIMApplication
import XCTest

final class IncompleteResponseTests: XCTestCase {
    func testStatusPersistsBranchesAndIsExcludedFromProviderContext() async throws {
        let repository = SQLiteConversationRepository(database: try AIMDatabase(inMemory: true))
        let conversation = Conversation(title: "Interrupted")
        try await repository.save(conversation)
        let user = ConversationMessage(conversationID: conversation.id, role: .user, content: "Explain", sequence: 0)
        let failed = ConversationMessage(conversationID: conversation.id, role: .assistant,
            content: "Partial text", sequence: 1, completionStatus: .failed)
        let next = ConversationMessage(conversationID: conversation.id, role: .user, content: "Try a new topic", sequence: 2)
        let completed = ConversationMessage(conversationID: conversation.id, role: .assistant, content: "Done", sequence: 3)
        for message in [user, failed, next, completed] { try await repository.append(message) }

        let saved = try await repository.messages(conversationID: conversation.id)
        XCTAssertEqual(saved.map(\.completionStatus), [nil, .failed, nil, nil])
        XCTAssertEqual(ProviderHistory.completedContext(saved).map(\.content), ["Explain", "Try a new topic", "Done"])
        let branch = try await repository.branch(conversationID: conversation.id, at: failed.id, includingMessage: true)
        let copied = try await repository.messages(conversationID: branch.id)
        XCTAssertEqual(copied.last?.completionStatus, .failed)

        let json = try ConversationExport(conversation: conversation, messages: saved).data(format: .json)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(document["schemaVersion"] as? Int, 3)
        let records = try XCTUnwrap(document["messages"] as? [[String: Any]])
        XCTAssertEqual(records[1]["completionStatus"] as? String, "failed")
        let text = String(decoding: try ConversationExport(conversation: conversation, messages: saved).data(format: .text), as: UTF8.self)
        XCTAssertTrue(text.contains("FAILED (incomplete)"))
    }

    func testOldMessageJSONWithoutStatusRemainsComplete() throws {
        let id = UUID()
        let conversationID = UUID()
        let json = """
        {"id":"\(id.uuidString)","conversationID":"\(conversationID.uuidString)","role":"assistant","content":"Old answer","sequence":1,"createdAt":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let message = try decoder.decode(ConversationMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.completionStatus)
        XCTAssertEqual(message.content, "Old answer")
    }
}
