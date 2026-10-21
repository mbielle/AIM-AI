@testable import AIMMacPlatform
import Foundation
import XCTest

final class AgentBrowserConfigurationTests: XCTestCase {
    func testExtensionModeNeverCollectsPageTools() {
        let arguments = AgentBrowserConfiguration(mode: .extensionConnected).serverArguments
        XCTAssertEqual(arguments, ["--extension", "--no-webmcp"])
    }

    func testIsolatedModeUsesInMemoryProfileAndPrivateRecords() {
        let directory = URL(fileURLWithPath: "/tmp/aim-session")
        let visible = AgentBrowserConfiguration(mode: .isolated, outputDirectory: directory).serverArguments
        XCTAssertTrue(visible.contains("--isolated"))
        XCTAssertTrue(visible.contains("--no-webmcp"))
        XCTAssertFalse(visible.contains("--extension"))
        XCTAssertFalse(visible.contains("--headless"), "Agent runs show the isolated browser")
        XCTAssertEqual(visible[visible.firstIndex(of: "--output-dir")! + 1], directory.path)
        XCTAssertTrue(visible.contains("--save-session"))
        let unattended = AgentBrowserConfiguration(mode: .isolated, headless: true).serverArguments
        XCTAssertTrue(unattended.contains("--headless"))
        XCTAssertFalse(unattended.contains("--output-dir"))
    }
}
