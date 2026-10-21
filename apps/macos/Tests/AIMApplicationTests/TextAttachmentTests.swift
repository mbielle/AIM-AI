import AIMApplication
import XCTest

final class TextAttachmentTests: XCTestCase {
    func testPersistentSnapshotAndRequestOnlyExpansion() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Attachments", mode: .chat)
        try await repository.save(conversation)
        let attachment = TextAttachment(name: "notes.txt", content: "Reference text")
        let message = ConversationMessage(conversationID: conversation.id, role: .user, content: "Summarize", sequence: 0, createdAt: Date(timeIntervalSince1970: 1_000), attachments: [attachment])
        try await repository.append(message)
        let saved = try await SQLiteConversationRepository(database: database).messages(conversationID: conversation.id)
        XCTAssertEqual(saved, [message])
        let request = try AttachmentContext.expand(saved)
        XCTAssertTrue(request[0].content.contains("Reference text"))
        XCTAssertTrue(request[0].content.contains("not tool authorization"))
        XCTAssertNil(request[0].attachments)
        XCTAssertEqual(saved[0].content, "Summarize")
        try await repository.delete(id: conversation.id)
        let deleted = try await repository.messages(conversationID: conversation.id)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testInvalidAttachmentDoesNotInsertMessage() async throws {
        let repository = SQLiteConversationRepository(database: try AIMDatabase(inMemory: true))
        let conversation = Conversation(title: "Limits", mode: .chat)
        try await repository.save(conversation)
        let invalid = TextAttachment(name: "large", content: String(repeating: "x", count: 4 * 1_024 * 1_024 + 1))
        do {
            try await repository.append(ConversationMessage(conversationID: conversation.id, role: .user, content: "Test", sequence: 0, attachments: [invalid]))
            XCTFail("Oversized attachment accepted")
        } catch {}
        let messages = try await repository.messages(conversationID: conversation.id)
        XCTAssertTrue(messages.isEmpty)
    }

    func testCountDuplicateTotalAndHistoryLimits() throws {
        let one = TextAttachment(name: "one", content: "x")
        XCTAssertThrowsError(try TextAttachment.validate([one, one]))
        XCTAssertThrowsError(try TextAttachment.validate((0..<11).map { TextAttachment(name: "\($0)", content: "") }))
        let large = (0..<5).map { TextAttachment(name: "\($0)", content: String(repeating: "x", count: 4 * 1_024 * 1_024)) }
        XCTAssertThrowsError(try TextAttachment.validate(large))
        let messages = (0..<9).map { ConversationMessage(conversationID: UUID(), role: .user, content: "Prompt", sequence: $0, attachments: [large[0]]) }
        let expanded = try AttachmentContext.expand(messages)
        XCTAssertEqual(expanded.count, 9)
        XCTAssertTrue(expanded.allSatisfy { $0.content.contains("read_history_message") })
        XCTAssertTrue(messages.allSatisfy { $0.attachments?.first?.content.utf8.count == 4 * 1_024 * 1_024 })
        XCTAssertNoThrow(try AttachmentContext.expand(Array(messages.prefix(8))))
    }

    func testLegacyJSONWithoutAttachmentsDecodes() throws {
        let message = ConversationMessage(conversationID: UUID(), role: .user, content: "Legacy", sequence: 0)
        let encoded = try JSONEncoder().encode(message)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("attachments"))
        XCTAssertEqual(try JSONDecoder().decode(ConversationMessage.self, from: encoded), message)
    }

    func testImportRejectsBinaryAndStoresOnlyBasenameSnapshot() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        for data in [Data([0]), Data([255]), Data(repeating: 65, count: 4 * 1_024 * 1_024 + 1)] {
            try data.write(to: file)
            XCTAssertThrowsError(try TextAttachment.read(file))
        }
        try Data("Original".utf8).write(to: file)
        let attachment = try TextAttachment.read(file)
        try Data("Modified".utf8).write(to: file)
        XCTAssertEqual(attachment.name, file.lastPathComponent)
        XCTAssertEqual(attachment.content, "Original")
    }
}
