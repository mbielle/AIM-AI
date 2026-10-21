import XCTest
@testable import AIMCore

final class RemoteObservedActionTests: XCTestCase {
    func testAllObservedStatesSurviveWireRoundTripWithoutChangingLegacyStatus() throws {
        let owner = UUID(), turn = UUID(), start = Date(timeIntervalSince1970: 10)
        for state in [ConversationAction.State.running, .waiting, .completed, .failed, .cancelled, .needsReview] {
            let action = ConversationAction(id: "observed", conversationID: owner, turnID: turn, ordinal: 3,
                name: "web_fetch", state: state, startedAt: start,
                finishedAt: [.running, .waiting].contains(state) ? nil : start.addingTimeInterval(2),
                input: "https://example.com/read", output: "Public fixture")
            let wire = try XCTUnwrap(ConversationAction.remoteTimeline([action], content: ""))
            let entries = try XCTUnwrap(wire.arrayValue)
            let legacyStatus = try XCTUnwrap(entries[0].objectValue?["tool"]?.objectValue?["status"]?.stringValue)
            XCTAssertTrue(["running", "error", "done"].contains(legacyStatus))
            let segments = RemoteTimelineRules.displayTimeline(for: .init(id: turn.uuidString, role: .assistant,
                content: "", timeline: entries))
            guard case let .tool(_, tool) = try XCTUnwrap(segments.first) else { return XCTFail("Expected tool") }
            let projected = tool.observedAction(conversationID: owner, turnID: turn, ordinal: 3)
            XCTAssertEqual(projected.state, state)
            XCTAssertEqual(projected.startedAt, start)
            XCTAssertEqual(projected.finishedAt, action.finishedAt)
            XCTAssertEqual(projected.ordinal, 3)
            XCTAssertEqual(projected.input, action.input)
        }
    }

    func testLegacySnapshotsRemainDeterministicAndCancellationIsNotAVisit() {
        let owner = UUID(), turn = UUID()
        for status in ["cancelled", "canceled"] {
            let tool = RemoteTimelineTool(id: "old", name: "web_fetch", status: status, input: "https://example.com/read")
            let first = tool.observedAction(conversationID: owner, turnID: turn, ordinal: 9)
            let second = tool.observedAction(conversationID: owner, turnID: turn, ordinal: 9)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.state, .cancelled)
            let layout = TurnLayout<ConversationAction>.make(content: "", timeline: nil, tools: [first], key: \.id)
            let projection = TurnWorkPresentation(layout: layout, sources: [], live: false)
            XCTAssertTrue(projection.visitedPages.isEmpty)
            XCTAssertTrue(projection.hasInterruptedActions)
        }
    }

    func testLegacyWarningKeepsUnknownOutcomeAndFailedToolNeverLooksSuccessful() {
        let owner = UUID(), turn = UUID()
        let unknown = RemoteTimelineTool(id: "u", name: "web_fetch", status: "done", warning: "Effect unknown")
        let failed = RemoteTimelineTool(id: "f", name: "web_fetch", status: "error")
        XCTAssertEqual(unknown.observedAction(conversationID: owner, turnID: turn, ordinal: 0).state, .needsReview)
        XCTAssertEqual(failed.observedAction(conversationID: owner, turnID: turn, ordinal: 1).state, .failed)
    }
}
