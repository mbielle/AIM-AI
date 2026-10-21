#if DEBUG
import AIMAgentKit
import AppKit
import Foundation

/// Field matrix for background input on the disposable fixture: identity of
/// identically titled windows, minimized/hidden/off-screen/occluded windows
/// and a restarted process. Each case checks the fixture's own state file.
public enum CuaFieldMatrix {
    public static func run(into report: QualificationReport) async {
        guard let executable = CuaRuntimeIdentity.bundledDriver,
              let initial = await FixtureController.perform("reset"), initial.windows.count >= 2 else {
            report.set("conclusion", "Run the fixture (with --all-spaces) and bundle the driver first.")
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let host = EmbeddedCuaDriverHost(executable: executable, hostBundleID: bundleID)
        let client: PlaywrightMCPClient
        let generation: UUID
        do {
            let connection = try await host.start()
            generation = connection.generation
            client = try PlaywrightMCPClient(cuaDriver: executable, socketPath: connection.socketPath,
                hostBundleID: bundleID)
            try await client.initialize()
            _ = try await client.listTools()
        } catch {
            report.set("conclusion", "The driver could not start: \(error.localizedDescription)")
            await host.stop()
            return
        }
        let adapter = CuaBackgroundWindowAdapter(transport: CuaMCPTransport(client: client), generation: generation)
        let digest = CuaRuntimeIdentity.schemaDigest(client) ?? ""
        let service = AgentCuaToolService(qualified: [.observe: digest, .axClick: digest], modelSeesImages: false,
            leases: CuaTargetLeaseCoordinator())
        var cases: [String: [String: Any]] = [:]
        var pid = initial.pid
        let main = initial.windows[0].number
        let second = initial.windows[1].number

        func listed(_ windowID: Int) async -> Bool {
            guard let raw = try? await client.callRawTool("list_windows", arguments: ["pid": Int(pid), "on_screen_only": true]),
                  let rows = (raw["structuredContent"] as? [String: Any])?.values.compactMap({ $0 as? [[String: Any]] }).first
            else { return false }
            return rows.contains { $0["window_id"] as? Int == windowID }
        }
        func increment(_ windowID: Int) async -> (receipt: CuaBackgroundActionReceipt?, error: String?) {
            do {
                let observation = try await adapter.observe(pid: pid, windowID: windowID)
                guard let button = observation.elements.first(where: { $0.role == "AXButton" && $0.label == "Increment" }) else {
                    return (nil, observation.state.degradation.map { String(describing: $0) } ?? "no Increment button")
                }
                return (try await adapter.perform(.click(elementIndex: button.index), observationID: observation.id), nil)
            } catch {
                return (nil, String(describing: error))
            }
        }

        // F1: identically titled windows are distinguished by exact window ID.
        do {
            let first = try await adapter.observe(pid: pid, windowID: main)
            let other = try await adapter.observe(pid: pid, windowID: second)
            let firstHas = first.elements.contains { $0.label == "Increment" }
            let otherHas = other.elements.contains { $0.label == "Increment" }
            cases["F1_same_title_identity"] = ["passed": firstHas && !otherHas,
                "titles": [first.state.windowTitle ?? "", other.state.windowTitle ?? ""]]
        } catch {
            cases["F1_same_title_identity"] = ["passed": false, "error": String(describing: error)]
        }

        // F2/F3: a minimized window or hidden app is never offered or acted on by
        // AIM's tools, and AIM never restores it. The raw driver behaviour is recorded.
        for (name, command, restore) in [("F2_minimized", "minimize", "unminimize"), ("F3_hidden", "hide", "unhide")] {
            // Obtain a window_ref while the window is visible, as a model would.
            let listedBefore = await service.execute(ToolRequest(name: "bg_list_windows", arguments: [:], risk: .computerRead))
            let ref = CuaToolServiceQualification.fixtureWindowRef(listedBefore.content)
            guard let before = await FixtureController.perform(command) else { continue }
            try? await Task.sleep(for: .milliseconds(800))
            let stillListed = await listed(main)
            let observed = await service.execute(ToolRequest(name: "bg_observe_window",
                arguments: ["window_ref": ref ?? "w0"], risk: .computerRead))
            let afterTool = FixtureController.read()
            let raw = await increment(main)
            try? await Task.sleep(for: .milliseconds(300))
            let afterRaw = FixtureController.read()
            cases[name] = ["passed": ref != nil && !stillListed && observed.isError && afterTool?.count == before.count &&
                afterRaw?.deminiaturizations == before.deminiaturizations && afterRaw?.unhides == before.unhides &&
                afterRaw?.isActive == false,
                "listed_on_screen": stillListed, "tool_refused": observed.isError,
                "tool_message": String(observed.content.prefix(200)),
                "raw_driver_delivered": (afterRaw?.count ?? 0) > before.count,
                "raw_outcome": raw.receipt?.outcome.rawValue ?? NSNull(), "raw_error": raw.error ?? NSNull()]
            _ = await FixtureController.perform(restore)
            try? await Task.sleep(for: .milliseconds(800))
            _ = await FixtureController.perform("reset")
        }

        // F4: an off-screen window on the current Space still receives an exact AX action.
        if let before = await FixtureController.perform("offscreen") {
            try? await Task.sleep(for: .milliseconds(300))
            let attempt = await increment(main)
            let after = await FixtureController.waitFor { $0.count == before.count + 1 }
            cases["F4_offscreen"] = ["passed": after != nil && after?.isActive == false &&
                attempt.receipt?.report?.isBackground == true,
                "attempt_error": attempt.error ?? NSNull(), "outcome": attempt.receipt?.outcome.rawValue ?? NSNull()]
            _ = await FixtureController.perform("onscreen")
        }

        // F7: an occluded window still receives an exact AX action.
        if let before = await FixtureController.perform("overlap") {
            try? await Task.sleep(for: .milliseconds(300))
            let attempt = await increment(main)
            let after = await FixtureController.waitFor { $0.count == before.count + 1 }
            cases["F7_occluded"] = ["passed": after != nil && after?.isActive == false &&
                attempt.receipt?.report?.isBackground == true,
                "attempt_error": attempt.error ?? NSNull(), "outcome": attempt.receipt?.outcome.rawValue ?? NSNull()]
            _ = await FixtureController.perform("reset")
        }

        // F8: an observation of a process that restarted is refused before any action.
        do {
            let stale = try await adapter.observe(pid: pid, windowID: main)
            let relaunched = await relaunchFixture()
            if let relaunched {
                let receipt = try? await adapter.perform(.click(elementIndex: stale.elements.first {
                    $0.label == "Increment" }?.index ?? 4), observationID: stale.id)
                try? await Task.sleep(for: .milliseconds(500))
                let state = FixtureController.read()
                cases["F8_restarted_process"] = ["passed": receipt == nil && state?.pid == relaunched && state?.count == 0 &&
                    state?.isActive == false,
                    "new_pid_differs": relaunched != stale.pid, "relaunched_fixture_active": state?.isActive ?? NSNull()]
                pid = relaunched
            } else {
                cases["F8_restarted_process"] = ["passed": false, "error": "fixture relaunch failed"]
            }
        } catch {
            cases["F8_restarted_process"] = ["passed": false, "error": String(describing: error)]
        }

        await service.closeSession()
        client.stop()
        await host.stop()
        report.set("cases", cases)
        report.set("screen_count", await MainActor.run { NSScreen.screens.count })
        let failed = cases.filter { $0.value["passed"] as? Bool != true }.map(\.key).sorted()
        report.set("conclusion", failed.isEmpty ? "all field cases passed (\(cases.count))" :
            "failed: \(failed.joined(separator: ", "))")
    }

    /// Restarts only AIM's fixture, in the background, and returns the new PID.
    private static func relaunchFixture() async -> Int32? {
        guard let running = FixtureAccessibilityProbe.fixtureApplications().first,
              let url = running.bundleURL else { return nil }
        let oldPID = running.processIdentifier
        running.terminate()
        for _ in 0..<50 where !running.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--all-spaces"]
        configuration.createsNewApplicationInstance = true
        guard (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil else {
            return nil
        }
        let state = await FixtureController.waitFor(timeout: .seconds(8)) { $0.pid != oldPID }
        return state?.pid
    }
}
#endif
