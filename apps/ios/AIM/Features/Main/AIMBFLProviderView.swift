import AIMCore
import SwiftUI

struct AIMBFLProviderView: View {
    let chat: NativeChatStore
    let back: () -> Void
    @State private var key = ""
    @State private var saving = false
    @State private var disconnect = false
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Black Forest Labs", back: back)
            AIMSettingsForm {
                Section {
                    HStack(spacing: 14) { AIMBrandLogo(identity: "black-forest-labs"); Text("Black Forest Labs").font(.headline) }
                    LabeledContent("Connection", value: chat.bflConnected ? "Key saved on this iPhone" : "Not connected")
                    Text("FLUX image creation. Billing belongs to your Black Forest Labs account.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("API key").font(.subheadline.weight(.medium))
                    SecureField(chat.bflConnected ? "•••••••• · replace key" : "Paste API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().padding(12)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    Button(saving ? "Validating…" : "Validate and save") {
                        saving = true
                        Task { if await chat.saveBFLKey(key) { key = "" }; saving = false }
                    }.disabled(saving || key.isEmpty)
                    if let status = chat.bflStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
                } footer: { Text("Validation checks the account credit endpoint without generating an image. The key stays in this device’s Keychain.") }
                Section {
                    ForEach(MediaModel.blackForestLabs) { model in Text(model.name).frame(minHeight: 44) }
                } header: { Text("Documented image models") }
                if chat.bflConnected { Button("Disconnect") { disconnect = true } }
            }
        }.tint(.primary)
        .confirmationDialog("Disconnect Black Forest Labs?", isPresented: $disconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { chat.disconnectBFL() }
            Button("Cancel", role: .cancel) { }
        }
    }
}
