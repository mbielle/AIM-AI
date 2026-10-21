import AIMMacPlatform
import AppKit

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var prepare: @MainActor () async -> Bool = { true }
    var reopenMainWindow: (@MainActor () -> Void)?
    var reply: @MainActor (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    private let supervisor: ProcessSupervisor
    private var shutdown: Task<Void, Never>?

    override init() { supervisor = .shared; super.init() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AIM has one main window; no window tabs or "+" tab button.
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    init(supervisor: ProcessSupervisor) { self.supervisor = supervisor; super.init() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, shutdown == nil, let reopenMainWindow else { return true }
        reopenMainWindow()
        return false // The SwiftUI scene is opened explicitly; do not also use AppKit's default reopening.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shutdown == nil else { return .terminateLater }
        supervisor.beginShutdown()
        shutdown = Task {
            let saved = await prepare()
            await supervisor.waitForIdle()
            if !saved {
                supervisor.resumeAfterCancelledShutdown()
                shutdown = nil
            }
            reply(sender, saved)
        }
        return .terminateLater
    }
}
