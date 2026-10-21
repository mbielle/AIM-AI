import AIMApplication
import AIMCore
@testable import AIMMac
import XCTest

final class ContinuityDecisionTests: XCTestCase {
    private func execution(_ state: ExecutionState, _ reason: String?) -> AgentExecution {
        var value = AgentExecution(commandID: UUID(), conversationID: UUID(), request: Data())
        value.state = state; value.reason = reason
        return value
    }

    func testWaitingStatesBecomePlainDecisions() throws {
        let spending = try XCTUnwrap(ContinuityDecision.make(execution(.waitingUser, "Paused before sending: a sub-agent's request does not fit under your spending limit.")))
        XCTAssertEqual(spending.kind, "Spending limit")
        XCTAssertTrue(spending.spending)
        XCTAssertEqual(spending.primary, .resume)
        let child = try XCTUnwrap(ContinuityDecision.make(execution(.waitingUser, "A sub-agent stopped and needs your review before the task continues.")))
        XCTAssertEqual(child.kind, "Sub-agent")
        XCTAssertEqual(child.primary, .continueWithoutBlocked)
        let interrupted = try XCTUnwrap(ContinuityDecision.make(execution(.waitingUser, "Interrupted before any action. Nothing was changed.")))
        XCTAssertEqual(interrupted.primary, .retry)
        XCTAssertNil(ContinuityDecision.make(execution(.awaitingReview, nil)), "a delivered answer asks for nothing")
        XCTAssertNil(ContinuityDecision.make(execution(.running, nil)))
        XCTAssertFalse(child.title.contains("reconciliation"))
    }

    func testChangedFilesCountsDistinctCompletedFileActions() {
        let id = UUID(), turn = UUID()
        func action(_ name: String, _ path: String?, _ state: ConversationAction.State = .completed) -> ConversationAction {
            ConversationAction(id: UUID().uuidString, conversationID: id, turnID: turn, ordinal: 0, name: name, state: state,
                               input: path.map { #"{"path":"\#($0)"}"# })
        }
        XCTAssertNil(ChangedFilesSummary.count([action("read_file", "a.swift"), action("web_search", nil)]))
        XCTAssertEqual(ChangedFilesSummary.count([action("apply_edit", "a.swift"), action("apply_edit", "a.swift"),
                                                  action("move_file", "b.swift"), action("apply_edit", "c.swift", .failed)]), 2)
    }
}
