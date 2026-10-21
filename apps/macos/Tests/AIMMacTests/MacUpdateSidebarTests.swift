import AIMMacPlatform
@testable import AIMMac
import XCTest

@MainActor
final class MacUpdateSidebarTests: XCTestCase {
    func testSidebarOnlyOffersAnAvailableUpdateAndKeepsItsFrenchLabel() throws {
        XCTAssertNil(AppModel.updateSidebarTitle(for: .unavailable))
        var available = try XCTUnwrap(AppModel.updateSidebarTitle(for: .available(version: "0.2")))
        available.locale = Locale(identifier: "fr")
        XCTAssertEqual(String(localized: available), "Mise à jour disponible")
        // Background checks can last or be paused; they never occupy a sidebar row.
        XCTAssertNil(AppModel.updateSidebarTitle(for: .checking))
    }

    func testHourlyDefaultIsPlistConfigurationWithDownloadsStillOptIn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Config/Info.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(dictionary["SUScheduledCheckInterval"] as? Int, 3600)
        XCTAssertEqual(dictionary["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(dictionary["SUAutomaticallyUpdate"] as? Bool, false)
    }
}
