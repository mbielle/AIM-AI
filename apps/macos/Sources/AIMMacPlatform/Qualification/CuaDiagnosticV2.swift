#if DEBUG
import AIMAgentKit
import AppKit
import CoreGraphics
import Foundation

/// No-gesture CUA diagnostic for the disposable fixture. It records the exact
/// driver contract, launch/signing facts and how both the daemon and AIM see
/// the fixture windows, so the observation failure can be attributed before
/// any adapter change. It never calls an input tool and never reads another app.
public enum CuaDiagnosticV2 {
    static let contractTools = [
        "get_window_state", "click", "list_windows", "type_text", "set_value", "scroll",
        "press_key", "hotkey", "verify_state", "get_accessibility_tree", "list_apps",
        "check_permissions", "health_report"
    ]
    static let inputTools: Set<String> = [
        "click", "double_click", "right_click", "type_text", "set_value", "scroll", "press_key",
        "hotkey", "drag", "mouse_drag", "move_cursor", "launch_app", "kill_app", "invoke_menu",
        "bring_to_front", "set_window_frame"
    ]

    public static func run(into report: QualificationReport) async {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        report.set("aim_instance_count",
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }.count)
        let fixtures = FixtureAccessibilityProbe.fixtureApplications()
        report.set("fixture_instance_count", fixtures.count)
        let facts = await MainActor.run { () -> (Int, Bool, String, Bool, Bool) in
            let frontmost = NSWorkspace.shared.frontmostApplication
            let category: String
            if frontmost?.processIdentifier == getpid() { category = "aim" }
            else if frontmost?.bundleIdentifier == FixtureAccessibilityProbe.fixtureBundleID { category = "fixture" }
            else { category = frontmost == nil ? "none" : "other" }
            return (NSScreen.screens.count, NSApp.windows.contains { $0.styleMask.contains(.fullScreen) },
                    category, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess())
        }
        let environment: [String: Any] = [
            "screen_count": facts.0, "aim_fullscreen_window": facts.1, "frontmost": facts.2,
            "ax_trusted_in_aim": facts.3, "screen_capture_preflight_in_aim": facts.4]
        report.set("environment", environment)

        guard let executable = HostBundleResources.resourceURL?.appendingPathComponent("CuaDriver/cua-driver"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            report.set("conclusion", "The pinned driver is not bundled.")
            return
        }
        report.set("driver_sha256", QualificationReport.sha256(fileAt: executable) ?? "")
        report.set("driver_signing", QualificationReport.signingFacts(path: executable))
        report.set("driver_help", [
            "root": helperOutput(executable, ["--help"], bundleID: bundleID),
            "serve": helperOutput(executable, ["serve", "--help"], bundleID: bundleID),
            "mcp": helperOutput(executable, ["mcp", "--help"], bundleID: bundleID),
            "telemetry": helperOutput(executable, ["telemetry", "--help"], bundleID: bundleID)
        ])
        report.checkpoint()

        do {
            let prerequisites = try await CuaDriverDiagnostics().probe()
            report.set("prerequisites", [
                "host_identity_verified": prerequisites.hostIdentityVerified,
                "accessibility_granted": prerequisites.accessibilityGranted,
                "screen_recording_granted": prerequisites.screenRecordingGranted,
                "core_schema_sha256": prerequisites.coreSchemaSHA256])
        } catch {
            report.set("prerequisites_error", String(describing: error))
        }
        report.checkpoint()

        let host = EmbeddedCuaDriverHost(executable: executable)
        let client: PlaywrightMCPClient
        do {
            let connection = try await host.start()
            client = try PlaywrightMCPClient(cuaDriver: executable, socketPath: connection.socketPath,
                hostBundleID: bundleID)
        } catch {
            report.set("conclusion", "The driver could not start: \(error)")
            await host.stop()
            return
        }
        do {
            try await client.initialize()
            report.set("handshake", jsonObject(client.handshakeSummary()))
            let names = try await client.listTools()
            report.set("tool_names", names.sorted())
            var contract: [String: Any] = [:]
            for name in contractTools {
                guard let definition = client.toolDefinition(for: name) else { continue }
                contract[name] = ["sha256": QualificationReport.sha256(definition),
                                  "definition": jsonObject(definition) ?? NSNull()]
            }
            report.set("tool_contract", contract)
            if let pid = await host.daemonProcessIdentifier() {
                report.set("daemon_network_sockets", networkSockets(pid: pid))
            }
            report.set("check_permissions", try await structured(client, "check_permissions", [:]))
            if let health = try await structured(client, "health_report", [:]) as? [String: Any],
               let checks = health["checks"] as? [[String: Any]] {
                report.set("health_checks", checks.map {
                    ["name": $0["name"] ?? "", "status": $0["status"] ?? ""]
                })
            }
            report.checkpoint()
            guard fixtures.count == 1, let fixture = fixtures.first else {
                report.set("conclusion", "Launch exactly one AgentFixture in the background, then rerun.")
                client.stop(); await host.stop()
                return
            }
            await inspectFixture(pid: fixture.processIdentifier, client: client, report: report)
        } catch {
            report.set("driver_error", String(describing: error))
        }
        client.stop()
        await host.stop()
    }

    // MARK: Fixture inspection (fixture windows only)

    private static func inspectFixture(pid: pid_t, client: PlaywrightMCPClient, report: QualificationReport) async {
        let cgRows = coreGraphicsRows(pid: pid)
        report.set("aim_cg_windows", cgRows)
        var cuaRows: [[String: Any]] = []
        do {
            let listed = try await structured(client, "list_windows", ["pid": Int(pid)])
            cuaRows = windowRows(in: listed).filter { ($0["pid"] as? Int) == Int(pid) }
            report.set("cua_list_windows", cuaRows)
            let onScreen = try await structured(client, "list_windows", ["pid": Int(pid), "on_screen_only": true])
            report.set("cua_list_windows_on_screen_ids",
                windowRows(in: onScreen).filter { ($0["pid"] as? Int) == Int(pid) }.compactMap { $0["window_id"] })
        } catch {
            report.set("cua_list_windows_error", String(describing: error))
        }

        let ax = FixtureAccessibilityProbe.windows(pid: pid)
        report.set("aim_ax", [
            "windows_status": ax.status.rawValue,
            "window_count": ax.windows.count,
            "windows": ax.windows.map { window -> [String: Any] in
                ["title": window.title,
                 "frame": window.frame.map(rect) ?? NSNull(),
                 "cg_window_id": window.windowID.map { Int($0) } ?? NSNull()]
            },
            "menu_bar_children": FixtureAccessibilityProbe.menuBarChildCount(pid: pid) ?? NSNull(),
            "counter": FixtureAccessibilityProbe.counter(pid: pid) ?? NSNull()])
        report.checkpoint()

        var candidates = cuaRows.compactMap { $0["window_id"] as? Int }
        for row in cgRows where (row["layer"] as? Int) == 0 {
            if let id = row["window_id"] as? Int, !candidates.contains(id) { candidates.append(id) }
        }
        var states: [[String: Any]] = []
        var bestWindow: Int?
        var bestCount = -1
        for windowID in candidates {
            do {
                let raw = try await client.callRawTool("get_window_state", arguments: [
                    "pid": Int(pid), "window_id": windowID, "include_screenshot": false, "max_elements": 50])
                var summary = summarize(raw)
                summary["window_id"] = windowID
                states.append(summary)
                let count = (summary["element_rows"] as? [Any])?.count ?? 0
                if count > bestCount { bestCount = count; bestWindow = windowID }
            } catch {
                states.append(["window_id": windowID, "call_error": String(describing: error)])
            }
            report.set("cua_window_states", states)
            report.checkpoint()
        }
        if let bestWindow {
            do {
                let raw = try await client.callRawTool("get_window_state", arguments: [
                    "pid": Int(pid), "window_id": bestWindow, "include_screenshot": true, "max_elements": 50])
                let structured = raw["structuredContent"] as? [String: Any] ?? [:]
                let keys = ["screenshot_width", "screenshot_height", "screenshot_scale",
                            "screenshot_frame_valid", "screenshot_mime_type", "window_bounds",
                            "screenshot_error", "degraded", "degraded_reason"]
                var geometry: [String: Any] = ["window_id": bestWindow]
                for key in keys { geometry[key] = structured[key] ?? NSNull() }
                geometry["image_blocks"] = (raw["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "image" }.count
                report.set("cua_screenshot_geometry", geometry)
            } catch {
                report.set("cua_screenshot_error", String(describing: error))
            }
        }
        if let schema = client.inputSchema(for: "get_accessibility_tree"),
           let object = jsonObject(schema) as? [String: Any],
           let properties = object["properties"] as? [String: Any], properties["pid"] != nil {
            do {
                let raw = try await client.callRawTool("get_accessibility_tree", arguments: ["pid": Int(pid)])
                let text = textContent(raw)
                report.set("cua_accessibility_tree", [
                    "is_error": raw["isError"] as? Bool ?? false,
                    "structured_keys": (raw["structuredContent"] as? [String: Any])?.keys.sorted() ?? [],
                    "contains_menu_bar": text.contains("AXMenuBar"),
                    "contains_window": text.contains("AXWindow"),
                    "contains_increment": text.contains("Increment"),
                    "text_prefix": String(text.prefix(2_000))])
            } catch {
                report.set("cua_accessibility_tree_error", String(describing: error))
            }
        }
        report.set("conclusion", conclusion(report: report, states: states))
    }

    private static func summarize(_ raw: [String: Any]) -> [String: Any] {
        let structured = raw["structuredContent"] as? [String: Any] ?? [:]
        var summary: [String: Any] = [
            "is_error": raw["isError"] as? Bool ?? false,
            "text_prefix": String(textContent(raw).prefix(600)),
            "structured_keys": structured.keys.sorted(),
            "degraded": structured["degraded"] ?? NSNull(),
            "degraded_reason": structured["degraded_reason"] ?? NSNull(),
            "snapshot_present": (structured["snapshot_id"] as? String)?.isEmpty == false,
            "window_title_present": structured["window_title"] != nil,
            "element_count": structured["element_count"] ?? NSNull(),
            "total_element_count": structured["total_element_count"] ?? NSNull(),
            "returned_element_count": structured["returned_element_count"] ?? NSNull(),
            "elements_complete": structured["elements_complete"] ?? NSNull(),
            "truncated": structured["truncated"] ?? NSNull(),
            "background_input": structured["background_input"] ?? NSNull()
        ]
        let markdown = structured["tree_markdown"] as? String ?? ""
        summary["tree_contains_count"] = markdown.contains("Count:")
        summary["tree_markdown_prefix"] = String(markdown.prefix(2_000))
        let rows = structured["elements"] as? [[String: Any]] ?? []
        summary["element_rows"] = rows.prefix(25).map { row -> [String: Any] in
            var copy = row.filter { $0.key != "element_token" && $0.key != "frame" }
            if let token = row["element_token"] as? String {
                copy["token_shape"] = token.split(separator: ":").count == 2 && token.hasPrefix("s")
                    ? "s<hex>:<index>" : "other"
            }
            copy["has_frame"] = row["frame"] != nil
            return copy
        }
        return summary
    }

    private static func conclusion(report: QualificationReport, states: [[String: Any]]) -> String {
        let matched = states.contains { $0["snapshot_present"] as? Bool == true }
        let reasons = states.compactMap { $0["degraded_reason"] as? String }
        let ax = report.value("aim_ax") as? [String: Any] ?? [:]
        let aimWindows = ax["window_count"] as? Int ?? 0
        let aimMapped = (ax["windows"] as? [[String: Any]] ?? []).contains { $0["cg_window_id"] is Int }
        let cua = report.value("cua_list_windows") as? [[String: Any]] ?? []
        let offSpace = cua.contains { $0["on_current_space"] as? Bool == false }
        let tree = report.value("cua_accessibility_tree") as? [String: Any] ?? [:]
        let daemonSeesMenu = tree["contains_menu_bar"] as? Bool ?? false
        if matched { return "matched: at least one fixture window produced an actionable snapshot" }
        if reasons.contains(where: { $0.hasPrefix("ax_window_unresolved") }) {
            if aimWindows == 0 && offSpace { return "(a) fixture windows are not on the current Space" }
            if aimWindows > 0 && aimMapped { return "driver bug: AIM maps CG↔AX in-process but the driver does not" }
            if aimWindows > 0 { return "(b) CG↔AX correspondence unavailable on this macOS build" }
            return daemonSeesMenu ? "(a) AX lists no windows on this Space" : "(c) AX ineffective in the daemon"
        }
        if reasons.contains(where: { $0.hasPrefix("ax_tree_empty") }) {
            return aimWindows > 0 ? "(c) daemon AX walk empty while AIM reads the fixture" : "ax_tree_empty in both"
        }
        return "undetermined; inspect cua_window_states"
    }

    // MARK: Helpers

    private static func coreGraphicsRows(pid: pid_t) -> [[String: Any]] {
        let onScreen = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }.map { info in
            let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
            let bounds = (info[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return ["window_id": id,
                    "layer": (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                    "title": info[kCGWindowName as String] as? String ?? "",
                    "alpha": (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1,
                    "is_on_screen_flag": info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                    "in_on_screen_list": onScreen.contains(id),
                    "bounds": bounds.map(rect) ?? NSNull()]
        }
    }

    private static func structured(_ client: PlaywrightMCPClient, _ name: String,
                                   _ arguments: [String: Any]) async throws -> Any? {
        let raw = try await client.callRawTool(name, arguments: arguments)
        return raw["structuredContent"]
    }

    private static func windowRows(in value: Any?) -> [[String: Any]] {
        if let rows = value as? [[String: Any]], rows.contains(where: { $0["window_id"] != nil }) { return rows }
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let rows = windowRows(in: dictionary[key])
                if !rows.isEmpty { return rows }
            }
        }
        return []
    }

    private static func textContent(_ raw: [String: Any]) -> String {
        (raw["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private static func jsonObject(_ data: Data?) -> Any? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height]
    }

    /// Runs a read-only CLI subcommand (help text) with AIM's helper environment.
    private static func helperOutput(_ executable: URL, _ arguments: [String], bundleID: String) -> String {
        let command = ProcessCommand(executable: executable, arguments: arguments,
            environment: CuaDriverEnvironment.make(hostBundleID: bundleID), timeout: .seconds(5), inheritsEnvironment: false)
        do {
            let data = try ConfinedBinaryProcess.runOpaqueSynchronously(command, maximumOutputBytes: 64 * 1_024)
            return String(decoding: data, as: UTF8.self)
        } catch { return "diagnostic refused or failed: \(error.localizedDescription)" }
    }

    private static func networkSockets(pid: Int32) -> [String: Any] {
        let command = ProcessCommand(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-a", "-p", String(pid), "-i", "-Fn"], environment: [:], timeout: .seconds(5), inheritsEnvironment: false)
        let data: Data
        do { data = try ConfinedBinaryProcess.runOpaqueSynchronously(command, maximumOutputBytes: 64 * 1_024) }
        catch { return ["error": "socket diagnostic refused or failed: \(error.localizedDescription)"] }
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        return ["count": names.count, "endpoints": names]
    }
}
#endif
