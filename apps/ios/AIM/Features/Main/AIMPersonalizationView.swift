import AIMCore
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
private final class AIMConnectorsStore {
    var connectors: [AIMConnector] = []
    var isLoading = false
    var error: String?

    private let service: any CloudContentServicing

    init(service: any CloudContentServicing) {
        self.service = service
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { connectors = try await service.loadConnectors() }
        catch { self.error = String(localized: "connectors.error.load") }
    }

    func setActive(_ connector: AIMConnector, active: Bool) async {
        do {
            try await service.setConnectorActive(id: connector.id, isActive: active)
            replace(connector, isActive: active)
        } catch { self.error = String(localized: "connectors.error.save") }
    }

    func setPermission(_ permission: ConnectorToolPermission, tool: AIMConnectorTool, connector: AIMConnector) async {
        do {
            try await service.setConnectorToolPermission(id: connector.id, toolName: tool.name, permission: permission)
            let permissions = connector.toolPermissions.merging([tool.name: permission]) { _, new in new }
            replace(connector, permissions: permissions)
        } catch { self.error = String(localized: "connectors.error.save") }
    }

    func delete(_ connector: AIMConnector) async -> Bool {
        do {
            try await service.deleteConnector(id: connector.id)
            connectors.removeAll { $0.id == connector.id }
            return true
        } catch {
            self.error = String(localized: "connectors.error.delete")
            return false
        }
    }

    func authorizationURL(for provider: AIMConnectorOAuthProvider) async throws -> URL {
        try await service.connectorAuthorizationURL(
            provider: provider,
            redirectURL: URL(string: "aim://connector-callback")!
        )
    }

    func connectorAuthorizationCompleted() async {
        await load()
    }

    func reportAuthorizationFailure() {
        error = String(localized: "connectors.error.save")
    }
    func reportBrokerUnavailable() {
        error = String(localized: "connectors.oauth_broker.unconfigured")
    }

    private func replace(_ connector: AIMConnector, isActive: Bool? = nil, permissions: [String: ConnectorToolPermission]? = nil) {
        guard let index = connectors.firstIndex(where: { $0.id == connector.id }) else { return }
        connectors[index] = .init(
            id: connector.id,
            type: connector.type,
            displayName: connector.displayName,
            serverURL: connector.serverURL,
            isActive: isActive ?? connector.isActive,
            lastConnectedAt: connector.lastConnectedAt,
            tools: connector.tools,
            toolPermissions: permissions ?? connector.toolPermissions,
            defaultParentID: connector.defaultParentID,
            defaultParentName: connector.defaultParentName,
            createdAt: connector.createdAt
        )
    }
}

struct AIMWebAccountConnectorsView: View {
    let showsHeader: Bool
    let safeTop: CGFloat
    let openMenu: () -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.locale) private var locale
    @State private var store: AIMConnectorsStore
    @State private var query = ""
    @State private var selectedID: String?
    @State private var connectorToDelete: AIMConnector?
    @State private var connectingProvider: AIMConnectorOAuthProvider?
    @State private var webAuthenticator = ASWebAuthenticationSessionClient()

    init(service: any CloudContentServicing, safeTop: CGFloat, selectedAccountID: String? = nil, showsHeader: Bool = true, openMenu: @escaping () -> Void) {
        self.showsHeader = showsHeader
        _selectedID = State(initialValue: selectedAccountID)
        self.safeTop = safeTop
        self.openMenu = openMenu
        _store = State(initialValue: AIMConnectorsStore(service: service))
    }

    private var filtered: [AIMConnector] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.connectors }
        return store.connectors.filter {
            $0.productName.localizedCaseInsensitiveContains(needle)
                || $0.displayName.localizedCaseInsensitiveContains(needle)
        }
    }

    private var selected: AIMConnector? {
        store.connectors.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            if store.isLoading && store.connectors.isEmpty {
                ProgressView().frame(maxHeight: .infinity)
            } else if let selected {
                connectorDetail(selected)
            } else {
                connectorList
            }
            if let error = store.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain).accessibilityIdentifier("personalization-screen")
        .task { await store.load() }
        .confirmationDialog(
            "connectors.disconnect.confirm",
            isPresented: Binding(
                get: { connectorToDelete != nil },
                set: { if !$0 { connectorToDelete = nil } }
            )
        ) {
            Button("connectors.disconnect", role: .destructive) {
                guard let connector = connectorToDelete else { return }
                connectorToDelete = nil
                selectedID = nil
                Task { _ = await store.delete(connector) }
            }
            Button("common.cancel", role: .cancel) { connectorToDelete = nil }
        }
    }

    private var header: some View {
        HStack {
            Button {
                if selectedID != nil { selectedID = nil } else { openMenu() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(AIMScrollSafeButtonStyle())
            .accessibilityLabel(Text(selectedID == nil ? "sidebar.open" : "common.back"))
            Spacer()
            Text(selectedID == nil ? "sidebar.personalization" : "connectors.title")
                .font(AIMDesign.titleFont(size: 23))
            Spacer()
            Button { Task { await store.load() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
            }
            .buttonStyle(AIMScrollSafeButtonStyle())
            .accessibilityLabel(Text("common.refresh"))
        }
        .padding(.horizontal, 16)
        .padding(.top, safeTop + 10)
        .padding(.bottom, 12)
    }

    private var connectorList: some View {
        VStack(spacing: 12) {
            HStack {
                Menu {
                    ForEach(AIMConnectorOAuthProvider.allCases) { provider in
                        Button(provider.displayName) { connect(provider) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if connectingProvider != nil { ProgressView().controlSize(.small) }
                        else { Image(systemName: "plus") }
                        Text(copy("Add a connector", "Ajouter un connecteur"))
                    }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 15)
                    .frame(height: 42)
                    .aimGlassCapsule()
                }
                .buttonStyle(AIMScrollSafeButtonStyle())
                .disabled(connectingProvider != nil || !environment.legacyOAuthBrokerConfigured)
                .accessibilityIdentifier("add-connector-button")
                Spacer()
            }
            .padding(.horizontal, 16)

            if !environment.legacyOAuthBrokerConfigured {
                Text("connectors.oauth_broker.unconfigured")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("legacy-oauth-broker-unconfigured")
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("connectors.search", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 17))
            .padding(.horizontal, 16)

            if filtered.isEmpty {
                ContentUnavailableView(
                    "connectors.empty.title",
                    systemImage: "puzzlepiece.extension",
                    description: Text("connectors.empty.body")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { connector in
                            Button { selectedID = connector.id } label: {
                                HStack(spacing: 13) {
                                    connectorIcon(connector)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(connector.productName)
                                            .font(.system(size: 16, weight: .semibold))
                                        Text(connector.isActive ? "Active web account" : "Disabled web account")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Circle()
                                        .fill(connector.isActive ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 8, height: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                            }
                            .buttonStyle(AIMScrollSafeButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 26)
                }
                .refreshable { await store.load() }
            }
        }
    }

    private func connectorDetail(_ connector: AIMConnector) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    connectorIcon(connector, size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connector.productName).font(.title2.weight(.semibold)).accessibilityIdentifier("web-account-detail-title-" + connector.id)
                        Text(connector.isActive ? "Active web account" : "Disabled web account")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("connectors.active", isOn: Binding(
                        get: { connector.isActive },
                        set: { active in Task { await store.setActive(connector, active: active) } }
                    ))
                    .labelsHidden()
                }

                if let parent = connector.defaultParentName, !parent.isEmpty {
                    Label(parent, systemImage: "folder").font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("connectors.tools.title").font(.headline)
                    if connector.tools.isEmpty {
                        Text("connectors.tools.empty").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(connector.tools, id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name).font(.system(.subheadline, design: .monospaced).weight(.medium))
                                        if let description = tool.description, !description.isEmpty {
                                            Text(description).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Picker("connectors.tools.permission", selection: Binding(
                                        get: { connector.permission(for: tool.name) },
                                        set: { permission in Task { await store.setPermission(permission, tool: tool, connector: connector) } }
                                    )) {
                                        Text("connectors.permission.allow").tag(ConnectorToolPermission.alwaysAllow)
                                        Text("connectors.permission.ask").tag(ConnectorToolPermission.ask)
                                        Text("connectors.permission.block").tag(ConnectorToolPermission.block)
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                                Divider()
                            }
                        }
                    }
                }
                .padding(16)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))

                Button(role: .destructive) {
                    connectorToDelete = connector
                } label: {
                    Label("connectors.disconnect", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 32)
        }.accessibilityIdentifier("web-account-detail-" + connector.id)
    }

    private func connectorIcon(_ connector: AIMConnector, size: CGFloat = 44) -> some View {
        AIMModelLogo(modelID: connector.type.replacingOccurrences(of: "oauth_", with: "").replacingOccurrences(of: "mcp_", with: ""), provider: connector.type, displayName: connector.productName, size: size)
    }

    private func connectorSymbol(_ type: String) -> String {
        switch type {
        case "oauth_github": "chevron.left.forwardslash.chevron.right"
        case "oauth_slack": "bubble.left.and.bubble.right"
        case "mcp_supabase": "cylinder.split.1x2"
        case "oauth_notion": "doc.text"
        case "oauth_canva": "paintpalette"
        default: "puzzlepiece.extension"
        }
    }

    private func connect(_ provider: AIMConnectorOAuthProvider) {
        guard environment.legacyOAuthBrokerConfigured else { store.reportBrokerUnavailable(); return }
        guard connectingProvider == nil else { return }
        connectingProvider = provider
        Task { @MainActor in
            defer { connectingProvider = nil }
            do {
                let authorizationURL = try await store.authorizationURL(for: provider)
                let callback = try await webAuthenticator.authenticate(
                    at: authorizationURL,
                    callbackScheme: "aim",
                    prefersEphemeralSession: false
                )
                guard callback.scheme == "aim",
                      callback.host == "connector-callback",
                      URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "oauth_connector" })?.value == "success"
                else {
                    store.reportAuthorizationFailure()
                    return
                }
                await store.connectorAuthorizationCompleted()
            } catch WebAuthenticationError.cancelled {
                // Cancellation is an intentional user action, not an error state.
            } catch {
                store.reportAuthorizationFailure()
            }
        }
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}

/// Sidebar hub: both connector entry points embed the same directory.
struct AIMPersonalizationView: View {
    let service: any CloudContentServicing
    let safeTop: CGFloat
    let openMenu: () -> Void
    var connectors: AIMWebConnectorStore?
    var remote: [AIMConnectorDirectoryRemoteConnection] = []
    var openSettings: ((SettingsDestination) -> Void)?
    var skills: AIMSkillsStore = .shared
    @State private var section = 0
    @State private var showWebAccounts = false
    @State private var webAccountID: String?
    @State private var skillMode = 0
    @State private var query = ""
    @State private var selectedFile = "SKILL.md"
    @State private var showMac = false
    @State private var showRemove = false

    var body: some View {
        AIMSettingsPageContainer {
            VStack(spacing: 12) {
            HStack {
                Button { back() } label: { Image(systemName: "chevron.left").frame(width: 48, height: 48).aimGlassCircle() }.buttonStyle(AIMScrollSafeButtonStyle())
                    .accessibilityLabel("Back")
                Spacer()
                Text(skills.preview?.name ?? "Personalization").accessibilityIdentifier("personalization-floating-title").font(.system(size: 21, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { Task { await skills.reload(); if section == 1 { await skills.loadCatalog(query: query) } } } label: { Image(systemName: "arrow.clockwise").frame(width: 48, height: 48).aimGlassCircle() }.buttonStyle(AIMScrollSafeButtonStyle()).accessibilityLabel("Refresh")
            }.padding(.horizontal, 16).padding(.top, safeTop + 10)
            if skills.preview == nil && !showWebAccounts {
                Picker("Personalization", selection: $section) { Text("Connectors").tag(0); Text("Skills").tag(1) }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
            }
            }.padding(.bottom, 12).aimSettingsHeader()
            ZStack {
                // Keep both lists mounted while visiting a detail, preserving their
                // native scroll positions, queries and registry pagination.
                Group {
                    if let connectors, let openSettings {
                        AIMConnectorDirectoryView(connectors: connectors, cloud: service, remote: remote, open: openSettings, openWebAccounts: { id in webAccountID = id; showWebAccounts = true })
                    } else {
                        AIMWebAccountConnectorsView(service: service, safeTop: 0, showsHeader: false, openMenu: openMenu)
                    }
                }.opacity(section == 0 && skills.preview == nil && !showWebAccounts ? 1 : 0)
                    .allowsHitTesting(section == 0 && skills.preview == nil && !showWebAccounts)
                    .accessibilityHidden(section != 0 || skills.preview != nil || showWebAccounts)
                skillsPage.opacity(section == 1 && skills.preview == nil && !showWebAccounts ? 1 : 0)
                    .allowsHitTesting(section == 1 && skills.preview == nil && !showWebAccounts)
                    .accessibilityHidden(section != 1 || skills.preview != nil || showWebAccounts)
                if let preview = skills.preview { detail(preview) }
                if showWebAccounts {
                    AIMWebAccountConnectorsView(service: service, safeTop: 0, selectedAccountID: webAccountID, showsHeader: false, openMenu: { showWebAccounts = false })
                }
            }
        }
        .environment(\.aimSettingsSurface, Color(uiColor: .systemBackground))

        .tint(.primary)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .font(.system(.body))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("personalization-screen")
        .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { value in
            if value.startLocation.x <= 24 && value.translation.width > 70 && value.translation.width > abs(value.translation.height) * 1.5 && (skills.preview != nil || showWebAccounts || showMac) { back() }
        })
        .task { await skills.reload() }
        .task(id: section) {
            if section == 1 && skills.catalog.isEmpty && ProcessInfo.processInfo.environment["AIM_UI_TEST_SCENARIO"] == nil { await skills.loadCatalog() }
        }
        .confirmationDialog("Remove this skill?", isPresented: $showRemove) {
            Button("Remove", role: .destructive) { if let skill = skills.preview { Task { await skills.remove(skill) } } }
        }
    }
    private func back() {
        if skills.preview != nil { skills.preview = nil; selectedFile = "SKILL.md" }
        else if showWebAccounts { showWebAccounts = false }
        else if showMac { showMac = false }
        else { openMenu() }
    }
    private var skillsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search skills", text: $query).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { Task { await skills.loadCatalog(query: query) } }
                    if !query.isEmpty { Button { query = ""; Task { await skills.loadCatalog() } } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                }.padding(14).aimGlassCapsule()
                Picker("Skills", selection: $skillMode) { Text("Installed").tag(0); Text("Catalog").tag(1) }.pickerStyle(.segmented)
                Button { showMac = true; Task { await skills.loadMac() } } label: { Label("Import from selected Mac", systemImage: "desktopcomputer").frame(minHeight: 44) }.buttonStyle(AIMScrollSafeButtonStyle())
                if let error = skills.error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("skills-error") }
                if skills.isLoading { ProgressView().frame(maxWidth: .infinity) }
                if showMac {
                    Text("Preview and select global skills. The originals stay on your Mac; imported copies start disabled.").font(.footnote).foregroundStyle(.secondary)
                    ForEach(skills.macSkills) { skill in
                        HStack {
                            Button { if skills.selectedMacSkills.contains(skill.name) { skills.selectedMacSkills.remove(skill.name) } else { skills.selectedMacSkills.insert(skill.name) } } label: { Image(systemName: skills.selectedMacSkills.contains(skill.name) ? "checkmark.circle.fill" : "circle").frame(width: 44, height: 44) }.accessibilityLabel("Select \(skill.name)")
                            Button { Task { await skills.previewMac(skill.name) } } label: { VStack(alignment: .leading) { Text(skill.name).font(.headline); Text(skill.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(AIMScrollSafeButtonStyle())
                        }
                    }
                    Button("Import selected (disabled)") { Task { await skills.importSelected() } }.buttonStyle(.borderedProminent).tint(.primary).disabled(skills.selectedMacSkills.isEmpty || skills.isLoading)
                } else if skillMode == 0 {
                    if skills.installed.isEmpty { ContentUnavailableView("No installed iPhone skills", systemImage: "sparkles", description: Text("Browse the catalog, review a skill, then install and enable it for Chat.")) }
                    if !skills.macSkills.isEmpty {
                        Text("On selected Mac").font(.headline)
                        ForEach(skills.macSkills) { item in
                            Button { Task { await skills.previewMac(item.name) } } label: {
                                HStack(spacing: 12) { Image(systemName: "desktopcomputer").frame(width: 40, height: 40); VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.headline); Text(item.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2); if let note = item.availabilityNote { Text(note).font(.caption).foregroundStyle(.secondary) } else if item.requiresMac == true { Text("Desktop tools required for some actions").font(.caption).foregroundStyle(.secondary) }; Text(skills.installed.contains(where: { $0.name == item.name && $0.version == item.version }) ? "Available offline on iPhone" : "Mac · Review to copy to iPhone").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "info.circle").frame(width: 44, height: 44) }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(AIMScrollSafeButtonStyle())
                        }
                    }
                    ForEach(skills.installed.filter { query.isEmpty || ($0.name + $0.summary).localizedCaseInsensitiveContains(query) }) { skill in
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles").frame(width: 40, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            Button { selectedFile = "SKILL.md"; skills.preview = skill; Task { await skills.loadVersions(skill) } } label: { VStack(alignment: .leading, spacing: 4) { Text(skill.name).font(.headline); Text(skill.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(AIMScrollSafeButtonStyle())
                            Toggle("Enable \(skill.name)", isOn: Binding(get: { skill.enabled }, set: { enabled in Task { await skills.toggle(skill, enabled: enabled) } })).labelsHidden().tint(.green)
                        }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    }
                } else {
                    ForEach(skills.catalog) { item in
                        Button { selectedFile = "SKILL.md"; Task { await skills.show(item) } } label: {
                            HStack(spacing: 12) { Image(systemName: "sparkles").frame(width: 40, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.headline); Text(item.source).font(.footnote).foregroundStyle(.secondary); if let installs = item.installs { Text("\(installs.formatted()) installs").font(.caption).foregroundStyle(.secondary) }; }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(12).frame(minHeight: 60).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(AIMScrollSafeButtonStyle())
                    }
                    if query.isEmpty { Button("Load more") { Task { await skills.loadCatalog(more: true) } }.frame(minHeight: 44).disabled(skills.isLoading) }
                }
                Text("Skills provide instructions only. They grant no permissions and never run scripts on this iPhone.").font(.footnote).foregroundStyle(.secondary)
            }.padding(16)
        }.scrollDismissesKeyboard(.interactively).accessibilityElement(children: .contain).accessibilityIdentifier("skills-screen")
    }
    private func detail(_ skill: NativeSkill) -> some View {
        let installed = skills.installed.first { $0.name == skill.name }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(skill.summary).font(.body)
                Text(skill.origin).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Version \(skill.version.prefix(12))").font(.caption).foregroundStyle(.secondary)
                if let notice = skill.dependencyNotice { Label(notice, systemImage: "desktopcomputer").font(.footnote).foregroundStyle(.secondary) }
                if installed?.version == skill.version {
                    Toggle("Use automatically in compatible Chat", isOn: Binding(get: { installed?.enabled ?? false }, set: { enabled in Task { await skills.toggle(skill, enabled: enabled) } })).tint(.green)
                    Button("Remove skill", role: .destructive) { showRemove = true }.frame(minHeight: 44)
                } else {
                    Text("Review instructions and supporting files before installing. Scripts remain inactive. Installation starts disabled.").font(.footnote).foregroundStyle(.secondary)
                    Button(installed == nil ? "Install (disabled)" : "Replace and preserve previous version") { Task { await skills.acceptPreview(replace: installed != nil) } }.buttonStyle(.borderedProminent).tint(.primary).disabled(skills.isLoading)
                    if installed != nil { Button("Keep installed version") { skills.preview = nil }.frame(minHeight: 44) }
                }
                Button { skills.attachInstructions(skill) } label: { Label("Attach instructions to next Chat message", systemImage: "text.badge.plus").frame(minHeight: 44) }.buttonStyle(.bordered)
                Text("For a model without skill tools, this explicit action attaches the reviewed instructions to your next message. It does not run files or grant permissions.").font(.footnote).foregroundStyle(.secondary)
                if skills.importWrite != nil {
                    Text("An existing Mac version is preserved before replacement. Review these instructions and files before installing.").font(.footnote).foregroundStyle(.secondary)
                    Button { Task { await skills.installOnMac(skill) } } label: { Label("Install or replace on selected Mac (disabled)", systemImage: "desktopcomputer").frame(minHeight: 44) }.buttonStyle(.bordered).disabled(skills.isLoading)
                }
                Picker("Files", selection: $selectedFile) { ForEach(skill.files.keys.sorted(), id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                Text(skill.files[selectedFile] ?? skill.files["SKILL.md"] ?? "").font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                if !skills.versions.isEmpty {
                    Text("Previous versions").font(.headline)
                    ForEach(skills.versions, id: \.version) { version in Button("Review \(version.version.prefix(12))") { skills.preview = version; selectedFile = "SKILL.md" }.frame(minHeight: 44) }
                }
                if let error = skills.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding(16)
        }.accessibilityIdentifier("skill-detail")
    }
}

/// A row activates only after a completed tap. A drag fails this recognizer,
/// including horizontal gestures which never engage the vertical scroll view.
struct AIMScrollSafeButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded { configuration.trigger() })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { configuration.trigger() }
    }
}
