import Foundation
import CoreGraphics

public struct DesktopApplication: Codable, Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let isActive: Bool
    public let isHidden: Bool
    public let launchedAt: Date?
}

public struct DesktopAXWindow: Codable, Sendable {
    public let pid: pid_t
    public let title: String
    public let frame: CGRect?
    public let isMinimized: Bool?
    /// A unique geometry/title correlation, not an AX-provided system identifier.
    public let correlatedWindowID: CGWindowID?
}

public struct DesktopInventory: Codable, Sendable {
    public var applications: [DesktopApplication]
    public var windows: [DesktopWindow]
    public var warnings: [String]
    public var axWindows: [DesktopAXWindow]
    public var coverage = "best_effort_all_spaces; Space membership unknown; absent does not mean closed"

    /// macOS processes whose windows are never a task's target.
    static let systemOwners: Set<String> = ["Window Server", "Dock", "WindowManager", "Control Center", "ControlCenter",
        "SystemUIServer", "loginwindow", "Notification Center", "NotificationCenter", "Spotlight", "TextInputMenuAgent",
        "universalAccessAuthWarn", "Wallpaper", "Screenshot", "CursorUIViewService", "AutoFill", "Open and Save Panel Service"]

    /// What the model reads (Round 37): one line per useful window instead of the full inventory,
    /// which listed every process and cost ~15k tokens per call. `query` keeps windows whose app
    /// or title contains it.
    public func compactListing(query: String? = nil, limit: Int = 60) -> String {
        let filter = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let active = Set(applications.filter(\.isActive).map(\.pid))
        let useful = windows.filter { window in
            !Self.systemOwners.contains(window.applicationName) && window.frame.width >= 60 && window.frame.height >= 40
                && (!window.title.isEmpty || window.isOnScreen == true)
                && (filter.isEmpty || window.applicationName.lowercased().contains(filter) || window.title.lowercased().contains(filter))
        }.sorted {
            if active.contains($0.ownerPID) != active.contains($1.ownerPID) { return active.contains($0.ownerPID) }
            if ($0.isOnScreen == true) != ($1.isOnScreen == true) { return $0.isOnScreen == true }
            return $0.applicationName < $1.applicationName
        }
        var lines = ["Windows (window_id | app | title | state | size):"]
        for window in useful.prefix(limit) {
            var state: [String] = []
            if active.contains(window.ownerPID) { state.append("frontmost app") }
            if window.isMinimized == true { state.append("minimized") }
            else if window.isOnScreen == true { state.append("on screen") }
            else { state.append("other Space or hidden") }
            lines.append("- \(window.id) | \(window.applicationName) | \"\(window.title.isEmpty ? "(untitled)" : String(window.title.prefix(80)))\" | \(state.joined(separator: ", ")) | \(Int(window.frame.width))×\(Int(window.frame.height))")
        }
        if useful.isEmpty { lines.append("- none" + (filter.isEmpty ? "" : " matching \"\(filter)\"")) }
        if useful.count > limit { lines.append("(\(useful.count - limit) more; pass query to narrow)") }
        let withWindows = Set(useful.map(\.applicationName))
        let others = applications.map(\.name).filter { !withWindows.contains($0) && !Self.systemOwners.contains($0) }
        if filter.isEmpty, !others.isEmpty {
            lines.append("Other running apps (no listed window): " + others.sorted().prefix(30).joined(separator: ", ")
                         + (others.count > 30 ? " and \(others.count - 30) more" : ""))
        }
        lines.append("Coverage: " + coverage)
        if !warnings.isEmpty { lines.append("Warnings: " + warnings.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    public static func merge(_ first: [DesktopWindow], _ second: [DesktopWindow]) -> [DesktopWindow] {
        var merged = first
        for window in second {
            guard let index = merged.firstIndex(where: { $0.id == window.id && $0.ownerPID == window.ownerPID }) else {
                merged.append(window)
                continue
            }
            var latest = window
            latest.sources.formUnion(merged[index].sources)
            if latest.title.isEmpty { latest.title = merged[index].title }
            if latest.isOnScreen == nil { latest.isOnScreen = merged[index].isOnScreen }
            merged[index] = latest
        }
        return merged
    }
}

/// Facts sampled for one exact window. AX and pixels have independent
/// availability, so a partial observation never masquerades as a full one.
public struct DesktopObservation: Codable, Sendable {
    public let id: UUID
    public let window: DesktopWindow
    public let observedAt: Date
    public let axObservedAt: Date?
    public let imageCapturedAt: Date?
    public let targetVerifiedAt: Date
    public let imagePixelWidth: Int?
    public let imagePixelHeight: Int?
    public let imageCoordinateOrigin: String?
    public let axNodes: [DesktopObservedNode]
    public let axCoverage: String
    public let ocrText: String?
    public let warnings: [String]

    public var imageAvailable: Bool { imagePixelWidth != nil && imagePixelHeight != nil }

    public func matches(_ current: DesktopWindow) -> Bool {
        current.id == window.id && current.ownerPID == window.ownerPID &&
            current.processLaunchedAt == window.processLaunchedAt && current.frame == window.frame
    }
}

public struct DesktopObservedNode: Codable, Sendable {
    public let id: UUID
    public let role: String
    public let title: String?
    public let value: String?
    public let isEnabled: Bool
    public let depth: Int
    public let isSecure: Bool

    public init(_ node: AccessibilityNode) {
        id = node.id
        role = node.role
        title = node.isSecure ? nil : node.title
        value = node.isSecure ? nil : node.value.map { String($0.prefix(500)) }
        isEnabled = node.isEnabled
        depth = node.depth
        isSecure = node.isSecure
    }
}
