import AIMApplication
import XCTest

final class ProjectWorkflowTests: XCTestCase {
    func testProjectInstructionsAndConversationAssociationPersistWithoutDeletingChats() async throws {
        let database = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: database)
        let conversations = SQLiteConversationRepository(database: database)
        var project = AIMProject(name: "Native app", instructions: "Use Swift")
        project.usesGlobalMemory = false
        project.isPinned = true
        try await projects.save(project)
        let conversation = Conversation(title: "Architecture", projectID: project.id)
        try await conversations.save(conversation)
        try await conversations.append(ConversationMessage(conversationID: conversation.id, role: .user, content: "Hello", sequence: 0))
        let stored = try await projects.list()
        XCTAssertEqual(stored.first?.instructions, "Use Swift")
        XCTAssertEqual(stored.first?.usesGlobalMemory, false)
        XCTAssertEqual(stored.first?.isPinned, true)
        let associated = try await conversations.conversation(id: conversation.id)
        XCTAssertEqual(associated?.projectID, project.id)
        try await projects.delete(id: project.id)
        let retained = try await conversations.conversation(id: conversation.id)
        let messages = try await conversations.messages(conversationID: conversation.id)
        XCTAssertNotNil(retained)
        XCTAssertNil(retained?.projectID)
        XCTAssertEqual(messages.first?.content, "Hello")
    }

    func testLegacyProjectJSONKeepsDefaultOptionalSyncMetadata() throws {
        let original = AIMProject(name: "Legacy metadata")
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "isPinned"); payload.removeValue(forKey: "usesGlobalMemory")
        let restored = try JSONDecoder().decode(AIMProject.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(restored.id, original.id); XCTAssertEqual(restored.name, original.name)
        XCTAssertNil(restored.isPinned); XCTAssertNil(restored.usesGlobalMemory)
    }

    func testContextIsRequestOnlyUserMessageAndMissingProjectAddsNothing() {
        let id = UUID()
        let messages = [ConversationMessage(conversationID: id, role: .user, content: "Build a view", sequence: 0)]
        let project = AIMProject(name: "App", instructions: "Use SwiftUI")
        let contextual = ProjectContext.messages(messages, project: project, conversationID: id)
        XCTAssertEqual(contextual.count, 2)
        XCTAssertEqual(contextual.first?.role, .user)
        XCTAssertTrue(contextual.first?.content.contains("Use SwiftUI") == true)
        XCTAssertEqual(contextual.last?.id, messages.first?.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(ProjectContext.messages(messages, project: nil, conversationID: id), messages)
        XCTAssertEqual(ProjectContext.messages(messages, project: AIMProject(name: "Blank", instructions: " \n"), conversationID: id), messages)
    }
}
