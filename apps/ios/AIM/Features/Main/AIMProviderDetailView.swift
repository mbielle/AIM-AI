import AIMCore
import SwiftUI

struct AIMProviderDetailView: View {
    let chat: NativeChatStore
    let provider: ChatProvider
    let back: () -> Void
    @State private var key = ""
    @State private var saving = false
    @State private var discard = false
    @State private var remove = false
    @State private var saved = false
    @State private var error: String?
    @State private var catalog: [ChatModel] = []
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: provider.name, back: leave)
            AIMSettingsForm {
                Section {
                    HStack(spacing: 14) {
                        AIMModelLogo(modelID: "", provider: provider.rawValue, displayName: provider.name, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name).font(.headline)
                            Text(chat.connectedProviders.contains(provider) ? "Connected on this iPhone" : "Add an API key").font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key").font(.subheadline)
                        SecureField(chat.connectedProviders.contains(provider) ? "•••••••• · replace key" : "Paste API key", text: $key)
                            .accessibilityIdentifier("provider-key-field")
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            .padding(12).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.16)))
                    }.padding(.vertical, 6)
                    Link(destination: provider.keyURL) { Label("Get an API key", systemImage: "arrow.up.right").foregroundStyle(.primary) }
                    Button(action: { Task { await save() } }) {
                        HStack { Text("Check and save"); Spacer(); if saving { ProgressView() } else { Image(systemName: "checkmark") } }.foregroundStyle(.primary)
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    if saved { Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                    if let error { AIMSettingsMessage(text: error) }
                } header: { Text("API key") } footer: { Text("Validation checks access without generating a response.") }
                if chat.connectedProviders.contains(provider) {
                    Section("Available models") {
                        if catalog.isEmpty { Text("No models loaded").foregroundStyle(.secondary) }
                        ForEach(catalog.prefix(20)) { model in Text(model.name).font(.subheadline) }
                    }
                    Section { Button { remove = true } label: { Label("Disconnect provider", systemImage: "minus.circle").foregroundStyle(.primary) } }
                }
            }
        }.task { if chat.connectedProviders.contains(provider) { catalog = (try? await chat.catalog(for: provider)) ?? [] } }
        .settingsDraftNavigationProtection(!key.isEmpty || saving, onBackAttempt: leave)
        .interactiveDismissDisabled(!key.isEmpty || saving)
        .alert("Unsaved key", isPresented: $discard) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { key = ""; back() }
            Button("Save") { Task { await save(); if key.isEmpty { back() } } }
        }
        .alert("Disconnect \(provider.name)?", isPresented: $remove) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { chat.removeKey(provider); if !chat.connectedProviders.contains(provider) { back() } else { error = chat.errorMessage } }
        }
    }
    private func leave() { if saving { return }; if key.isEmpty { back() } else { discard = true } }
    private func save() async {
        guard !saving else { return }; saving = true; defer { saving = false }
        if await chat.saveKey(key, provider: provider) { key = ""; saved = true; error = nil; catalog = (try? await chat.catalog(for: provider)) ?? [] }
        else { error = chat.errorMessage }
    }
}
