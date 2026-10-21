import AIMAgentKit
import AIMApplication
import XCTest

final class DurableInteractionTests: XCTestCase {
    func testApprovalReceiptRestoresExactOperationButChangedReviewAsksAgain() async throws {
        let database = try AIMDatabase(inMemory: true)
        let owner = UUID(); try await SQLiteAgentExecutionRepository(database: database).installOwner(owner)
        let store = AgentInteractionStore(database: database, owner: owner)
        let session = UUID()
        let request = ToolRequest(id: "stable-call", name: "apply_edit", arguments: ["id": "proposal"], risk: .localMutation, workspacePath: "/tmp")
        let review = ToolReview(path: "file", before: "a", after: "b")
        let broker = ToolApprovalBroker(persistence: store)
        let first = Task { await broker.request(request, sessionID: session, allowsSessionDecision: false, review: review) }
        var pending: [PendingToolApproval] = []
        for _ in 0..<100 {
            pending = await broker.snapshot(); if !pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = try XCTUnwrap(pending.first)
        let decided = await broker.decide(id: original.id, sessionID: session, decision: .allowOnce)
        XCTAssertTrue(decided); let allowed = await first.value; XCTAssertTrue(allowed)
        let restarted = ToolApprovalBroker(persistence: store)
        let restored = await restarted.request(request, sessionID: session, allowsSessionDecision: false, review: review)
        XCTAssertTrue(restored); let after = await restarted.snapshot(); XCTAssertTrue(after.isEmpty)
        let changed = Task { await restarted.request(request, sessionID: session, allowsSessionDecision: false,
                                                      review: ToolReview(path: "file", before: "a", after: "different")) }
        for _ in 0..<100 {
            pending = await restarted.snapshot(); if !pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let new = try XCTUnwrap(pending.first)
        XCTAssertNotEqual(new.id, original.id)
        _ = await restarted.decide(id: new.id, sessionID: session, decision: .deny)
        let rejected = await changed.value; XCTAssertFalse(rejected)
    }
    func testQuestionAnswerSurvivesRestartAndStaleOwnerCannotApprove() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteAgentExecutionRepository(database: database)
        let owner = UUID(); try await repository.installOwner(owner)
        let store = AgentInteractionStore(database: database, owner: owner)
        let broker = AgentQuestionBroker(persistence: store)
        let question = AgentQuestion(id: "stable-question", conversationID: UUID(), text: "Which result?", options: ["A", "B"])
        let waiting = Task { await broker.ask(question) }
        for _ in 0..<100 {
            if !(await broker.snapshot()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let answered = await broker.answer(question.id, text: "B"); XCTAssertTrue(answered)
        let original = await waiting.value; XCTAssertEqual(original, "B")
        let restarted = AgentQuestionBroker(persistence: store)
        let restored = await restarted.ask(question); XCTAssertEqual(restored, "B")
        let nextOwner = UUID(); try await repository.installOwner(nextOwner)
        do { try store.answer(id: question.id, sessionID: question.conversationID, response: JSONEncoder().encode("A")); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionStoreError, .staleOwner) }
    }
}
