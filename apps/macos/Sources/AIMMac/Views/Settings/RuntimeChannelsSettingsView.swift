import AIMAgentRuntime
import AIMApplication
import AppKit
import SwiftUI

struct RuntimeChannelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var staged: Data?
    @State private var preview: RuntimeChannelConfiguration?
    @State private var statuses: [RuntimeChannelRouter.DeliveryStatus] = []
    @State private var error: String?
    @State private var busy = false
    @State private var token = ""
    @State private var tokenKey = "channel.telegram.bot"
    @State private var reconciling: String?
    @State private var messageID = ""
    @State private var allowResend = false

    var body: some View {
        SettingsGroup("Mission channels", description: "Route events and results for an existing mission through files, HTTPS, or Telegram. Incoming messages supply data within an explicit grant; they cannot grant new permissions.") {
            SettingsRow("Routing configuration") {
                Button("Import and review…") { selectConfiguration() }.buttonStyle(.settings).disabled(busy)
                Button("Refresh deliveries") { Task { await refresh() } }.buttonStyle(.settings).disabled(busy)
            }
            SettingsRow("Telegram token key") { TextField("Keychain key", text: $tokenKey).frame(width: 230) }
            SettingsRow("Telegram bot token", description: "Saved only in the Mac Keychain. Configurations contain the key name.") {
                SecureField("Token", text: $token).frame(width: 230)
                Button("Save token") {
                    do { try model.storeChannelToken(token, key: tokenKey); token = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.settings).disabled(token.isEmpty)
            }
            if let preview {
                SettingsRow(preview.enabled ? "Routing will be enabled" : "Routing will remain disabled",
                    description: "Review each mission and scope before applying this file.")
                ForEach(preview.grants, id: \.id) { grant in
                    SettingsRow(grant.transport.rawValue.capitalized,
                        description: "Account \(grant.accountID.uuidString) · Mission \(grant.executionID.uuidString) · \(grant.scopes.map(\.rawValue).sorted().joined(separator: ", ")) · expires \(grant.expiresAt.formatted())")
                    SettingsRow("Destination", description: destination(grant)) {
                        if grant.transport == .telegram || grant.transport == .plugin {
                            Button("Restart polling") { Task { await restart(grant.id) } }.buttonStyle(.settings).disabled(busy || staged != nil)
                        }
                    }
                }
                if staged != nil { SettingsRow("Apply reviewed configuration") {
                    Button("Cancel") { staged = nil; self.preview = nil }.buttonStyle(.settings)
                    Button("Apply") { Task { await applyConfiguration() } }.buttonStyle(.settingsPrimary).disabled(busy)
                } }
            }
            ForEach(statuses, id: \.id) { receipt in
                SettingsRow(receipt.state, description: receipt.id + (receipt.messageID.map { " · Telegram message \($0)" } ?? "")) {
                    if receipt.state == "outcome_unknown" {
                        Button("Reconcile…") { reconciling = receipt.id; messageID = ""; allowResend = false }.buttonStyle(.settings)
                    }
                }
            }
            if let receipt = reconciling {
                SettingsRow("Uncertain delivery", description: "Inspect the destination first. A resend may duplicate a message accepted before the connection failed.")
                SettingsRow("Confirmed destination receipt ID") { TextField("Receipt ID", text: $messageID).frame(width: 230) }
                SettingsToggleRow("Authorize a resend after inspection", isOn: $allowResend)
                SettingsRow("Resolve receipt") {
                    Button("Cancel") { reconciling = nil }.buttonStyle(.settings)
                    Button("Apply decision") { Task { await reconcile(receipt) } }.buttonStyle(.settings).disabled(busy || (messageID.isEmpty && !allowResend))
                }
            }
            if let error { SettingsNotice(error, tone: .error) }
        }
    }
    private func destination(_ grant: RuntimeChannelGrant) -> String {
        if let plugin = grant.plugin { return "Plugin \(plugin.pluginID) · Version \(plugin.pluginVersion) · API \(plugin.apiVersion) · Config \(plugin.configuration.count) bytes" }
        if let t = grant.telegram {
            return "Bot \(t.botID) · Chat \(t.chatID) · Senders \(t.senderIDs.sorted().map(String.init).joined(separator: ", ")) · Key \(t.tokenKey)" + (grant.revoked ? " · revoked" : "")
        }
        return [grant.endpoint?.absoluteString, grant.inboxDirectory, grant.outboxDirectory].compactMap { $0 }.joined(separator: " · ")
    }
    private func restart(_ grant: UUID) async {
        busy = true; defer { busy = false }
        do { _ = try await model.channelControl(.init(action: .restart, grantID: grant)); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func selectConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 262_144 else { throw RuntimeChannelError.invalidConfiguration }
            let data = try Data(contentsOf: file)
            Task {
                busy = true; defer { busy = false }
                do {
                    let decoded = JSONDecoder(); decoded.dateDecodingStrategy = .iso8601
                    let response = try await model.channelControl(.init(action: .preview, configuration: data))
                    preview = try decoded.decode(RuntimeChannelConfiguration.self, from: response)
                    staged = data; error = nil
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func applyConfiguration() async {
        guard let staged else { return }
        busy = true; defer { busy = false }
        do { _ = try await model.channelControl(.init(action: .apply, configuration: staged)); self.staged = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func refresh() async {
        busy = true; defer { busy = false }
        do { statuses = try JSONDecoder().decode([RuntimeChannelRouter.DeliveryStatus].self, from: await model.channelControl(.init(action: .statuses))); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func reconcile(_ receipt: String) async {
        busy = true; defer { busy = false }
        do {
            let value = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            let plugin = statuses.first(where: { $0.id == receipt })?.transport == .plugin
            if plugin {
                guard value.isEmpty || !allowResend else { throw RuntimeChannelError.invalidConfiguration }
                _ = try await model.channelControl(.init(action: .reconcilePlugin, receiptID: receipt, authorizeResend: allowResend, confirmedRemoteReceiptID: value.isEmpty ? nil : value))
            } else {
                let id = value.isEmpty ? nil : Int64(value)
                guard value.isEmpty || (id ?? 0) > 0, id == nil || !allowResend else { throw RuntimeChannelError.invalidConfiguration }
                _ = try await model.channelControl(.init(action: .reconcile, receiptID: receipt, confirmedMessageID: id, authorizeResend: allowResend))
            }
            reconciling = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
