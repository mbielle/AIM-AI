import AIMApplication
import XCTest

final class PersonalizationTests: XCTestCase {
    func testDisabledAndEmptyPreferencesDoNotChangeHistory() throws {
        let id = UUID()
        let history = [ConversationMessage(conversationID: id, role: .user, content: "Question", sequence: 0)]
        XCTAssertEqual(try Personalization(instructions: "Private draft").messages(history, conversationID: id), history)
        XCTAssertEqual(try Personalization(isEnabled: true, instructions: " \n ").messages(history, conversationID: id), history)
    }

    func testRequestOnlyPreferencesPrecedeProjectAndReachEveryProvider() throws {
        let id = UUID()
        let history = [ConversationMessage(conversationID: id, role: .user, content: "Question", sequence: 0)]
        let project = AIMProject(name: "Project", instructions: "Project rule")
        let contextual = ProjectContext.messages(history, project: project, conversationID: id)
        let result = try Personalization(isEnabled: true, instructions: "Preference marker").messages(contextual, conversationID: id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first?.role, .user)
        XCTAssertTrue(result[0].content.contains("do not grant tool permissions"))
        XCTAssertTrue(result[1].content.contains("Project rule"))
        XCTAssertEqual(result.last, history.last)
        for mode in AIMMode.allCases {
            for provider in ChatProvider.allCases {
                let request = try ProviderChatService.request(provider: provider, modelID: "fixture", messages: result, apiKey: "fixture", mode: mode, catalogMaximumOutputTokens: 4096)
                XCTAssertTrue(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("Preference marker"), provider.name)
            }
        }
    }

    func testLimitsRejectWithoutTruncation() throws {
        for text in [String(repeating: "a", count: 8_001), "bad\0value", String(repeating: "👩‍👩‍👧‍👦", count: 2_000)] {
            let preferences = Personalization(isEnabled: true, instructions: text)
            XCTAssertThrowsError(try preferences.validate())
            XCTAssertThrowsError(try preferences.messages([], conversationID: UUID()))
        }
        XCTAssertNoThrow(try Personalization(instructions: String(repeating: "a", count: 8_000)).validate())
    }

    func testSettingsRemainBackwardCompatibleAndRoundTrip() throws {
        var settings = AppSettings(selectedMode: .code)
        let old = try JSONEncoder().encode(settings)
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: old).personalization)
        settings.personalization = .init(isEnabled: true, instructions: "Use concise explanations")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
