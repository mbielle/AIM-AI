import AIMAgentKit
import AIMApplication
import AppKit
import Foundation

/// Model-facing background control through the embedded CUA driver. Only
/// capabilities qualified for this exact driver, macOS build and adapter
/// contract are offered. One instance belongs to one agent run; its driver
/// session, observations and leases end with the run.
public actor AgentCuaToolService: DesktopToolServing, MissionIntentProviding, ToolSessionClosing, ToolReviewProviding {
    public static let toolCapabilities: [String: CuaCapability] = [
        "bg_list_windows": .observe, "bg_observe_window": .observe, "bg_click": .axClick,
        "bg_type_text": .typeText, "bg_set_value": .setValue, "bg_scroll": .scroll, "bg_press_key": .pressKey
    ]

    public nonisolated let supportedTools: Set<String>
    private let qualified: [CuaCapability: String]
    private let modelSeesImages: Bool
    private let leases: CuaTargetLeaseCoordinator
    private let owner = UUID()
    private let disqualify: @Sendable (CuaCapability, String) async -> Void

    private var host: EmbeddedCuaDriverHost?
    private var client: PlaywrightMCPClient?
    private var adapter: CuaBackgroundWindowAdapter?
    private var windows: [String: Target] = [:]
    private var nextWindowRef = 1
    private var observation: (id: String, target: Target, driverObservation: UUID, observedAt: Date,
                              state: CuaWindowState)?

    struct Target: Equatable, Sendable {
        let pid: Int32
        let windowID: Int
        let launchedAt: Date
        let appName: String
        let bundleID: String?
        let title: String
    }

    /// Offered tools for a qualified capability set. Pixel actions also require
    /// a model route that actually receives the screenshot.
    public static func tools(for qualified: Set<CuaCapability>, modelSeesImages: Bool) -> Set<String> {
        guard qualified.contains(.observe) else { return [] }
        var tools: Set<String> = ["bg_list_windows", "bg_observe_window"]
        for (tool, capability) in toolCapabilities where qualified.contains(capability) { tools.insert(tool) }
        if !qualified.contains(.axClick) && modelSeesImages && qualified.contains(.pixelClick) { tools.insert("bg_click") }
        if qualified.contains(.axClick) { tools.insert("bg_click_sequence") }
        return tools
    }

    public init(qualified: [CuaCapability: String], modelSeesImages: Bool,
                leases: CuaTargetLeaseCoordinator = .shared,
                disqualify: @escaping @Sendable (CuaCapability, String) async -> Void = { _, _ in }) {
        self.qualified = qualified
        self.modelSeesImages = modelSeesImages
        self.leases = leases
        self.disqualify = disqualify
        supportedTools = Self.tools(for: Set(qualified.keys), modelSeesImages: modelSeesImages)
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        if ScreenLockState.isLocked {
            var locked = ToolResult(requestID: request.id, content: ScreenLockState.reason, isError: true,
                                    metadata: ["screen_locked": "true"])
            locked.actionOutcome = .suspectedAbsent
            return locked
        }
        do {
            try Task.checkCancellation()
            switch request.name {
            case "bg_list_windows": return try await listWindows(request)
            case "bg_observe_window": return try await observe(request)
            case "bg_click", "bg_type_text", "bg_set_value", "bg_scroll", "bg_press_key":
                return try await act(request)
            case "bg_click_sequence":
                return try await clickSequence(request)
            default: throw AgentCuaError.invalidArgument("unknown tool")
            }
        } catch {
            var result = ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
            if request.name != "bg_list_windows" && request.name != "bg_observe_window" {
                result.actionOutcome = Self.isPreDelivery(error) ? .suspectedAbsent : .unknown
            }
            return result
        }
    }

    public func cancel(requestID: String) async {
        await adapter?.invalidate()
        observation = nil
    }

    public func closeSession() async {
        await adapter?.invalidate()
        client?.stop()
        await host?.stop()
        client = nil; host = nil; adapter = nil; observation = nil
        await leases.release(owner: owner)
        await ComputerUseActivity.shared.ended()
    }

    /// Screen point (Quartz coordinates) the action targets, for the visible AI cursor.
    static func point(of action: CuaBackgroundAction, state: CuaWindowState) -> CGPoint? {
        func element(_ index: Int) -> CGPoint? {
            guard let frame = state.elements.first(where: { $0.index == index })?.frame, frame.width > 0 else { return nil }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        func pixel(_ x: Double, _ y: Double) -> CGPoint? {
            guard let geometry = state.screenshot, let bounds = geometry.windowBounds, geometry.scale > 0 else { return nil }
            return CGPoint(x: bounds.minX + x / geometry.scale, y: bounds.minY + y / geometry.scale)
        }
        switch action {
        case .click(let index), .typeText(let index, _), .setValue(let index, _), .scroll(let index, _, _), .pressKey(let index, _):
            return element(index)
        case .clickPixel(let x, let y), .scrollPixel(let x, let y, _, _):
            return pixel(x, y)
        }
    }

    static func describe(_ action: CuaBackgroundAction, state: CuaWindowState, app: String) -> String {
        func name(_ index: Int) -> String {
            let label = state.elements.first(where: { $0.index == index })?.label ?? ""
            return label.isEmpty ? "an element" : "“\(label.prefix(40))”"
        }
        switch action {
        case .click(let index): return "Clicking \(name(index)) in \(app)"
        case .clickPixel: return "Clicking in \(app)"
        case .typeText(let index, _): return "Typing into \(name(index)) in \(app)"
        case .setValue(let index, _): return "Setting \(name(index)) in \(app)"
        case .scroll, .scrollPixel: return "Scrolling in \(app)"
        case .pressKey(_, let key): return "Pressing \(key) in \(app)"
        }
    }

    // MARK: Mission scope and review

    public func missionIntent(for request: ToolRequest) async throws -> MissionToolIntent? {
        let operation: MissionOperation
        switch request.name {
        case "bg_observe_window": operation = .observe
        case "bg_type_text", "bg_set_value": operation = .input
        case "bg_scroll": operation = .navigate
        // Clicks and keys can commit a purchase or a message; exact approval.
        default: return nil
        }
        let target: Target
        if request.name == "bg_observe_window" {
            guard let ref = request.arguments["window_ref"], let found = windows[ref] else { return nil }
            target = found
        } else {
            guard let current = observation, request.arguments["observation_id"] == current.id else { return nil }
            target = current.target
            // After the person used this app, the next action needs a person again.
            if await leases.hasHumanConflict(pid: target.pid) { return nil }
        }
        guard let bundleID = target.bundleID else { return nil }
        return MissionToolIntent(operation: operation,
            target: try MissionResource(kind: .application, identifier: bundleID))
    }

    /// Host-owned approval text: the exact element as AIM observed it.
    public func review(_ request: ToolRequest) async throws -> ToolReview? {
        guard request.name.hasPrefix("bg_"), request.name != "bg_list_windows",
              request.name != "bg_observe_window", let current = observation,
              request.arguments["observation_id"] == current.id else { return nil }
        if request.name == "bg_click_sequence" {
            let place = "\(current.target.appName) — \(current.target.title) (background, focus unchanged)"
            do {
                let indices = try Self.sequenceIndices(request, state: current.state)
                let labels = indices.compactMap { index in current.state.elements.first { $0.index == index }?.label }
                return ToolReview(path: place, before: "\(labels.count) clicks in this order",
                                  after: labels.map { "click “\($0.prefix(60))”" }.joined(separator: "\n"))
            } catch {
                return ToolReview(path: place, before: "Invalid click sequence", after: error.localizedDescription)
            }
        }
        let element = Int(request.arguments["element_index"] ?? "").flatMap { index in
            current.state.elements.first { $0.index == index }
        }
        let place = "\(current.target.appName) — \(current.target.title) (background, focus unchanged)"
        let what = element.map { "\($0.role) “\(String($0.label.prefix(120)))”" } ??
            "point x=\(request.arguments["x"] ?? "?"), y=\(request.arguments["y"] ?? "?") of the observed screenshot"
        var change = request.name.replacingOccurrences(of: "bg_", with: "")
        if let text = request.arguments["text"] ?? request.arguments["value"] { change += ": “\(String(text.prefix(400)))”" }
        if let key = request.arguments["key"] { change += ": \(key)" }
        if let direction = request.arguments["direction"] { change += ": \(direction)" }
        return ToolReview(path: place, before: what, after: change)
    }

    // MARK: Tools

    private func listWindows(_ request: ToolRequest) async throws -> ToolResult {
        let client = try await session().client
        observation = nil
        let raw = try await client.callRawTool("list_windows", arguments: ["on_screen_only": true])
        let rows = Self.windowRows(raw["structuredContent"])
        let applications = await MainActor.run {
            Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                       uniquingKeysWith: { first, _ in first })
                .mapValues { (name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier, launchedAt: $0.launchDate) }
        }
        windows.removeAll()
        nextWindowRef = 1
        var listed: [[String: Any]] = []
        for row in rows {
            guard let pid = (row["pid"] as? Int).map(Int32.init), pid != getpid(),
                  let windowID = row["window_id"] as? Int, (row["layer"] as? Int ?? 0) == 0,
                  let app = applications[pid], let launchedAt = app.launchedAt else { continue }
            let title = row["title"] as? String ?? ""
            let bounds = CuaWindowStateParser.rect(row["bounds"])
            // Menu-bar and similar chrome surfaces are untitled thin strips.
            if title.isEmpty, let bounds, bounds.height <= 48 { continue }
            let ref = "w\(nextWindowRef)"
            nextWindowRef += 1
            windows[ref] = Target(pid: pid, windowID: windowID, launchedAt: launchedAt,
                appName: app.name, bundleID: app.bundleID, title: title)
            var entry: [String: Any] = ["window_ref": ref, "app": app.name, "title": String(title.prefix(200))]
            if let bounds { entry["bounds"] = ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height] }
            listed.append(entry)
            if listed.count >= 120 { break }
        }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["windows": listed],
            options: [.sortedKeys]), as: UTF8.self) +
            "\nOnly windows on the current Space are listed; windows on other Spaces or minimized cannot be controlled in the background. Use bg_observe_window with a window_ref."
        return ToolResult(requestID: request.id, content: content,
            metadata: ["window_count": String(listed.count)])
    }

    private func observe(_ request: ToolRequest) async throws -> ToolResult {
        guard let ref = request.arguments["window_ref"], let target = windows[ref] else {
            throw AgentCuaError.invalidArgument("Unknown window_ref; call bg_list_windows first.")
        }
        let wantsImage = request.arguments["include_screenshot"] == "true" && modelSeesImages
        let result = try await freshObservation(of: target, includeScreenshot: wantsImage)
        var content = result.content
        if wantsImage && result.image == nil {
            content += "\nNo screenshot pixels were returned for this window."
        }
        return ToolResult(requestID: request.id, content: content,
            metadata: ["observation_id": result.id, "actionable": String(result.state.isActionable)],
            imagePNG: result.image)
    }

    private func act(_ request: ToolRequest) async throws -> ToolResult {
        guard let current = observation, request.arguments["observation_id"] == current.id else {
            throw AgentCuaError.staleObservation
        }
        let action = try Self.action(for: request, state: current.state, pixelAllowed: qualified[.pixelClick] != nil &&
            modelSeesImages)
        let receipt = try await perform(action, on: current)
        var content = "\(receipt.detail)"
        var metadata = Self.metadata(for: receipt)
        // Reobserve, but send only what changed: a full snapshot after every action
        // multiplied the cost of long action chains.
        if receipt.outcome != .unknown || receipt.report != nil,
           let after = try? await freshObservation(of: current.target, includeScreenshot: false) {
            content += "\n" + Self.changeSummary(from: current.state, to: after.state, observationID: after.id)
            metadata["observation_id"] = after.id
        }
        return ToolResult(requestID: request.id, content: content, isError: receipt.outcome == .unknown,
            metadata: metadata)
    }

    /// Several clicks in one call (e.g. calculator keys). Each step re-reads the
    /// window and finds the next element again by role and label, so indices
    /// shifting between steps cannot misdirect a click; it stops at the first problem.
    private func clickSequence(_ request: ToolRequest) async throws -> ToolResult {
        guard let first = observation, request.arguments["observation_id"] == first.id else {
            throw AgentCuaError.staleObservation
        }
        let indices = try Self.sequenceIndices(request, state: first.state)
        let identities = indices.map { index -> (String, String) in
            let element = first.state.elements.first { $0.index == index }!
            return (element.role, element.label)
        }
        var current = first
        var done: [String] = []
        for (step, identity) in identities.enumerated() {
            if step > 0 {
                let fresh = try await freshObservation(of: first.target, includeScreenshot: false)
                guard let next = observation, next.id == fresh.id else { throw AgentCuaError.staleObservation }
                current = next
            }
            let matches = current.state.elements.filter { $0.role == identity.0 && $0.label == identity.1 }
            guard matches.count == 1, let index = matches.first?.index else {
                let summary = "Stopped before step \(step + 1) of \(identities.count): “\(identity.1)” is no longer a unique element. Completed: \(done.isEmpty ? "none" : done.joined(separator: ", "))."
                return ToolResult(requestID: request.id, content: summary, isError: true,
                                  metadata: ["action_outcome": done.isEmpty ? ActionOutcome.suspectedAbsent.rawValue : ActionOutcome.partial.rawValue])
            }
            let receipt = try await perform(.click(elementIndex: index), on: current)
            if receipt.outcome == .unknown {
                return ToolResult(requestID: request.id,
                    content: "Step \(step + 1) (“\(identity.1)”) has an unknown outcome; stopped. Completed before it: \(done.joined(separator: ", ")).",
                    isError: true, metadata: ["action_outcome": ActionOutcome.unknown.rawValue])
            }
            done.append("“\(identity.1)”")
        }
        var content = "Clicked in order: \(done.joined(separator: ", "))."
        var metadata: [String: String] = ["action_outcome": ActionOutcome.unverified.rawValue, "clicks": String(done.count)]
        if let after = try? await freshObservation(of: first.target, includeScreenshot: false) {
            content += "\n" + Self.changeSummary(from: first.state, to: after.state, observationID: after.id)
            metadata["observation_id"] = after.id
        }
        return ToolResult(requestID: request.id, content: content, metadata: metadata)
    }

    static func sequenceIndices(_ request: ToolRequest, state: CuaWindowState) throws -> [Int] {
        // Models send numbers or numeric strings; a bare comma list is accepted too.
        let raw = request.arguments["element_indices"] ?? ""
        let decoded: [Int]? = (try? JSONDecoder().decode([Int].self, from: Data(raw.utf8)))
            ?? (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))).flatMap { values in
                let numbers = values.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                return numbers.count == values.count ? numbers : nil
            }
            ?? {
                let parts = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",")
                let numbers = parts.compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))) }
                return !parts.isEmpty && numbers.count == parts.count ? numbers : nil
            }()
        guard let indices = decoded, (1...20).contains(indices.count) else {
            throw AgentCuaError.invalidArgument("element_indices must be a JSON array of 1 to 20 element indices.")
        }
        for index in indices {
            guard let element = state.elements.first(where: { $0.index == index }), !element.label.isEmpty,
                  state.elements.filter({ $0.role == element.role && $0.label == element.label }).count == 1 else {
                throw AgentCuaError.invalidArgument("Every element of a sequence needs a unique, labelled element (index \(index) is not); click it separately.")
            }
        }
        return indices
    }

    /// The single delivery path for every background action: person priority,
    /// visibility, target lease, the visible AI cursor and disqualification.
    private func perform(_ action: CuaBackgroundAction,
                         on current: (id: String, target: Target, driverObservation: UUID, observedAt: Date, state: CuaWindowState))
        async throws -> CuaBackgroundActionReceipt {
        let capability = Self.capability(for: action)
        guard qualified[capability] != nil else { throw AgentCuaError.notQualified(capability) }
        let target = current.target
        observation = nil
        if await leases.humanInterventionSince(current.observedAt, pid: target.pid) {
            await leases.markHumanConflict(pid: target.pid)
            throw AgentCuaError.humanIntervention
        }
        let session = try await session()
        // The person cannot see a minimized, hidden or off-Space window; the driver
        // would still deliver to it, so AIM refuses before sending anything.
        guard try await isOnScreen(target, client: session.client) else { throw AgentCuaError.notOnScreen }
        try await leases.acquire(pid: target.pid, owner: owner)
        defer { Task { [leases, owner] in await leases.release(owner: owner) } }
        await ComputerUseActivity.shared.acting(Self.describe(action, state: current.state, app: target.appName),
                                                at: Self.point(of: action, state: current.state))
        let receipt: CuaBackgroundActionReceipt
        do {
            receipt = try await session.adapter.perform(action, observationID: current.driverObservation)
        } catch CuaBackgroundWindowError.foregroundConflict {
            await leases.markHumanConflict(pid: target.pid)
            throw AgentCuaError.humanIntervention
        }
        if receipt.report?.deliveredOutsideBackground == true {
            await disqualify(capability, "Delivered outside the background route on \(target.appName).")
        }
        // A person approved and AIM executed this action; future actions resume normal policy.
        await leases.clearHumanConflict(pid: target.pid)
        return receipt
    }

    private static func metadata(for receipt: CuaBackgroundActionReceipt) -> [String: String] {
        var metadata: [String: String] = ["action_outcome": receipt.outcome.rawValue,
                                          "focus_changed": String(receipt.focusChanged)]
        if let report = receipt.report {
            metadata["driver_effect"] = report.effect ?? "unknown"
            metadata["driver_route"] = report.route ?? "unknown"
        }
        return metadata
    }

    /// What changed between two observations of the same window, compactly.
    static func changeSummary(from before: CuaWindowState, to after: CuaWindowState, observationID: String) -> String {
        func describe(_ element: CuaWindowElement) -> String {
            var text = "[\(element.index)] \(element.role)"
            if !element.label.isEmpty { text += " “\(element.label.prefix(80))”" }
            if let value = element.value { text += " = “\(value.prefix(120))”" }
            return text
        }
        let old = Set(before.elements.map(describe))
        let new = after.elements.map(describe)
        let added = new.filter { !old.contains($0) }
        let removed = before.elements.count + added.count - after.elements.count
        let oldLines = Set(before.treeMarkdown.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let textChanges = after.treeMarkdown.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !oldLines.contains($0) && !$0.hasPrefix("- [") }
        var lines = ["Window after the action — observation_id \(observationID)."]
        if added.isEmpty && textChanges.isEmpty {
            lines.append("No visible change detected (static text and elements identical). Verify before repeating.")
        }
        if !textChanges.isEmpty { lines.append("Text now shown: " + textChanges.prefix(12).joined(separator: " | ")) }
        if !added.isEmpty {
            lines.append("New or changed elements: " + added.prefix(15).joined(separator: "; ") + (added.count > 15 ? " …" : ""))
        }
        if removed > 0 { lines.append("\(removed) element(s) no longer listed.") }
        lines.append("Call bg_observe_window for the full window.")
        return lines.joined(separator: "\n")
    }

    // MARK: Session and observation

    private func session() async throws -> (client: PlaywrightMCPClient, adapter: CuaBackgroundWindowAdapter) {
        if let client, let adapter { return (client, adapter) }
        guard let executable = CuaRuntimeIdentity.bundledDriver else { throw AgentCuaError.unavailable }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let host = EmbeddedCuaDriverHost(executable: executable, hostBundleID: bundleID)
        do {
            let connection = try await host.start()
            let client = try PlaywrightMCPClient(cuaDriver: executable, socketPath: connection.socketPath,
                hostBundleID: bundleID)
            try await client.initialize()
            _ = try await client.listTools()
            let digest = CuaRuntimeIdentity.schemaDigest(client)
            guard let digest, qualified.values.allSatisfy({ $0 == digest }) else {
                client.stop()
                await host.stop()
                throw AgentCuaError.schemaChanged
            }
            await leases.startMonitoring()
            let adapter = CuaBackgroundWindowAdapter(transport: CuaMCPTransport(client: client),
                generation: connection.generation)
            self.host = host; self.client = client; self.adapter = adapter
            return (client, adapter)
        } catch let error as AgentCuaError {
            throw error
        } catch {
            await host.stop()
            throw AgentCuaError.unavailableDetail(error.localizedDescription)
        }
    }

    private func freshObservation(of target: Target, includeScreenshot: Bool) async throws
        -> (id: String, state: CuaWindowState, content: String, image: Data?) {
        guard await MainActor.run(body: {
            NSRunningApplication(processIdentifier: target.pid)?.launchDate == target.launchedAt
        }) else { throw AgentCuaError.staleWindow }
        let session = try await session()
        guard try await isOnScreen(target, client: session.client) else { throw AgentCuaError.notOnScreen }
        let adapter = session.adapter
        let observedAt = Date.now
        let driverObservation = try await adapter.observe(pid: target.pid, windowID: target.windowID,
            includeScreenshot: includeScreenshot)
        let id = UUID().uuidString
        observation = (id, target, driverObservation.id, observedAt, driverObservation.state)
        await ComputerUseActivity.shared.observed(appName: target.appName, pid: target.pid,
                                                  windowID: CGWindowID(target.windowID))
        let state = driverObservation.state
        var payload: [String: Any] = ["observation_id": id, "app": target.appName,
                                      "title": String((state.windowTitle ?? target.title).prefix(200))]
        if let degradation = state.degradation {
            payload["actionable"] = false
            payload["limitation"] = degradation.summary
        } else {
            payload["actionable"] = true
            payload["elements"] = state.elements.prefix(150).map { element -> [String: Any] in
                var row: [String: Any] = ["index": element.index, "role": element.role]
                if !element.label.isEmpty { row["label"] = String(element.label.prefix(200)) }
                if let value = element.value { row["value"] = String(value.prefix(300)) }
                if element.enabled == false { row["enabled"] = false }
                if !element.actions.isEmpty { row["actions"] = element.actions }
                return row
            }
            if state.elements.count > 150 { payload["elements_truncated"] = state.elements.count }
            // The outline adds visible static text (labels, counters) that is not actionable.
            if !state.treeMarkdown.isEmpty {
                payload["outline"] = String(state.treeMarkdown.prefix(6_000))
                if state.treeMarkdown.count > 6_000 { payload["outline_truncated"] = true }
            }
        }
        if let geometry = state.screenshot, driverObservation.state.screenshotPNG != nil {
            payload["screenshot"] = ["width": geometry.width, "height": geometry.height,
                                     "origin": "top_left", "pixel_actions": qualified[.pixelClick] != nil]
        }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self)
        return (id, state, content, includeScreenshot ? state.screenshotPNG : nil)
    }

    private func isOnScreen(_ target: Target, client: PlaywrightMCPClient) async throws -> Bool {
        let raw = try await client.callRawTool("list_windows", arguments: ["pid": Int(target.pid), "on_screen_only": true])
        return Self.windowRows(raw["structuredContent"]).contains {
            $0["window_id"] as? Int == target.windowID && ($0["pid"] as? Int).map(Int32.init) == target.pid
        }
    }

    // MARK: Argument mapping

    static func action(for request: ToolRequest, state: CuaWindowState, pixelAllowed: Bool) throws -> CuaBackgroundAction {
        let arguments = request.arguments
        let index = arguments["element_index"].flatMap(Int.init)
        func requireIndex() throws -> Int {
            guard let index, state.elements.contains(where: { $0.index == index }) else {
                throw AgentCuaError.invalidArgument("element_index must name an element of the current observation.")
            }
            return index
        }
        switch request.name {
        case "bg_click":
            if let x = arguments["x"].flatMap(Double.init), let y = arguments["y"].flatMap(Double.init) {
                guard pixelAllowed, index == nil else {
                    throw AgentCuaError.invalidArgument("Pixel clicks are unavailable on this route.")
                }
                return .clickPixel(x: x, y: y)
            }
            return .click(elementIndex: try requireIndex())
        case "bg_type_text":
            guard let text = arguments["text"], !text.isEmpty, text.utf8.count <= 16_384 else {
                throw AgentCuaError.invalidArgument("text must be 1 to 16384 bytes.")
            }
            return .typeText(elementIndex: try requireIndex(), text: text)
        case "bg_set_value":
            guard let value = arguments["value"], value.utf8.count <= 16_384 else {
                throw AgentCuaError.invalidArgument("value must be at most 16384 bytes.")
            }
            return .setValue(elementIndex: try requireIndex(), value: value)
        case "bg_scroll":
            guard let direction = arguments["direction"], ["up", "down", "left", "right"].contains(direction) else {
                throw AgentCuaError.invalidArgument("direction must be up, down, left or right.")
            }
            let amount = arguments["amount"].flatMap(Int.init) ?? 3
            guard (1...25).contains(amount) else { throw AgentCuaError.invalidArgument("amount must be 1 to 25.") }
            if let x = arguments["x"].flatMap(Double.init), let y = arguments["y"].flatMap(Double.init) {
                guard pixelAllowed else { throw AgentCuaError.invalidArgument("Pixel scrolling is unavailable on this route.") }
                return .scrollPixel(x: x, y: y, direction: direction, amount: amount)
            }
            return .scroll(elementIndex: try requireIndex(), direction: direction, amount: amount)
        case "bg_press_key":
            guard let key = arguments["key"], !key.isEmpty, key.count <= 24,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                throw AgentCuaError.invalidArgument("key must be one key name without modifiers.")
            }
            return .pressKey(elementIndex: try requireIndex(), key: key)
        default:
            throw AgentCuaError.invalidArgument("unknown action")
        }
    }

    static func capability(for action: CuaBackgroundAction) -> CuaCapability {
        switch action {
        case .click: .axClick
        case .clickPixel: .pixelClick
        case .typeText: .typeText
        case .setValue: .setValue
        case .scroll, .scrollPixel: .scroll
        case .pressKey: .pressKey
        }
    }

    private static func isPreDelivery(_ error: Error) -> Bool {
        if error is AgentCuaError || error is CuaTargetLeaseCoordinator.LeaseError { return true }
        guard let error = error as? CuaBackgroundWindowError else { return false }
        switch error {
        case .invalidObservation, .missingElement, .staleProcess, .busy, .secureInput, .pixelsUnavailable,
             .degraded, .foregroundConflict, .invalidTarget, .unavailableProcess: return true
        case .invalidResponse, .refused: return false
        }
    }

    private static func windowRows(_ value: Any?) -> [[String: Any]] {
        if let rows = value as? [[String: Any]], rows.contains(where: { $0["window_id"] != nil }) { return rows }
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let rows = windowRows(dictionary[key])
                if !rows.isEmpty { return rows }
            }
        }
        return []
    }
}

enum AgentCuaError: LocalizedError, Equatable {
    case unavailable, unavailableDetail(String), schemaChanged, staleObservation, staleWindow
    case humanIntervention, notQualified(CuaCapability), invalidArgument(String), notOnScreen

    var errorDescription: String? {
        switch self {
        case .unavailable: "Background control is not bundled in this build."
        case .unavailableDetail(let detail): "Background control could not start: \(detail)"
        case .schemaChanged: "The background driver changed since it was qualified; background control is disabled until it is requalified."
        case .staleObservation: "Use the observation_id of the latest bg_observe_window result; observations expire after any action."
        case .staleWindow: "The window's application restarted or quit. List windows again."
        case .humanIntervention: "The person at the Mac is using this application, so background input was stopped and nothing was sent. Call the action again: AIM asks the person for their approval on this app and waits for them. Do not abandon the task."
        case .notQualified(let capability): "The \(capability.rawValue) background capability is not qualified on this Mac."
        case .invalidArgument(let detail): detail
        case .notOnScreen: "The window is minimized, hidden or not on the current Space, so the person cannot see it. Nothing was sent; ask them to show it first."
        }
    }
}
