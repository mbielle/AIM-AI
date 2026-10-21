import AIMApplication
import XCTest

final class ChatServiceTests: XCTestCase {
    func testStreamPayloads() throws {
        XCTAssertEqual(try ChatStreamPayload.decode(#"{"choices":[{"delta":{"content":"Bonjour 🌍"}}]}"#), .text("Bonjour 🌍"))
        XCTAssertEqual(try ChatStreamPayload.decode("[DONE]"), .done)
        XCTAssertEqual(try ChatStreamPayload.decode(#"{"choices":[],"usage":{}}"#), .ignored)
        XCTAssertThrowsError(try ChatStreamPayload.decode("broken"))
        XCTAssertThrowsError(try ChatStreamPayload.decode(#"{"error":{"message":"private detail"}}"#))
        XCTAssertThrowsError(try ChatStreamPayload.decode(#"{"choices":[{"finish_reason":"tool_calls"}]}"#))
    }

    func testRequestPreservesHistoryAndKeepsCredentialsOutOfBody() throws {
        let id = UUID()
        let messages = [
            ConversationMessage(conversationID: id, role: .user, content: "Hello", sequence: 0),
            ConversationMessage(conversationID: id, role: .assistant, content: "Hi", sequence: 1)
        ]
        let request = try OpenRouterChatService.request(modelID: "provider/model", messages: messages, apiKey: "test-secret", mode: .code)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-secret"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let history = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.last?["content"], "Hi")
        XCTAssertTrue(history[0]["content"]!.contains("cannot execute tools"))
        XCTAssertThrowsError(try OpenRouterChatService.request(modelID: "x", messages: [], apiKey: " ", mode: .chat))
    }

    func testRenameAndArchivePreserveSearchableContent() async throws {
        let repository = SQLiteConversationRepository(database: try AIMDatabase(inMemory: true))
        var conversation = Conversation(title: "Original")
        try await repository.save(conversation)
        try await repository.append(ConversationMessage(conversationID: conversation.id, role: .user, content: "Unique constellation", sequence: 0))
        conversation.title = "Renamed"
        try await repository.save(conversation)
        let renamed = try await repository.search("constellation", limit: 10)
        XCTAssertEqual(renamed.map(\.id), [conversation.id])
        conversation.isArchived = true
        try await repository.save(conversation)
        let archived = try await repository.search("constellation", limit: 10)
        XCTAssertTrue(archived.isEmpty)
        conversation.isArchived = false
        try await repository.save(conversation)
        let restored = try await repository.search("constellation", limit: 10)
        XCTAssertEqual(restored.count, 1)
        _ = try await repository.search("\" OR *", limit: 10)
    }
}
