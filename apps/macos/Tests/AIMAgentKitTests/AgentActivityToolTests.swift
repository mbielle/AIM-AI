import AIMAgentKit
import AIMApplication
import XCTest

final class AgentActivityToolTests: XCTestCase {
    func testOptInAndCurrentPrivacyRulesAreEnforced() async throws {
        let database = try AIMDatabase(inMemory: true)
        let activity = SQLiteActivityRepository(database: database)
        try await activity.record(ActivityEntry(application: "Xcode", title: "keyword project", startedAt: .now, endedAt: .now))
        try await activity.record(ActivityEntry(application: "1Password", title: "keyword vault", startedAt: .now, endedAt: .now))
        try await activity.record(ActivityEntry(application: "Notes", title: "keyword note", startedAt: .now, endedAt: .now))
        let request = ToolRequest(name: "search_activity", arguments: ["query": "keyword"], risk: .sensitiveRead)

        let off = await AgentActivityToolService(repository: activity, settings: ActivitySettings(isEnabled: false)).execute(request)
        XCTAssertTrue(off.isError)
        let on = await AgentActivityToolService(repository: activity,
            settings: ActivitySettings(isEnabled: true, excludedApplications: ["Notes"])).execute(request)
        XCTAssertTrue(on.content.contains("Xcode"))
        XCTAssertFalse(on.content.contains("1Password"))
        XCTAssertFalse(on.content.contains("Notes"))
        XCTAssertFalse(on.content.contains("project"), "Window titles must never be returned")
    }

    func testDisablingActivityRevokesAlreadyAdvertisedTool() async throws {
        let database = try AIMDatabase(inMemory: true)
        let activity = SQLiteActivityRepository(database: database)
        try await activity.record(ActivityEntry(application: "Xcode", title: "keyword", startedAt: .now, endedAt: .now))
        let settings = MutableActivitySettings()
        let tool = AgentActivityToolService(repository: activity, settingsRepository: settings)
        let request = ToolRequest(name: "search_activity", arguments: ["query": "keyword"], risk: .sensitiveRead)
        let allowed = await tool.execute(request)
        XCTAssertTrue(allowed.content.contains("Xcode"))
        await settings.disable()
        let revoked = await tool.execute(request)
        XCTAssertTrue(revoked.isError)
        XCTAssertFalse(revoked.content.contains("Xcode"))
    }
}

private actor MutableActivitySettings: SettingsRepository {
    private var value = AppSettings(activity: ActivitySettings(isEnabled: true))
    func load() -> AppSettings { value }
    func save(_ settings: AppSettings) { value = settings }
    func disable() { value.activity.isEnabled = false }
}
