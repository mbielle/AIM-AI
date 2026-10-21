import AIMAgentKit
import AIMApplication
import XCTest

final class AgentHistoryToolTests: XCTestCase {
    func testSearchFindsWordsInEveryProjectCurrentScopeFirst() async throws {
        let database = try AIMDatabase(inMemory: true)
        let projects = SQLiteProjectRepository(database: database)
        let conversations = SQLiteConversationRepository(database: database)
        let project = AIMProject(name: "Private project")
        try await projects.save(project)
        let general = Conversation(title: "General notes", mode: .chat)
        let projectChat = Conversation(title: "Project notes", mode: .agent, projectID: project.id)
        try await conversations.save(general)
        try await conversations.save(projectChat)
        try await conversations.append(ConversationMessage(conversationID: general.id, role: .user, content: "We chose the blue logo for the landing page", sequence: 0))
        try await conversations.append(ConversationMessage(conversationID: projectChat.id, role: .user, content: "The landing pages need a logo refresh", sequence: 0))
        // Words in any order, word beginnings match ("pages" for "page"), not the exact phrase.
        let request = ToolRequest(id: "history", name: "search_history", arguments: ["query": "what logo for the landing page?"], risk: .sensitiveRead)
        let generalResult = await AgentHistoryToolService(repository: conversations, projectID: nil).execute(request)
        XCTAssertFalse(generalResult.isError)
        let general1 = try XCTUnwrap(generalResult.content.range(of: "General notes")), project1 = try XCTUnwrap(generalResult.content.range(of: "Project notes (another project)"))
        XCTAssertLessThan(general1.lowerBound, project1.lowerBound)
        XCTAssertTrue(generalResult.content.contains("blue logo"))
        let projectResult = await AgentHistoryToolService(repository: conversations, projectID: project.id).execute(request)
        let project2 = try XCTUnwrap(projectResult.content.range(of: "Project notes (this project)")), general2 = try XCTUnwrap(projectResult.content.range(of: "General notes"))
        XCTAssertLessThan(project2.lowerBound, general2.lowerBound)
    }

    func testSensitiveHistoryAlwaysRequiresApproval() {
        XCTAssertTrue(ApprovalPolicy.alwaysAsk.requiresApproval(for: .sensitiveRead))
        XCTAssertTrue(ApprovalPolicy.smart.requiresApproval(for: .sensitiveRead))
        XCTAssertTrue(ApprovalPolicy.autoApprove.requiresApproval(for: .sensitiveRead))
        XCTAssertTrue(ApprovalPolicy.plan.requiresApproval(for: .sensitiveRead))
    }

    func testScopedSearchIsNotCrowdedOutByOtherProjects() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let projectID = UUID()
        try await SQLiteProjectRepository(database: database).save(AIMProject(id: projectID, name: "Target"))
        let target = Conversation(title: "needle in target", mode: .agent, projectID: projectID,
                                  createdAt: .distantPast, updatedAt: .distantPast)
        try await conversations.save(target)
        for index in 0..<110 {
            try await conversations.save(Conversation(title: "needle elsewhere \(index)", mode: .chat))
        }
        let result = await AgentHistoryToolService(repository: conversations, projectID: projectID)
            .execute(ToolRequest(name: "search_history", arguments: ["query": "needle"], risk: .sensitiveRead))
        // The current project's conversation comes first, however old.
        let lines = result.content.split(separator: "\n").dropFirst()
        XCTAssertTrue(lines.first?.contains("needle in target") == true)
        XCTAssertEqual(lines.count, 10)
    }
}
