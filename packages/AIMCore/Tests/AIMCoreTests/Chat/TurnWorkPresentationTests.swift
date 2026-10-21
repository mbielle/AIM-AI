import XCTest
@testable import AIMCore

final class TurnWorkPresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)
    private let owner = UUID(), turn = UUID()
    private func action(_ id: String, name: String = "web_fetch", state: ConversationAction.State = .completed,
                        ordinal: Int = 0, input: String? = "https://example.com/read") -> ConversationAction {
        .init(id: id, conversationID: owner, turnID: turn, ordinal: ordinal, name: name, state: state,
              startedAt: start, finishedAt: state == .running ? nil : start.addingTimeInterval(1), input: input)
    }
    private func presentation(_ actions: [ConversationAction] = [], sources: [ConversationSource] = [], live: Bool = false) -> TurnWorkPresentation {
        let layout = TurnLayout<ConversationAction>.make(content: "Answer", timeline: nil, tools: actions, key: \.id, running: live)
        return TurnWorkPresentation(layout: layout, sources: sources, live: live, locale: Locale(identifier: "en"))
    }

    func testOneGlobalDurationAndReasoningDetailNeverContainsASecondDuration() throws {
        var builder = TurnTimelineBuilder(startedAt: start)
        builder.reasoning("Provided text", at: start)
        builder.text("Answer", at: start.addingTimeInterval(20))
        builder.finish(at: start.addingTimeInterval(35))
        let layout = TurnLayout<ConversationAction>.make(content: "Answer", timeline: builder.timeline, tools: [], key: \.id)
        let projection = TurnWorkPresentation(layout: layout, sources: [], live: false, locale: Locale(identifier: "en"))
        XCTAssertEqual(projection.header, "Thought for 35 s")
        XCTAssertEqual(projection.reasoningTitle, "Provider reasoning text")
        XCTAssertFalse(projection.reasoningTitle.contains("20"))
        XCTAssertNil(projection.activeLabel)
        XCTAssertEqual(layout.work.count, 1)
        XCTAssertEqual(layout.answer.count, 1)
        // Rendering the projection must not rewrite historical entries/content.
        XCTAssertEqual(builder.timeline.entries[0].text, "Provided text")
        XCTAssertEqual(builder.timeline.entries[0].endedAt, start.addingTimeInterval(20))
    }

    func testCitationsAndSearchResultsNeverCountAsPageVisits() throws {
        let source = try XCTUnwrap(ConversationSource(url: "https://example.com/read", title: "Example", references: [1]))
        let p = presentation([action("search", name: "web_search", input: #"{"query":"news","results":[{"url":"https://example.com/read"}]}"#)], sources: [source])
        XCTAssertTrue(p.visitedPages.isEmpty)
        XCTAssertEqual(p.receivedSources, 1)
        XCTAssertEqual(p.citedSources, 1)
        XCTAssertEqual(p.sourceSummary, "1 source received")
        XCTAssertNil(p.activeWebAction)
    }

    func testPageReadsAreSuccessfulUniqueAndNeverIncludeFailedOrRunningVisits() {
        let p = presentation([
            action("one"), action("two", ordinal: 1, input: "https://example.com/read?tracking=hidden#part"),
            action("failed", state: .failed, ordinal: 2, input: "https://example.com/failed"),
            action("running", state: .running, ordinal: 3, input: "https://example.com/running")])
        XCTAssertEqual(p.visitedPages.map(\.absoluteString), ["https://example.com/read"])
        XCTAssertTrue(p.hasFailedActions)
        XCTAssertEqual(p.sourceSummary, "1 page read")
    }

    func testNewestObservedRunningWebActionWinsWithoutRotatingFinishedCitations() {
        let p = presentation([action("a", state: .running), action("b", state: .running, ordinal: 1, input: "https://example.com/current"),
                              action("done", ordinal: 2, input: "https://example.com/done")], live: true)
        XCTAssertEqual(p.activeWebAction?.id, "b")
        XCTAssertNil(p.activeLabel)
        XCTAssertNil(presentation([action("done")], live: false).activeWebAction)
    }

    func testStructuredTerminalStateDoesNotRegressToRunning() {
        let p = presentation([action("same", state: .running), action("same", state: .completed)], live: true)
        XCTAssertNil(p.activeWebAction)
        XCTAssertEqual(p.visitedPages.count, 1)
        XCTAssertEqual(p.activeLabel, "Writing the answer…")
    }

    func testThinkingAndWritingLabelsFollowOnlyRecordedParts() {
        var b = TurnTimelineBuilder(startedAt: start); b.reasoning("Provided text", at: start)
        let thinking = TurnLayout<ConversationAction>.make(content: "", timeline: b.timeline, tools: [], key: \.id, running: true)
        XCTAssertEqual(TurnWorkPresentation(layout: thinking, sources: [], live: true, locale: Locale(identifier: "fr")).activeLabel, "Réflexion…")
        XCTAssertEqual(presentation(live: true).activeLabel, "Writing the answer…")
        b.text("Answer", at: start.addingTimeInterval(1))
        let writing = TurnLayout<ConversationAction>.make(content: "Answer", timeline: b.timeline, tools: [], key: \.id, running: true)
        XCTAssertEqual(TurnWorkPresentation(layout: writing, sources: [], live: true, locale: Locale(identifier: "fr")).activeLabel, "Rédaction de la réponse…")
    }

    func testInterruptedActionsStayVisibleAndDoNotBecomeSuccessfulVisits() {
        for state in [ConversationAction.State.cancelled, .needsReview] {
            let p = presentation([action("interrupted", state: state)])
            XCTAssertTrue(p.hasInterruptedActions); XCTAssertTrue(p.visitedPages.isEmpty)
        }
    }
}
