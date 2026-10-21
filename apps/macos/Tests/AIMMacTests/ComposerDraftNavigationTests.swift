@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class ComposerDraftNavigationTests: XCTestCase {
    func testConversationDraftsAreIsolatedAndRestoreAfterModelRecreation() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let first = Conversation(title: "One"), second = Conversation(title: "Two")
        try await repository.save(first)
        try await repository.save(second)
        let model = AppModel(database: database)
        await model.selectConversation(first.id)
        model.composerText = "First draft"
        model.pendingAttachments = [TextAttachment(name: "first.txt", content: "Private to first")]
        await model.selectConversation(second.id)
        XCTAssertTrue(model.composerText.isEmpty)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        model.composerText = "Second draft"
        XCTAssertTrue(model.flushComposer())
        let reopened = AppModel(database: database)
        await reopened.selectConversation(first.id)
        XCTAssertEqual(reopened.composerText, "First draft")
        XCTAssertEqual(reopened.pendingAttachments.first?.content, "Private to first")
        await reopened.selectConversation(second.id)
        XCTAssertEqual(reopened.composerText, "Second draft")
        XCTAssertTrue(reopened.pendingAttachments.isEmpty)
    }

    func testNewModeDraftsStaySeparate() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        model.composerText = "Chat draft"
        model.selectMode(.code)
        XCTAssertTrue(model.composerText.isEmpty)
        model.composerText = "Code draft"
        model.selectMode(.chat)
        XCTAssertEqual(model.composerText, "Chat draft")
        model.selectMode(.code)
        XCTAssertEqual(model.composerText, "Code draft")
    }

    func testNewDraftSurvivesRecreationBeforeConversationSelection() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database)
        model.composerText = "Unsent new chat"
        XCTAssertTrue(model.flushComposer())
        let reopened = AppModel(database: database)
        XCTAssertEqual(reopened.composerText, "Unsent new chat")
        await reopened.newConversation()
        XCTAssertEqual(reopened.composerText, "Unsent new chat")
        _ = await reopened.saveProject(id: nil, name: "Draft fixture", instructions: "")
        let project = try XCTUnwrap(reopened.projects.first)
        await reopened.selectProject(project.id)
        XCTAssertTrue(reopened.composerText.isEmpty)
        await reopened.selectProject(nil)
        XCTAssertEqual(reopened.composerText, "Unsent new chat")
    }
}
