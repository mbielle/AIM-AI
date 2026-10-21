import CoreGraphics

/// Foreground gestures use the same AI cursor as background work (one style).
@MainActor
final class AgentCursorOverlay {
    static let shared = AgentCursorOverlay()
    private init() {}

    func show(at quartzPoint: CGPoint, clicking: Bool) {
        AgentBackgroundCursor.shared.showForeground(at: quartzPoint, clicking: clicking)
    }

    func hide() { AgentBackgroundCursor.shared.dismiss() }
}
