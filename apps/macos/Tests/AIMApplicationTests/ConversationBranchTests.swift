import AIMApplication
import XCTest

final class ConversationBranchTests: XCTestCase {
    func testAtomicBranchPreservesRouteAttachmentsProjectAndOriginal() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteConversationRepository(database: database)
        let project = AIMProject(name: "App")
        try await SQLiteProjectRepository(database: database).save(project)
        let original = Conversation(title: "Original", mode: .code, projectID: project.id, provider: .anthropic, modelID: "fixture", workspacePath: "/tmp/project")
        try await repository.save(original)
        let first = ConversationMessage(conversationID: original.id, role: .user, content: "Unique search phrase", sequence: 0, attachments: [TextAttachment(name: "context.txt", content: "Copy this snapshot")])
        let second = ConversationMessage(conversationID: original.id, role: .assistant, content: "Answer", sequence: 1)
        let third = ConversationMessage(conversationID: original.id, role: .user, content: "Later", sequence: 2)
        for message in [first, second, third] { try await repository.append(message) }
        let branch = try await repository.branch(conversationID: original.id, at: second.id, includingMessage: true)
        XCTAssertNotEqual(branch.id, original.id)
        XCTAssertEqual(branch.projectID, project.id)
        XCTAssertEqual(branch.mode, .code)
        XCTAssertEqual(branch.provider, .anthropic)
        XCTAssertEqual(branch.modelID, "fixture")
        XCTAssertEqual(branch.workspacePath, "/tmp/project")
        let copied = try await repository.messages(conversationID: branch.id)
        XCTAssertEqual(copied.map(\.content), [first.content, second.content])
        XCTAssertEqual(copied.map(\.sequence), [0, 1])
        XCTAssertTrue(copied.allSatisfy { $0.conversationID == branch.id })
        XCTAssertNotEqual(copied.first?.id, first.id)
        XCTAssertEqual(copied.first?.attachments, first.attachments)
        let unchanged = try await repository.messages(conversationID: original.id)
        XCTAssertEqual(unchanged.map(\.id), [first.id, second.id, third.id])
        let matches = try await repository.search("Unique", limit: 10)
        XCTAssertEqual(Set(matches.map(\.id)), [original.id, branch.id])
        try await repository.delete(id: original.id)
        let retained = try await repository.messages(conversationID: branch.id)
        XCTAssertEqual(retained.count, 2)
    }

    func testEditBranchExcludesSelectedMessageAndInvalidTargetCreatesNothing() async throws {
        let repository = SQLiteConversationRepository(database: try AIMDatabase(inMemory: true))
        let original = Conversation(title: "Original")
        try await repository.save(original)
        let first = ConversationMessage(conversationID: original.id, role: .user, content: "Correct me", sequence: 0)
        try await repository.append(first)
        do {
            _ = try await repository.branch(conversationID: original.id, at: UUID(), includingMessage: true)
            XCTFail("Unknown message accepted")
        } catch {}
        let before = try await repository.list(includeArchived: true)
        XCTAssertEqual(before.count, 1)
        let branch = try await repository.branch(conversationID: original.id, at: first.id, includingMessage: false)
        let copied = try await repository.messages(conversationID: branch.id)
        XCTAssertTrue(copied.isEmpty)
    }
}
