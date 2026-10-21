@testable import AIMApplication
import XCTest

final class AppPreferencesTests: XCTestCase {
    func testOlderSettingsDecodeWithTodaysBehavior() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()))
        XCTAssertNil(settings.preferences)
        // A partial preferences object keeps every other default.
        let partial = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"sendWithCommandReturn":true,"accent":"pink","unknown":1}"#.utf8))
        XCTAssertTrue(partial.sendWithCommandReturn)
        XCTAssertEqual(partial.accent, .pink)
        XCTAssertEqual(partial.followUp, .steer)
        XCTAssertEqual(partial.defaultApprovalPolicy, "alwaysAsk")
        XCTAssertFalse(partial.preventSleepWhileRunning)
        XCTAssertTrue(partial.showInMenuBar)
        XCTAssertTrue(partial.showContextGauge)
        // A wrong type for one key does not lose the others.
        let wrong = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"followUp":"sideways","notifyQuestions":false}"#.utf8))
        XCTAssertEqual(wrong.followUp, .steer)
        XCTAssertFalse(wrong.notifyQuestions)
        var full = AppPreferences()
        full.modeDefaults["agent"] = { var value = AppPreferences.ModeDefaults(); value.effort = "high"; value.shownEfforts = ["low", "high"]; return value }()
        full.shortcuts["newChat"] = .init(key: "k", command: true, shift: true)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(full)), full)
        XCTAssertEqual(full.shortcuts["newChat"]?.display, "⇧⌘K")
    }

    func testTranslucentSidebarDefaultsForNewAndMissingPreferences() throws {
        XCTAssertTrue(AppPreferences().translucentSidebar)
        let legacy = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"accent":"purple"}"#.utf8))
        XCTAssertTrue(legacy.translucentSidebar)
        XCTAssertEqual(legacy.accent, .purple)
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()))
        XCTAssertTrue((settings.preferences ?? AppPreferences()).translucentSidebar)
    }

    func testExplicitSidebarChoicesSurviveDecodeAndSettingsRoundTrip() throws {
        for choice in [false, true] {
            let data = try JSONSerialization.data(withJSONObject: ["translucentSidebar": choice, "pointerCursors": true])
            let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
            XCTAssertEqual(preferences.translucentSidebar, choice)
            XCTAssertTrue(preferences.pointerCursors)
            var settings = AppSettings()
            settings.preferences = preferences
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored.preferences?.translucentSidebar, choice)
            XCTAssertEqual(restored.preferences?.pointerCursors, true)
        }
    }

    func testNotificationRules() {
        var prefs = AppPreferences()
        XCTAssertTrue(prefs.allowsNotification(.completion, appActive: false))
        XCTAssertFalse(prefs.allowsNotification(.completion, appActive: true))
        XCTAssertFalse(prefs.allowsNotification(.approval, appActive: true))
        XCTAssertTrue(prefs.allowsNotification(.approval, appActive: false))
        // Unattended work is reported even while AIM is in front.
        XCTAssertTrue(prefs.allowsNotification(.automation, appActive: true))
        XCTAssertTrue(prefs.allowsNotification(.remote, appActive: true))
        prefs.completionNotifications = .never
        XCTAssertFalse(prefs.allowsNotification(.completion, appActive: false))
        prefs.completionNotifications = .always
        XCTAssertTrue(prefs.allowsNotification(.completion, appActive: true))
        XCTAssertTrue(prefs.allowsNotification(.question, appActive: true))
        prefs.notifyQuestions = false
        prefs.notifyAutomations = false
        XCTAssertFalse(prefs.allowsNotification(.question, appActive: false))
        XCTAssertFalse(prefs.allowsNotification(.automation, appActive: false))
    }

    func testGlobalAgentInstructionsComeFirstEvenWithoutAWorkspace() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let global = folder.appending(path: "AGENTS.md")
        try Data("Always answer in French.".utf8).write(to: global)
        let workspace = folder.appending(path: "repo")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("Use tabs.".utf8).write(to: workspace.appending(path: "AGENTS.md"))

        let alone = try XCTUnwrap(ProjectInstructionsContext.message(workspace: nil, conversationID: UUID(), globalFile: global))
        XCTAssertTrue(alone.content.contains("Always answer in French."))
        let both = try XCTUnwrap(ProjectInstructionsContext.message(workspace: workspace.path, conversationID: UUID(), globalFile: global))
        let globalRange = try XCTUnwrap(both.content.range(of: "Always answer in French."))
        let projectRange = try XCTUnwrap(both.content.range(of: "Use tabs."))
        XCTAssertLessThan(globalRange.lowerBound, projectRange.lowerBound)
        XCTAssertNil(ProjectInstructionsContext.message(workspace: nil, conversationID: UUID(), globalFile: folder.appending(path: "missing.md")))
    }
}
