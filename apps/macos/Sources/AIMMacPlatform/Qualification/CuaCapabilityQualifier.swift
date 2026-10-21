#if DEBUG
import AIMAgentKit
import AIMApplication
import AppKit
import Foundation

/// Progressive background-input qualification on AIM's disposable fixture.
/// A level passes only after three consecutive attempts whose effect is seen in
/// the fixture's own state file, with the frontmost app, the pointer and the
/// fixture's activation count unchanged and a background delivery path.
public enum CuaCapabilityQualifier {
    public enum Level: String, CaseIterable, Sendable {
        case observe = "L0_observe"
        case axClick = "L1_ax_click"
        case pixelClick = "L2_pixel_click"
        case typeText = "L3_type_text"
        case setValue = "L4_set_value"
        case scroll = "L5_scroll"
        case pressKey = "L6_press_key"
    }

    static let requiredPasses = 3

    /// Capabilities a finished report proves, for persistence by the app.
    public static func qualifiedCapabilities(in report: QualificationReport) -> [CuaCapability] {
        let passed = report.value("passed_levels") as? [String: Bool] ?? [:]
        let mapping: [(Level, CuaCapability)] = [(.observe, .observe), (.axClick, .axClick),
            (.pixelClick, .pixelClick), (.typeText, .typeText), (.setValue, .setValue),
            (.scroll, .scroll), (.pressKey, .pressKey)]
        let secureRefused = (report.value("negative_secure_type") as? [String: Any])?["passed"] as? Bool == true
        return mapping.compactMap { level, capability in
            guard passed[level.rawValue] == true else { return nil }
            // Text-entering capabilities also require the secure-field refusal to hold.
            if [.typeText, .setValue, .pressKey].contains(capability) && !secureRefused { return nil }
            return capability
        }
    }
    static let typedText = "AIM é 日本語"
    static let setText = "AIM set é 日本"

    struct Targets {
        let increment: CuaWindowElement
        let field: CuaWindowElement
        let secure: CuaWindowElement
    }

    public static func run(into report: QualificationReport) async {
        do {
            let prerequisites = try await CuaDriverDiagnostics().probe()
            report.set("prerequisites", ["host_identity_verified": prerequisites.hostIdentityVerified,
                "accessibility_granted": prerequisites.accessibilityGranted,
                "screen_recording_granted": prerequisites.screenRecordingGranted])
            guard prerequisites.backgroundPrerequisitesAvailable else {
                report.set("conclusion", "Host identity or a macOS permission is missing.")
                return
            }
        } catch {
            report.set("conclusion", "Driver diagnostics failed: \(error.localizedDescription)")
            return
        }
        let fixtures = FixtureAccessibilityProbe.fixtureApplications()
        guard fixtures.count == 1, let pid = fixtures.first?.processIdentifier,
              let initial = await FixtureController.perform("reset"), initial.pid == pid,
              let mainWindow = initial.windows.first, mainWindow.onActiveSpace, !initial.isActive else {
            report.set("conclusion", "Run exactly one fixture in the background on the current Space.")
            return
        }
        report.set("fixture_main_window", mainWindow.number)
        guard let executable = HostBundleResources.resourceURL?.appendingPathComponent("CuaDriver/cua-driver") else {
            report.set("conclusion", "The pinned driver is absent.")
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let host = EmbeddedCuaDriverHost(executable: executable)
        let client: PlaywrightMCPClient
        let generation: UUID
        do {
            let connection = try await host.start()
            generation = connection.generation
            client = try PlaywrightMCPClient(cuaDriver: executable, socketPath: connection.socketPath,
                hostBundleID: bundleID)
            try await client.initialize()
            _ = try await client.listTools()
            report.set("schema_digest", CuaRuntimeIdentity.schemaDigest(client) ?? NSNull())
        } catch {
            report.set("conclusion", "The driver could not start: \(error.localizedDescription)")
            await host.stop()
            return
        }
        let adapter = CuaBackgroundWindowAdapter(transport: CuaMCPTransport(client: client), generation: generation)
        var passed: [String: Bool] = [:]
        let windowID = mainWindow.number

        // L0: matched, actionable observation with stable fixture targets.
        var targets: Targets?
        var observeAttempts: [[String: Any]] = []
        for _ in 0..<requiredPasses {
            do {
                let observation = try await adapter.observe(pid: pid, windowID: windowID)
                let found = locate(observation)
                observeAttempts.append(["actionable": observation.state.isActionable,
                    "elements": observation.elements.count, "targets_found": found != nil,
                    "degradation": observation.state.degradation.map { String(describing: $0) } ?? NSNull()])
                if targets == nil { targets = found }
                if found == nil || !observation.state.isActionable { break }
            } catch {
                observeAttempts.append(["error": String(describing: error)])
                break
            }
        }
        passed[Level.observe.rawValue] = observeAttempts.count == requiredPasses &&
            observeAttempts.allSatisfy { $0["targets_found"] as? Bool == true }
        report.set(Level.observe.rawValue, observeAttempts)
        report.checkpoint()

        if passed[Level.observe.rawValue] == true {
            let ladder: [(Level, Bool, (CuaWindowObservation, Targets) -> CuaBackgroundAction?,
                          (FixtureState, FixtureState) -> Bool, [String])] = [
                (.axClick, false, { _, t in .click(elementIndex: t.increment.index) },
                 { before, after in after.count == before.count + 1 }, []),
                (.pixelClick, true, { observation, t in pixelCenter(of: t.increment, in: observation).map {
                    .clickPixel(x: $0.x, y: $0.y) } },
                 { before, after in after.count == before.count + 1 }, []),
                (.typeText, false, { _, t in .typeText(elementIndex: t.field.index, text: typedText) },
                 { before, after in after.text != before.text && after.text.contains(typedText) }, ["reset"]),
                (.setValue, false, { _, t in .setValue(elementIndex: t.field.index, value: setText) },
                 { _, after in after.text == setText }, ["reset"]),
                (.scroll, true, { observation, _ in listPixel(pid: pid, observation: observation).map {
                    .scrollPixel(x: $0.x, y: $0.y, direction: "down", amount: 5) } },
                 { before, after in after.firstVisibleRow > before.firstVisibleRow }, ["reset"]),
                (.pressKey, false, { _, t in .pressKey(elementIndex: t.field.index, key: "a") },
                 { before, after in after.text != before.text &&
                    after.text.filter { $0 == "a" }.count > before.text.filter { $0 == "a" }.count }, ["reset", "solo"])
            ]
            for (level, screenshot, makeAction, expect, prepare) in ladder {
                var attempts: [[String: Any]] = []
                for _ in 0..<requiredPasses {
                    let attempt = await act(adapter: adapter, pid: pid, windowID: windowID,
                        includeScreenshot: screenshot, prepare: prepare, makeAction: makeAction, expect: expect)
                    attempts.append(attempt)
                    report.set(level.rawValue, attempts)
                    report.checkpoint()
                    if attempt["passed"] as? Bool != true { break }
                }
                passed[level.rawValue] = attempts.count == requiredPasses &&
                    attempts.allSatisfy { $0["passed"] as? Bool == true }
            }
            _ = await FixtureController.perform("front")
            report.set("negative_secure_type", await secureRefusal(adapter: adapter, pid: pid, windowID: windowID))
        }
        report.set("passed_levels", passed)
        if let key = await CuaRuntimeIdentity.currentKey() {
            report.set("qualification_key", ["driver_version": key.driverVersion, "driver_sha256": key.driverSHA256,
                                             "os_build": key.osBuild, "adapter_contract": key.adapterContract])
        }
        report.set("conclusion", Level.allCases.map { "\($0.rawValue)=\(passed[$0.rawValue] == true ? "pass" : "fail")" }
            .joined(separator: " "))
        client.stop()
        await host.stop()
        _ = await FixtureController.perform("reset")
    }

    private static func locate(_ observation: CuaWindowObservation) -> Targets? {
        let elements = observation.elements
        guard let increment = elements.first(where: { $0.role == "AXButton" && $0.label == "Increment" }),
              let field = elements.first(where: { $0.role == "AXTextField" && $0.label == "Fixture editable text" }),
              let secure = elements.first(where: { $0.label == "Fixture secure field" }),
              [increment, field, secure].allSatisfy({ $0.token != nil }) else { return nil }
        return Targets(increment: increment, field: field, secure: secure)
    }

    private static func act(adapter: CuaBackgroundWindowAdapter, pid: Int32, windowID: Int, includeScreenshot: Bool,
                            prepare: [String],
                            makeAction: (CuaWindowObservation, Targets) -> CuaBackgroundAction?,
                            expect: (FixtureState, FixtureState) -> Bool) async -> [String: Any] {
        var record: [String: Any] = ["passed": false]
        for command in prepare { _ = await FixtureController.perform(command) }
        guard let before = FixtureController.read() else { record["error"] = "fixture state unreadable"; return record }
        let invariantsBefore = await MainActor.run { (NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                       NSEvent.mouseLocation) }
        do {
            let observation = try await adapter.observe(pid: pid, windowID: windowID, includeScreenshot: includeScreenshot)
            guard let targets = locate(observation), let action = makeAction(observation, targets) else {
                record["error"] = "target not resolved"
                return record
            }
            record["action"] = String(describing: action)
            let receipt = try await adapter.perform(action, observationID: observation.id)
            let confirmed = await FixtureController.waitFor(timeout: .seconds(3)) { expect(before, $0) }
            try? await Task.sleep(for: .milliseconds(300))
            let after = FixtureController.read()
            let invariantsAfter = await MainActor.run { (NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                          NSEvent.mouseLocation) }
            let frontmostChanged = invariantsBefore.0 != invariantsAfter.0
            let pointerMoved = hypot(invariantsBefore.1.x - invariantsAfter.1.x,
                                     invariantsBefore.1.y - invariantsAfter.1.y) > 1
            // A driver-moved pointer would rest on the action target; movement that
            // ends elsewhere is the person at the Mac and proves nothing either way.
            let target = await targetPoint(of: action, targets: targets, observation: observation)
            let pointerAtTarget = target.map { hypot($0.x - invariantsAfter.1.x, $0.y - invariantsAfter.1.y) <= 4 } ?? true
            record["human_pointer_activity"] = pointerMoved && !pointerAtTarget
            let activated = (after?.activations ?? before.activations) != before.activations || after?.isActive == true
            let report = receipt.report
            let background = report?.isBackground == true
            record["outcome"] = receipt.outcome.rawValue
            record["host_outcome"] = (report?.outcome(hostConfirmed: confirmed != nil) ?? .unknown).rawValue
            record["delivery_mode"] = report?.deliveryMode ?? NSNull()
            record["route"] = report?.route ?? NSNull()
            record["evidence"] = report?.evidence ?? []
            record["effect"] = report?.effect ?? NSNull()
            record["escalation"] = report?.escalation ?? NSNull()
            record["driver_detail"] = report?.detail ?? receipt.detail
            record["driver_structured"] = report?.structuredJSON ?? NSNull()
            record["effect_seen_in_state_file"] = confirmed != nil
            record["frontmost_changed"] = frontmostChanged
            record["pointer_moved"] = pointerMoved
            record["fixture_activated"] = activated
            record["key_window_changes_delta"] = (after?.keyWindowChanges ?? 0) - before.keyWindowChanges
            record["state_before"] = before.summary
            record["state_after"] = after?.summary ?? NSNull()
            if includeScreenshot, let geometry = observation.state.screenshot {
                record["screenshot"] = ["width": geometry.width, "height": geometry.height,
                                        "scale": geometry.scale, "frame_valid": geometry.frameValid]
            }
            // A background action could only bring the fixture forward; another app
            // becoming frontmost is the person switching apps and is recorded as such.
            let fixtureFrontmost = invariantsAfter.0 == pid
            record["human_app_switch"] = frontmostChanged && !fixtureFrontmost
            record["passed"] = confirmed != nil && background && !fixtureFrontmost &&
                !(pointerMoved && pointerAtTarget) && !activated
        } catch {
            record["error"] = String(describing: error)
        }
        return record
    }

    /// The action's target in Cocoa global coordinates (bottom-left origin), to
    /// compare with `NSEvent.mouseLocation`.
    private static func targetPoint(of action: CuaBackgroundAction, targets: Targets,
                                    observation: CuaWindowObservation) async -> CGPoint? {
        var point: CGPoint?
        if let index = action.elementIndex,
           let frame = [targets.increment, targets.field, targets.secure].first(where: { $0.index == index })?.frame {
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else if let pixel = action.pixel, let geometry = observation.state.screenshot,
                  let bounds = geometry.windowBounds, geometry.width > 0, geometry.height > 0 {
            point = CGPoint(x: bounds.minX + pixel.x * bounds.width / Double(geometry.width),
                            y: bounds.minY + pixel.y * bounds.height / Double(geometry.height))
        }
        guard let point else { return nil }
        let primaryHeight = await MainActor.run { NSScreen.screens.first?.frame.height ?? 0 }
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Text entry into the secure field must be refused by AIM before any driver call.
    private static func secureRefusal(adapter: CuaBackgroundWindowAdapter, pid: Int32, windowID: Int) async -> [String: Any] {
        guard let before = FixtureController.read() else { return ["passed": false, "error": "state unreadable"] }
        do {
            let observation = try await adapter.observe(pid: pid, windowID: windowID)
            guard let targets = locate(observation) else { return ["passed": false, "error": "target not resolved"] }
            _ = try await adapter.perform(.typeText(elementIndex: targets.secure.index, text: "secret"),
                observationID: observation.id)
            return ["passed": false, "error": "secure text entry was not refused"]
        } catch CuaBackgroundWindowError.secureInput {
            try? await Task.sleep(for: .milliseconds(300))
            let after = FixtureController.read()
            return ["passed": after?.secureLength == before.secureLength, "refused_before_driver": true]
        } catch {
            return ["passed": false, "error": String(describing: error)]
        }
    }

    /// Converts an element frame into window-local screenshot pixels. Frames may
    /// be global or window-relative; the window bounds decide which.
    static func pixelCenter(of element: CuaWindowElement, in observation: CuaWindowObservation) -> (x: Double, y: Double)? {
        guard let frame = element.frame else { return nil }
        return pixel(for: CGPoint(x: frame.midX, y: frame.midY), in: observation)
    }

    static func pixel(for point: CGPoint, in observation: CuaWindowObservation, global: Bool? = nil) -> (x: Double, y: Double)? {
        guard let geometry = observation.state.screenshot, geometry.frameValid,
              let bounds = geometry.windowBounds, bounds.width > 0, bounds.height > 0 else { return nil }
        let isGlobal = global ?? bounds.insetBy(dx: -2, dy: -2).contains(point)
        let local = isGlobal ? CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY) : point
        let x = local.x * Double(geometry.width) / bounds.width
        let y = local.y * Double(geometry.height) / bounds.height
        guard x >= 0, y >= 0, x < Double(geometry.width), y < Double(geometry.height) else { return nil }
        return (x, y)
    }

    private static func listPixel(pid: Int32, observation: CuaWindowObservation) -> (x: Double, y: Double)? {
        guard let frame = FixtureAccessibilityProbe.identifiedFrame("fixture.scroll", pid: pid) else { return nil }
        // AX frames are global top-left points.
        return pixel(for: CGPoint(x: frame.midX, y: frame.midY), in: observation, global: true)
    }
}
#endif
