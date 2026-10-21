import AIMAgentKit
import AIMApplication
import AppKit
import Foundation
import Vision

/// One instance belongs to one agent run. AX element IDs never survive a new read
/// or another run, and every action is bound to an exact host-approved tool call.
public actor AgentDesktopToolService: DesktopToolServing, MissionIntentProviding, ToolApprovalCategorizing {
    public nonisolated let supportedTools: Set<String> = [
        "desktop_list_windows", "desktop_read_window", "desktop_focus_window",
        "desktop_press", "desktop_set_value", "desktop_screenshot", "desktop_observe_window",
        "desktop_click", "desktop_move", "desktop_drag", "desktop_scroll",
        "desktop_type", "desktop_key"
    ]

    private let accessibility: MacAccessibilityService
    private let capture: MacScreenCaptureService
    private let input: MacDesktopInputService
    private var selectedWindow: DesktopWindow?
    private var latestCapture: DesktopCaptureGeometry?
    private var observationID: UUID?
    private var activeCancellation: [String: DesktopInputCancellationToken] = [:]
    private var cancelledRequests: Set<String> = []
    private var suspendedForHumanIntervention = false

    public init(accessibility: MacAccessibilityService = MacAccessibilityService(),
                capture: MacScreenCaptureService = MacScreenCaptureService(),
                input: MacDesktopInputService = MacDesktopInputService()) {
        self.accessibility = accessibility
        self.capture = capture
        self.input = input
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        if ScreenLockState.isLocked {
            var locked = ToolResult(requestID: request.id, content: ScreenLockState.reason, isError: true,
                                    metadata: ["screen_locked": "true"])
            locked.actionOutcome = .suspectedAbsent
            return locked
        }
        // Another task driving the screen finishes its gestures first; nothing is interleaved.
        if Self.isDesktopAction(request.name), !(await ScreenControlArbiter.shared.acquire(ObjectIdentifier(self))) {
            return ToolResult(requestID: request.id,
                content: "Another AIM task is controlling the screen. Nothing was done; try again in a moment or continue without the screen.", isError: true)
        }
        let cancellation = DesktopInputCancellationToken()
        if cancelledRequests.contains(request.id) { cancellation.cancel() }
        activeCancellation[request.id] = cancellation
        defer {
            activeCancellation.removeValue(forKey: request.id)
            cancelledRequests.remove(request.id)
        }
        do {
            try Task.checkCancellation()
            try cancellation.check()
            if Self.isDesktopAction(request.name) {
                // Invalid/stale actions have no effect to hand over. Reject them before
                // waiting for idle input so the error cannot depend on the person's activity.
                if request.name != "desktop_focus_window" {
                    guard selectedWindow != nil, let observationID,
                          request.arguments["observation_id"] == observationID.uuidString else {
                        throw AgentDesktopError.staleElement
                    }
                }
                // Every desktop action is approved by the person one by one: an approval after an
                // interruption is the person handing control back.
                suspendedForHumanIntervention = false
                guard await MacDesktopInputService.waitForPersonIdle() else { throw DesktopInputError.personActive }
            }
            var content: String
            var screenshotPNG: Data?
            var metadata: [String: String] = [:]
            switch request.name {
            case "desktop_list_windows":
                invalidateObservation()
                var report = await accessibility.inventory()
                report.windows.removeAll { $0.ownerPID == getpid() }
                report.applications.removeAll { $0.pid == getpid() }
                let count = report.windows.count
                if count > 200 {
                    report.windows = Array(report.windows.prefix(200))
                    report.warnings.append("Window results truncated: 200 of \(count). Use a targeted window read.")
                }
                content = report.compactListing(query: request.arguments["query"])
            case "desktop_read_window":
                invalidateObservation()
                let window = try await resolveWindow(request.arguments)
                let nodes = try await accessibility.readWindow(window, maximumNodes: 300)
                selectedWindow = window
                let id = UUID()
                observationID = id
                metadata["observation_id"] = id.uuidString
                let query = request.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard query.utf8.count <= 200 else { throw AgentDesktopError.invalidArgument }
                let maximum = Int(request.arguments["max"] ?? "80") ?? 80
                guard (1...300).contains(maximum) else { throw AgentDesktopError.invalidArgument }
                let matching = nodes.filter { node in
                    query.isEmpty || node.role.localizedCaseInsensitiveContains(query) ||
                        (node.title?.localizedCaseInsensitiveContains(query) ?? false) ||
                        (node.value?.localizedCaseInsensitiveContains(query) ?? false)
                }
                metadata["coverage"] = nodes.count >= 300 ? "node_limit_reached; partial" : "bounded_AX_tree; depth_limit_12"
                metadata["matching_nodes"] = String(matching.count)
                metadata["returned_nodes"] = String(min(maximum, matching.count))
                metadata["truncated"] = String(matching.count > maximum || nodes.count >= 300)
                content = Self.encode(matching.prefix(maximum).map { node in
                    ["node_id": node.id.uuidString, "role": node.role,
                     "title": node.title ?? "", "value": String((node.value ?? "").prefix(500)),
                     "enabled": String(node.isEnabled), "depth": String(node.depth),
                     "secure": String(node.isSecure)] as [String: String]
                })
                content += "\nObservation ID: \(id.uuidString). Pass observation_id with desktop_press or desktop_set_value."
            case "desktop_focus_window":
                let window = try await resolveWindow(request.arguments)
                try cancellation.check()
                try await accessibility.focus(window: window)
                invalidateObservation()
                let frontmostPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
                guard frontmostPID == window.ownerPID, try await accessibility.isFocused(window: window) else {
                    return ToolResult(requestID: request.id,
                        content: "Focus was requested, but the exact target window could not be verified as focused. macOS may have changed the frontmost app or Space; inspect before trying again. No gesture was sent.",
                        isError: true, metadata: ["focus_unverified": "true", "action_outcome": ActionOutcome.unknown.rawValue])
                }
                content = "Focused and verified \(window.applicationName) window \(window.id). This may have activated the app or switched Spaces. Take a fresh screenshot before any coordinate gesture."
                metadata["action_outcome"] = ActionOutcome.confirmed.rawValue
            case "desktop_press", "desktop_set_value":
                guard let selectedWindow, let observationID,
                      request.arguments["observation_id"] == observationID.uuidString,
                      let rawID = request.arguments["node_id"], let nodeID = UUID(uuidString: rawID),
                      let window = try await accessibility.listWindowsVerified().first(where: { $0.id == selectedWindow.id && $0.ownerPID == selectedWindow.ownerPID &&
                          $0.processLaunchedAt == selectedWindow.processLaunchedAt && $0.frame == selectedWindow.frame && $0.ownerPID != getpid() }) else {
                    throw AgentDesktopError.staleElement
                }
                _ = window
                try cancellation.check()
                if request.name == "desktop_press" {
                    try await accessibility.perform(.press, nodeID: nodeID)
                } else {
                    guard let value = request.arguments["value"], value.utf8.count <= 16_384 else {
                        throw AgentDesktopError.invalidArgument
                    }
                    try await accessibility.perform(.setValue(value), nodeID: nodeID)
                }
                invalidateObservation()
                content = "Accessibility action was accepted; its effect remains unverified. Read the window again before claiming success."
                metadata["action_outcome"] = ActionOutcome.unverified.rawValue
            case "desktop_screenshot":
                invalidateObservation()
                let window = try await resolveWindow(request.arguments)
                let image = try await capture.captureWithGeometry(windowID: window.id, maximumWidth: 1_280)
                let presentation = await Self.screenshotPresentation(requestID: request.id, png: image.png,
                    recognize: Self.recognizedText)
                content = presentation.content
                metadata = presentation.metadata
                let current = try await resolveWindow(request.arguments)
                guard current.ownerPID == window.ownerPID, current.processLaunchedAt == window.processLaunchedAt,
                      current.frame == image.windowFrame else { throw DesktopInputError.staleCapture }
                if image.png.count <= 6_000_000 {
                    screenshotPNG = image.png
                    let id = UUID()
                    observationID = id
                    metadata["observation_id"] = id.uuidString
                    latestCapture = DesktopCaptureGeometry(windowID: window.id, ownerPID: window.ownerPID,
                        frame: image.windowFrame, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight,
                        capturedAt: image.capturedAt, processLaunchedAt: window.processLaunchedAt)
                    content += "\nImage coordinates: x=0..<\(image.pixelWidth), y=0..<\(image.pixelHeight), origin at top left. " +
                        "Pass observation_id=\(id.uuidString) with desktop_click/move/drag/scroll; capture again after any action."
                } else {
                    latestCapture = nil
                    content += "\n[Image pixels omitted because this capture exceeded the 6 MB limit. Coordinate actions are unavailable.]"
                }
            case "desktop_observe_window":
                invalidateObservation()
                let window = try await resolveWindow(request.arguments)
                let id = UUID()
                var warnings: [String] = []
                var nodes: [AccessibilityNode] = []
                var axCoverage = "unavailable"
                var axObservedAt: Date?
                do {
                    nodes = try await accessibility.readWindow(window, maximumNodes: 300)
                    axObservedAt = .now
                    axCoverage = nodes.count >= 300 ? "node_limit_reached; partial" : "bounded_AX_tree; depth_limit_12"
                    if nodes.count > 80 {
                        axCoverage += "; returned_80_of_\(nodes.count)"
                    }
                } catch {
                    warnings.append("AX unavailable: \(error.localizedDescription)")
                }
                var image: CapturedWindowImage?
                do {
                    image = try await capture.captureWithGeometry(windowID: window.id, maximumWidth: 1_280)
                } catch {
                    warnings.append("Capture unavailable: \(error.localizedDescription)")
                }
                let current = try await resolveWindow(request.arguments)
                let targetVerifiedAt = Date.now
                guard current.id == window.id, current.ownerPID == window.ownerPID,
                      current.processLaunchedAt == window.processLaunchedAt,
                      current.frame == window.frame,
                      image == nil || image?.windowFrame == current.frame else {
                    throw DesktopInputError.staleCapture
                }
                if let image {
                    if image.png.count <= 6_000_000 {
                        screenshotPNG = image.png
                        latestCapture = DesktopCaptureGeometry(windowID: current.id, ownerPID: current.ownerPID,
                            frame: current.frame, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight,
                            capturedAt: image.capturedAt, processLaunchedAt: current.processLaunchedAt)
                    } else {
                        warnings.append("Image exceeds the 6 MB model limit; coordinate actions are unavailable.")
                    }
                }
                var ocrText: String?
                if let screenshotPNG {
                    do { ocrText = try await Self.recognizedText(in: screenshotPNG) }
                    catch { warnings.append("OCR unavailable: \(error.localizedDescription)") }
                }
                let observation = DesktopObservation(id: id, window: current, observedAt: .now,
                    axObservedAt: axObservedAt, imageCapturedAt: image?.capturedAt,
                    targetVerifiedAt: targetVerifiedAt,
                    imagePixelWidth: screenshotPNG == nil ? nil : image?.pixelWidth,
                    imagePixelHeight: screenshotPNG == nil ? nil : image?.pixelHeight,
                    imageCoordinateOrigin: screenshotPNG == nil ? nil : "top_left",
                    axNodes: nodes.prefix(80).map(DesktopObservedNode.init), axCoverage: axCoverage,
                    ocrText: ocrText, warnings: warnings)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                content = String(decoding: try encoder.encode(observation), as: UTF8.self)
                metadata["observation_id"] = id.uuidString
                metadata["coverage"] = axCoverage
                metadata["truncated"] = String(nodes.count > 80)
                selectedWindow = nodes.isEmpty ? nil : current
                observationID = id
                if screenshotPNG == nil && nodes.isEmpty {
                    return ToolResult(requestID: request.id, content: content, isError: true,
                        metadata: metadata)
                }
            case "desktop_click", "desktop_move", "desktop_drag", "desktop_scroll", "desktop_type", "desktop_key":
                let window = try await prepareGesture(request.arguments)
                try cancellation.check()
                let accessibility = self.accessibility
                let verifyWindow: MacDesktopInputService.FocusVerifier = {
                    try await accessibility.isFocused(window: window)
                }
                defer { invalidateObservation() }
                switch request.name {
                case "desktop_click":
                    let point = try point("x", "y", request.arguments, in: window)
                    let count = Int(request.arguments["click_count"] ?? "1") ?? 0
                    let button = request.arguments["button"] ?? "left"
                    guard ["left", "right"].contains(button) else { throw AgentDesktopError.invalidArgument }
                    try await input.click(at: point, count: count, right: button == "right",
                        expectedFrontmostPID: window.ownerPID, verifyFocusedWindow: verifyWindow,
                        cancellation: cancellation)
                case "desktop_move":
                    try await input.move(to: point("x", "y", request.arguments, in: window),
                        expectedFrontmostPID: window.ownerPID, verifyFocusedWindow: verifyWindow,
                        cancellation: cancellation)
                case "desktop_drag":
                    let start = try point("from_x", "from_y", request.arguments, in: window)
                    let end = try point("to_x", "to_y", request.arguments, in: window)
                    try await input.drag(from: start, to: end, expectedFrontmostPID: window.ownerPID,
                        verifyFocusedWindow: verifyWindow, cancellation: cancellation)
                case "desktop_scroll":
                    let location = try point("x", "y", request.arguments, in: window)
                    guard let vertical = Int32(request.arguments["delta_y"] ?? ""),
                          let horizontal = Int32(request.arguments["delta_x"] ?? "0") else {
                        throw AgentDesktopError.invalidArgument
                    }
                    try await input.scroll(at: location, horizontal: horizontal, vertical: vertical,
                        expectedFrontmostPID: window.ownerPID, verifyFocusedWindow: verifyWindow,
                        cancellation: cancellation)
                case "desktop_type":
                    guard let value = request.arguments["text"] else { throw AgentDesktopError.invalidArgument }
                    let target = try await accessibility.beginTyping(in: window, text: value)
                    do {
                        try await input.type(value, expectedFrontmostPID: window.ownerPID,
                            verifyFocusedWindow: {
                                try await accessibility.isTypingTargetFocused(target, in: window)
                            }, cancellation: cancellation)
                        var effect: Bool?
                        // AX updates can lag HID dispatch. Observe briefly, without replaying input.
                        for _ in 0..<5 {
                            try cancellation.check()
                            effect = try await accessibility.typingEffect(target, in: window)
                            if effect != false { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        await accessibility.endTyping(target)
                        if effect == false {
                            return ToolResult(requestID: request.id,
                                content: "Typing was dispatched, but the targeted control did not contain the expected text. Do not claim it was entered or retry blindly; observe the window and its actual input control.",
                                isError: true, metadata: ["typing_effect": "not_observed", "action_outcome": ActionOutcome.suspectedAbsent.rawValue])
                        }
                        metadata["typing_effect"] = effect == true ? "value_verified" : "unverified"
                    } catch {
                        await accessibility.endTyping(target)
                        throw error
                    }
                case "desktop_key":
                    guard let key = request.arguments["key"] else { throw AgentDesktopError.invalidArgument }
                    try await accessibility.ensureFocusedInputIsNotSecure(pid: window.ownerPID)
                    try await input.key(key, modifiers: request.arguments["modifiers"],
                        expectedFrontmostPID: window.ownerPID, verifyFocusedWindow: verifyWindow,
                        cancellation: cancellation)
                default: break
                }
                if metadata["typing_effect"] == "value_verified" {
                    content = "Typed text was verified in the exact focused control of \(window.applicationName) (window \(window.id)) using its accessibility value. Observe current state before another coordinate action."
                    metadata["action_outcome"] = ActionOutcome.confirmed.rawValue
                } else {
                    content = "Input dispatched to \(window.applicationName) (window \(window.id)); its effect remains unverified. " +
                        "Take a new screenshot or accessibility read to verify the result before another coordinate action."
                    metadata["action_outcome"] = ActionOutcome.unverified.rawValue
                }
            default:
                throw AgentDesktopError.invalidArgument
            }
            if !["desktop_list_windows", "desktop_read_window", "desktop_screenshot", "desktop_observe_window"].contains(request.name) {
                selectedWindow = nil
            }
            try Task.checkCancellation()
            try cancellation.check()
            return ToolResult(requestID: request.id, content: content, metadata: metadata, imagePNG: screenshotPNG)
        } catch {
            invalidateObservation()
            if error is CancellationError { await AgentCursorOverlay.shared.hide() }
            var result = ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
            if case DesktopInputError.personActive = error { result.metadata["needs_handover"] = "true" }
            if case DesktopInputError.humanIntervention = error {
                suspendedForHumanIntervention = true
                result.metadata["needs_handover"] = "true"
                result.metadata["human_conflict"] = "true"
                await AgentCursorOverlay.shared.hide()
            }
            if Self.isDesktopAction(request.name) {
                result.actionOutcome = .unknown
            }
            return result
        }
    }

    private nonisolated static func isDesktopAction(_ name: String) -> Bool {
        ["desktop_focus_window", "desktop_press", "desktop_set_value", "desktop_click", "desktop_move",
         "desktop_drag", "desktop_scroll", "desktop_type", "desktop_key"].contains(name)
    }

    public func cancel(requestID: String) async {
        cancelledRequests.insert(requestID)
        activeCancellation[requestID]?.cancel()
        invalidateObservation()
        await AgentCursorOverlay.shared.hide()
    }

    /// A bundle identity is resolved from the running process, never from
    /// model-provided application names or a mutable window title.
    public func missionIntent(for request: ToolRequest) async throws -> MissionToolIntent? {
        let operation: MissionOperation
        switch request.name {
        case "desktop_read_window", "desktop_screenshot", "desktop_observe_window": operation = .observe
        case "desktop_move", "desktop_scroll": operation = .navigate
        case "desktop_type", "desktop_set_value": operation = .input
        // Generic clicks, presses, drags and keys can commit a purchase or
        // contract. They need a semantic target classifier before a blanket
        // mission grant may bypass their exact-action approval.
        case "desktop_focus_window", "desktop_press", "desktop_click", "desktop_drag", "desktop_key": return nil
        default: return nil
        }
        let window: DesktopWindow
        if request.name == "desktop_press" || request.name == "desktop_set_value" {
            guard let selectedWindow, let observationID,
                  request.arguments["observation_id"] == observationID.uuidString else {
                throw AgentDesktopError.staleElement
            }
            window = try await resolveWindow(["window_id": String(selectedWindow.id)])
            guard window.ownerPID == selectedWindow.ownerPID,
                  window.processLaunchedAt == selectedWindow.processLaunchedAt,
                  window.frame == selectedWindow.frame else { throw AgentDesktopError.staleElement }
        } else {
            window = try await resolveWindow(request.arguments)
        }
        guard let bundleID = await MainActor.run(body: {
            NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier == window.ownerPID && $0.launchDate == window.processLaunchedAt
            }?.bundleIdentifier
        }) else { return nil }
        let resource = try MissionResource(kind: .application, identifier: bundleID)
        return MissionToolIntent(operation: operation, target: resource)
    }

    /// Approvals for controlling an app are grouped per app, identified by its running process.
    public func approvalCategory(for request: ToolRequest) async -> ToolApprovalCategory? {
        guard request.name.hasPrefix("desktop_") else { return nil }
        let window: DesktopWindow?
        if let id = request.arguments["window_id"] { window = try? await resolveWindow(["window_id": id]) } else { window = selectedWindow }
        guard let window, let app = await MainActor.run(body: { () -> (String, String)? in
            guard let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier == window.ownerPID && $0.launchDate == window.processLaunchedAt
            }), let bundle = running.bundleIdentifier else { return nil }
            return (bundle, running.localizedName ?? bundle)
        }) else { return nil }
        return ToolApprovalCategory(key: "app:" + app.0.lowercased(), title: "Computer use", scope: "controlling \(app.1)")
    }

    private func prepareGesture(_ arguments: [String: String]) async throws -> DesktopWindow {
        let window = try await resolveWindow(arguments)
        guard let latestCapture, latestCapture.windowID == window.id,
              let observationID, arguments["observation_id"] == observationID.uuidString else {
            throw DesktopInputError.staleCapture
        }
        // Focusing is a separate, approved tool effect. A coordinate gesture
        // must never change Spaces or steal focus as a hidden prerequisite.
        let frontmostPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard frontmostPID == window.ownerPID, try await accessibility.isFocused(window: window) else {
            throw DesktopInputError.appNotFrontmost
        }
        guard let current = try await accessibility.listWindowsVerified().first(where: { $0.id == window.id && $0.ownerPID == window.ownerPID }) else {
            throw AgentDesktopError.staleWindow
        }
        _ = try latestCapture.globalPoint(x: 0, y: 0, current: current)
        let stillFrontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard stillFrontmost == current.ownerPID, try await accessibility.isFocused(window: current) else {
            throw DesktopInputError.appNotFrontmost
        }
        return current
    }

    private func point(_ xName: String, _ yName: String, _ arguments: [String: String],
                       in window: DesktopWindow) throws -> CGPoint {
        guard let x = Double(arguments[xName] ?? ""), let y = Double(arguments[yName] ?? ""),
              let latestCapture else { throw AgentDesktopError.invalidArgument }
        return try latestCapture.globalPoint(x: x, y: y, current: window)
    }

    private func resolveWindow(_ arguments: [String: String]) async throws -> DesktopWindow {
        guard let raw = arguments["window_id"], let id = CGWindowID(raw) else { throw AgentDesktopError.invalidArgument }
        guard let window = try await accessibility.listWindowsVerified().first(where: { $0.id == id && $0.ownerPID != getpid() }) else {
            throw AgentDesktopError.staleWindow
        }
        return window
    }

    private func invalidateObservation() {
        selectedWindow = nil
        latestCapture = nil
        observationID = nil
    }

    private nonisolated static func encode(_ rows: [[String: String]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    nonisolated static func screenshotPresentation(requestID: String, png: Data,
        recognize: @Sendable (Data) async throws -> String) async -> ToolResult {
        do { return ToolResult(requestID: requestID, content: try await recognize(png), imagePNG: png) }
        catch {
            return ToolResult(requestID: requestID,
                content: "Window screenshot captured. OCR unavailable; inspect the attached image.",
                metadata: ["ocr": "unavailable"], imagePNG: png)
        }
    }

    private nonisolated static func recognizedText(in png: Data) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: png)
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return "Window screenshot captured in memory (not saved). Recognized text for orientation; inspect the attached image for visual layout when the provider supports image input:\n" +
            String(lines.joined(separator: "\n").prefix(20_000))
    }
}

private enum AgentDesktopError: LocalizedError {
    case invalidArgument, staleWindow, staleElement
    var errorDescription: String? {
        switch self {
        case .invalidArgument: "Invalid desktop tool arguments."
        case .staleWindow: "The selected window was not found in the available sources. List windows again; absence does not prove the app is closed."
        case .staleElement: "The interface element is stale. Read the window again."
        }
    }
}
