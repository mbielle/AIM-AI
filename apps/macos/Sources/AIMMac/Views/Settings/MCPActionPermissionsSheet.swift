import AIMApplication
import AIMCore
import AIMMacPlatform
import SwiftUI

struct MCPActionPermissionsSheet: View {
    let server: MCPServerConfiguration
    let save: (MCPServerConfiguration) async throws -> Void
    let cancel: () -> Void
    @State private var exceptions: [String: ConnectorPermissionPolicy.Decision]
    @State private var tools: [MCPToolInfo] = []
    @State private var loading = false
    @State private var saving = false
    @State private var message: String?
    @State private var leaving = false
    init(server: MCPServerConfiguration, save: @escaping (MCPServerConfiguration) async throws -> Void, cancel: @escaping () -> Void) {
        self.server = server; self.save = save; self.cancel = cancel
        _exceptions = State(initialValue: server.actionPermissions ?? [:])
    }
    private var dirty: Bool { exceptions != (server.actionPermissions ?? [:]) }
    private var actions: [String] { Set(tools.map(\.name) + Array(exceptions.keys)).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Action permissions").font(.title2.bold())
            Text(server.displayName).font(.headline)
            Text("Allow reviewed reads. Confirm changes, sends and unknown actions. Server annotations do not prove safety.").font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView() }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(actions, id: \.self) { name in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.body).textSelection(.enabled)
                                Text(ConnectorPermissionService.assess(server: server, action: name).label).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker(name, selection: Binding(get: { exceptions[name]?.rawValue ?? "" }, set: { exceptions[name] = ConnectorPermissionPolicy.Decision(rawValue: $0) })) {
                                Text("Default").tag(""); Text("Always ask").tag("ask"); Text("Block").tag("block")
                            }.labelsHidden().frame(width: 150)
                        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.frame(minHeight: 140, maxHeight: 360)
            HStack {
                Button("Reload actions") { Task { await load() } }.disabled(loading || saving)
                Spacer()
                Button("Cancel") { if dirty { leaving = true } else { cancel() } }.disabled(saving)
                Button(saving ? "Saving…" : "Save") { Task { await commit() } }.buttonStyle(.settingsPrimary).disabled(!dirty || saving)
            }
        }.padding(24).frame(width: 540).tint(.primary)
        .task { await load() }.interactiveDismissDisabled(dirty || saving)
        .alert("Save permission changes?", isPresented: $leaving) {
            Button("Keep editing", role: .cancel) {}; Button("Discard", role: .destructive, action: cancel); Button("Save") { Task { await commit() } }
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { tools = try await MCPServerManager.shared.tools(of: server); message = tools.isEmpty ? "This connection offers no actions." : nil }
        catch { message = "Actions could not be loaded. Existing exceptions are preserved." }
    }
    private func commit() async {
        guard !saving else { return }; saving = true; defer { saving = false }
        var updated = server; updated.actionPermissions = exceptions
        do { try await save(updated) } catch { message = "Permissions could not be saved. Your changes are still available here." }
    }
}
