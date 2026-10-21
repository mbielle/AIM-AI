import AIMCore
import AIMAgentKit
import SwiftUI

struct CustomAgentsSettingsView: View {
    @AppStorage(CustomAgentLibrary.selectionKey, store: AIMInstallationContext.sharedPreferences) private var selected = ""
    @State private var profiles: [CustomAgentProfile] = []
    @State private var editing: CustomAgentProfile?
    @State private var error: String?
    var body: some View {
        SettingsGroup("Custom agents", description: "Profiles apply to new Agent and Code requests. Instructions never grant permissions; each profile can restrict tools and spending.") {
            SettingsMenuRow("Default profile", selection: $selected,
                            options: [("", "Standard AIM")] + profiles.map { ($0.id.uuidString, $0.name) })
            ForEach(profiles) { profile in
                SettingsRow(profile.name, description: profile.readOnly ? "Read only" : "Uses the task's permissions") {
                    Button("Edit…") { editing = profile }.buttonStyle(.settings)
                    Button("Delete") {
                        do {
                            try CustomAgentLibrary().delete(profile.id)
                            if selected == profile.id.uuidString { selected = "" }
                            reload()
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.settings)
                }
            }
            SettingsRow("Create a profile") {
                Button("Add…") { editing = CustomAgentProfile(name: "New agent", instructions: "") }.buttonStyle(.settings)
            }
            if let error { SettingsNotice(error, tone: .error) }
        }
        .onAppear { reload() }
        .sheet(item: $editing, onDismiss: { reload() }) { CustomAgentEditor(profile: $0) }
    }
    private func reload() {
        do { profiles = try CustomAgentLibrary().list(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
private struct CustomAgentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: CustomAgentProfile
    @State private var tools = ""
    @State private var cap = ""
    @State private var providerPlugin = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom agent").font(.title2)
            TextField("Name", text: $profile.name)
            Toggle("Read only", isOn: $profile.readOnly)
            Text("Instructions are saved locally and sent to the selected model. Do not include credentials.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $profile.instructions).font(.system(size: 13, design: .monospaced)).frame(minHeight: 160)
            TextField("Allowed tool names, comma separated (empty: task catalogue)", text: $tools)
            TextField("Optional maximum spending in USD", text: $cap)
            TextField("Native provider plugin identifier (empty: built-in provider)", text: $providerPlugin)
            Text("The selected plugin must be installed, enabled, and support this provider. AIM will suspend if it is unavailable.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    profile.allowedTools = tools.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil :
                        Array(Set(tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
                    profile.maximumSpendUSD = cap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cap
                    let plugin = providerPlugin.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.providerPluginID = plugin.isEmpty ? nil : plugin
                    do { try CustomAgentLibrary().save(profile); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620, height: 510)
            .onAppear { tools = profile.allowedTools?.joined(separator: ", ") ?? ""; cap = profile.maximumSpendUSD ?? ""; providerPlugin = profile.providerPluginID ?? "" }
    }
}
