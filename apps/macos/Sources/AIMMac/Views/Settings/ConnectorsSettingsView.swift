import AIMApplication
import AIMCore
import AIMMacPlatform
import SwiftUI

/// MCP connectors available to Agent runs. Secrets go to the Keychain; the
/// stored configuration keeps only their names.
struct ConnectorsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var servers: [MCPServerConfiguration] = []
    @State private var statuses: [UUID: String] = [:]
    @State private var importText = ""
    @State private var showingImport = false
    @State private var showingAdd = false
    @State private var message: String?
    @State private var editingPermissions: MCPServerConfiguration?
    @State private var editingSecrets: MCPServerConfiguration?
    @State private var secretValues: [String: String] = [:]

    var body: some View {
        SettingsPage("Connectors", subtitle: "Agent runs can discover and call tools from these MCP servers. AIM allows reviewed reads and confirms changes, sends and unknown actions. A server's annotations never authorize an action. Server output is treated as untrusted data.") {
            RuntimeChannelsSettingsView()
            if let message { SettingsNotice(message) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("MCP servers").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Import JSON…") { showingImport = true }.buttonStyle(.settings)
                    Button("Add server…") { showingAdd = true }.buttonStyle(.settingsPrimary)
                }
                SettingsCard {
                    if servers.isEmpty {
                        SettingsRow("No connector yet", description: "Add a local command or a remote server, or import a Claude Desktop configuration.")
                    }
                    ForEach(servers) { server in row(server) }
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showingImport) { importSheet }
        .sheet(item: $editingPermissions) { server in
            MCPActionPermissionsSheet(server: server) { updated in try await model.mcpServerRepository.save(updated); await MCPServerManager.shared.disconnect(server.id); await reload(); editingPermissions = nil } cancel: { editingPermissions = nil }
        }
        .sheet(item: $editingSecrets) { server in secretsSheet(server) }
        .sheet(isPresented: $showingAdd) {
            AddMCPServerSheet { configuration, secrets in
                await save(configuration, secrets: secrets)
                showingAdd = false
            } cancel: { showingAdd = false }
        }
    }

    private func row(_ server: MCPServerConfiguration) -> some View {
        let endpoint = server.transport == .stdio ? (server.command ?? "") : (server.url ?? "")
        let detail = [endpoint, statuses[server.id]].compactMap { $0 }.joined(separator: " · ")
        return SettingsRow(title: server.displayName, description: detail, leading: {
            Image(systemName: server.transport == .stdio ? "terminal" : "globe")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 32, height: 32).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }) {
            Menu {
                Button("Test connection") { Task { await test(server) } }
                Button("Action permissions…") { editingPermissions = server }
                if server.transport != .stdio && !server.secretNames.contains("AUTHORIZATION") {
                    Button("Connect another account…") { Task { await addAccount(server) } }
                }
                if server.transport != .stdio && !server.secretNames.contains("AUTHORIZATION") {
                    if MCPOAuth.storedTokens(serverID: server.id) == nil {
                        Button("Sign in…") { Task { await signIn(server) } }
                    } else {
                        Button("Sign out") {
                            MCPOAuth.signOut(serverID: server.id)
                            Task { await MCPServerManager.shared.disconnect(server.id); await reload() }
                        }
                    }
                }
                if !server.secretNames.isEmpty {
                    Button("Set secrets (\(server.secretNames.joined(separator: ", ")))…") { secretValues = [:]; editingSecrets = server }
                }
                Divider()
                Button("Remove", role: .destructive) { Task { await remove(server) } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Actions for \(server.name)")
            SettingsSwitch(isOn: Binding(get: { server.enabled }, set: { value in
                var updated = server; updated.enabled = value
                Task { await save(updated, secrets: [:]) }
            }), label: "Enabled")
        }
    }

    private func secretsSheet(_ server: MCPServerConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Secrets for \(server.name)").font(.headline)
            Text("Values are stored in the Keychain and passed only to this server. Leave a field empty to keep its current value.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(server.secretNames, id: \.self) { name in
                SecureField(name, text: Binding(get: { secretValues[name] ?? "" }, set: { secretValues[name] = $0 }))
            }
            HStack {
                Spacer()
                Button("Cancel") { editingSecrets = nil }
                Button("Save") {
                    let values = secretValues.filter { !$0.value.isEmpty }
                    editingSecrets = nil
                    Task { await save(server, secrets: values) }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import MCP servers").font(.headline)
            Text("Paste a JSON object with an \"mcpServers\" map (the format used by Claude Desktop and other clients). Commands must be absolute paths or programs found in /usr/bin, /opt/homebrew/bin or /usr/local/bin. Environment values are saved in the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $importText).font(.system(.caption, design: .monospaced)).frame(minHeight: 180)
                .border(.quaternary)
            HStack {
                Spacer()
                Button("Cancel") { showingImport = false }
                Button("Import") { Task { await importServers() } }.keyboardShortcut(.defaultAction)
                    .disabled(importText.isEmpty)
            }
        }
        .padding(20).frame(width: 560)
    }

    private func reload() async {
        servers = (try? await model.mcpServerRepository.list()) ?? []
        for server in servers {
            statuses[server.id] = describe(await MCPServerManager.shared.status(of: server))
        }
    }

    private func describe(_ status: MCPServerManager.Status) -> String {
        switch status {
        case .idle: "Not connected (connects when an Agent run first uses it)"
        case .connected(let count): "Connected · \(count) tools"
        case .coolingDown(let until, let reason): "Paused until \(until.formatted(date: .omitted, time: .shortened)) after repeated failures: \(reason)"
        case .failed(let reason): "Last error: \(reason)"
        }
    }

    private func save(_ configuration: MCPServerConfiguration, secrets: [String: String]) async {
        do {
            for (name, value) in secrets { try MCPSecretStore.save(value, name: name, serverID: configuration.id) }
            try await model.mcpServerRepository.save(configuration)
            await MCPServerManager.shared.disconnect(configuration.id)
            message = nil
        } catch {
            message = "Could not save \(configuration.name): \(error.localizedDescription)"
        }
        await reload()
    }

    private func remove(_ server: MCPServerConfiguration) async {
        await MCPServerManager.shared.disconnect(server.id)
        for name in server.secretNames { try? MCPSecretStore.remove(name: name, serverID: server.id) }
        MCPOAuth.signOut(serverID: server.id)
        try? await model.mcpServerRepository.delete(id: server.id)
        await reload()
    }

    private func addAccount(_ source: MCPServerConfiguration) async {
        guard let raw = source.url, let url = URL(string: raw) else { return }
        do {
            let existing = try await model.mcpServerRepository.list()
            var added = MCPConnectionIdentity.new(name: source.displayName, endpoint: url, existing: existing, connectorID: source.connectorID)
            added.transport = source.transport
            try await model.mcpServerRepository.save(added)
            await reload()
            await signIn(added)
        } catch { message = "This account could not be added. Existing connections are preserved." }
    }

    private func signIn(_ server: MCPServerConfiguration) async {
        message = "\(server.name): finish signing in in your browser…"
        do {
            try await MCPOAuth.signIn(server: server)
            await MCPServerManager.shared.disconnect(server.id)
            message = "\(server.name): signed in."
            await test(server)
        } catch {
            message = "\(server.name): \(error.localizedDescription)"
        }
    }

    private func test(_ server: MCPServerConfiguration) async {
        do {
            let tools = try await MCPServerManager.shared.tools(of: server)
            message = "\(server.name): handshake and listing succeeded (\(tools.count) tools offered after filters)."
        } catch {
            message = "\(server.name): \(error.localizedDescription)"
        }
        await reload()
    }

    private func importServers() async {
        do {
            let entries = try MCPServerImport.parse(Data(importText.utf8), resolveCommand: AgentMissionEvidenceToolService.resolveProgram)
            for entry in entries { await save(entry.configuration, secrets: entry.secrets) }
            message = "Imported \(entries.count) server(s). Reviewed reads are allowed; other actions require confirmation."
            importText = ""
            showingImport = false
        } catch {
            message = error.localizedDescription
        }
    }
}

struct AddMCPServerSheet: View {
    let onSave: (MCPServerConfiguration, [String: String]) async -> Void
    let cancel: () -> Void
    @State private var name = ""
    @State private var transport = MCPServerConfiguration.Transport.stdio
    @State private var command = ""
    @State private var arguments = ""
    @State private var url = ""
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add MCP server").font(.headline)
            TextField("Name (letters, digits, - or _)", text: $name)
            Picker("Transport", selection: $transport) {
                Text("Local command (stdio)").tag(MCPServerConfiguration.Transport.stdio)
                Text("Remote (Streamable HTTP)").tag(MCPServerConfiguration.Transport.http)
                Text("Remote (legacy SSE)").tag(MCPServerConfiguration.Transport.sse)
            }.pickerStyle(.segmented)
            if transport == .stdio {
                TextField("Command (absolute path or program name)", text: $command)
                TextField("Arguments, one per line", text: $arguments, axis: .vertical).lineLimit(2...5)
                TextField("Secret environment variable name (optional)", text: $secretName)
            } else {
                TextField("https:// URL", text: $url)
                Text("An optional bearer token is stored as the AUTHORIZATION secret. Without one, servers that use OAuth show a Sign in button.").font(.caption).foregroundStyle(.secondary)
            }
            SecureField(transport == .stdio ? "Secret value (Keychain)" : "Bearer token (Keychain, optional)", text: $secretValue)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }

    private func save() async {
        var secrets: [String: String] = [:]
        let configuration: MCPServerConfiguration
        if transport == .stdio {
            let resolved = command.hasPrefix("/") ? command : AgentMissionEvidenceToolService.resolveProgram(command)
            let key = secretName.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !secretValue.isEmpty { secrets[key] = secretValue }
            configuration = MCPServerConfiguration(name: name, transport: .stdio, command: resolved,
                arguments: arguments.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty },
                secretNames: secrets.keys.sorted())
        } else {
            if !secretValue.isEmpty { secrets["AUTHORIZATION"] = secretValue }
            configuration = MCPServerConfiguration(name: name, transport: transport, url: url, secretNames: secrets.keys.sorted())
        }
        guard configuration.isValid else {
            error = "Check the name, the command (it must resolve to an executable) or the HTTPS URL."
            return
        }
        await onSave(configuration, secrets)
    }
}
