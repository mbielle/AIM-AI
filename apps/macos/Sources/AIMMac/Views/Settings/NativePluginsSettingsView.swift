import AIMCore
import AIMAgentKit
import SwiftUI

struct NativePluginsSettingsView: View {
    @State private var manifests: [AgentPluginManifest] = []
    @State private var enabled: Set<String> = []
    var body: some View {
        SettingsGroup("Native extensions", description: "Extensions linked into this build can contribute tools, context and services. Enable each explicitly; task scopes and approvals still apply.") {
            if manifests.isEmpty { SettingsRow("No native extension registered in this build") }
            ForEach(manifests, id: \.identifier) { manifest in
                SettingsToggleRow(manifest.identifier, description: "Version \(manifest.version) · API \(manifest.apiVersion)",
                    isOn: Binding(get: { enabled.contains(manifest.identifier) }, set: { value in
                        if value { enabled.insert(manifest.identifier) } else { enabled.remove(manifest.identifier) }
                        let defaults = AIMInstallationContext.sharedPreferences
                        defaults.set(enabled.sorted(), forKey: AgentPluginRegistry.enabledKey); defaults.synchronize()
                        if !value { Task { await AgentPluginRegistry.shared.deactivate(identifier: manifest.identifier) } }
                    }))
            }
        }.task {
            manifests = await AgentPluginRegistry.shared.manifests()
            enabled = Set(AIMInstallationContext.sharedPreferences.stringArray(forKey: AgentPluginRegistry.enabledKey) ?? [])
        }
    }
}
