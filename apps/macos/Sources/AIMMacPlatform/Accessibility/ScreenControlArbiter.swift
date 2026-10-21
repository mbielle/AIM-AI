import Foundation

/// Several Agent tasks can run at once; only one at a time drives the screen (clicks, typing,
/// focus). A task keeps the screen while it acts, and gives it up after a short pause so another
/// task's actions can proceed. A waiting task waits instead of interleaving its gestures.
public actor ScreenControlArbiter {
    public static let shared = ScreenControlArbiter()
    /// After this long without an action, the screen is free for another task.
    public static let idleRelease: TimeInterval = 20
    private var owner: ObjectIdentifier?
    private var lastUse = Date.distantPast

    /// Waits until the screen is free (or already this owner's); false after `timeout`.
    public func acquire(_ candidate: ObjectIdentifier, timeout: TimeInterval = 180) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            if owner == nil || owner == candidate || Date.now.timeIntervalSince(lastUse) > Self.idleRelease {
                owner = candidate; lastUse = .now
                return true
            }
            guard Date.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    public func release(_ candidate: ObjectIdentifier) {
        if owner == candidate { owner = nil }
    }
}
