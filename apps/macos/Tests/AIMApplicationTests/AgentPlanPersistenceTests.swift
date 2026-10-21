import AIMApplication
import XCTest

final class AgentPlanPersistenceTests: XCTestCase {
    func testPlanSurvivesRepositoryRecreationAndConversationDelete() async throws {
        let database = try AIMDatabase(inMemory: true)
        let conversations = SQLiteConversationRepository(database: database)
        let conversation = Conversation(title: "Long task", mode: .agent)
        try await conversations.save(conversation)

        let first = SQLiteAgentPlanRepository(database: database)
        let plan = AgentPlan(conversationID: conversation.id, steps: [
            AgentPlanStep(title: "Inspect", status: .done),
            AgentPlanStep(title: "Implement", status: .doing)
        ])
        try await first.save(plan)

        let second = SQLiteAgentPlanRepository(database: database)
        let restored = try await second.load(conversationID: conversation.id)
        XCTAssertEqual(restored?.steps, plan.steps)
        try await conversations.delete(id: conversation.id)
        let afterDelete = try await second.load(conversationID: conversation.id)
        XCTAssertNil(afterDelete)
    }
}
