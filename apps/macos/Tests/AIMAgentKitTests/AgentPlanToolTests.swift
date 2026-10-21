import AIMAgentKit
import AIMApplication
import XCTest

final class AgentPlanToolTests: XCTestCase {
    func testTypedPlanArrayReachesPersistentPlanTool() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Typed plan", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let repository = SQLiteAgentPlanRepository(database: database)
        let service = AgentPlanToolService(repository: repository, conversationID: conversation.id) { _ in }
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "update_plan", risk: .readOnly,
            requiredArguments: ["steps"], argumentKinds: ["steps": .planSteps], approvalExempt: true, executor: service)],
            broker: ToolApprovalBroker(), policy: .plan, workspacePath: nil)
        let result = await dispatcher.executeJSON(id: "typed-plan", name: "update_plan", arguments: [
            "steps": .array([.object(["title": .string("Inspect"), "status": .string("doing")])])
        ])
        XCTAssertFalse(result.isError)
        let saved = try await repository.load(conversationID: conversation.id)
        XCTAssertEqual(saved?.steps.first?.title, "Inspect")
    }

    func testValidPlanPersistsAndInvalidPlanDoesNotReplaceIt() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Agent", mode: .agent)
        try await conversations.save(conversation)
        let repository = SQLiteAgentPlanRepository(database: database)
        let service = AgentPlanToolService(repository: repository, conversationID: conversation.id) { _ in }

        let valid = ToolRequest(id: "1", name: "update_plan", arguments: [
            "steps": #"[{"title":"Inspect","status":"doing"},{"title":"Build","status":"todo"}]"#
        ], risk: .readOnly)
        let saved = await service.execute(valid)
        XCTAssertFalse(saved.isError)
        let original = try await repository.load(conversationID: conversation.id)
        XCTAssertEqual(original?.steps.count, 2)

        let invalid = ToolRequest(id: "2", name: "update_plan", arguments: [
            "steps": #"[{"title":"One","status":"doing"},{"title":"Two","status":"doing"}]"#
        ], risk: .readOnly)
        let rejected = await service.execute(invalid)
        XCTAssertTrue(rejected.isError)
        let stillSaved = try await repository.load(conversationID: conversation.id)
        XCTAssertEqual(stillSaved?.steps, original?.steps)
    }

    func testDoneWhenCriteriaAreKeptAndRecalled() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversation = Conversation(title: "Criteria", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(conversation)
        let repository = SQLiteAgentPlanRepository(database: database)
        let service = AgentPlanToolService(repository: repository, conversationID: conversation.id) { _ in }
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "update_plan", risk: .readOnly,
            requiredArguments: ["steps"], argumentKinds: ["steps": .planSteps], approvalExempt: true, executor: service)],
            broker: ToolApprovalBroker(), policy: .plan, workspacePath: nil)
        let result = await dispatcher.executeJSON(id: "p1", name: "update_plan", arguments: ["steps": .array([
            .object(["title": .string("Fix parser"), "status": .string("done"), "done_when": .string("swift test passes")]),
            .object(["title": .string("Update docs"), "status": .string("todo")])
        ])])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Fix parser: swift test passes"))
        XCTAssertTrue(result.content.contains("“Update docs”"))
        let saved = try await repository.load(conversationID: conversation.id)
        XCTAssertEqual(saved?.steps.first?.doneWhen, "swift test passes")
        let wrongType = await dispatcher.executeJSON(id: "p2", name: "update_plan", arguments: ["steps": .array([
            .object(["title": .string("A"), "status": .string("todo"), "done_when": .integer(3)])
        ])])
        XCTAssertTrue(wrongType.isError)
        await dispatcher.close()
    }
}
