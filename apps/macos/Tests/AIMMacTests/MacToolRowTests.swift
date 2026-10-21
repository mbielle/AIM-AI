import AIMCore
@testable import AIMMac
import XCTest

@MainActor
final class MacToolRowTests: XCTestCase {
    func testFailedOpeningAndSuccessfulRetryHaveDistinctTruthfulTitlesAndTargets() {
        let failed = action(.failed, app: "Calculatrice")
        let completed = action(.completed, app: "Calculator")
        let english = Locale(identifier: "en")
        XCTAssertEqual(MacToolRow.title(for: failed, locale: english), "Failed · Opening app")
        XCTAssertEqual(MacToolRow.title(for: completed, locale: english), "Opened app")
        XCTAssertEqual(MacToolRow.subject(for: failed), "Calculatrice")
        XCTAssertEqual(MacToolRow.subject(for: completed), "Calculator")
        XCTAssertEqual(failed.output, "No installed app named Calculatrice")
    }

    func testCancelledAndUnknownEffectsDoNotClaimSuccessIncludingSpecialTools() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(MacToolRow.title(for: action(.cancelled), locale: english), "Cancelled · Opening app")
        XCTAssertEqual(MacToolRow.title(for: action(.needsReview), locale: english), "Effect unknown · Opening app")
        var network = action(.failed)
        network.name = "network"
        XCTAssertTrue(MacToolRow.title(for: network, locale: english).hasPrefix("Failed · "))
        XCTAssertEqual(MacToolRow.title(for: action(.failed), locale: Locale(identifier: "fr")), "Échec · Ouverture d'une app")
    }

    func testWebRowsUseObservedPageInsteadOfRawAddressAndRetainFailure() {
        var web = action(.running)
        web.name = "web_search"
        web.input = #"{"type":"open_page","url":"https://databricks.com/a?tracking=1"}"#
        XCTAssertEqual(MacToolRow.title(for: web, locale: Locale(identifier: "en")), "Reading page")
        XCTAssertEqual(MacToolRow.subject(for: web), "databricks.com")
        web.state = .failed
        XCTAssertEqual(MacToolRow.title(for: web, locale: Locale(identifier: "en")), "Web request failed")
    }

    private func action(_ state: ConversationAction.State, app: String = "Calculator") -> ConversationAction {
        .init(id: UUID().uuidString, conversationID: UUID(), turnID: UUID(), ordinal: 0,
              name: "open_app", state: state, input: "{\"app\":\"\(app)\"}",
              output: state == .failed ? "No installed app named Calculatrice" : "Opened Calculator")
    }
}
