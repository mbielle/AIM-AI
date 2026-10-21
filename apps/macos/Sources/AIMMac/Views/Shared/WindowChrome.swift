import AppKit
import SwiftUI

/// Places the window's close/minimize/zoom buttons in AIM's 48 pt top bar (vertically
/// centered with its controls, like ChatGPT) and reports full screen, where macOS hides
/// them and the bar's own buttons can move back to the edge.
struct WindowChrome: NSViewRepresentable {
    static let barHeight: CGFloat = 48
    /// Room the traffic lights take at the left of the bar when they are visible.
    static let trafficLightInset: CGFloat = 78
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.onFullScreenChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.onFullScreenChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
    }

    final class ChromeView: NSView {
        var onFullScreenChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func layout() {
            super.layout()
            apply()
        }

        private func apply() {
            guard let window else { return }
            // The SwiftUI toolbar and modal dimming also draw behind the native bar.
            window.titlebarAppearsTransparent = true
            let fullScreen = window.styleMask.contains(.fullScreen)
            DispatchQueue.main.async { [weak self] in self?.onFullScreenChange?(fullScreen) }
            guard !fullScreen else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            guard let titlebar = buttons.first?.superview, let container = titlebar.superview else { return }
            let height = WindowChrome.barHeight
            let frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
            if container.frame != frame { container.frame = frame }
            if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
            for (index, button) in buttons.enumerated() {
                let origin = NSPoint(x: 18 + CGFloat(index) * 20, y: ((height - button.frame.height) / 2).rounded())
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
