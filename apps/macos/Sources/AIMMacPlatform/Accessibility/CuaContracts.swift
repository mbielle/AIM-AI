import AIMAgentKit
import CoreGraphics
import Foundation

/// One actionable element from a matched CUA snapshot. The driver lists only
/// actionable nodes; static text without actions is absent by contract.
struct CuaWindowElement: Sendable, Equatable {
    let index: Int
    let token: String?
    let role: String
    let label: String
    let value: String?
    let enabled: Bool?
    let actions: [String]
    let frame: CGRect?
}

/// Why the driver returned no actionable snapshot. A degraded window can still
/// be observed visually, but element actions are never offered for it.
enum CuaDegradation: Sendable, Equatable {
    /// The CG window could not be matched to an AXWindow (e.g. other Space,
    /// menu-bar surface, or a window AX does not expose on this Space).
    case axWindowUnresolved(axWindowCount: Int?)
    /// The window was matched but exposes no actionable AX element.
    case axTreeEmpty
    case other(String)

    init(reason: String) {
        if reason.hasPrefix("ax_window_unresolved") {
            let count = reason.range(of: #"none of the (\d+) AXWindow"#, options: .regularExpression)
                .flatMap { Int(reason[$0].split(separator: " ")[3]) }
            self = .axWindowUnresolved(axWindowCount: count)
        } else if reason.hasPrefix("ax_tree_empty") {
            self = .axTreeEmpty
        } else {
            self = .other(String(reason.prefix(300)))
        }
    }

    var summary: String {
        switch self {
        case .axWindowUnresolved(let count):
            "The window is not matched to an accessibility window (\(count.map(String.init) ?? "unknown") AX windows visible). It may be on another Space, minimized, hidden or a menu-bar surface."
        case .axTreeEmpty:
            "The window exposes no actionable accessibility element; only visual inspection is possible."
        case .other(let reason):
            "The driver reported a degraded observation: \(reason)"
        }
    }
}

struct CuaScreenshotGeometry: Sendable, Equatable {
    let width: Int
    let height: Int
    let scale: Double
    let frameValid: Bool
    let windowBounds: CGRect?
}

/// A parsed `get_window_state` response, validated against the exact target.
struct CuaWindowState: Sendable {
    let snapshotID: String?
    let windowTitle: String?
    let elements: [CuaWindowElement]
    let degradation: CuaDegradation?
    let elementsComplete: Bool?
    let screenshot: CuaScreenshotGeometry?
    let screenshotPNG: Data?
    /// The driver's indented AX outline, including non-actionable text.
    var treeMarkdown: String = ""

    var isActionable: Bool { degradation == nil && snapshotID != nil }
}

enum CuaContractError: LocalizedError, Equatable {
    case refused(String)
    case malformed(String)
    case degraded(CuaDegradation)

    var errorDescription: String? {
        switch self {
        case .refused(let detail): "CUA refused the request: \(detail)"
        case .malformed(let detail): "CUA returned an unexpected window snapshot (\(detail))."
        case .degraded(let degradation): degradation.summary
        }
    }
}

enum CuaWindowStateParser {
    static func parse(_ raw: [String: Any], pid: Int32, windowID: Int, maximumElements: Int) throws -> CuaWindowState {
        if raw["isError"] as? Bool == true {
            throw CuaContractError.refused(String(textContent(raw).prefix(400)))
        }
        guard let structured = raw["structuredContent"] as? [String: Any] else {
            throw CuaContractError.malformed("missing structured content")
        }
        if let actualPID = structured["pid"] as? Int, actualPID != Int(pid) {
            throw CuaContractError.malformed("pid mismatch")
        }
        if let actualWindow = structured["window_id"] as? Int, actualWindow != windowID {
            throw CuaContractError.malformed("window mismatch")
        }
        let rows = structured["elements"] as? [[String: Any]] ?? []
        let screenshot = geometry(structured)
        let image = pngImage(raw)
        if structured["degraded"] as? Bool == true {
            guard rows.isEmpty, (structured["snapshot_id"] as? String)?.isEmpty != false else {
                throw CuaContractError.malformed("degraded snapshot carried actionable elements")
            }
            let reason = structured["degraded_reason"] as? String ?? "unspecified"
            return CuaWindowState(snapshotID: nil, windowTitle: structured["window_title"] as? String,
                elements: [], degradation: CuaDegradation(reason: reason),
                elementsComplete: structured["elements_complete"] as? Bool, screenshot: screenshot,
                screenshotPNG: image, treeMarkdown: "")
        }
        guard let snapshotID = structured["snapshot_id"] as? String, !snapshotID.isEmpty else {
            throw CuaContractError.malformed("no snapshot for a non-degraded window")
        }
        guard rows.count <= maximumElements else { throw CuaContractError.malformed("too many elements") }
        var tokenPrefix: Substring?
        var seen: Set<Int> = []
        let elements = try rows.map { row -> CuaWindowElement in
            guard let index = row["element_index"] as? Int, index >= 0, seen.insert(index).inserted,
                  let role = row["role"] as? String else {
                throw CuaContractError.malformed("element without a unique index and role")
            }
            let token = row["element_token"] as? String
            if let token {
                // Tokens are `s<hex>:<index>` and must all belong to this snapshot.
                let parts = token.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0].hasPrefix("s"), Int(parts[1]) == index,
                      tokenPrefix == nil || tokenPrefix == parts[0] else {
                    throw CuaContractError.malformed("element token does not match its snapshot")
                }
                tokenPrefix = parts[0]
            }
            return CuaWindowElement(index: index, token: token, role: role,
                label: row["label"] as? String ?? "", value: stringValue(row["value"]),
                enabled: row["enabled"] as? Bool, actions: row["actions"] as? [String] ?? [],
                frame: rect(row["frame"]))
        }
        return CuaWindowState(snapshotID: snapshotID, windowTitle: structured["window_title"] as? String,
            elements: elements, degradation: nil,
            elementsComplete: structured["elements_complete"] as? Bool, screenshot: screenshot,
            screenshotPNG: image, treeMarkdown: String((structured["tree_markdown"] as? String ?? "").prefix(64 * 1_024)))
    }

    static func textContent(_ raw: [String: Any]) -> String {
        (raw["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private static func geometry(_ structured: [String: Any]) -> CuaScreenshotGeometry? {
        guard let width = structured["screenshot_width"] as? Int,
              let height = structured["screenshot_height"] as? Int else { return nil }
        return CuaScreenshotGeometry(width: width, height: height,
            scale: (structured["screenshot_scale"] as? NSNumber)?.doubleValue ?? 1,
            frameValid: structured["screenshot_frame_valid"] as? Bool ?? false,
            windowBounds: rect(structured["window_bounds"]))
    }

    private static func pngImage(_ raw: [String: Any]) -> Data? {
        for block in raw["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "image" {
            guard block["mimeType"] as? String == "image/png", let encoded = block["data"] as? String,
                  let data = Data(base64Encoded: encoded), data.count <= 6_000_000,
                  data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { continue }
            return data
        }
        return nil
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let object = value as? [String: Any],
              let x = (object["x"] as? NSNumber)?.doubleValue, let y = (object["y"] as? NSNumber)?.doubleValue,
              let width = ((object["width"] ?? object["w"]) as? NSNumber)?.doubleValue,
              let height = ((object["height"] ?? object["h"]) as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}

/// The driver's own account of an input action. It is never proof of effect:
/// AIM still has to observe the target before reporting success.
/// Shape (0.28.2): `{delivery: {mode, delivered_count?}, effect, evidence?, route}`.
struct CuaActionReport: Sendable, Equatable {
    let isError: Bool
    /// `background`, `foreground`, `not_applicable` or `unknown`.
    let deliveryMode: String?
    /// e.g. `accessibility` or `synthetic_events`.
    let route: String?
    /// `confirmed`, `unverifiable`, `suspected_noop` or `refused`.
    let effect: String?
    let evidence: [String]
    let escalation: String?
    let detail: String
    /// Sorted JSON of the driver's structured result, kept for qualification evidence.
    let structuredJSON: String

    static func parse(_ raw: [String: Any]) -> CuaActionReport {
        let structured = raw["structuredContent"] as? [String: Any] ?? [:]
        let delivery = structured["delivery"] as? [String: Any]
        let escalation = (structured["escalation"] as? [String: Any])?["recommended"] as? String
        let evidence = (structured["evidence"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        let json = (try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]))
            .map { String(decoding: $0.prefix(4_096), as: UTF8.self) } ?? "{}"
        return CuaActionReport(isError: raw["isError"] as? Bool ?? false,
            deliveryMode: delivery?["mode"] as? String, route: structured["route"] as? String,
            effect: structured["effect"] as? String, evidence: evidence, escalation: escalation,
            detail: String(CuaWindowStateParser.textContent(raw).prefix(400)), structuredJSON: json)
    }

    var isBackground: Bool { deliveryMode == "background" }
    /// The driver declined before delivering anything.
    var refused: Bool { effect == "refused" }
    /// Anything but background delivery may have changed focus; such a capability
    /// is disqualified, never treated as a background success.
    var deliveredOutsideBackground: Bool { !refused && !isBackground }

    func outcome(hostConfirmed: Bool?) -> ActionOutcome {
        if isError || deliveredOutsideBackground { return .unknown }
        if refused { return .suspectedAbsent }
        if let hostConfirmed { return hostConfirmed ? .confirmed : .suspectedAbsent }
        if effect == "suspected_noop" { return .suspectedAbsent }
        return .unverified
    }
}
