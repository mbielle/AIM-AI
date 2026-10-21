import AIMCore
import AuthenticationServices
import SwiftUI

struct AIMConnectorListView: View {
    let connectors: AIMWebConnectorStore
    var cloud: (any CloudContentServicing)? = nil
    var remote: [AIMConnectorDirectoryRemoteConnection] = []
    let open: (SettingsDestination) -> Void
    let back: () -> Void
    var openWebAccounts: ((String?) -> Void)? = nil
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Connectors", back: back)
            AIMConnectorDirectoryView(connectors: connectors, cloud: cloud, remote: remote, open: open,
                                      openWebAccounts: openWebAccounts ?? { _ in })
        }
    }
}
struct AIMConnectorDetailView: View {
    let connectors: AIMWebConnectorStore
    let connector: PortableConnector
    let open: (SettingsDestination) -> Void
    let back: () -> Void
    @State private var web = ASWebAuthenticationSessionClient()
    @State private var connecting = false
    private var phoneCompatible: Bool { connector.supportsIPhone }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: connector.name, back: back)
            AIMSettingsForm {
                Section {
                    HStack(spacing: 16) { AIMConnectorCatalogLogo(connector: connector); VStack(alignment: .leading, spacing: 6) { Text(connector.name).font(.title2.bold()); Text(connector.publisher).font(.footnote).foregroundStyle(.secondary) } }.padding(.vertical, 12)
                    Text(connector.description).foregroundStyle(.secondary)
                    LabeledContent("Execution", value: connector.soon || connector.url == nil ? "Unavailable" : (phoneCompatible ? "This iPhone" : "Selected Mac"))
                }
                Section {
                    ForEach(connectors.servers.filter { $0.connectorID == connector.id || $0.url == connector.url }) { server in
                        AIMSettingsAction(title: server.displayName, icon: "person.crop.circle") { open(.connectorAccount(server.id)) }
                    }
                    if phoneCompatible {
                        Button(connecting ? "Connecting…" : "Connect another account") {
                            if connector.auth == .oauth { Task { await signIn() } }
                            else { connectors.draftConnector = connector; open(.newConnector) }
                        }.disabled(connecting)
                    }
                } header: { Text("Accounts on this iPhone") } footer: { if phoneCompatible { Text("Each connection keeps its own credentials on this iPhone.") } }
                if !phoneCompatible { AIMSettingsMessage(text: connector.soon || connector.url == nil ? "This connection is not available yet." : "Configure this connector on the selected Mac.") }
                Section { AIMSettingsAction(title: "Permissions", icon: "checkmark.shield") { open(.connectorPermissions) } }
                if let error = connectors.errorMessage { AIMSettingsMessage(text: error) }
            }
        }.webAuthenticationPresentationAnchor(web)
    }
    private func signIn() async {
        guard #available(iOS 17.4, *), let raw = connector.url, let url = URL(string: raw), !connecting else { return }
        connecting = true; defer { connecting = false }
        do {
            let flow = try await MCPAuthorizationFlow.prepare(resource: url, callback: URL(string: "https://aim-ai.tech/auth/mcp/ios")!)
            let callback = try await web.authenticateHTTPS(at: flow.authorizationURL, host: "aim-ai.tech", path: "/auth/mcp/ios")
            let tokens = try await flow.exchange(callback: callback)
            let server = try connectors.saveOAuth(name: connector.name, url: url, tokens: tokens, connectorID: connector.id)
            open(.connectorAccount(server.id))
        } catch { connectors.errorMessage = "This connector could not sign in. Check the connection and callback configuration, then retry." }
    }
}
struct AIMConnectorAccountView: View {
    let connectors: AIMWebConnectorStore
    let id: UUID
    let open: (SettingsDestination) -> Void
    let back: () -> Void
    @State private var disconnecting = false
    @State private var label = ""
    @State private var include = ""
    @State private var exclude = ""
    @State private var enabled = true
    @State private var initialized = false
    @State private var leaving = false
    @State private var connecting = false
    @State private var web = ASWebAuthenticationSessionClient()
    private var server: MCPServerConfiguration? { connectors.servers.first { $0.id == id } }
    private var catalogue: PortableConnector? { ConnectorCatalog.connectors.first { $0.id == server?.connectorID || $0.url == server?.url } }
    private var dirty: Bool { initialized && (label != server?.displayName || include != (server?.includeTools.joined(separator: "\n") ?? "") || exclude != (server?.excludeTools.joined(separator: "\n") ?? "") || enabled != server?.enabled) }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: server?.displayName ?? "Connection", back: { if dirty { leaving = true } else { back() } })
            AIMSettingsForm {
                Section {
                    if let catalogue { HStack(spacing: 12) { AIMConnectorCatalogLogo(connector: catalogue); Text(catalogue.name).font(.headline) }.padding(.vertical, 6) }
                    LabeledContent("Execution", value: "This iPhone")
                    LabeledContent("Status", value: server?.enabled == false ? "Disabled" : (connectors.loadedServerID == id ? "Connected" : "Saved"))
                    if let url = server?.url { Text(url).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) { Text("Account label").font(.subheadline); TextField("Name on this device", text: $label).textFieldStyle(.roundedBorder) }
                    Toggle("Enabled", isOn: $enabled)
                    AIMSettingsEditor(title: "Included actions", text: $include)
                    AIMSettingsEditor(title: "Excluded actions", text: $exclude)
                    Button("Save configuration", action: save).disabled(!dirty || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("Configuration") } footer: { Text("One action or * pattern per line. Exclusions take priority; leave Included actions empty for all.") }
                Section("Actions") {
                    if connectors.busy { ProgressView() }
                    ForEach(connectors.loadedServerID == id ? connectors.tools : []) { tool in
                        AIMSettingsAction(title: tool.name, value: connectors.assessment(serverID: id, action: tool.name).label) { open(.connectorTool(id, tool.name)) }
                    }
                    Button("Refresh actions") { Task { if let server { await connectors.loadTools(server) } } }.disabled(connectors.busy || server?.enabled != true || dirty)
                }
                Section {
                    AIMSettingsAction(title: "Permissions", icon: "checkmark.shield") { open(.connectorPermissions) }
                    if catalogue?.auth == .oauth { Button(connecting ? "Connecting…" : "Reconnect this account") { Task { await reconnect() } }.disabled(connecting) }
                    Button("Disconnect account") { disconnecting = true }
                }
                if let error = connectors.errorMessage { AIMSettingsMessage(text: error) }
            }
        }.webAuthenticationPresentationAnchor(web).task(id: id) {
            if let server {
                if !initialized { label = server.displayName; include = server.includeTools.joined(separator: "\n"); exclude = server.excludeTools.joined(separator: "\n"); enabled = server.enabled; initialized = true }
                if connectors.loadedServerID != id { await connectors.loadTools(server) }
            }
        }.settingsDraftNavigationProtection(dirty, onBackAttempt: { leaving = true }).interactiveDismissDisabled(dirty)
        .alert("Disconnect this account?", isPresented: $disconnecting) { Button("Cancel", role: .cancel) {}; Button("Disconnect", role: .destructive) { Task { if let server { await connectors.disconnect(server); if !connectors.servers.contains(where: { $0.id == id }) { back() } } } } }
        .alert("Save connection changes?", isPresented: $leaving) { Button("Keep editing", role: .cancel) {}; Button("Discard", role: .destructive, action: back); Button("Save") { if saveConfiguration() { back() } } }
    }
    private func save() { if saveConfiguration(), let server { Task { if server.enabled { await connectors.loadTools(server) } else { await connectors.close() } } } }
    private func saveConfiguration() -> Bool {
        guard var updated = server else { return false }
        updated.accountLabel = label.trimmingCharacters(in: .whitespacesAndNewlines); updated.enabled = enabled
        updated.includeTools = include.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        updated.excludeTools = exclude.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do { try connectors.saveConfiguration(updated); return true } catch { connectors.errorMessage = "Check the account label and action filters, then save again."; return false }
    }
    private func reconnect() async {
        guard #available(iOS 17.4, *), let server, let raw = server.url, let url = URL(string: raw), !connecting else { return }
        connecting = true; defer { connecting = false }
        do {
            let flow = try await MCPAuthorizationFlow.prepare(resource: url, callback: URL(string: "https://aim-ai.tech/auth/mcp/ios")!)
            let callback = try await web.authenticateHTTPS(at: flow.authorizationURL, host: "aim-ai.tech", path: "/auth/mcp/ios")
            let tokens = try await flow.exchange(callback: callback)
            _ = try connectors.saveOAuth(name: server.name, url: url, tokens: tokens, reconnecting: id)
            await connectors.loadTools(server)
        } catch { connectors.errorMessage = "This account could not reconnect. Its existing connection is preserved." }
    }
}
struct AIMConnectorEditorView: View {
    let connectors: AIMWebConnectorStore
    let back: () -> Void
    @State private var name = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var leaving = false
    @State private var initialized = false
    private var dirty: Bool { !name.isEmpty || !endpoint.isEmpty || !token.isEmpty }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "New connector", back: { if dirty { leaving = true } else { back() } })
            AIMSettingsForm {
                Section {
                    VStack(alignment: .leading) { Text("Account label").font(.subheadline); TextField("Name on this device", text: $name).textFieldStyle(.roundedBorder) }
                    VStack(alignment: .leading) { Text("HTTPS endpoint").font(.subheadline); TextField("https://…/mcp", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder) }
                    VStack(alignment: .leading) { Text("Bearer token").font(.subheadline); SecureField("Optional", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder) }
                } footer: { Text("Tokens stay in this iPhone’s Keychain.") }
                Section { Button("Save connection", action: save).disabled(name.isEmpty || endpoint.isEmpty) }
                if let error = connectors.errorMessage { AIMSettingsMessage(text: error) }
            }
        }.onAppear { if !initialized { name = connectors.draftConnector?.name ?? ""; endpoint = connectors.draftConnector?.url ?? ""; initialized = true } }
        .interactiveDismissDisabled(dirty).settingsDraftNavigationProtection(dirty, onBackAttempt: { leaving = true })
        .alert("Save connection?", isPresented: $leaving) { Button("Keep editing", role: .cancel) {}; Button("Discard", role: .destructive) { token = ""; back() }; Button("Save", action: save) }
    }
    private func save() { do { try connectors.add(name: name, url: endpoint, token: token, connectorID: connectors.draftConnector?.id); token = ""; back() } catch { connectors.errorMessage = "Enter a valid HTTPS MCP endpoint and account label." } }
}
struct AIMConnectorPermissionsView: View {
    let connectors: AIMWebConnectorStore
    let back: () -> Void
    @State private var selected: UUID?
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Permissions", back: back)
            AIMSettingsForm {
                Section { Text("Allow verified reads"); Text("Confirm changes, sends and unknown actions").foregroundStyle(.secondary) } footer: { Text("A server’s read-only annotation is not proof. AIM uses its reviewed action catalogue.") }
                if !connectors.servers.isEmpty {
                    Section { Picker("Connection", selection: $selected) { ForEach(connectors.servers) { Text($0.displayName).tag(Optional($0.id)) } } }
                    Section {
                        if connectors.busy { ProgressView() }
                        ForEach(connectors.loadedServerID == selected ? connectors.tools : []) { tool in
                            Picker(tool.name, selection: Binding(get: { override(tool.name) }, set: { set(tool.name, value: $0) })) { Text("Default").tag(""); Text("Always ask").tag("ask"); Text("Block").tag("block") }
                        }
                        if !connectors.busy && connectors.tools.isEmpty { Text("No actions available for this connection.").foregroundStyle(.secondary) }
                    } header: { Text("Action exceptions") } footer: { Text("Exceptions apply to this connection and account on this device.") }
                }
                if let error = connectors.errorMessage { AIMSettingsMessage(text: error) }
            }
        }.onAppear { selected = connectors.loadedServerID ?? connectors.servers.first?.id }
        .task(id: selected) { if let selected, let server = connectors.servers.first(where: { $0.id == selected }), connectors.loadedServerID != selected { await connectors.loadTools(server) } }
    }
    private func override(_ action: String) -> String { connectors.servers.first { $0.id == selected }?.actionPermissions?[action]?.rawValue ?? "" }
    private func set(_ action: String, value: String) { if let selected { connectors.setPermission(serverID: selected, action: action, decision: ConnectorPermissionPolicy.Decision(rawValue: value)) } }
}
struct AIMConnectorToolView: View {
    let connectors: AIMWebConnectorStore
    let serverID: UUID
    let name: String
    let back: () -> Void
    @State private var arguments = "{}"
    @State private var submittedArguments = "{}"
    @State private var confirming = false
    @State private var leaving = false
    private var tool: MCPWebTool? { connectors.loadedServerID == serverID ? connectors.tools.first { $0.name == name } : nil }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: name, back: { if arguments != "{}" { leaving = true } else { back() } })
            AIMSettingsForm {
                if let tool {
                    Section { Text(tool.description).font(.subheadline).foregroundStyle(.secondary); LabeledContent("Permission", value: connectors.assessment(serverID: serverID, action: name).label); AIMSettingsEditor(title: "JSON arguments", text: $arguments) }
                    Section { Button("Run action") { prepare(tool) }.disabled(connectors.busy) }
                    DisclosureGroup("Argument schema") { Text(String(decoding: (try? JSONEncoder().encode(tool.schema)) ?? Data(), as: UTF8.self)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
                if let result = connectors.resultText { Section("Result") { Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                if let error = connectors.errorMessage { AIMSettingsMessage(text: error) }
            }
        }.settingsDraftNavigationProtection(arguments != "{}", onBackAttempt: { leaving = true }).interactiveDismissDisabled(arguments != "{}")
        .alert("Run this action?", isPresented: $confirming) { Button("Cancel", role: .cancel) {}; Button("Run") { Task { if let tool { await connectors.execute(tool, serverID: serverID, arguments: submittedArguments, confirmed: true) } } } } message: { Text(name + "\n" + submittedArguments) }
        .alert("Discard arguments?", isPresented: $leaving) { Button("Keep editing", role: .cancel) {}; Button("Discard", role: .destructive, action: back) }
    }
    private func prepare(_ tool: MCPWebTool) {
        guard let json = try? JSONDecoder().decode(RemoteJSONValue.self, from: Data(arguments.utf8)), json.objectValue != nil else { connectors.errorMessage = "Enter a JSON object for this action."; return }
        switch connectors.assessment(serverID: serverID, action: name, arguments: json).authorization {
        case .deny: connectors.errorMessage = "This action is blocked in connector permissions."
        case .confirm: submittedArguments = arguments; confirming = true
        case .allow: let captured = arguments; Task { await connectors.execute(tool, serverID: serverID, arguments: captured, confirmed: false) }
        }
    }
}
