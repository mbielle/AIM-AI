@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class ConversationBranchNavigationTests: XCTestCase {
    func testEditingCreatesUnsentDraftWithAttachmentsAndRevokesTools() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let source = Conversation(title: "Original", mode: .code, provider: .google, modelID: "fixture", workspacePath: "/tmp/example")
        try await repository.save(source)
        let message = ConversationMessage(conversationID: source.id, role: .user, content: "Edit this", sequence: 0, attachments: [TextAttachment(name: "notes", content: "Keep")])
        try await repository.append(message)
        let model = AppModel(database: database)
        await model.selectConversation(source.id)
        model.workspaceToolsEnabled = true
        model.workspaceCommandsEnabled = true
        await model.branchConversation(at: message, edit: true)
        XCTAssertNotEqual(model.selectedConversationID, source.id)
        XCTAssertEqual(model.composerText, message.content)
        XCTAssertEqual(model.pendingAttachments, message.attachments)
        XCTAssertEqual(model.selectedProvider, .google)
        XCTAssertEqual(model.mode, .code)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.isSending)
        XCTAssertFalse(model.workspaceToolsEnabled)
        XCTAssertFalse(model.workspaceCommandsEnabled)
        XCTAssertFalse(model.isBranchingConversation)
    }

    func testBranchDoesNotDiscardDraftOrBranchDuringRun() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let source = Conversation(title: "Original")
        try await repository.save(source)
        let message = ConversationMessage(conversationID: source.id, role: .user, content: "Prompt", sequence: 0)
        try await repository.append(message)
        let model = AppModel(database: database)
        await model.selectConversation(source.id)
        model.composerText = "Unsaved"
        await model.branchConversation(at: message, edit: true)
        XCTAssertEqual(model.composerText, "Unsaved")
        model.composerText = ""
        model.isSending = true
        await model.branchConversation(at: message, edit: false)
        let stored = try await repository.list(includeArchived: true)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(model.selectedConversationID, source.id)
    }
}
