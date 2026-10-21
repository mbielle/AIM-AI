import XCTest
@testable import AIMCore

final class WebActivityPresentationTests: XCTestCase {
    private let english = Locale(identifier: "en")
    private func action(_ input: String?, state: ConversationAction.State = .running, ordinal: Int = 0, name: String = "web_search") -> ConversationAction {
        .init(id: "web-\(ordinal)", conversationID: UUID(), turnID: UUID(), ordinal: ordinal, name: name, state: state, input: input)
    }

    func testReadingSiteRequiresAnObservedPageActionAndDoesNotUseSearchResultURLs() throws {
        let search = action(#"{"type":"search","query":"AIM news","results":[{"url":"https://databricks.com/a"}]}"#)
        let first = try XCTUnwrap(WebActivityPresentation(action: search, locale: english))
        XCTAssertEqual(first.title, "Searching the web")
        XCTAssertEqual(first.subject, "AIM news")
        XCTAssertNil(first.url)
        let page = action(#"{"type":"open_page","url":"https://databricks.com/article?token=hidden#private"}"#)
        let second = try XCTUnwrap(WebActivityPresentation(action: page, locale: english))
        XCTAssertEqual(second.title, "Reading page")
        XCTAssertEqual(second.domain, "databricks.com")
        XCTAssertEqual(second.url?.absoluteString, "https://databricks.com/article")
    }

    func testActiveLineChangesOnlyWithARealRunningAction() throws {
        let search = action("AIM news")
        let finished = action(#"{"type":"open_page","url":"https://example.com/finished"}"#, state: .completed, ordinal: 2)
        XCTAssertEqual(WebActivityPresentation.active(in: [search, finished], locale: english)?.title, "Searching the web")
        let page = action(#"{"url":"https://example.com/now"}"#, ordinal: 3, name: "web_fetch")
        XCTAssertEqual(WebActivityPresentation.active(in: [search, finished, page], locale: english)?.title, "Reading page")
        XCTAssertNil(WebActivityPresentation.active(in: [finished], locale: english))
        XCTAssertNil(WebActivityPresentation(action: action("https://example.com", name: "read_file")))
    }

    func testTerminalFailureNeverClaimsSuccessfulVisit() {
        XCTAssertEqual(WebActivityPresentation(action: action(#"{"type":"open_page","url":"https://example.com"}"#, state: .failed), locale: english)?.title, "Web request failed")
        XCTAssertEqual(WebActivityPresentation(action: action("query", state: .cancelled), locale: english)?.title, "Web request cancelled")
        XCTAssertNil(WebActivityPresentation(action: action(#"{"type":"open_page","url":"https://user:password@example.com"}"#))?.url)
    }

    func testResponsesProgressRetainsActionMetadataAndTerminalState() throws {
        var tracker = NativeWebSearchTracker()
        let progress = tracker.consume(#"{"type":"response.web_search_call.in_progress","item_id":"s1","action":{"type":"open_page","url":"https://example.com/read"}}"#, provider: .openAI)
        let input = try XCTUnwrap(progress.first?.input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
        XCTAssertEqual(object["url"], "https://example.com/read")
        let completed = tracker.consume(#"{"type":"response.output_item.done","item":{"type":"web_search_call","id":"s1","action":{"type":"open_page","url":"https://example.com/read"}}}"#, provider: .openAI)
        XCTAssertEqual(completed.first?.status, .completed)
        let late = tracker.consume(#"{"type":"response.web_search_call.searching","item_id":"s1"}"#, provider: .openAI)
        XCTAssertEqual(late.first?.status, .completed)
        XCTAssertEqual(late.first?.input, completed.first?.input)
    }

    func testOpenRouterCitationDoesNotInventAVisitTimeline() {
        var tracker = NativeWebSearchTracker()
        XCTAssertTrue(tracker.consume(#"{"choices":[{"delta":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://databricks.com/a","title":"Article"}}]}}]}"#, provider: .openRouter).isEmpty)
    }
}
