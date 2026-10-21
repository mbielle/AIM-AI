import AIMAgentKit
import AppKit
import Foundation

/// The narrow CUA surface AIM can qualify independently of the model tool
/// registry. The transport is owned by one embedded daemon generation.
protocol CuaWindowToolCalling: Sendable {
    func callRawTool(_ name: String, arguments: Data) async throws -> Data
}

struct CuaMCPTransport: CuaWindowToolCalling {
    let client: PlaywrightMCPClient

    func callRawTool(_ name: String, arguments: Data) async throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw CuaBackgroundWindowError.invalidTarget
        }
        let result = try await client.callRawTool(name, arguments: object)
        return try JSONSerialization.data(withJSONObject: result)
    }
}

struct CuaWindowObservation: Sendable {
    let id: UUID
    let generation: UUID
    let pid: Int32
    let windowID: Int
    let processLaunchedAt: Date
    let state: CuaWindowState

    var snapshotID: String? { state.snapshotID }
    var elements: [CuaWindowElement] { state.elements }
}

/// One host-chosen background input. Delivery is always fixed to the
/// background route by AIM; the model never selects foreground delivery.
enum CuaBackgroundAction: Sendable, Equatable {
    case click(elementIndex: Int)
    /// Window-local screenshot pixels of the observation that authorized it.
    case clickPixel(x: Double, y: Double)
    case typeText(elementIndex: Int, text: String)
    case setValue(elementIndex: Int, value: String)
    case scroll(elementIndex: Int, direction: String, amount: Int)
    /// Pixel-wheel scroll at window-local screenshot pixels.
    case scrollPixel(x: Double, y: Double, direction: String, amount: Int)
    case pressKey(elementIndex: Int, key: String)

    var toolName: String {
        switch self {
        case .click, .clickPixel: "click"
        case .typeText: "type_text"
        case .setValue: "set_value"
        case .scroll, .scrollPixel: "scroll"
        case .pressKey: "press_key"
        }
    }

    var pixel: (x: Double, y: Double)? {
        switch self {
        case .clickPixel(let x, let y), .scrollPixel(let x, let y, _, _): (x, y)
        default: nil
        }
    }

    var elementIndex: Int? {
        switch self {
        case .click(let index), .typeText(let index, _), .setValue(let index, _),
             .scroll(let index, _, _), .pressKey(let index, _): index
        case .clickPixel, .scrollPixel: nil
        }
    }

    /// Keys can enter text as well; all three require a positively non-secure target.
    var entersText: Bool {
        switch self {
        case .typeText, .setValue, .pressKey: true
        default: false
        }
    }
}

struct CuaBackgroundActionReceipt: Sendable {
    let outcome: ActionOutcome
    let detail: String
    let focusChanged: Bool
    let report: CuaActionReport?
}

enum CuaBackgroundWindowError: LocalizedError, Equatable {
    case invalidTarget, unavailableProcess, foregroundConflict, invalidObservation
    case invalidResponse, missingElement, staleProcess, busy, secureInput, pixelsUnavailable
    case degraded(CuaDegradation)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "The CUA target must be one exact live window and process."
        case .unavailableProcess: "The target process identity could not be established."
        case .foregroundConflict: "The user is using the target process; background input is suspended."
        case .invalidObservation: "The CUA observation is missing or was already used. Observe again."
        case .invalidResponse: "CUA did not return a valid, window-scoped snapshot."
        case .missingElement: "The selected element was not present in this observation."
        case .staleProcess: "The target process restarted after observation."
        case .busy: "A CUA observation or action is already in progress."
        case .secureInput: "Text entry into a secure or unidentified field is refused."
        case .pixelsUnavailable: "This observation has no valid screenshot geometry for a pixel action."
        case .degraded(let degradation): degradation.summary
        case .refused(let detail): "CUA refused the request: \(detail)"
        }
    }
}

/// Makes one background action against a freshly observed exact window. It
/// never silently escalates to foreground delivery or retries an uncertain
/// action. No model-facing tool uses a capability until signed-bundle
/// qualification has verified its effect.
actor CuaBackgroundWindowAdapter {
    typealias ProcessState = @Sendable (Int32) -> Date?
    typealias ForegroundPID = @Sendable () -> Int32?
    /// Classifies the target of a text action using AIM's own AX view, since the
    /// driver does not expose secure subroles. Only `.safe` permits text entry.
    typealias InputSafety = @Sendable (_ pid: Int32, _ element: CuaWindowElement) async -> CuaInputSafety

    static let maximumElements = 300

    private let transport: any CuaWindowToolCalling
    private let generation: UUID
    private let processLaunchedAt: ProcessState
    private let foregroundPID: ForegroundPID
    private let inputSafety: InputSafety
    private var current: CuaWindowObservation?
    private var busy = false
    private var epoch = 0

    init(transport: any CuaWindowToolCalling, generation: UUID,
         processLaunchedAt: @escaping ProcessState = { NSRunningApplication(processIdentifier: $0)?.launchDate },
         foregroundPID: @escaping ForegroundPID = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         inputSafety: @escaping InputSafety = { pid, element in
             await MainActor.run { CuaSecureInputGuard.classify(pid: pid, element: element) }
         }) {
        self.transport = transport
        self.generation = generation
        self.processLaunchedAt = processLaunchedAt
        self.foregroundPID = foregroundPID
        self.inputSafety = inputSafety
    }

    /// A degraded window still yields an observation (useful for pixels), but
    /// element actions are refused for it.
    func observe(pid: Int32, windowID: Int, includeScreenshot: Bool = false) async throws -> CuaWindowObservation {
        guard !busy else { throw CuaBackgroundWindowError.busy }
        current = nil
        guard pid > 0, windowID > 0 else { throw CuaBackgroundWindowError.invalidTarget }
        guard let launchedAt = processLaunchedAt(pid) else { throw CuaBackgroundWindowError.unavailableProcess }
        busy = true
        let startedAtEpoch = epoch
        defer { busy = false }
        let arguments = try JSONSerialization.data(withJSONObject: [
            "pid": Int(pid), "window_id": windowID,
            "include_screenshot": includeScreenshot, "max_elements": Self.maximumElements
        ])
        let rawData = try await transport.callRawTool("get_window_state", arguments: arguments)
        guard let raw = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw CuaBackgroundWindowError.invalidResponse
        }
        let state: CuaWindowState
        do {
            state = try CuaWindowStateParser.parse(raw, pid: pid, windowID: windowID,
                maximumElements: Self.maximumElements)
        } catch CuaContractError.refused(let detail) {
            throw CuaBackgroundWindowError.refused(detail)
        } catch {
            throw CuaBackgroundWindowError.invalidResponse
        }
        guard processLaunchedAt(pid) == launchedAt else { throw CuaBackgroundWindowError.staleProcess }
        guard epoch == startedAtEpoch else { throw CuaBackgroundWindowError.invalidObservation }
        let observation = CuaWindowObservation(id: UUID(), generation: generation, pid: pid,
            windowID: windowID, processLaunchedAt: launchedAt, state: state)
        current = observation
        return observation
    }

    func clickElement(observationID: UUID, elementIndex: Int) async throws -> CuaBackgroundActionReceipt {
        try await perform(.click(elementIndex: elementIndex), observationID: observationID)
    }

    func perform(_ action: CuaBackgroundAction, observationID: UUID) async throws -> CuaBackgroundActionReceipt {
        guard !busy else { throw CuaBackgroundWindowError.busy }
        guard let observation = current, observation.id == observationID,
              observation.generation == generation else { throw CuaBackgroundWindowError.invalidObservation }
        var element: CuaWindowElement?
        if let index = action.elementIndex {
            if let degradation = observation.state.degradation {
                current = nil
                throw CuaBackgroundWindowError.degraded(degradation)
            }
            guard let found = observation.elements.first(where: { $0.index == index }) else {
                throw CuaBackgroundWindowError.missingElement
            }
            element = found
        } else if let (x, y) = action.pixel {
            guard let geometry = observation.state.screenshot, geometry.frameValid,
                  x >= 0, y >= 0, x < Double(geometry.width), y < Double(geometry.height) else {
                throw CuaBackgroundWindowError.pixelsUnavailable
            }
        }
        // Consume before any await so reentrant calls cannot double-act.
        current = nil
        guard processLaunchedAt(observation.pid) == observation.processLaunchedAt else {
            throw CuaBackgroundWindowError.staleProcess
        }
        guard let frontmostBefore = foregroundPID(), frontmostBefore != observation.pid else {
            throw CuaBackgroundWindowError.foregroundConflict
        }
        if action.entersText {
            guard let element, await inputSafety(observation.pid, element) == .safe else {
                throw CuaBackgroundWindowError.secureInput
            }
        }
        busy = true
        let startedAtEpoch = epoch
        defer { busy = false }
        let arguments = Self.arguments(for: action, observation: observation, element: element)
        do {
            let request = try JSONSerialization.data(withJSONObject: arguments)
            let rawData = try await transport.callRawTool(action.toolName, arguments: request)
            guard let result = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
                throw CuaBackgroundWindowError.invalidResponse
            }
            let report = CuaActionReport.parse(result)
            let changed = foregroundPID() != frontmostBefore
            if epoch != startedAtEpoch {
                return CuaBackgroundActionReceipt(outcome: .unknown,
                    detail: "The CUA action was invalidated while in flight; its effect is unknown.",
                    focusChanged: changed, report: report)
            }
            if report.refused {
                return CuaBackgroundActionReceipt(outcome: .suspectedAbsent,
                    detail: "CUA refused the background action before delivery; nothing was sent. \(report.detail)",
                    focusChanged: changed, report: report)
            }
            if report.isError {
                return CuaBackgroundActionReceipt(outcome: .unknown,
                    detail: "CUA failed the action after admission; inspect a fresh target observation before retrying. \(report.detail)",
                    focusChanged: changed, report: report)
            }
            if changed || report.deliveredOutsideBackground {
                return CuaBackgroundActionReceipt(outcome: .unknown,
                    detail: "The action was not confined to the background route; its effect is uncertain.",
                    focusChanged: true, report: report)
            }
            let outcome = report.outcome(hostConfirmed: nil)
            return CuaBackgroundActionReceipt(outcome: outcome,
                detail: outcome == .suspectedAbsent
                    ? "CUA suspects the action had no effect. Observe again before choosing another route."
                    : "CUA delivered the action in the background. Reobserve the target to verify its effect.",
                focusChanged: false, report: report)
        } catch {
            return CuaBackgroundActionReceipt(outcome: .unknown,
                detail: "The CUA connection failed after action admission. Its effect is unknown.",
                focusChanged: foregroundPID() != frontmostBefore, report: nil)
        }
    }

    func invalidate() { epoch &+= 1; current = nil }

    /// Flat arguments accepted by every input tool of the pinned 0.28.2 contract.
    static func arguments(for action: CuaBackgroundAction, observation: CuaWindowObservation,
                          element: CuaWindowElement?) -> [String: Any] {
        var arguments: [String: Any] = ["pid": Int(observation.pid), "window_id": observation.windowID]
        if action.toolName != "set_value" { arguments["delivery_mode"] = "background" }
        if let element {
            if let token = element.token, !token.isEmpty {
                arguments["element_token"] = token
            } else if let snapshot = observation.snapshotID {
                arguments["element_index"] = element.index
                arguments["snapshot_id"] = snapshot
            }
        }
        switch action {
        case .click: break
        case .clickPixel(let x, let y):
            arguments["x"] = x
            arguments["y"] = y
        case .scrollPixel(let x, let y, let direction, let amount):
            arguments["x"] = x
            arguments["y"] = y
            arguments["direction"] = direction
            arguments["amount"] = amount
        case .typeText(_, let text): arguments["text"] = text
        case .setValue(_, let value): arguments["value"] = value
        case .scroll(_, let direction, let amount):
            arguments["direction"] = direction
            arguments["amount"] = amount
        case .pressKey(_, let key): arguments["key"] = key
        }
        return arguments
    }
}
