import AIMAgentKit
@testable import AIMMacPlatform
import XCTest

final class AgentDesktopToolTests: XCTestCase {
    override func setUp() { ScreenLockState.overrideForTesting = false }
    override func tearDown() { ScreenLockState.overrideForTesting = nil }

    func testTypingRequiresEditableFocusedControlInExactWindow() throws {
        XCTAssertNoThrow(try DesktopTypingPolicy.validate(roles: [("AXTextArea", ""), ("AXScrollArea", "")],
            enabled: true, editable: true, belongsToWindow: true))
        let rejected: [[(role: String, subrole: String)]] = [
            [("AXButton", "")], [("AXTextArea", ""), ("AXSheet", "")],
            [("AXTextField", ""), ("AXWindow", "AXDialog")],
            [("AXTextField", "AXSecureTextField")], [("AXSecureTextField", "")],
            [("AXTextField", ""), ("AXGroup", "AXPasswordGroup")], [("", "")]
        ]
        for roles in rejected {
            XCTAssertThrowsError(try DesktopTypingPolicy.validate(roles: roles,
                enabled: true, editable: true, belongsToWindow: true))
        }
        XCTAssertThrowsError(try DesktopTypingPolicy.validate(roles: [("AXTextArea", "")],
            enabled: false, editable: true, belongsToWindow: true))
        XCTAssertThrowsError(try DesktopTypingPolicy.validate(roles: [("AXTextArea", "")],
            enabled: true, editable: false, belongsToWindow: true))
        XCTAssertThrowsError(try DesktopTypingPolicy.validate(roles: [("AXTextArea", "")],
            enabled: true, editable: true, belongsToWindow: false))
    }

    func testTypingEffectUsesUTF16SelectionAndNeverGuessesInvalidRange() {
        XCTAssertEqual(DesktopTypingPolicy.expectedValue(before: "A🙂Z", selection: NSRange(location: 1, length: 2), text: "é"), "AéZ")
        XCTAssertEqual(DesktopTypingPolicy.expectedValue(before: "start", selection: NSRange(location: 5, length: 0), text: " fin"), "start fin")
        XCTAssertNil(DesktopTypingPolicy.expectedValue(before: "abc", selection: NSRange(location: NSNotFound, length: 0), text: "x"))
        XCTAssertNil(DesktopTypingPolicy.expectedValue(before: "abc", selection: NSRange(location: 1, length: Int.max), text: "x"))
        XCTAssertNil(DesktopTypingPolicy.expectedValue(before: "A🙂Z", selection: NSRange(location: 2, length: 1), text: "x"))
    }

    func testStopArrivingBeforeDesktopExecutionPreventsLaterAction() async {
        let service = AgentDesktopToolService()
        await service.cancel(requestID: "stopped-before-start")
        let result = await service.execute(ToolRequest(id: "stopped-before-start",
            name: "desktop_list_windows", arguments: [:], risk: .computerRead))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.localizedCaseInsensitiveContains("cancel"))
    }

    func testObservationBindsExactWindowAndRedactsSecureNodes() throws {
        let launch = Date(timeIntervalSince1970: 1_000)
        var window = DesktopWindow(id: 12, ownerPID: 88, applicationName: "Fixture",
            title: "Untitled", frame: CGRect(x: -900, y: 100, width: 600, height: 400))
        window.processLaunchedAt = launch
        let secure = AccessibilityNode(id: UUID(), role: "AXSecureTextField",
            title: "Password", value: "secret", isEnabled: true, depth: 1, isSecure: true)
        let observed = DesktopObservedNode(secure)
        XCTAssertNil(observed.title)
        XCTAssertNil(observed.value)
        XCTAssertTrue(observed.isSecure)

        let observation = DesktopObservation(id: UUID(), window: window, observedAt: launch,
            axObservedAt: launch, imageCapturedAt: launch.addingTimeInterval(1),
            targetVerifiedAt: launch.addingTimeInterval(2), imagePixelWidth: 1200,
            imagePixelHeight: 800, imageCoordinateOrigin: "top_left", axNodes: [observed],
            axCoverage: "bounded_AX_tree", ocrText: nil, warnings: [])
        XCTAssertTrue(observation.matches(window))
        XCTAssertTrue(observation.imageAvailable)
        var other = window
        other.id = 13
        XCTAssertFalse(observation.matches(other))
        other = window
        other.frame.origin.x += 1
        XCTAssertFalse(observation.matches(other))
        other = window
        other.processLaunchedAt = launch.addingTimeInterval(3)
        XCTAssertFalse(observation.matches(other))
        let encoded = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("Password"))
    }

    func testInventoryMergesBySystemIdentityAndKeepsSmallOffscreenWindows() {
        var cg = DesktopWindow(id: 2, ownerPID: 7, applicationName: "Fixture", title: "Dialog",
            frame: CGRect(x: -600, y: -300, width: 50, height: 30))
        cg.sources = ["core_graphics_all"]
        cg.isOnScreen = false
        var sck = cg
        sck.sources = ["screen_capture_kit"]
        sck.title = ""
        let duplicateTitle = DesktopWindow(id: 3, ownerPID: 7, applicationName: "Fixture", title: "Dialog", frame: cg.frame)
        let merged = DesktopInventory.merge([cg, duplicateTitle], [sck])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].title, "Dialog")
        XCTAssertEqual(merged[0].sources, ["core_graphics_all", "screen_capture_kit"])
        XCTAssertEqual(merged[0].isOnScreen, false)
        XCTAssertEqual(merged[0].frame.width, 50)
    }

    func testOCRFailureDoesNotDiscardPixels() async {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let result = await AgentDesktopToolService.screenshotPresentation(requestID: "capture", png: png) { _ in
            throw ScreenCaptureError.encodingFailed
        }
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.imagePNG, png)
        XCTAssertEqual(result.metadata["ocr"], "unavailable")
    }

    func testNegativeScreenCoordinatesAndRestartInvalidateCapture() throws {
        let frame = CGRect(x: -1200, y: -800, width: 800, height: 600)
        let launch = Date(timeIntervalSince1970: 100)
        var window = DesktopWindow(id: 4, ownerPID: 8, applicationName: "Fixture", title: "", frame: frame)
        window.processLaunchedAt = launch
        let capture = DesktopCaptureGeometry(windowID: 4, ownerPID: 8, frame: frame,
            pixelWidth: 1600, pixelHeight: 1200, processLaunchedAt: launch)
        XCTAssertEqual(try capture.globalPoint(x: 800, y: 600, current: window), CGPoint(x: -800, y: -500))
        window.processLaunchedAt = launch.addingTimeInterval(1)
        XCTAssertThrowsError(try capture.globalPoint(x: 800, y: 600, current: window))
    }

    func testWindowEnumerationCannotSilentlyReportAnEmptyDesktop() throws {
        XCTAssertThrowsError(try MacAccessibilityService.externalWindows([], excludingPID: 12)) { error in
            guard case MacAccessibilityError.noExternalWindows = error else {
                return XCTFail("Expected an explicit inconclusive-enumeration error, got \(error)")
            }
        }
        let own = DesktopWindow(id: 1, ownerPID: 12, applicationName: "AIM", title: "Chat",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertThrowsError(try MacAccessibilityService.externalWindows([own], excludingPID: 12))
        let other = DesktopWindow(id: 2, ownerPID: 13, applicationName: "TextEdit", title: "Document",
            frame: CGRect(x: 50, y: 50, width: 800, height: 600))
        XCTAssertEqual(try MacAccessibilityService.externalWindows([own, other], excludingPID: 12), [other])
    }

    func testScreenshotPixelsMapToWindowAndRejectMovedOrExpiredTarget() throws {
        let captured = Date(timeIntervalSince1970: 1_000)
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        let window = DesktopWindow(id: 42, ownerPID: 91, applicationName: "Test", title: "Document", frame: frame)
        let geometry = DesktopCaptureGeometry(windowID: 42, ownerPID: 91, frame: frame,
            pixelWidth: 1_600, pixelHeight: 1_200, capturedAt: captured)
        let point = try geometry.globalPoint(x: 800, y: 600, current: window,
            now: captured.addingTimeInterval(10))
        XCTAssertEqual(point.x, 500)
        XCTAssertEqual(point.y, 500)
        XCTAssertThrowsError(try geometry.globalPoint(x: 1_600, y: 10, current: window,
            now: captured.addingTimeInterval(10)))
        XCTAssertThrowsError(try geometry.globalPoint(x: 10, y: 10, current: window,
            now: captured.addingTimeInterval(61)))
        var moved = window
        moved.frame.origin.x += 3
        XCTAssertThrowsError(try geometry.globalPoint(x: 10, y: 10, current: moved,
            now: captured.addingTimeInterval(10)))
        moved = window
        moved.ownerPID += 1
        XCTAssertThrowsError(try geometry.globalPoint(x: 10, y: 10, current: moved,
            now: captured.addingTimeInterval(10)))
    }

    func testKeyWhitelistAndCoordinateToolsRequireExactApproval() async {
        XCTAssertEqual(MacDesktopInputService.keyCode(for: "Return"), 36)
        XCTAssertEqual(MacDesktopInputService.keyCode(for: "left"), 123)
        XCTAssertEqual(MacDesktopInputService.keyCode(for: "F12"), 111)
        XCTAssertNil(MacDesktopInputService.keyCode(for: "volumeUp"))
        let service = AgentDesktopToolService()
        XCTAssertTrue(service.supportedTools.isSuperset(of: ["desktop_click", "desktop_move",
            "desktop_drag", "desktop_scroll", "desktop_type", "desktop_key"]))
        XCTAssertTrue(ApprovalPolicy.autoApprove.requiresApproval(for: .computerAction))
        XCTAssertFalse(ApprovalPolicy.autoApprove.requiresApproval(for: .computerRead))
        XCTAssertTrue(ApprovalPolicy.alwaysAsk.requiresApproval(for: .computerRead))
        let noCapture = await service.execute(ToolRequest(name: "desktop_click",
            arguments: ["window_id": "0", "x": "1", "y": "1"], risk: .computerAction))
        XCTAssertTrue(noCapture.isError)
    }

    func testSecureFieldsAreRecognizedAndNotActionableWithoutFreshRead() async {
        XCTAssertTrue(ApprovalPolicy.autoApprove.requiresApproval(for: .computerAction))
        XCTAssertTrue(ApprovalPolicy.autoApprove.requiresApproval(for: .sensitiveRead))
        XCTAssertTrue(MacAccessibilityService.isSecureRole(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(MacAccessibilityService.isSecureRole(role: "password", subrole: ""))
        XCTAssertFalse(MacAccessibilityService.isSecureRole(role: "AXButton", subrole: ""))
        let service = AgentDesktopToolService()
        let result = await service.execute(ToolRequest(name: "desktop_set_value",
            arguments: ["node_id": UUID().uuidString, "value": "secret"], risk: .externalEffect))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.localizedCaseInsensitiveContains("stale"))
    }

    func testWindowListingIsCompactWithoutSystemProcessesAndFiltersByQuery() {
        var text = DesktopWindow(id: 34258, ownerPID: 10, applicationName: "TextEdit", title: "Untitled", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        text.isOnScreen = true
        let dock = DesktopWindow(id: 1, ownerPID: 2, applicationName: "Dock", title: "", frame: CGRect(x: 0, y: 0, width: 1500, height: 900))
        let menu = DesktopWindow(id: 3, ownerPID: 11, applicationName: "Safari", title: "", frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        var safari = DesktopWindow(id: 4, ownerPID: 11, applicationName: "Safari", title: "Apple", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        safari.isOnScreen = false
        let apps = [DesktopApplication(pid: 10, name: "TextEdit", bundleID: nil, isActive: true, isHidden: false, launchedAt: nil),
                    DesktopApplication(pid: 11, name: "Safari", bundleID: nil, isActive: false, isHidden: false, launchedAt: nil),
                    DesktopApplication(pid: 12, name: "Mail", bundleID: nil, isActive: false, isHidden: false, launchedAt: nil),
                    DesktopApplication(pid: 2, name: "Dock", bundleID: nil, isActive: false, isHidden: false, launchedAt: nil)]
        let inventory = DesktopInventory(applications: apps, windows: [text, dock, menu, safari], warnings: [], axWindows: [])
        let listing = inventory.compactListing()
        XCTAssertTrue(listing.contains("- 34258 | TextEdit | \"Untitled\" | frontmost app, on screen | 800×600"), listing)
        XCTAssertTrue(listing.contains("- 4 | Safari | \"Apple\""))
        XCTAssertFalse(listing.contains("Dock |"), "system processes are left out")
        XCTAssertTrue(listing.contains("Other running apps (no listed window): Mail"))
        XCTAssertLessThan(listing.utf8.count, 600)
        let filtered = inventory.compactListing(query: "textedit")
        XCTAssertTrue(filtered.contains("34258")); XCTAssertFalse(filtered.contains("Safari"))
    }
}
