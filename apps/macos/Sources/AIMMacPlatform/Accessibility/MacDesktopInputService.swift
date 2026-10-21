import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Screenshot coordinates are deliberately short lived. An action cannot guess
/// at a point on a different window or after the window has moved.
public struct DesktopCaptureGeometry: Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let frame: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let processLaunchedAt: Date?
    public let capturedAt: Date

    public init(windowID: CGWindowID, ownerPID: pid_t, frame: CGRect,
                pixelWidth: Int, pixelHeight: Int, capturedAt: Date = .now, processLaunchedAt: Date? = nil) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.capturedAt = capturedAt
        self.processLaunchedAt = processLaunchedAt
    }

    public func globalPoint(x: Double, y: Double, current: DesktopWindow, now: Date = .now) throws -> CGPoint {
        guard current.id == windowID, current.ownerPID == ownerPID,
              current.processLaunchedAt == processLaunchedAt,
              now.timeIntervalSince(capturedAt) >= 0, now.timeIntervalSince(capturedAt) <= 60,
              abs(frame.minX - current.frame.minX) < 2, abs(frame.minY - current.frame.minY) < 2,
              abs(frame.width - current.frame.width) < 2, abs(frame.height - current.frame.height) < 2 else {
            throw DesktopInputError.staleCapture
        }
        guard x.isFinite, y.isFinite, pixelWidth > 0, pixelHeight > 0,
              x >= 0, y >= 0, x < Double(pixelWidth), y < Double(pixelHeight) else {
            throw DesktopInputError.invalidCoordinate
        }
        return CGPoint(x: frame.minX + x / Double(pixelWidth) * frame.width,
                       y: frame.minY + y / Double(pixelHeight) * frame.height)
    }
}

public enum DesktopInputError: LocalizedError {
    case staleCapture, invalidCoordinate, permissionRequired, eventUnavailable
    case invalidKey, textTooLong, secureField, appNotFrontmost
    case humanMonitoringUnavailable, humanIntervention, personActive

    public var errorDescription: String? {
        switch self {
        case .staleCapture: "Capture expired or the window moved. Take a new desktop_screenshot."
        case .invalidCoordinate: "Coordinates must be inside the screenshot's pixel dimensions."
        case .permissionRequired: "Accessibility permission is required for desktop input."
        case .eventUnavailable: "macOS could not create the input event."
        case .invalidKey: "Unsupported key or modifier."
        case .textTooLong: "Text must contain 1–4,000 UTF-8 bytes."
        case .secureField: "Typing into a secure or unidentified field is blocked."
        case .appNotFrontmost: "The exact target window is no longer focused. Input stopped; part of a multi-step gesture may already have been sent. Inspect the target before retrying. If needed, explicitly approve desktop_focus_window and capture a fresh screenshot."
        case .humanMonitoringUnavailable: "AIM could not monitor human input during this global gesture. No gesture was sent; check macOS Accessibility permission before trying again."
        case .humanIntervention: "The person used the Mac during this gesture, so AIM stopped and released its input; part of it may already have taken effect. Inspect the target, then call the next desktop action: AIM asks the person to hand over control and waits for their approval. Do not abandon the task."
        case .personActive: "The person is using the Mac right now, so nothing was sent. Call the action again: AIM asks the person to hand over control (a notification and an approval in the conversation) and waits for them. Do not abandon the task."
        }
    }
}

/// A request-local stop signal. The desktop executor can revoke it while an
/// input sequence is suspended at an await inside this actor.
public final class DesktopInputCancellationToken: @unchecked Sendable {
    private enum State { case active, cancelled, humanIntervention }
    private let lock = NSLock()
    private var state: State = .active

    public init() {}

    public func cancel() {
        lock.withLock { state = .cancelled }
    }

    public func revokeForHumanInput() {
        lock.withLock { if case .active = state { state = .humanIntervention } }
    }

    public func check() throws {
        try lock.withLock { try requireActive() }
    }

    /// Check immediately before posting. Never hold the lock through AppKit or
    /// Quartz delivery: a monitor callback may revoke this token while the
    /// system handles the posted event. Cleanup releases bypass this guard.
    func postIfActive(_ post: () -> Void) throws {
        try check()
        post()
    }

    private func requireActive() throws {
        switch state {
        case .active: break
        case .cancelled: throw CancellationError()
        case .humanIntervention: throw DesktopInputError.humanIntervention
        }
    }
}

public actor MacDesktopInputService {
    public init() {}

    /// Waits until the person has left the mouse and keyboard alone for `quiet` seconds, at most
    /// `maximum`; false when they are still using the Mac.
    public static func waitForPersonIdle(maximum: TimeInterval = 10, quiet: TimeInterval = 1.5) async -> Bool {
        let start = Date.now
        while Date.now.timeIntervalSince(start) < maximum {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            if idle >= quiet { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    public typealias FocusVerifier = @Sendable () async throws -> Bool

    private func withHumanPriority<T>(_ cancellation: DesktopInputCancellationToken?,
                                      operation: (DesktopInputCancellationToken) async throws -> T) async throws -> T {
        let token = cancellation ?? DesktopInputCancellationToken()
        let monitorID = try await MainActor.run { try DesktopHumanActivityMonitor.shared.begin(token) }
        do {
            let value = try await operation(token)
            await MainActor.run { DesktopHumanActivityMonitor.shared.end(monitorID) }
            return value
        } catch {
            await MainActor.run { DesktopHumanActivityMonitor.shared.end(monitorID) }
            throw error
        }
    }

    public func move(to point: CGPoint, expectedFrontmostPID: pid_t? = nil,
                     verifyFocusedWindow: FocusVerifier? = nil,
                     cancellation: DesktopInputCancellationToken? = nil) async throws {
        try requirePermission()
        try await withHumanPriority(cancellation) { token in
            try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
            try postMouse(.mouseMoved, at: point, cancellation: token)
            await AgentCursorOverlay.shared.show(at: point, clicking: false)
        }
    }

    public func click(at point: CGPoint, count: Int = 1, right: Bool = false,
                      expectedFrontmostPID: pid_t? = nil,
                      verifyFocusedWindow: FocusVerifier? = nil,
                      cancellation: DesktopInputCancellationToken? = nil) async throws {
        try requirePermission()
        guard (1...2).contains(count), !(right && count == 2) else { throw DesktopInputError.invalidCoordinate }
        try await withHumanPriority(cancellation) { token in
            try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
            try postMouse(.mouseMoved, at: point, cancellation: token)
            await AgentCursorOverlay.shared.show(at: point, clicking: true)
            for index in 1...count {
                try token.check()
                try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
                let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
                let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
                let button: CGMouseButton = right ? .right : .left
                try postMouse(down, at: point, button: button, clickState: index, cancellation: token)
                var held = true
                defer { if held { try? postMouse(up, at: point, button: button, clickState: index) } }
                try postMouse(up, at: point, button: button, clickState: index)
                held = false
            }
        }
    }

    public func drag(from start: CGPoint, to end: CGPoint,
                     expectedFrontmostPID: pid_t? = nil,
                     verifyFocusedWindow: FocusVerifier? = nil,
                     cancellation: DesktopInputCancellationToken? = nil) async throws {
        try requirePermission()
        try await withHumanPriority(cancellation) { token in
            try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
            try postMouse(.mouseMoved, at: start, cancellation: token)
            await AgentCursorOverlay.shared.show(at: start, clicking: true)
            try postMouse(.leftMouseDown, at: start, cancellation: token)
            var last = start
            defer { try? postMouse(.leftMouseUp, at: last) }
            for step in 1...16 {
                try token.check()
                try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
                let fraction = CGFloat(step) / 16
                last = CGPoint(x: start.x + (end.x - start.x) * fraction,
                               y: start.y + (end.y - start.y) * fraction)
                try postMouse(.leftMouseDragged, at: last, cancellation: token)
                await AgentCursorOverlay.shared.show(at: last, clicking: true)
                try await Task.sleep(for: .milliseconds(22))
            }
        }
    }

    public func scroll(at point: CGPoint, horizontal: Int32, vertical: Int32,
                       expectedFrontmostPID: pid_t? = nil,
                       verifyFocusedWindow: FocusVerifier? = nil,
                       cancellation: DesktopInputCancellationToken? = nil) async throws {
        try requirePermission()
        guard abs(Int64(horizontal)) <= 1_200, abs(Int64(vertical)) <= 1_200,
              horizontal != 0 || vertical != 0 else { throw DesktopInputError.invalidCoordinate }
        try await withHumanPriority(cancellation) { token in
            try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
            try postMouse(.mouseMoved, at: point, cancellation: token)
            await AgentCursorOverlay.shared.show(at: point, clicking: false)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
                throw DesktopInputError.eventUnavailable
            }
            event.location = point
            event.setIntegerValueField(.eventSourceUserData, value: DesktopAgentEventMarker.value)
            try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
            try token.postIfActive { event.post(tap: .cghidEventTap) }
        }
    }

    public func type(_ text: String, expectedFrontmostPID: pid_t? = nil,
                     verifyFocusedWindow: FocusVerifier? = nil,
                     cancellation: DesktopInputCancellationToken? = nil) async throws {
        try requirePermission()
        guard !text.isEmpty, text.utf8.count <= 4_000 else { throw DesktopInputError.textTooLong }
        // Unicode events permit international text without clipboard access.
        try await withHumanPriority(cancellation) { token in
            for scalar in text.unicodeScalars {
                try token.check()
                try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
                let units = Array(String(scalar).utf16)
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                    throw DesktopInputError.eventUnavailable
                }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                down.setIntegerValueField(.eventSourceUserData, value: DesktopAgentEventMarker.value)
                up.setIntegerValueField(.eventSourceUserData, value: DesktopAgentEventMarker.value)
                try token.postIfActive { down.post(tap: .cghidEventTap) }
                up.post(tap: .cghidEventTap)
            }
        }
    }

    public func key(_ name: String, modifiers: String?, expectedFrontmostPID: pid_t? = nil,
                    verifyFocusedWindow: FocusVerifier? = nil,
                    cancellation: DesktopInputCancellationToken? = nil) async throws {
        try requirePermission()
        guard let code = Self.keyCode(for: name) else { throw DesktopInputError.invalidKey }
        let names = (modifiers ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard names.count <= 4, Set(names).count == names.count else { throw DesktopInputError.invalidKey }
        let supported: [String: (CGKeyCode, CGEventFlags)] = [
            "command": (55, .maskCommand), "shift": (56, .maskShift),
            "option": (58, .maskAlternate), "control": (59, .maskControl)
        ]
        guard names.allSatisfy({ supported[$0] != nil }) else { throw DesktopInputError.invalidKey }
        var flags: CGEventFlags = []
        for name in names { flags.insert(supported[name]!.1) }
        try await withHumanPriority(cancellation) { token in
            var pressed: [CGKeyCode] = []
            defer {
                for modifier in pressed.reversed() {
                    let release = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: false)
                    release?.setIntegerValueField(.eventSourceUserData, value: DesktopAgentEventMarker.value)
                    release?.post(tap: .cghidEventTap)
                }
            }
            for name in names {
                try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
                let modifier = supported[name]!.0
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: modifier, keyDown: true) else {
                    throw DesktopInputError.eventUnavailable
                }
                event.setIntegerValueField(.eventSourceUserData, value: DesktopAgentEventMarker.value)
                try token.postIfActive { event.post(tap: .cghidEventTap) }
                pressed.append(modifier)
            }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
                throw DesktopInputError.eventUnavailable
            }
            down.flags = flags
            up.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: DesktopAgentEventMarker.value)
            up.setIntegerValueField(.eventSourceUserData, value: DesktopAgentEventMarker.value)
            try await requireFrontmost(expectedFrontmostPID, verifyFocusedWindow, token)
            try token.postIfActive { down.post(tap: .cghidEventTap) }
            up.post(tap: .cghidEventTap)
        }
    }

    private func requirePermission() throws {
        guard AXIsProcessTrusted() else { throw DesktopInputError.permissionRequired }
    }

    private func requireFrontmost(_ expectedPID: pid_t?, _ verifier: FocusVerifier?,
                                  _ cancellation: DesktopInputCancellationToken?) async throws {
        try Task.checkCancellation()
        try cancellation?.check()
        if let expectedPID {
            let actualPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            guard actualPID == expectedPID else { throw DesktopInputError.appNotFrontmost }
        }
        if let verifier {
            guard (try? await verifier()) == true else { throw DesktopInputError.appNotFrontmost }
        }
        try Task.checkCancellation()
        try cancellation?.check()
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint,
                           button: CGMouseButton = .left, clickState: Int = 1,
                           cancellation: DesktopInputCancellationToken? = nil) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else {
            throw DesktopInputError.eventUnavailable
        }
        if clickState > 1 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        event.setIntegerValueField(.eventSourceUserData, value: DesktopAgentEventMarker.value)
        if let cancellation {
            try cancellation.postIfActive { event.post(tap: .cghidEventTap) }
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    public nonisolated static func keyCode(for name: String) -> CGKeyCode? {
        let keys: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18,
            "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28,
            "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "return": 36, "l": 37,
            "j": 38, "k": 40, "n": 45, "m": 46, "tab": 48, "space": 49,
            "backspace": 51, "escape": 53, "delete": 117, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        return keys[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
