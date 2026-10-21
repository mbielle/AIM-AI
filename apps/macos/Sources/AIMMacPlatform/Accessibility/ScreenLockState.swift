import CoreGraphics
import Foundation

/// Whether the person's session is locked or switched out (no app windows are
/// reachable then): desktop tools fail fast with this reason instead of a
/// misleading "window not found".
public enum ScreenLockState {
    /// Tests set this to a fixed answer; nil reads the real session state.
    nonisolated(unsafe) public static var overrideForTesting: Bool?

    public static var isLocked: Bool {
        if let overrideForTesting { return overrideForTesting }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        return session[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    public static let reason = "The Mac's screen is locked (or another user is active), so no app window can be observed or controlled until the person unlocks it. Nothing was sent."
}
