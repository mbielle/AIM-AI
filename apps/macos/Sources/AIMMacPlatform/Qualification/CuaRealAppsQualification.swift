#if DEBUG
import AIMAgentKit
import AIMApplication
import AppKit
import Foundation

/// The model-facing background tools on real apps (no model): Calculator
/// (clicks, result read back), TextEdit on a temporary file (typing and
/// replacing text) and a Chrome tab on a local page (a click in web content).
/// Every case also checks that the target app never became active. Only what
/// the suite opened is closed; nothing personal is read or changed.
public enum CuaRealAppsQualification {
    public static func run(into report: QualificationReport, qualified: [CuaCapability: String], apps: Set<String>) async {
        guard qualified[.observe] != nil, qualified[.axClick] != nil else {
            report.set("conclusion", "Run cua-ladder first: observe and ax_click must be qualified for this driver and macOS build.")
            return
        }
        guard !ScreenLockState.isLocked else {
            report.set("conclusion", "not run: the screen is locked; unlock the Mac and rerun")
            return
        }
        let service = AgentCuaToolService(qualified: qualified, modelSeesImages: false)
        var results: [String: Any] = [:]
        if apps.contains("calculator") { results["calculator"] = await calculator(service) }
        if apps.contains("textedit") { results["textedit"] = await textEdit(service, typing: qualified[.typeText] != nil,
                                                                           setting: qualified[.setValue] != nil) }
        if apps.contains("chrome") { results["chrome"] = await chrome(service) }
        await service.closeSession()
        report.set("apps", results)
        let failed = results.compactMap { name, value -> String? in
            ((value as? [String: Any])?["passed"] as? Bool) == true ? nil : name
        }.sorted()
        report.set("conclusion", failed.isEmpty ? "all real-app cases passed (\(results.count))" : "failed: \(failed.joined(separator: ", "))")
    }

    // MARK: Apps

    @MainActor
    private static func launch(bundleID: String, opening file: URL? = nil) async -> NSRunningApplication? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        if let file {
            return try? await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration)
        }
        return try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private static func calculator(_ service: AgentCuaToolService) async -> [String: Any] {
        let bundle = "com.apple.calculator"
        let wasRunning = await isRunning(bundle)
        guard let app = await launch(bundleID: bundle) else { return ["passed": false, "error": "Calculator could not start"] }
        try? await Task.sleep(for: .seconds(2))
        var steps: [String: Bool] = [:]
        var notes: [String: String] = [:]
        guard let ref = await windowRef(service, apps: ["Calculator", "Calculatrice", "Calculette"]) else {
            await cleanup(app, launched: !wasRunning)
            return ["passed": false, "error": "no Calculator window on the current Space"]
        }
        let sequence: [[String]] = [["all clear", "effacer tout", "ac", "clear", "effacer", "c"], ["7"], ["multiply", "multiplier", "×", "*"],
                                    ["6"], ["equals", "égal", "egal", "="]]
        var clicks = 0
        for (offset, labels) in sequence.enumerated() {
            let observation = await observe(service, ref)
            guard let observation, let index = observation.index(matching: labels) else {
                if offset == 0 { continue } // no clear key in this layout
                notes["missing_\(offset)"] = "no button matching \(labels.first!)"
                notes["elements"] = observation.map { "\($0.elements.count) elements; limitation: \($0.limitation); " + $0.summary } ?? "no observation"
                break
            }
            let click = await call(service, "bg_click", ["observation_id": observation.id, "element_index": String(index)])
            if click.isError { notes["click_\(offset)"] = String(click.content.prefix(300)); break }
            clicks += 1
        }
        try? await Task.sleep(for: .milliseconds(500))
        // The visible AI cursor should be on screen next to the last button pressed.
        let cursor = await MainActor.run { AgentBackgroundCursor.shared.debugState }
        steps["ai_cursor_visible"] = cursor.visible
        notes["ai_cursor_frame"] = cursor.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"
        if let image = await ComputerUseActivity.captureMainDisplay(containing: cursor.frame.map { CGPoint(x: $0.midX, y: $0.midY) }) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("aim-cursor-\(UUID().uuidString.prefix(6)).png")
            if (try? image.write(to: file)) != nil { notes["screen_capture"] = file.path }
        }
        let final = await observe(service, ref)
        steps["clicked_7_times_6_equals"] = clicks >= 4
        steps["result_42_read_back"] = final?.outline.contains("42") == true
        steps["never_activated"] = !app.isActive
        notes["outline_excerpt"] = String(final?.outline.prefix(400) ?? "")
        await cleanup(app, launched: !wasRunning)
        return ["passed": steps.values.allSatisfy { $0 }, "steps": steps, "notes": notes]
    }

    private static func textEdit(_ service: AgentCuaToolService, typing: Bool, setting: Bool) async -> [String: Any] {
        let bundle = "com.apple.TextEdit"
        guard !(await isRunning(bundle)) else {
            return ["passed": false, "error": "TextEdit is already open; close it so the suite can use and then quit its own document"]
        }
        let name = "AIM-CUA-\(UUID().uuidString.prefix(6)).txt"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? "Hello from the fixture.\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let app = await launch(bundleID: bundle, opening: file) else { return ["passed": false, "error": "TextEdit could not start"] }
        try? await Task.sleep(for: .seconds(2))
        var steps: [String: Bool] = [:]
        var notes: [String: String] = [:]
        guard let ref = await windowRef(service, apps: ["TextEdit"], title: name) else {
            await cleanup(app, launched: true)
            return ["passed": false, "error": "no TextEdit window for the test file"]
        }
        if typing, let observation = await observe(service, ref), let area = observation.index(role: "AXTextArea") {
            let typed = await call(service, "bg_type_text", ["observation_id": observation.id, "element_index": String(area),
                                                             "text": " AIM é 日本語"])
            notes["type"] = String(typed.content.prefix(200))
            try? await Task.sleep(for: .milliseconds(400))
            let after = await observe(service, ref)
            steps["typed_text_read_back"] = !typed.isError && (after?.text(ofRole: "AXTextArea")?.contains("AIM é 日本語") == true)
        }
        if setting, let observation = await observe(service, ref), let area = observation.index(role: "AXTextArea") {
            let set = await call(service, "bg_set_value", ["observation_id": observation.id, "element_index": String(area),
                                                           "value": "Replaced by AIM"])
            notes["set"] = String(set.content.prefix(200))
            try? await Task.sleep(for: .milliseconds(400))
            let after = await observe(service, ref)
            steps["set_value_read_back"] = !set.isError && after?.text(ofRole: "AXTextArea")?.hasPrefix("Replaced by AIM") == true
        }
        steps["never_activated"] = !app.isActive
        await cleanup(app, launched: true)
        return ["passed": !steps.isEmpty && steps.values.allSatisfy { $0 }, "steps": steps, "notes": notes]
    }

    private static func chrome(_ service: AgentCuaToolService) async -> [String: Any] {
        let bundle = "com.google.Chrome"
        guard await isRunning(bundle) else {
            return ["passed": false, "error": "Chrome is not running; the suite only adds a tab to an open Chrome"]
        }
        guard let server = try? await FixtureHTTPServer.start(page: BrowserIsolatedQualification.page) else {
            return ["passed": false, "error": "local page server failed"]
        }
        defer { server.stop() }
        let previous = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        // Reuse a test tab already showing the page (opening one makes Chrome activate itself).
        let existing = await windowRef(service, apps: ["Google Chrome"], title: "AIM fixture", attempts: 1)
        let app: NSRunningApplication
        if existing != nil, let running = await MainActor.run(body: { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first }) {
            app = running
        } else {
            guard let url = URL(string: "http://127.0.0.1:\(server.port)/fixture.html"),
                  let opened = await launch(bundleID: bundle, opening: url) else { return ["passed": false, "error": "Chrome could not open the page"] }
            app = opened
            try? await Task.sleep(for: .seconds(3))
        }
        // Chrome activates itself to show an opened URL, and macOS does not let a
        // background app hand the focus back. Wait (up to 45 s) for the person to
        // switch to another app, then clear the alert our own setup caused.
        var setupActivated = false
        for _ in 0..<45 {
            let active = await MainActor.run { app.isActive }
            if !active { break }
            setupActivated = true
            try? await Task.sleep(for: .seconds(1))
        }
        if setupActivated { await CuaTargetLeaseCoordinator.shared.clearHumanConflict(pid: app.processIdentifier) }
        if await MainActor.run(body: { app.isActive }) {
            return ["passed": false, "error": "Chrome stayed in front; switch to another app after the test tab opens"]
        }
        _ = previous
        var steps: [String: Bool] = [:]
        var notes: [String: String] = [:]
        guard let ref = await windowRef(service, apps: ["Google Chrome"], title: "AIM fixture") else {
            return ["passed": false, "error": "no Chrome window showing the local page on the current Space (it may be behind another tab)"]
        }
        let observation = await observe(service, ref)
        steps["web_content_observable"] = observation?.index(matching: ["incrémenter"]) != nil
        if let observation, let button = observation.index(matching: ["incrémenter"]) {
            let click = await call(service, "bg_click", ["observation_id": observation.id, "element_index": String(button)])
            notes["click"] = String(click.content.prefix(200))
            try? await Task.sleep(for: .milliseconds(600))
            let after = await observe(service, ref)
            steps["click_changed_page"] = !click.isError && (after?.title.contains("Count 1") == true || after?.outline.contains("Count 1") == true)
        } else {
            notes["elements"] = observation.map { String($0.summary.prefix(600)) } ?? "no observation"
        }
        steps["never_activated"] = !app.isActive
        notes["setup_activated_chrome"] = setupActivated ? "yes (waited for the person to switch apps)" : "no"
        notes["cleanup"] = "the test tab stays open in Chrome; close it when convenient"
        return ["passed": steps.values.allSatisfy { $0 }, "steps": steps, "notes": notes]
    }

    // MARK: Helpers

    struct Observation {
        let id: String
        let title: String
        let outline: String
        let elements: [[String: Any]]
        var limitation: String = ""

        func index(matching labels: [String]) -> Int? {
            let wanted = Set(labels.map { $0.lowercased() })
            return elements.first { wanted.contains(($0["label"] as? String ?? "").lowercased()) }?["index"] as? Int
        }
        func index(role: String) -> Int? { elements.first { $0["role"] as? String == role }?["index"] as? Int }
        func text(ofRole role: String) -> String? { elements.first { $0["role"] as? String == role }?["value"] as? String }
        var summary: String {
            elements.prefix(40).map { "\($0["role"] ?? "")|\($0["label"] ?? "")" }.joined(separator: ", ")
        }
    }

    private static func call(_ service: AgentCuaToolService, _ name: String, _ arguments: [String: String]) async -> ToolResult {
        await service.execute(ToolRequest(name: name, arguments: arguments,
                                          risk: name == "bg_observe_window" || name == "bg_list_windows" ? .computerRead : .computerAction))
    }

    private static func observe(_ service: AgentCuaToolService, _ ref: String) async -> Observation? {
        let result = await call(service, "bg_observe_window", ["window_ref": ref])
        guard let data = result.content.split(separator: "\n").first.flatMap({ $0.data(using: .utf8) }) ?? result.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["observation_id"] as? String else { return nil }
        return Observation(id: id, title: object["title"] as? String ?? "", outline: object["outline"] as? String ?? "",
                           elements: object["elements"] as? [[String: Any]] ?? [], limitation: object["limitation"] as? String ?? "")
    }

    private static func windowRef(_ service: AgentCuaToolService, apps: [String], title: String? = nil,
                                  attempts: Int = 5) async -> String? {
        for _ in 0..<attempts {
            let listed = await call(service, "bg_list_windows", [:])
            if let data = listed.content.split(separator: "\n").first.flatMap({ $0.data(using: .utf8) }),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let windows = object["windows"] as? [[String: Any]],
               let match = windows.first(where: { window in
                   apps.contains(window["app"] as? String ?? "") &&
                       (title == nil || (window["title"] as? String ?? "").contains(title!))
               }) {
                return match["window_ref"] as? String
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    @MainActor
    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @MainActor
    private static func cleanup(_ app: NSRunningApplication, launched: Bool) {
        // Only an app the suite started is quit; its test document is discarded.
        if launched { app.forceTerminate() }
    }
}
#endif
