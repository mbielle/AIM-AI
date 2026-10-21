import AppKit
import Observation
import ScreenCaptureKit

/// What AIM's agent is doing on the computer right now, for the person: the app
/// and window it controls, its last action, a live preview of that window (even
/// on another Space) and a visible AI cursor at each action point.
@MainActor
@Observable
public final class ComputerUseActivity {
    public static let shared = ComputerUseActivity()

    public struct Session: Equatable {
        public let appName: String
        public let pid: pid_t
        public let windowID: CGWindowID
        public var lastAction: String
        public var updatedAt: Date
    }

    public private(set) var session: Session?
    public private(set) var preview: NSImage?
    /// Set by the app: stops the agent run that is using the computer.
    @ObservationIgnored public var stopHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    private init() {}

    /// The agent observed a window it may act on.
    public func observed(appName: String, pid: pid_t, windowID: CGWindowID) {
        guard NSApp != nil else { return } // headless (tests): no UI
        let isNew = session?.windowID != windowID
        session = Session(appName: appName, pid: pid, windowID: windowID,
                          lastAction: isNew ? "Observing the window" : (session?.lastAction ?? "Observing the window"),
                          updatedAt: .now)
        if isNew { preview = nil }
        startCapture()
        scheduleIdleEnd()
    }

    /// The agent is about to act at a screen point (Quartz coordinates), if known.
    public func acting(_ description: String, at point: CGPoint?) {
        guard var current = session else { return }
        current.lastAction = description
        current.updatedAt = .now
        session = current
        if let point { AgentBackgroundCursor.shared.move(to: point, windowID: current.windowID, clicking: true) }
        scheduleIdleEnd()
    }

    public func ended() {
        session = nil
        preview = nil
        captureTask?.cancel()
        captureTask = nil
        idleTask?.cancel()
        AgentBackgroundCursor.shared.dismiss()
    }

    public func stop() {
        stopHandler?()
        ended()
    }

    /// The cursor and preview fade out when the agent stops acting for a while.
    private func scheduleIdleEnd() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.ended()
        }
    }

    private func startCapture() {
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let windowID = self?.session?.windowID else { return }
                if let image = await Self.capture(windowID: windowID) { self?.preview = image }
                try? await Task.sleep(for: .milliseconds(1_200))
            }
        }
    }

    /// PNG of the display under the AI cursor (qualification evidence only).
    nonisolated static func captureMainDisplay(containing cocoaPoint: CGPoint? = nil) async -> Data? {
        let located: (CGDirectDisplayID, CGRect)? = await MainActor.run {
            guard let cocoaPoint, let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) }),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            // A close-up around the point, in display-local top-left points.
            let local = CGPoint(x: cocoaPoint.x - screen.frame.minX, y: screen.frame.maxY - cocoaPoint.y)
            return (CGDirectDisplayID(number.uint32Value), CGRect(x: local.x - 180, y: local.y - 130, width: 360, height: 260))
        }
        let screenID = located?.0
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        if let crop = located?.1 {
            configuration.sourceRect = crop
            configuration.width = Int(crop.width) * 2
            configuration.height = Int(crop.height) * 2
        }
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                                      configuration: configuration) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// One frame of a window through ScreenCaptureKit (works for windows on other
    /// Spaces or behind others); nil without Screen Recording permission.
    nonisolated static func capture(windowID: CGWindowID) async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(1, 720 / max(window.frame.width, 1))
        configuration.width = max(1, Int(window.frame.width * scale * 2))
        configuration.height = max(1, Int(window.frame.height * scale * 2))
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
