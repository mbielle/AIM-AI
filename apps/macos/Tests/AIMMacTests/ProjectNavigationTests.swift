@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import XCTest

@MainActor
final class ProjectNavigationTests: XCTestCase {
    func testSidebarNewChatLeavesProjectAndPreservesItsDraft() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let created = await model.saveProject(id: nil, name: "Beta", instructions: "")
        XCTAssertTrue(created)
        let project = try XCTUnwrap(model.projects.first)
        await model.openProjects(project.id)
        model.composerText = "Project draft"
        await model.newGeneralConversation()
        XCTAssertNil(model.selectedProjectID)
        XCTAssertNil(model.selectedConversationID)
        XCTAssertTrue(model.composerText.isEmpty)
        await model.openProjects(project.id)
        XCTAssertEqual(model.composerText, "Project draft")
    }

    func testCodeRequiresWorkingFolderBeforeSending() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        model.selectMode(.code)
        model.workspacePath = nil
        model.composerText = "Inspect the app"
        await model.sendComposer()
        XCTAssertNil(model.selectedConversationID)
        XCTAssertEqual(model.composerText, "Inspect the app")
        XCTAssertTrue(model.alertMessage?.contains("working folder") == true)
    }

    func testLegacyProjectSourceRemainsReadOnlyUntilExplicitGrant() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database)
        let created = await model.saveProject(id: nil, name: "Beta", instructions: "")
        XCTAssertTrue(created)
        let project = try XCTUnwrap(model.projects.first)
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-project-permission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = ProjectSource(projectID: project.id, canonicalPath: folder.path, displayName: folder.lastPathComponent)
        try await SQLiteProjectRepository(database: database).save(source: source)
        model.selectMode(.code)
        await model.openProjects(project.id)
        let chosenWhileReadOnly = await model.chooseWorkspace(folder.path)
        XCTAssertFalse(chosenWhileReadOnly)
        let nested = folder.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedWhileReadOnly = await model.chooseWorkspace(nested.path)
        XCTAssertFalse(nestedWhileReadOnly)
        try await model.setProjectSourceWriteAccess(source, granted: true)
        let chosenAfterGrant = await model.chooseWorkspace(folder.path)
        XCTAssertTrue(chosenAfterGrant)
        let saved = try await SQLiteProjectRepository(database: database).sources(projectID: project.id)
        XCTAssertEqual(saved.first?.writeAccessGranted, true)
    }

    func testBreadcrumbNavigationPreservesProjectAndConversationDrafts() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database)
        _ = await model.saveProject(id: nil, name: "Beta", instructions: "", usesGlobalMemory: false)
        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.usesGlobalMemory, false)
        await model.openProjects(project.id)
        model.composerText = "Project draft"
        let conversation = Conversation(title: "Task", projectID: project.id)
        try await SQLiteConversationRepository(database: database).save(conversation)
        await model.selectConversation(conversation.id)
        XCTAssertFalse(model.projectPageVisible)
        model.composerText = "Conversation draft"
        await model.openProjects(project.id)
        XCTAssertTrue(model.projectPageVisible)
        XCTAssertNil(model.selectedConversationID)
        XCTAssertEqual(model.composerText, "Project draft")
        await model.openProjects()
        XCTAssertNil(model.selectedProjectID)
        await model.openProjects(project.id)
        XCTAssertEqual(model.composerText, "Project draft")
        await model.selectConversation(conversation.id)
        XCTAssertEqual(model.composerText, "Conversation draft")
    }

    func testProjectCRUDMoveAndSelectionUsePersistedAssociations() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database)
        let saved = await model.saveProject(id: nil, name: "  App  ", instructions: "Use Swift")
        XCTAssertTrue(saved)
        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.name, "App")
        await model.selectProject(project.id)
        XCTAssertEqual(model.selectedProjectID, project.id)
        XCTAssertNil(model.selectedConversationID)
        let conversation = Conversation(title: "Existing")
        let repository = SQLiteConversationRepository(database: database)
        try await repository.save(conversation)
        await model.moveConversation(conversation.id, toProject: project.id)
        await model.selectConversation(conversation.id)
        XCTAssertEqual(model.selectedProjectID, project.id)
        let deleted = await model.deleteProject(project.id)
        XCTAssertTrue(deleted)
        XCTAssertNil(model.selectedProjectID)
        let retained = try await repository.conversation(id: conversation.id)
        XCTAssertNotNil(retained)
        XCTAssertNil(retained?.projectID)
    }

    func testInvalidOrActiveProjectChangesAreRejected() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let empty = await model.saveProject(id: nil, name: " ", instructions: "")
        let long = await model.saveProject(id: nil, name: "App", instructions: String(repeating: "x", count: 16_001))
        XCTAssertFalse(empty)
        XCTAssertFalse(long)
        model.isSending = true
        let active = await model.saveProject(id: nil, name: "App", instructions: "")
        XCTAssertFalse(active)
        XCTAssertTrue(model.projects.isEmpty)
    }
}
