import AIMApplication
import XCTest

final class WorkspaceRecentsTests: XCTestCase {
    func testRecentFoldersDeduplicateMoveToFrontAndRemainBounded() throws {
        var settings = AppSettings()
        XCTAssertNil(settings.recentWorkspacePaths)
        for index in 0..<10 { settings.rememberWorkspace("/work/project-\(index)") }
        XCTAssertEqual(settings.recentWorkspacePaths?.count, 8)
        XCTAssertEqual(settings.recentWorkspacePaths?.first, "/work/project-9")
        XCTAssertFalse(settings.recentWorkspacePaths?.contains("/work/project-0") ?? true)
        settings.rememberWorkspace("/work/project-5")
        XCTAssertEqual(settings.recentWorkspacePaths?.first, "/work/project-5")
        XCTAssertEqual(settings.recentWorkspacePaths?.filter { $0 == "/work/project-5" }.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testOlderSettingsDecodeWithoutRecents() throws {
        let older = Data(#"{"launchAtLogin":false,"selectedMode":"chat","activity":{"isEnabled":false,"retentionDays":30,"excludedApplications":[],"excludedDomains":[]}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: older)
        XCTAssertNil(decoded.recentWorkspacePaths)
    }
}
