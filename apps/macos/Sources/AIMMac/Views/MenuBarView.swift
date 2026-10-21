import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.hasAccess ? "Open AIM AI" : "Sign in to AIM AI…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        if model.hasAccess {
            Divider()
            ForEach(model.engineStatuses, id: \.id) { status in
                Label("\(status.id.rawValue.capitalized): \(status.state.rawValue)", systemImage: status.state == .ready ? "checkmark.circle.fill" : "circle")
            }
            Divider()
            Button("Check for Updates…") { model.checkForUpdates() }
        }
        Button("Quit AIM AI") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
