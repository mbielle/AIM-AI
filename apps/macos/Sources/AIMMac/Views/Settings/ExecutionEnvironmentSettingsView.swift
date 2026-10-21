import AIMMacPlatform
import AppKit
import SwiftUI

struct ExecutionEnvironmentSettingsView: View {
    @State private var environment = WorkspaceExecutionEnvironment()
    @State private var error: String?
    var body: some View {
        SettingsGroup("Command execution environment", description: "Native Mac tools keep their existing permissions. A configured container or SSH backend changes foreground workspace shell commands only; it does not isolate graphical actions.") {
            SettingsRow("Backend", description: environment.backend == .host ? "Local macOS account" : environment.backend.rawValue.capitalized) {
                Button("Import configuration…") {
                    let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.json]
                    guard panel.runModal() == .OK, let file = panel.url else { return }
                    do {
                        let data = try Data(contentsOf: file)
                        guard data.count <= 16_384 else { throw WorkspaceEnvironmentError.invalidConfiguration }
                        let value = try JSONDecoder().decode(WorkspaceExecutionEnvironment.self, from: data)
                        try WorkspaceExecutionEnvironment.save(value); environment = value; error = nil
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.settings)
                if environment.backend != .host {
                    Button("Use local account") {
                        do { let value = WorkspaceExecutionEnvironment(); try WorkspaceExecutionEnvironment.save(value); environment = value; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.settings)
                }
            }
            if environment.backend != .host {
                SettingsRow("Workspace scope", description: environment.workspaceRoot)
                SettingsRow("Background commands", description: "Unavailable for this backend. There is no automatic fallback to the Mac.")
            }
            if let error { SettingsNotice(error, tone: .error) }
        }.onAppear {
            do { environment = try WorkspaceExecutionEnvironment.current() }
            catch { self.error = error.localizedDescription }
        }
    }
}
