import AppKit
import ApplicationServices
import Foundation

/// Explicit debug-build qualification. Only the dedicated fixture can be captured
/// or changed. Reports never contain user window titles, AX text or screenshots.
public enum DesktopFixtureQualification {
    public static func report() async -> Data {
        let accessibility = MacAccessibilityService()
        let inventory = await accessibility.inventory()
        let fixturePIDs = Set(inventory.applications.filter {
            $0.bundleID == "com.aimai.macos.agent-fixture"
        }.map(\.pid))
        var checks: [[String: String]] = []
        for window in inventory.windows where fixturePIDs.contains(window.ownerPID) {
            var result = ["window_id": String(window.id), "sources": window.sources.sorted().joined(separator: ","),
                          "on_screen": window.isOnScreen.map(String.init) ?? "unknown",
                          "small_window": String(window.frame.width <= 80 || window.frame.height <= 60)]
            do {
                let nodes = try await accessibility.readWindow(window)
                result["ax_nodes"] = String(nodes.count)
                func counter(_ nodes: [AccessibilityNode]) -> Int? {
                    for node in nodes {
                        for text in [node.title, node.value].compactMap({ $0 }) where text.hasPrefix("Count: ") {
                            if let value = Int(text.dropFirst(7)) { return value }
                        }
                    }
                    return nil
                }
                if let before = counter(nodes), let button = nodes.first(where: { $0.role == "AXButton" && $0.title == "Increment" }) {
                    try await accessibility.perform(.press, nodeID: button.id)
                    let after = try await accessibility.readWindow(window)
                    result["fixture_increment_verified"] = String(counter(after) == before + 1)
                }
            } catch { result["ax_error"] = error.localizedDescription }
            do {
                let image = try await MacScreenCaptureService().captureWithGeometry(windowID: window.id)
                result["capture_pixels"] = "\(image.pixelWidth)x\(image.pixelHeight)"
                result["capture_bytes"] = String(image.png.count)
            } catch { result["capture_error"] = error.localizedDescription }
            checks.append(result)
        }
        let report: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundle": Bundle.main.bundleURL.path,
            "accessibility_granted": AXIsProcessTrusted(),
            "screen_recording_granted": CGPreflightScreenCaptureAccess(),
            "application_count": inventory.applications.count,
            "window_count": inventory.windows.count,
            "fixture_window_count": checks.count,
            "fixture_checks": checks,
            "coverage": inventory.coverage,
            "warning_count": inventory.warnings.count,
            "limitations": "This fixture check does not qualify background gestures, Spaces, human priority or CUA. No images or user window content persisted."
        ]
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
