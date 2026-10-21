import AIMAgentKit
import Foundation
import XCTest

final class AgentQuestionBrokerTests: XCTestCase {
    func testTypedQuestionArrayReachesQuestionBroker() async throws {
        let broker = AgentQuestionBroker()
        let conversationID = UUID()
        let service = AskUserToolService(broker: broker, conversationID: conversationID)
        let dispatcher = try ApprovedToolDispatcher(tools: [RegisteredTool(name: "ask_user", risk: .readOnly,
            optionalArguments: ["questions"], argumentKinds: ["questions": .questionItems],
            approvalExempt: true, executor: service)], broker: ToolApprovalBroker(), policy: .plan, workspacePath: nil)
        let call = Task { await dispatcher.executeJSON(id: "typed", name: "ask_user", arguments: [
            "questions": .array([.object(["question": .string("Which folder?"),
                "options": .array([.string("A"), .string("B")]), "multi": .boolean(false)])])
        ]) }
        var pending: AgentQuestion?
        for _ in 0..<200 {
            pending = await broker.snapshot().first
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let question = try XCTUnwrap(pending)
        XCTAssertEqual(question.items.first?.options, ["A", "B"])
        let accepted = await broker.answer(question.id, text: "A")
        XCTAssertTrue(accepted)
        let result = await call.value
        XCTAssertEqual(result.content, "A")
    }

    func testQuestionPausesUntilAnswerAndPublishesRemoval() async {
        let broker = AgentQuestionBroker()
        let conversationID = UUID()
        let question = AgentQuestion(id: "q1", conversationID: conversationID, text: "Which folder?", options: ["One", "Two"])
        let updates = await broker.updates()
        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, [])
        let waiting = Task { await broker.ask(question) }
        let appeared = await iterator.next()
        XCTAssertEqual(appeared, [question])
        let rejectedEmpty = await broker.answer("q1", text: " ")
        XCTAssertFalse(rejectedEmpty)
        let accepted = await broker.answer("q1", text: "Two")
        XCTAssertTrue(accepted)
        let answer = await waiting.value
        XCTAssertEqual(answer, "Two")
        let removed = await iterator.next()
        XCTAssertEqual(removed, [])
    }

    func testCancellingToolUnblocksWaitingTurn() async {
        let broker = AgentQuestionBroker()
        let conversationID = UUID()
        let service = AskUserToolService(broker: broker, conversationID: conversationID)
        let updates = await broker.updates()
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        let request = ToolRequest(id: "call", name: "ask_user", arguments: ["question": "Continue?"], risk: .readOnly)
        let waiting = Task { await service.execute(request) }
        let appeared = await iterator.next()
        XCTAssertEqual(appeared?.first?.conversationID, conversationID)
        await service.cancel(requestID: "call")
        let result = await waiting.value
        XCTAssertTrue(result.isError)
        let removed = await iterator.next()
        XCTAssertEqual(removed, [])
    }

    func testOneToolCallCanAskSeveralQuestions() async throws {
        let broker = AgentQuestionBroker()
        let conversationID = UUID()
        let service = AskUserToolService(broker: broker, conversationID: conversationID)
        let updates = await broker.updates()
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()
        let questions = """
        [{"question":"Which folder?","options":["A","B"]},
         {"question":"Which checks?","options":["Build","Tests"],"multi":true}]
        """
        let request = ToolRequest(id: "multi", name: "ask_user", arguments: ["questions": questions], risk: .readOnly)
        let waiting = Task { await service.execute(request) }
        let pending = await iterator.next()
        let appeared = try XCTUnwrap(pending?.first)
        XCTAssertEqual(appeared.items.count, 2)
        XCTAssertTrue(appeared.items[1].multi)
        let accepted = await broker.answer(appeared.id, text: "1. A\n2. Build, Tests")
        XCTAssertTrue(accepted)
        let result = await waiting.value
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "1. A\n2. Build, Tests")
    }
}
