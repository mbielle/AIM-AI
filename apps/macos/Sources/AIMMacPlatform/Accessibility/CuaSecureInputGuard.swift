import ApplicationServices
import CoreGraphics
import Foundation

enum CuaInputSafety: Sendable, Equatable {
    case safe, secure, unresolved
}

/// The CUA driver does not report AX subroles, so AIM resolves the target of a
/// text action in its own accessibility tree. Text entry is allowed only when
/// the element is positively matched to a non-secure editable control; a
/// secure field or an ambiguous/unmatched element fails closed.
enum CuaSecureInputGuard {
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"
    ]

    @MainActor
    static func classify(pid: Int32, element: CuaWindowElement) -> CuaInputSafety {
        guard let frame = element.frame, frame.width > 0, frame.height > 0 else { return .unresolved }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return .unresolved }
        var matches: [Bool] = []
        var visited = 0
        for window in windows {
            let origin = Self.frame(of: window)?.origin ?? .zero
            // Element frames may be global or window-relative; accept either exact match.
            let candidates = [frame, frame.offsetBy(dx: origin.x, dy: origin.y)]
            collect(window, candidates: candidates, depth: 0, visited: &visited, matches: &matches)
        }
        if matches.contains(true) { return .secure }
        return matches.count == 1 ? .safe : .unresolved
    }

    /// Appends `true` for a matched secure control and `false` for a matched
    /// ordinary editable control.
    private static func collect(_ element: AXUIElement, candidates: [CGRect], depth: Int,
                                visited: inout Int, matches: inout [Bool]) {
        visited += 1
        guard depth <= 14, visited <= 3_000 else { return }
        let role = string(kAXRoleAttribute, of: element) ?? ""
        let subrole = string(kAXSubroleAttribute, of: element) ?? ""
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        if editableRoles.contains(role) || secure, let frame = frame(of: element),
           candidates.contains(where: { close($0, frame) }) {
            matches.append(secure)
        }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let children = raw as? [AXUIElement] else { return }
        for child in children {
            collect(child, candidates: candidates, depth: depth + 1, visited: &visited, matches: &matches)
        }
    }

    private static func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2 &&
            abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: point, size: extent)
    }
}
