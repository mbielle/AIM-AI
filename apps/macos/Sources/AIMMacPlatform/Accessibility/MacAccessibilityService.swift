import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct DesktopWindow: Identifiable, Hashable, Codable, Sendable {
    public var id: CGWindowID
    public var ownerPID: pid_t
    public var applicationName: String
    public var title: String
    public var frame: CGRect
    public var sources: Set<String> = []
    public var isOnScreen: Bool?
    public var isMinimized: Bool?
    public var processLaunchedAt: Date?
    /// Presence in SCK is not proof of a successful capture.
    public var captureAvailability: String = "not_tested"

    public init(id: CGWindowID, ownerPID: pid_t, applicationName: String, title: String, frame: CGRect) {
        self.id = id
        self.ownerPID = ownerPID
        self.applicationName = applicationName
        self.title = title
        self.frame = frame
    }
}

public struct AccessibilityNode: Identifiable, Sendable {
    public var id: UUID
    public var role: String
    public var title: String?
    public var value: String?
    public var isEnabled: Bool
    public var depth: Int
    public var isSecure: Bool

    public init(id: UUID, role: String, title: String?, value: String?, isEnabled: Bool, depth: Int, isSecure: Bool = false) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.isEnabled = isEnabled
        self.depth = depth
        self.isSecure = isSecure
    }
}

public enum AccessibilityAction: Sendable {
    case press
    case focus
    case setValue(String)
}

public actor MacAccessibilityService {
    private var nodeElements: [UUID: AXUIElement] = [:]
    private var secureNodes: Set<UUID> = []
    private struct TypingTarget {
        let element: AXUIElement
        let expectedValue: String?
    }
    private var typingTargets: [UUID: TypingTarget] = [:]

    public init() {}

    /// Sources are merged, never used as mutually exclusive fallbacks.
    /// No source proves that every Space/window is observable on this OS.
    public func inventory(includeAccessibility: Bool = true) async -> DesktopInventory {
        let apps = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map {
                DesktopApplication(pid: $0.processIdentifier, name: $0.localizedName ?? "",
                    bundleID: $0.bundleIdentifier, isActive: $0.isActive, isHidden: $0.isHidden,
                    launchedAt: $0.launchDate)
            }
        }
        var report = DesktopInventory(applications: apps, windows: listWindows(), warnings: [], axWindows: [])
        if CGPreflightScreenCaptureAccess() {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let captured = content.windows.compactMap { window -> DesktopWindow? in
                    guard let app = window.owningApplication else { return nil }
                    var item = DesktopWindow(id: window.windowID, ownerPID: app.processID,
                        applicationName: app.applicationName, title: window.title ?? "", frame: window.frame)
                    item.sources = ["screen_capture_kit"]
                    item.isOnScreen = window.isOnScreen
                    item.captureAvailability = "listed_not_tested"
                    return item
                }
                report.windows = DesktopInventory.merge(report.windows, captured)
            } catch { report.warnings.append("ScreenCaptureKit enumeration failed: \(error.localizedDescription)") }
        } else {
            report.warnings.append("Screen Recording not granted; capture availability and some titles are unknown.")
        }
        if includeAccessibility && AXIsProcessTrusted() {
            for app in apps where app.pid != getpid() {
                let element = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(element, 0.2)
                var raw: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw)
                guard status == .success, let windows = raw as? [AXUIElement] else {
                    if status != .attributeUnsupported {
                        report.warnings.append("AX windows unavailable for PID \(app.pid) (\(status.rawValue)).")
                    }
                    continue
                }
                for window in windows {
                    let title = stringAttribute(kAXTitleAttribute as CFString, from: window) ?? ""
                    let frame = axFrame(window)
                    let minimized = boolAttribute(kAXMinimizedAttribute as CFString, from: window)
                    // AX has no guaranteed public CGWindowID. Preserve unmatched windows
                    // instead of inventing an ID or merging solely by title.
                    let matches = report.windows.indices.filter {
                        report.windows[$0].ownerPID == app.pid && frame == report.windows[$0].frame &&
                            title == report.windows[$0].title
                    }
                    let match = matches.count == 1 ? matches.first : nil
                    report.axWindows.append(DesktopAXWindow(pid: app.pid, title: title, frame: frame,
                        isMinimized: minimized, correlatedWindowID: match.map { report.windows[$0].id }))
                    if let match {
                        report.windows[match].sources.insert("accessibility_geometry_title_correlation")
                        report.windows[match].isMinimized = minimized
                    }
                }
            }
        } else if includeAccessibility { report.warnings.append("Accessibility not granted; AX windows were not queried.") }
        for index in report.windows.indices {
            report.windows[index].processLaunchedAt = apps.first { $0.pid == report.windows[index].ownerPID }?.launchedAt
        }
        report.windows.sort { ($0.ownerPID, $0.id) < ($1.ownerPID, $1.id) }
        return report
    }

    public func listWindowsVerified() async throws -> [DesktopWindow] {
        let report = await inventory(includeAccessibility: false)
        guard !report.windows.isEmpty else {
            throw MacAccessibilityError.windowEnumerationUnavailable(report.warnings.joined(separator: "; "))
        }
        return report.windows
    }

    public nonisolated static func externalWindows(_ windows: [DesktopWindow], excludingPID: pid_t) throws -> [DesktopWindow] {
        let external = windows.filter { $0.ownerPID != excludingPID }
        guard !external.isEmpty else { throw MacAccessibilityError.noExternalWindows }
        return external
    }

    public func listWindows() -> [DesktopWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { info in
            guard
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                let owner = info[kCGWindowOwnerName as String] as? String,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            var window = DesktopWindow(
                id: CGWindowID(number.uint32Value),
                ownerPID: pid.int32Value,
                applicationName: owner,
                title: info[kCGWindowName as String] as? String ?? "",
                frame: frame
            )
            window.sources = ["core_graphics_all"]
            window.isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool
            return window
        }
    }

    public func readApplication(pid: pid_t, maximumNodes: Int = 300) throws -> [AccessibilityNode] {
        guard AXIsProcessTrusted() else { throw MacAccessibilityError.permissionRequired }
        nodeElements.removeAll(keepingCapacity: true)
        secureNodes.removeAll(keepingCapacity: true)
        let application = AXUIElementCreateApplication(pid)
        var output: [AccessibilityNode] = []
        walk(application, depth: 0, maximumNodes: min(max(maximumNodes, 1), 2_000), output: &output)
        return output
    }

    public func readWindow(_ window: DesktopWindow, maximumNodes: Int = 300) throws -> [AccessibilityNode] {
        guard AXIsProcessTrusted() else { throw MacAccessibilityError.permissionRequired }
        nodeElements.removeAll(keepingCapacity: true)
        secureNodes.removeAll(keepingCapacity: true)
        let element = try exactAXWindow(window)
        var output: [AccessibilityNode] = []
        walk(element, depth: 0, maximumNodes: min(max(maximumNodes, 1), 2_000), output: &output)
        return output
    }

    private func exactAXWindow(_ window: DesktopWindow) throws -> AXUIElement {
        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        let candidates = arrayAttribute(kAXWindowsAttribute as CFString, from: application).filter {
            (stringAttribute(kAXTitleAttribute as CFString, from: $0) ?? "") == window.title && axFrame($0) == window.frame
        }
        guard candidates.count == 1, let element = candidates.first else {
            throw candidates.isEmpty ? MacAccessibilityError.windowNotFound : MacAccessibilityError.ambiguousWindow
        }
        return element
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute as CFString, from: element),
              let size = attribute(kAXSizeAttribute as CFString, from: element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    public func perform(_ action: AccessibilityAction, nodeID: UUID) throws {
        guard AXIsProcessTrusted() else { throw MacAccessibilityError.permissionRequired }
        guard let element = nodeElements[nodeID] else { throw MacAccessibilityError.staleNode }
        guard !secureNodes.contains(nodeID) else { throw MacAccessibilityError.secureElement }
        let result: AXError
        switch action {
        case .press:
            result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case .focus:
            result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case let .setValue(value):
            result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        }
        guard result == .success else { throw MacAccessibilityError.actionFailed(result.rawValue) }
    }

    public func focus(window: DesktopWindow) async throws {
        guard AXIsProcessTrusted() else { throw MacAccessibilityError.permissionRequired }
        guard try await listWindowsVerified().contains(where: { $0.id == window.id && $0.ownerPID == window.ownerPID }) else {
            throw MacAccessibilityError.windowNotFound
        }
        let application = AXUIElementCreateApplication(window.ownerPID)
        let element = try exactAXWindow(window)
        guard AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success else {
            throw MacAccessibilityError.actionFailed(AXError.failure.rawValue)
        }
        let frontmost = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard frontmost == .success else { throw MacAccessibilityError.actionFailed(frontmost.rawValue) }
    }

    /// A global HID event is safe to send only while this exact AX window is
    /// focused. Matching just the PID would permit a different window of the
    /// same app to receive typing after the user changed focus.
    public func isFocused(window: DesktopWindow) throws -> Bool {
        guard AXIsProcessTrusted() else { throw MacAccessibilityError.permissionRequired }
        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let focused = attribute(kAXFocusedWindowAttribute as CFString, from: application),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(try exactAXWindow(window), focused)
    }

    /// Coordinate typing must never fall back to an unknown or password input.
    /// Recheck the actual focused control immediately before injecting text.
    public func ensureFocusedInputIsNotSecure(pid: pid_t) throws {
        guard AXIsProcessTrusted() else { throw MacAccessibilityError.permissionRequired }
        let application = AXUIElementCreateApplication(pid)
        guard let rawFocused = attribute(kAXFocusedUIElementAttribute as CFString, from: application),
              CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else {
            throw MacAccessibilityError.focusedElementUnknown
        }
        var element = rawFocused as! AXUIElement
        for _ in 0..<8 {
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element) ?? ""
            guard !role.isEmpty else { throw MacAccessibilityError.focusedElementUnknown }
            if Self.isSecureRole(role: role, subrole: subrole) { throw MacAccessibilityError.secureElement }
            guard let parent = attribute(kAXParentAttribute as CFString, from: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
    }

    /// HID typing is bound to one editable control, not merely its application.
    /// A sheet can keep the document's AXFocusedWindow while intercepting all keys.
    public func beginTyping(in window: DesktopWindow, text: String) throws -> UUID {
        let element = try focusedTypingElement(in: window)
        var expected: String?
        if let before = stringAttribute(kAXValueAttribute as CFString, from: element),
           let rawRange = attribute(kAXSelectedTextRangeAttribute as CFString, from: element),
           CFGetTypeID(rawRange) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rawRange as! AXValue, .cfRange, &range) {
                expected = DesktopTypingPolicy.expectedValue(before: before,
                    selection: NSRange(location: range.location, length: range.length), text: text)
            }
        }
        let id = UUID()
        typingTargets[id] = TypingTarget(element: element, expectedValue: expected)
        return id
    }

    public func isTypingTargetFocused(_ id: UUID, in window: DesktopWindow) throws -> Bool {
        guard let target = typingTargets[id] else { return false }
        return CFEqual(target.element, try focusedTypingElement(in: window))
    }

    /// nil means AX cannot attest the result. Do not turn dispatched events into success.
    public func typingEffect(_ id: UUID, in window: DesktopWindow) throws -> Bool? {
        guard let target = typingTargets[id], try isTypingTargetFocused(id, in: window),
              let expected = target.expectedValue,
              let actual = stringAttribute(kAXValueAttribute as CFString, from: target.element) else { return nil }
        return actual == expected
    }

    public func endTyping(_ id: UUID) { typingTargets.removeValue(forKey: id) }

    private func focusedTypingElement(in window: DesktopWindow) throws -> AXUIElement {
        guard try isFocused(window: window) else { throw MacAccessibilityError.focusedElementUnknown }
        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let raw = attribute(kAXFocusedUIElementAttribute as CFString, from: application),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw MacAccessibilityError.focusedElementUnknown }
        let focused = raw as! AXUIElement
        let exactWindow = try exactAXWindow(window)
        var element = focused
        var roles: [(role: String, subrole: String)] = []
        for _ in 0..<32 {
            if CFEqual(element, exactWindow) {
                try DesktopTypingPolicy.validate(roles: roles,
                    enabled: boolAttribute(kAXEnabledAttribute as CFString, from: focused) == true,
                    editable: boolAttribute("AXEditable" as CFString, from: focused), belongsToWindow: true)
                return focused
            }
            roles.append((stringAttribute(kAXRoleAttribute as CFString, from: element) ?? "",
                          stringAttribute(kAXSubroleAttribute as CFString, from: element) ?? ""))
            guard let parent = attribute(kAXParentAttribute as CFString, from: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        throw MacAccessibilityError.focusedElementUnknown
    }

    private func walk(_ element: AXUIElement, depth: Int, maximumNodes: Int, output: inout [AccessibilityNode]) {
        guard output.count < maximumNodes, depth <= 12 else { return }
        let id = UUID()
        nodeElements[id] = element
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? "unknown"
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element) ?? ""
        let isSecure = Self.isSecureRole(role: role, subrole: subrole)
        if isSecure { secureNodes.insert(id) }
        output.append(AccessibilityNode(
            id: id,
            role: role,
            title: isSecure ? nil : (stringAttribute(kAXTitleAttribute as CFString, from: element) ?? stringAttribute(kAXDescriptionAttribute as CFString, from: element)),
            value: isSecure ? nil : stringAttribute(kAXValueAttribute as CFString, from: element),
            isEnabled: boolAttribute(kAXEnabledAttribute as CFString, from: element) ?? true,
            depth: depth,
            isSecure: isSecure
        ))
        // A password control may expose nested accessibility children. Never
        // traverse that subtree or publish IDs that could be acted on later.
        if isSecure { return }
        for child in arrayAttribute(kAXChildrenAttribute as CFString, from: element) {
            guard output.count < maximumNodes else { break }
            walk(child, depth: depth + 1, maximumNodes: maximumNodes, output: &output)
        }
    }

    public nonisolated static func isSecureRole(role: String, subrole: String) -> Bool {
        role.localizedCaseInsensitiveContains("password") || role.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("secure") ||
            subrole.localizedCaseInsensitiveContains("password")
    }

    private func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }

    private func stringAttribute(_ name: CFString, from element: AXUIElement) -> String? {
        attribute(name, from: element) as? String
    }

    private func boolAttribute(_ name: CFString, from element: AXUIElement) -> Bool? {
        attribute(name, from: element) as? Bool
    }

    private func arrayAttribute(_ name: CFString, from element: AXUIElement) -> [AXUIElement] {
        attribute(name, from: element) as? [AXUIElement] ?? []
    }
}

enum DesktopTypingPolicy {
    static func validate(roles: [(role: String, subrole: String)], enabled: Bool,
                         editable: Bool?, belongsToWindow: Bool) throws {
        guard belongsToWindow, !roles.isEmpty, roles.allSatisfy({ !$0.role.isEmpty }) else {
            throw MacAccessibilityError.focusedElementUnknown
        }
        if roles.contains(where: { MacAccessibilityService.isSecureRole(role: $0.role, subrole: $0.subrole) }) {
            throw MacAccessibilityError.secureElement
        }
        // A modal descendant must be observed/targeted independently; it is not the document.
        guard !roles.contains(where: { $0.role == "AXSheet" || $0.subrole == "AXDialog" || $0.subrole == "AXSystemDialog" }),
              enabled, editable != false,
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(roles[0].role) else {
            throw MacAccessibilityError.focusedElementNotEditable
        }
    }

    static func expectedValue(before: String, selection: NSRange, text: String) -> String? {
        let value = before as NSString
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= value.length, selection.length <= value.length - selection.location else { return nil }
        let units = before.utf16
        let start = units.index(units.startIndex, offsetBy: selection.location)
        let end = units.index(start, offsetBy: selection.length)
        guard String.Index(start, within: before) != nil, String.Index(end, within: before) != nil else { return nil }
        return value.replacingCharacters(in: selection, with: text)
    }
}

public enum MacAccessibilityError: LocalizedError {
    case permissionRequired
    case staleNode
    case actionFailed(AXError.RawValue)
    case windowNotFound
    case ambiguousWindow
    case secureElement
    case focusedElementUnknown
    case focusedElementNotEditable
    case screenRecordingRequiredForWindows
    case windowEnumerationUnavailable(String?)
    case noExternalWindows

    public var errorDescription: String? {
        switch self {
        case .permissionRequired: "Accessibility permission is required."
        case .staleNode: "The interface element is no longer available."
        case let .actionFailed(code): "The accessibility action failed (\(code))."
        case .windowNotFound: "The selected window is no longer available."
        case .ambiguousWindow: "Several windows in this app have the same title; AIM did not guess which one to focus."
        case .secureElement: "Secure fields cannot be read or controlled by this tool."
        case .focusedElementUnknown: "The focused control cannot be identified. Typing was blocked."
        case .focusedElementNotEditable: "The selected window has no enabled editable control, or a different dialog is receiving input. Nothing was typed. Observe and select the actual input window before retrying."
        case .screenRecordingRequiredForWindows: "Window enumeration returned no usable windows. Enable Screen Recording for AIM in System Settings → Privacy & Security, then quit and reopen AIM before retrying. This is not proof that no windows are open."
        case let .windowEnumerationUnavailable(detail): "Window enumeration is unavailable\(detail.map { ": \($0)" } ?? "."). Check Screen Recording access and reopen AIM; do not conclude that the desktop is empty."
        case .noExternalWindows: "No other app windows were returned by the available sources. This may be a permissions or desktop-space issue; verify Screen Recording access and the target app before concluding it is closed."
        }
    }
}
