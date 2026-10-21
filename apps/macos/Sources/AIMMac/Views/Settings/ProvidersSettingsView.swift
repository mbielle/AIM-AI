import AIMCore
import AIMApplication
import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var connection = OpenRouterConnection()
    @State private var chatGPT = ChatGPTConnection()
    @State private var diagnostics: ChatProvider?
    @State private var editing: ChatProvider?
    @State private var reviewingLegacyKeys = false

    var body: some View {
        SettingsPage("Providers", subtitle: "Your keys stay in this Mac’s Keychain. Usage is billed directly by your providers.") {
            SettingsNotice("Provider credentials belong only to this local profile or signed-in AIM account. Previously saved keys stay quarantined until you explicitly review and copy selected API keys to this profile. Signing in never adopts old keys. OAuth sessions must be reconnected.")
            SettingsGroup("Previously saved keys") {
                SettingsRow("Review legacy API keys", description: "Choose individual providers and confirm the destination profile. Originals are preserved and existing keys are never overwritten.") {
                    Button("Review…") { reviewingLegacyKeys = true }.buttonStyle(.settings)
                }
            }
            SettingsGroup("Quick connect") {
                SettingsRow(title: "OpenRouter",
                            description: model.connectedProviders.contains(.openRouter)
                                ? "Connected. Hundreds of models with one account."
                                : "Sign in in your browser, without copying a key.",
                            leading: { ProviderLogo(provider: .openRouter, size: 28) }) {
                    if connection.connecting {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { connection.cancel() }.buttonStyle(.settings)
                    } else if model.connectedProviders.contains(.openRouter) {
                        SettingsStatus(text: "Connected")
                        Button("Disconnect") { model.removeProviderKey(.openRouter) }.buttonStyle(.settings)
                    } else {
                        Button("Connect") { let scope = model.captureCredentialScope(); connection.start { try model.saveProviderKey($0, provider: .openRouter, expectedScope: scope) } }
                            .buttonStyle(.settingsPrimary)
                    }
                }
                if let status = connection.status { SettingsBlock { SettingsNotice(status) } }
                ChatGPTPlanRow(connection: chatGPT)
            }
            SettingsGroup("Main providers") {
                ForEach(ChatProvider.allCases.filter { $0 != .local && !$0.isCompatible && $0 != .chatgpt }) { provider in
                    ProviderKeyRow(provider: provider, editing: $editing) { diagnostics = provider }
                }
            }
            ForEach(CompatibleProviderSpec.Group.allCases, id: \.self) { group in
                SettingsGroup(group.rawValue) {
                    ForEach(ChatProvider.allCases.filter { CompatibleProviders.spec($0)?.group == group }) { provider in
                        ProviderKeyRow(provider: provider, editing: $editing) { diagnostics = provider }
                    }
                }
            }
            SettingsGroup("Images") {
                FluxKeyRow()
            }
        }
        .id(model.account.identity?.storageID)
        .onChange(of: model.account.identity?.storageID) { _, _ in connection.cancel(); chatGPT.cancel(); editing = nil; diagnostics = nil }
        .onDisappear { connection.cancel(); chatGPT.cancel() }
        .task { await model.refreshChatGPTAccount() }
        .sheet(item: $diagnostics) { provider in ProviderDiagnosticsView(initialProvider: provider) }
        .sheet(isPresented: $reviewingLegacyKeys) { LegacyCredentialAdoptionView() }
    }
}

/// "Continue with ChatGPT": the official sign-in, which uses the usage included in the
/// person's ChatGPT plan instead of API billing.
private struct ChatGPTPlanRow: View {
    let connection: ChatGPTConnection
    @Environment(AppModel.self) private var model
    private var connected: Bool { model.connectedProviders.contains(.chatgpt) }

    var body: some View {
        SettingsRow(title: "ChatGPT",
                    description: connected
                        ? "Using your ChatGPT plan" + (model.chatGPTEmail.map { " · \($0)" } ?? "") + ". No API billing."
                        : "Use the usage included in your ChatGPT plan, without an API key.",
                    leading: { ProviderLogo(provider: .chatgpt, size: 28) }) {
            if connection.connecting {
                ProgressView().controlSize(.small)
                Button("Cancel") { connection.cancel() }.buttonStyle(.settings)
            } else if connected {
                Link("Manage usage", destination: ChatGPTPlanAuth.manageUsageURL)
                    .buttonStyle(TextLinkStyle()).font(.system(size: 12.5))
                Button("Disconnect") { model.disconnectChatGPT() }.buttonStyle(.settings)
            } else {
                Button("Continue with ChatGPT") {
                    let scope = model.captureCredentialScope()
                    Task {
                        do {
                            let previous = try await model.chatGPTSession()
                            guard scope == model.captureCredentialScope() else { return }
                            connection.start(previous: previous) { try model.saveChatGPTSession($0, expectedScope: scope) }
                        } catch { connection.credentialReadFailed() }
                    }
                }
                    .buttonStyle(.settingsPrimary)
            }
        }
        if let status = connection.status { SettingsBlock { SettingsNotice(status) } }
    }
}

private struct ProviderKeyRow: View {
    let provider: ChatProvider
    @Binding var editing: ChatProvider?
    let diagnostics: () -> Void
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var error: String?
    private var connected: Bool { model.connectedProviders.contains(provider) }
    private var isEditing: Bool { editing == provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: provider.name,
                        description: connected ? "Key saved on this Mac" : "Not connected",
                        leading: { ProviderLogo(provider: provider, size: 24).frame(width: 28) }) {
                if !isEditing {
                    if connected {
                        SettingsStatus(text: "Connected")
                        Button("Replace") { open() }.buttonStyle(.settings)
                        SettingsIconButton(systemImage: "trash", destructive: true, help: "Remove the \(provider.name) key from this Mac") {
                            model.removeProviderKey(provider)
                        }
                    } else {
                        Button("Add key") { open() }.buttonStyle(.settings)
                    }
                    Menu {
                        Link("Get an API key", destination: provider.keyURL)
                        Button("Connection diagnostics…", action: diagnostics)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More for \(provider.name)")
                }
            }
            if isEditing {
                HStack(spacing: 8) {
                    SecureField(connected ? "New \(provider.name) key" : "\(provider.name) API key", text: $key)
                        .textFieldStyle(.settings).onSubmit(save)
                    Button("Cancel") { editing = nil; key = ""; error = nil }.buttonStyle(.settings)
                    Button("Save", action: save).buttonStyle(.settingsPrimary)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 60).padding(.trailing, SettingsMetrics.rowHorizontal).padding(.bottom, 14)
            }
            if let error {
                SettingsNotice(error, tone: .error)
                    .padding(.leading, 60).padding(.trailing, SettingsMetrics.rowHorizontal).padding(.bottom, 14)
            }
        }
    }

    private func open() {
        key = ""
        error = nil
        editing = provider
    }

    private func save() {
        do {
            try model.saveProviderKey(key, provider: provider)
            key = ""
            error = nil
            editing = nil
        } catch { self.error = "Could not save the key. Check the value and Keychain access." }
    }
}


/// Black Forest Labs (FLUX) key, used by image generation.
private struct FluxKeyRow: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var editing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Black Forest Labs (FLUX)",
                        description: model.hasFluxKey ? "Key saved on this Mac · used for image generation" : "Image generation with FLUX models",
                        leading: { ModelCreatorLogo(creator: "black-forest-labs", size: 24).frame(width: 28) }) {
                if !editing {
                    if model.hasFluxKey {
                        SettingsStatus(text: "Connected")
                        Button("Replace") { editing = true }.buttonStyle(.settings)
                        SettingsIconButton(systemImage: "trash", destructive: true, help: "Remove the Black Forest Labs key") { model.removeFluxKey() }
                    } else {
                        Button("Add key") { editing = true }.buttonStyle(.settings)
                    }
                    Link(destination: BlackForestLabsImageService.keyURL) { Image(systemName: "arrow.up.right.square") }
                        .help("Get an API key")
                }
            }
            if editing {
                HStack(spacing: 8) {
                    SecureField("API key", text: $key).textFieldStyle(.settings)
                    Button("Cancel") { editing = false; key = "" }.buttonStyle(.settings)
                    Button("Save") {
                        do { try model.saveFluxKey(key); key = ""; editing = false; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.settingsPrimary).disabled(key.isEmpty)
                }
                .padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.bottom, 12)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.bottom, 10) }
            }
        }
        .task { await model.refreshFluxKey() }
    }
}
