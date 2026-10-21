import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A marker on Quartz events emitted by AIM. It is used only to distinguish
/// AIM's own input from physical input while a global gesture is active; it is
/// not a security credential or an authorization signal.
enum DesktopAgentEventMarker {
    static let value: Int64 = 0x41494D5F4147454E // "AIM_AGEN"
}

/// Contains no keystrokes, mouse positions or event history. The event handler
/// synchronously revokes every active global sequence before the next gesture.
final class DesktopHumanActivityState: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: DesktopInputCancellationToken] = [:]

    func register(_ token: DesktopInputCancellationToken) -> UUID {
        lock.withLock {
            let id = UUID()
            active[id] = token
            return id
        }
    }

    func unregister(_ id: UUID) {
        lock.withLock { _ = active.removeValue(forKey: id) }
    }

    var hasActiveSequences: Bool { lock.withLock { !active.isEmpty } }

    func observe(eventTag: Int64?) {
        guard eventTag != DesktopAgentEventMarker.value else { return }
        let tokens = lock.withLock { Array(active.values) }
        for token in tokens { token.revokeForHumanInput() }
    }
}

/// AppKit monitors observe other applications and AIM itself separately. They
/// are installed only while an AIM global-input sequence is running and are
/// removed afterward. If either monitor is unavailable, input fails closed.
@MainActor
final class DesktopHumanActivityMonitor {
    static let shared = DesktopHumanActivityMonitor()

    private let state = DesktopHumanActivityState()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    func begin(_ token: DesktopInputCancellationToken) throws -> UUID {
        if globalMonitor == nil || localMonitor == nil {
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .keyUp, .flagsChanged,
                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                .mouseMoved, .scrollWheel
            ]
            let state = self.state
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
                state.observe(eventTag: event.cgEvent?.getIntegerValueField(.eventSourceUserData))
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                state.observe(eventTag: event.cgEvent?.getIntegerValueField(.eventSourceUserData))
                return event
            }
            guard globalMonitor != nil, localMonitor != nil else {
                removeMonitors()
                throw DesktopInputError.humanMonitoringUnavailable
            }
        }
        return state.register(token)
    }

    func end(_ id: UUID) {
        state.unregister(id)
        if !state.hasActiveSequences { removeMonitors() }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }
}
