@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class ConversationExportIntegrationTests: XCTestCase {
    func testExportUsesSavedHistoryWithoutChangingCurrentDraftOrSelection() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Saved", mode: .agent)
        try await repository.save(conversation)
        try await repository.append(.init(conversationID: conversation.id, role: .user, content: "Persisted prompt", sequence: 0))
        let model = AppModel(database: database)
        model.composerText = "Unsaved draft"
        let export = try await model.conversationExport(conversation.id)
        let text = String(decoding: try export.data(format: .text), as: UTF8.self)
        XCTAssertTrue(text.contains("Persisted prompt"))
        XCTAssertFalse(text.contains("Unsaved draft"))
        XCTAssertEqual(model.composerText, "Unsaved draft")
        XCTAssertNil(model.selectedConversationID)
        XCTAssertEqual(model.mode, .chat)

        model.isSending = true
        do { _ = try await model.conversationExport(conversation.id); XCTFail("Exported active run") }
        catch { XCTAssertTrue(error is ExportError) }
        model.isSending = false
        model.responseSaveError = "Fixture failure"
        do { _ = try await model.conversationExport(conversation.id); XCTFail("Exported unsaved response") }
        catch { XCTAssertTrue(error is ExportError) }
        model.responseSaveError = nil
        do { _ = try await model.conversationExport(UUID()); XCTFail("Exported missing conversation") }
        catch { XCTAssertTrue(error is ExportError) }
    }
}
