#if DEBUG
import AppKit
import ApplicationServices
import Darwin
import Foundation

/// AIM's own, in-process accessibility view of the disposable fixture. It is
/// independent of the CUA daemon so a driver's claim can be checked against
/// what the host itself observes. Never used on another application.
enum FixtureAccessibilityProbe {
    static let fixtureBundleID = "com.aimai.macos.agent-fixture"

    struct WindowFacts {
        let title: String
        let frame: CGRect?
        let windowID: CGWindowID?
    }

    static func fixtureApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: fixtureBundleID).filter { !$0.isTerminated }
    }

    static func windows(pid: pid_t) -> (status: AXError, windows: [WindowFacts]) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1.0)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
        guard status == .success, let windows = raw as? [AXUIElement] else { return (status, []) }
        return (status, windows.map { window in
            WindowFacts(title: string(kAXTitleAttribute, of: window) ?? "", frame: frame(of: window),
                windowID: cgWindowID(of: window))
        })
    }

    static func menuBarChildCount(pid: pid_t) -> Int? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1.0)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return children(of: raw as! AXUIElement).count
    }

    /// The fixture's `fixture.count` label as AIM reads it, e.g. "Count: 3" → 3.
    static func counter(pid: pid_t) -> Int? {
        guard let value = identifiedValue("fixture.count", pid: pid) else { return nil }
        guard value.hasPrefix("Count: ") else { return nil }
        return Int(value.dropFirst(7))
    }

    /// Global top-left frame of the fixture element with this AX identifier.
    static func identifiedFrame(_ identifier: String, pid: pid_t) -> CGRect? {
        identifiedElement(identifier, pid: pid).flatMap { frame(of: $0) }
    }

    static func identifiedElement(_ identifier: String, pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1.0)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return nil }
        var visited = 0
        for window in windows {
            if let found = find(identifier, in: window, depth: 0, visited: &visited) { return found }
        }
        return nil
    }

    static func identifiedValue(_ identifier: String, pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1.0)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return nil }
        var visited = 0
        for window in windows {
            if let found = find(identifier, in: window, depth: 0, visited: &visited) {
                return string(kAXValueAttribute, of: found) ?? string(kAXTitleAttribute, of: found)
            }
        }
        return nil
    }

    private static func find(_ identifier: String, in element: AXUIElement, depth: Int, visited: inout Int) -> AXUIElement? {
        visited += 1
        guard depth <= 12, visited <= 2_000 else { return nil }
        if string(kAXIdentifierAttribute, of: element) == identifier { return element }
        for child in children(of: element) {
            if let found = find(identifier, in: child, depth: depth + 1, visited: &visited) { return found }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let children = raw as? [AXUIElement] else { return [] }
        return children
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        if let value = raw as? String { return value }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: point, size: extent)
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Private but long-standing HIServices symbol, resolved dynamically and used
    /// only by debug qualification to test the CG↔AX correspondence CUA relies on.
    private static func cgWindowID(of element: AXUIElement) -> CGWindowID? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        let function = unsafeBitCast(symbol, to: GetWindow.self)
        var identifier: CGWindowID = 0
        guard function(element, &identifier) == .success, identifier != 0 else { return nil }
        return identifier
    }
}
#endif
