import AIMApplication
import XCTest

final class ConversationExportTests: XCTestCase {
    func testJSONAllowlistOmitsPrivateMetadataAndAttachmentsByDefault() throws {
        let conversation = Conversation(title: "Example", mode: .code, projectID: UUID(), engineID: "private-engine", provider: .xAI, modelID: "private-model", workspacePath: "/private/workspace")
        let messages = [ConversationMessage(conversationID: conversation.id, role: .user, content: "Hello 🌍", sequence: 0,
                                            attachments: [TextAttachment(name: "secret.txt", content: "private-attachment")]),
                        ConversationMessage(conversationID: conversation.id, role: .tool, content: "private-tool", sequence: 1),
                        ConversationMessage(conversationID: conversation.id, role: .system, content: "private-system", sequence: 2)]
        let data = try ConversationExport(conversation: conversation, messages: messages).data(format: .json)
        let text = String(decoding: data, as: UTF8.self)
        for excluded in ["private-", "secret.txt", conversation.id.uuidString, "workspacePath", "provider", "projectID"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["attachmentsIncluded"] as? Bool, false)
        let records = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["text"] as? String, "Hello 🌍")
    }

    func testBothFormatsPreserveOrderAndExplicitAttachmentChoice() throws {
        let conversation = Conversation(title: "Title")
        let first = ConversationMessage(conversationID: conversation.id, role: .user, content: "First", sequence: 2, attachments: [TextAttachment(name: "notes.pdf", content: "Extracted text")])
        let last = ConversationMessage(conversationID: conversation.id, role: .assistant, content: "Last", sequence: 4)
        let snapshot = try ConversationExport(conversation: conversation, messages: [last, first])
        for format in ConversationExport.Format.allCases {
            let text = String(decoding: try snapshot.data(format: format, includeAttachments: true), as: UTF8.self)
            XCTAssertTrue(text.contains("notes.pdf"))
            XCTAssertTrue(text.contains("Extracted text"))
            XCTAssertLessThan(try XCTUnwrap(text.range(of: "First")?.lowerBound), try XCTUnwrap(text.range(of: "Last")?.lowerBound))
            XCTAssertFalse(String(decoding: try snapshot.data(format: format), as: UTF8.self).contains("Extracted text"))
        }
    }

    func testRejectsMixedHistoriesAndDuplicateSequences() throws {
        let conversation = Conversation(title: "Title")
        let message = ConversationMessage(conversationID: conversation.id, role: .user, content: "text", sequence: 0)
        XCTAssertThrowsError(try ConversationExport(conversation: conversation, messages: [message, message]))
        XCTAssertThrowsError(try ConversationExport(conversation: Conversation(title: "Other"), messages: [message]))
    }

    func testOversizedExportFailsWithoutTruncating() throws {
        let conversation = Conversation(title: "Title")
        let snapshot = try ConversationExport(conversation: conversation, messages: [.init(conversationID: conversation.id, role: .user, content: String(repeating: "x", count: 21 * 1_024 * 1_024), sequence: 0)])
        for format in ConversationExport.Format.allCases { XCTAssertThrowsError(try snapshot.data(format: format)) }
    }

    func testImagesAreExcludedUnlessExplicitlyIncludedInJSON() throws {
        let conversation = Conversation(title: "Image export")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        let image = try ImageAttachment(name: "private.png", mimeType: "image/png", data: png)
        let message = ConversationMessage(conversationID: conversation.id, role: .user, content: "Look", sequence: 0, images: [image])
        let snapshot = try ConversationExport(conversation: conversation, messages: [message])

        let ordinary = String(decoding: try snapshot.data(format: .json), as: UTF8.self)
        XCTAssertFalse(ordinary.contains("private.png"))
        XCTAssertFalse(ordinary.contains(png.base64EncodedString()))
        XCTAssertFalse(String(decoding: try snapshot.data(format: .text), as: UTF8.self).contains("private.png"))

        let included = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.data(format: .json, includeImages: true)) as? [String: Any])
        XCTAssertEqual(included["schemaVersion"] as? Int, 2)
        XCTAssertEqual(included["imagesIncluded"] as? Bool, true)
        let messages = try XCTUnwrap(included["messages"] as? [[String: Any]])
        let images = try XCTUnwrap(messages.first?["images"] as? [[String: Any]])
        XCTAssertEqual(images.first?["name"] as? String, "private.png")
        XCTAssertEqual(images.first?["mimeType"] as? String, "image/png")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(images.first?["dataBase64"] as? String)), png)
        XCTAssertThrowsError(try snapshot.data(format: .text, includeImages: true))
    }
}
