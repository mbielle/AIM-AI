import AppKit
import QuartzCore

/// The AI's own pointer, styled like a macOS cursor in grey with a soft shadow
/// so it reads on any background. It is drawn with Core Animation in one
/// transparent, click-through overlay per screen and glides along a gentle curve
/// to each action. For background work it shows only while the controlled
/// window is on the visible desktop; a small hit area at its tip offers Stop.
@MainActor
public final class AgentBackgroundCursor {
    public static let shared = AgentBackgroundCursor()

    private var overlays: [CGDirectDisplayID: CursorOverlayWindow] = [:]
    private var activeDisplay: CGDirectDisplayID?
    private var lastPoint: CGPoint?            // Cocoa global coordinates of the tip
    private var windowID: CGWindowID?          // nil: foreground gesture, always visible
    private var visible = false
    private var visibilityTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private let hitPanel = CursorHitPanel()

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlays.values.forEach { $0.orderOut(nil) }
                self?.overlays.removeAll()
                self?.activeDisplay = nil
                self?.visible = false
            }
        }
    }

    /// Background action on a window: the cursor stays while the agent works and
    /// is visible only on the desktop showing that window.
    func move(to quartzPoint: CGPoint, windowID: CGWindowID, clicking: Bool) {
        guard NSApp != nil else { return } // headless (tests): no windows
        self.windowID = windowID
        hideTask?.cancel()
        glide(to: quartzPoint, clicking: clicking)
        updateVisibility()
        if visibilityTimer == nil {
            visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            }
        }
    }

    /// Foreground gesture (the agent moved the real pointer): same cursor, shown
    /// briefly wherever the gesture happens.
    func showForeground(at quartzPoint: CGPoint, clicking: Bool) {
        guard NSApp != nil else { return }
        windowID = nil
        hideTask?.cancel()
        glide(to: quartzPoint, clicking: clicking)
        setVisible(true)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.setVisible(false)
        }
    }

    public func dismiss() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        windowID = nil
        setVisible(false)
    }

    /// For qualification: whether the cursor is shown, and its tip area (Cocoa coordinates).
    public var debugState: (visible: Bool, frame: CGRect?) {
        (visible, lastPoint.map { CGRect(x: $0.x - CursorLayer.tip.x, y: $0.y - CursorLayer.tip.y,
                                         width: CursorLayer.size, height: CursorLayer.size) })
    }

    // MARK: Motion

    private func glide(to quartzPoint: CGPoint, clicking: Bool) {
        guard let (display, screen, target) = Self.locate(quartzPoint) else { return }
        let overlay = overlay(for: display, screen: screen)
        let local = CGPoint(x: target.x - screen.frame.minX, y: target.y - screen.frame.minY)
        if activeDisplay != display || lastPoint == nil || !visible {
            // New screen or first appearance: place directly, then fade in.
            if let previous = activeDisplay, previous != display { overlays[previous]?.cursor.setOpacity(0, duration: 0.15) }
            overlay.cursor.place(at: local)
        } else if let last = lastPoint {
            let from = CGPoint(x: last.x - screen.frame.minX, y: last.y - screen.frame.minY)
            overlay.cursor.glide(from: from, to: local)
        }
        activeDisplay = display
        lastPoint = target
        if clicking { overlay.cursor.press(after: overlay.cursor.glideDuration) }
        hitPanel.place(atTip: target)
    }

    private func updateVisibility() {
        guard let windowID else { return }
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
        setVisible(onScreen)
    }

    private func setVisible(_ shown: Bool) {
        guard let display = activeDisplay, let overlay = overlays[display] else { return }
        if shown {
            overlay.orderFrontRegardless()
            if !visible { overlay.cursor.setOpacity(1, duration: 0.2) }
            hitPanel.orderFrontRegardless()
        } else if visible {
            overlay.cursor.setOpacity(0, duration: 0.25)
            hitPanel.orderOut(nil)
        }
        visible = shown
    }

    private func overlay(for display: CGDirectDisplayID, screen: NSScreen) -> CursorOverlayWindow {
        if let existing = overlays[display], existing.frame == screen.frame { return existing }
        overlays[display]?.orderOut(nil)
        let window = CursorOverlayWindow(screen: screen)
        overlays[display] = window
        return window
    }

    /// Screen containing a Quartz (top-left origin) point, and the point in Cocoa coordinates.
    static func locate(_ quartzPoint: CGPoint) -> (CGDirectDisplayID, NSScreen, CGPoint)? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let display = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(display)
            guard bounds.contains(quartzPoint) else { continue }
            return (display, screen, CGPoint(x: screen.frame.minX + quartzPoint.x - bounds.minX,
                                             y: screen.frame.maxY - (quartzPoint.y - bounds.minY)))
        }
        return nil
    }
}

/// Full-screen, transparent, click-through window that hosts the cursor layer.
@MainActor
private final class CursorOverlayWindow: NSWindow {
    let cursor = CursorLayer()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(cursor)
        cursor.contentsScale = screen.backingScaleFactor
        contentView = view
        setFrame(screen.frame, display: false)
    }
}

/// OpenAI-style AI cursor: a simple grey "navigation" arrow (no tail) inside a
/// small translucent round badge with a soft shadow, readable on any background.
/// The layer's anchor is the arrow tip, so its position is the exact action point.
private final class CursorLayer: CALayer {
    static let size: CGFloat = 36
    /// Arrow tip in layer coordinates (origin bottom-left).
    static let tip = CGPoint(x: 10, y: 26)
    private let badge = CALayer()
    private let arrow = CAShapeLayer()
    private(set) var glideDuration: CFTimeInterval = 0

    override init() {
        super.init()
        let size = Self.size
        bounds = CGRect(x: 0, y: 0, width: size, height: size)
        anchorPoint = CGPoint(x: Self.tip.x / size, y: Self.tip.y / size)
        opacity = 0
        badge.frame = bounds.insetBy(dx: 2, dy: 2)
        badge.cornerRadius = (size - 4) / 2
        badge.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.74).cgColor
        badge.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        badge.borderWidth = 0.75
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.24
        badge.shadowRadius = 6
        badge.shadowOffset = CGSize(width: 0, height: -1.5)
        addSublayer(badge)
        arrow.path = Self.arrowPath()
        arrow.fillColor = NSColor(calibratedWhite: 0.40, alpha: 1).cgColor
        arrow.strokeColor = NSColor(calibratedWhite: 0.22, alpha: 1).cgColor
        arrow.lineWidth = 1.1
        arrow.lineJoin = .round
        arrow.frame = bounds
        addSublayer(arrow)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A kite-shaped navigation arrow pointing up-left, tip at `tip`.
    private static func arrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: tip)                                  // tip (upper left)
        path.addLine(to: CGPoint(x: 26.5, y: 19.5))         // right wing
        path.addLine(to: CGPoint(x: 18.6, y: 17.6))         // notch toward the centre
        path.addLine(to: CGPoint(x: 16.5, y: 9.5))          // lower wing
        path.closeSubpath()
        return path
    }

    func place(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = point
        CATransaction.commit()
        glideDuration = 0
    }

    /// Eased motion along a slight arc; duration follows the distance.
    func glide(from start: CGPoint, to end: CGPoint) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 1 else { glideDuration = 0; return }
        let duration = min(0.7, max(0.28, Double(distance) / 1_400))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let bend = min(60, distance * 0.12)
        let normal = CGPoint(x: -(end.y - start.y) / distance, y: (end.x - start.x) / distance)
        let control = CGPoint(x: mid.x + normal.x * bend, y: mid.y + normal.y * bend)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.path = path
        animation.duration = duration
        animation.calculationMode = .paced
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.18, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = end
        CATransaction.commit()
        add(animation, forKey: "glide")
        glideDuration = duration
    }

    /// A short press: the arrow dips and returns, once it has arrived.
    func press(after delay: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1, 0.84, 1]
        animation.keyTimes = [0, 0.4, 1]
        animation.duration = 0.22
        animation.beginTime = CACurrentMediaTime() + delay
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        add(animation, forKey: "press")
    }

    func setOpacity(_ value: Float, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = presentation()?.opacity ?? opacity
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = value
        CATransaction.commit()
        add(animation, forKey: "opacity")
    }
}

/// A tiny invisible panel at the cursor tip: clicking the AI cursor offers Stop.
@MainActor
private final class CursorHitPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: CursorLayer.size, height: CursorLayer.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = NSColor.white.withAlphaComponent(0.001)
        hasShadow = false
        level = .statusBar
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = CursorHitView(frame: NSRect(x: 0, y: 0, width: CursorLayer.size, height: CursorLayer.size))
    }

    /// The hit area is the whole badge around the tip.
    func place(atTip tip: CGPoint) { setFrameOrigin(NSPoint(x: tip.x - CursorLayer.tip.x, y: tip.y - CursorLayer.tip.y)) }
}

@MainActor
private final class CursorHitView: NSView {
    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let stop = NSMenuItem(title: "Stop AIM", action: #selector(stopAgent), keyEquivalent: "")
        stop.target = self
        let hide = NSMenuItem(title: "Hide cursor", action: #selector(hideCursor), keyEquivalent: "")
        hide.target = self
        menu.addItem(stop)
        menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func stopAgent() { ComputerUseActivity.shared.stop() }
    @objc private func hideCursor() { AgentBackgroundCursor.shared.dismiss() }
}
