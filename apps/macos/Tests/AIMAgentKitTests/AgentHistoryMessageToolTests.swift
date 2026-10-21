import AIMAgentKit
import AIMApplication
import XCTest

final class AgentHistoryMessageToolTests: XCTestCase {
    func testPagesExactTextAndAttachmentInsideCurrentConversationOnly() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let own = Conversation(title: "Own", mode: .agent)
        let other = Conversation(title: "Other", mode: .agent)
        try await repository.save(own)
        try await repository.save(other)
        try await repository.append(ConversationMessage(conversationID: own.id, role: .user,
            content: "éééé", sequence: 0,
            attachments: [TextAttachment(name: "note.txt", content: "private exact source")]))
        try await repository.append(ConversationMessage(conversationID: other.id, role: .user,
            content: "other conversation secret", sequence: 1))

        let tool = AgentHistoryMessageToolService(repository: repository, conversationID: own.id)
        let first = await tool.execute(ToolRequest(name: "read_history_message",
            arguments: ["sequence": "0", "limit": "3"], risk: .readOnly))
        XCTAssertFalse(first.isError)
        XCTAssertTrue(first.content.contains("é"))
        XCTAssertEqual(first.metadata["next_offset"], "2")
        XCTAssertEqual(first.metadata["text_attachments"], "0: note.txt")

        let second = await tool.execute(ToolRequest(name: "read_history_message",
            arguments: ["sequence": "0", "offset": "2", "limit": "6"], risk: .readOnly))
        XCTAssertFalse(second.isError)
        XCTAssertEqual(second.metadata["next_offset"], "end")
        XCTAssertTrue(second.content.contains("ééé"))

        let attachment = await tool.execute(ToolRequest(name: "read_history_message",
            arguments: ["sequence": "0", "part": "attachment", "attachment_index": "0"],
            risk: .readOnly))
        XCTAssertTrue(attachment.content.contains("private exact source"))
        XCTAssertEqual(attachment.metadata["attachment_name"], "note.txt")

        let foreign = await tool.execute(ToolRequest(name: "read_history_message",
            arguments: ["sequence": "1"], risk: .readOnly))
        XCTAssertTrue(foreign.isError)
        XCTAssertFalse(foreign.content.contains("secret"))
    }

    func testRejectsInvalidRangeAndAttachmentWithoutLeakingText() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Own", mode: .agent)
        try await repository.save(conversation)
        try await repository.append(ConversationMessage(conversationID: conversation.id,
            role: .user, content: "é private", sequence: 0))
        let tool = AgentHistoryMessageToolService(repository: repository, conversationID: conversation.id)
        for arguments in [
            ["sequence": "0", "offset": "1"],
            ["sequence": "0", "limit": "32769"],
            ["sequence": "0", "part": "attachment", "attachment_index": "0"],
            ["sequence": "-1"]
        ] {
            let result = await tool.execute(ToolRequest(name: "read_history_message",
                arguments: arguments, risk: .readOnly))
            XCTAssertTrue(result.isError, "\(arguments)")
            XCTAssertFalse(result.content.contains("private"))
        }
    }
}
