import AIMAgentRuntime
import AIMCore
import AppKit
import SwiftUI

struct PeerWorkersSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: RuntimePeerStatus?
    @State private var identities: [RemotePeerPublicIdentity] = []
    @State private var pairs: [RemotePeerPair] = []
    @State private var staged: Data?
    @State private var preview: RuntimePeerConfiguration?
    @State private var fingerprint = ""
    @State private var limitPairDuration = true
    @State private var pairDays = 7
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SettingsGroup("Paired Mac workers", description: "Delegate to an explicitly paired Mac through the encrypted AIM relay. Configure existing mission IDs, workspace mappings, model and tool scopes on both Macs before delegation.") {
            SettingsRow("Worker configuration") {
                Button("Import and review…") { selectConfiguration() }.buttonStyle(.settings).disabled(busy)
                Button("Refresh") { Task { await refresh() } }.buttonStyle(.settings).disabled(busy)
            }
            if let status {
                SettingsRow("This Mac", description: status.machineID.uuidString)
                SettingsRow("Public fingerprint", description: status.fingerprint)
                SettingsRow("Relay", description: status.relayProtocolAvailable ? (status.qualified ? "Qualified protocol available" : "Experimental protocol available") : "Protocol unavailable; server migration and pairing may be required")
                if let diagnostic = status.diagnostic { SettingsNotice(diagnostic, tone: .error) }
                Button("Register this identity") { Task { await perform(.init(action: .register)); await refresh() } }.buttonStyle(.settings).disabled(busy)
            }
            if let preview, staged != nil {
                SettingsRow("Review configuration", description: "Account \(preview.accountID.uuidString) · \(preview.enabled ? "enabled" : "disabled") · \(preview.peers.count) scoped peers · experimental relay \(preview.experimentalUnqualifiedRelayOptIn ? "allowed" : "disabled")")
                ForEach(preview.peers, id: \.pairID) { peer in
                    SettingsRow(peer.remoteIdentity.machineID.uuidString, description: "Pair \(peer.pairID.uuidString) · \(peer.parentExecutionIDs.count) missions · \(peer.workspaces.count) workspaces · \(peer.allowedToolNames.count) tools · writer \(peer.writer ? "allowed" : "disabled") · expires \(peer.expiresAt.formatted())")
                }
                SettingsRow("Apply reviewed scopes") {
                    Button("Cancel") { staged = nil; self.preview = nil }.buttonStyle(.settings)
                    Button("Apply") { Task { await applyConfiguration() } }.buttonStyle(.settingsPrimary).disabled(busy)
                }
            }
            SettingsRow("Confirm the other Mac’s fingerprint", description: "Compare with the fingerprint displayed on that Mac. Enter it before proposing or accepting a pair.") {
                TextField("Verified fingerprint", text: $fingerprint).frame(width: 240)
            }
            SettingsToggleRow("Expire this pairing", description: "Expiration is optional. Revocation and account permissions still apply.", isOn: $limitPairDuration)
            if limitPairDuration { SettingsRow("Pairing days") { Stepper("\(pairDays)", value: $pairDays, in: 1...365_000) } }
            ForEach(identities.filter { $0.machineID != status?.machineID }, id: \.machineID) { identity in
                SettingsRow(identity.machineID.uuidString) {
                    Button("Propose pairing") { Task { await perform(.init(action: .propose, pairID: UUID(), identity: identity, confirmedFingerprint: fingerprint.trimmingCharacters(in: .whitespacesAndNewlines), expiresAt: limitPairDuration ? .now.addingTimeInterval(Double(pairDays) * 86_400) : .distantFuture)); await refresh() } }
                        .buttonStyle(.settings).disabled(busy || fingerprint.isEmpty)
                }
            }
            ForEach(pairs, id: \.id) { pair in
                SettingsRow(pair.id.uuidString, description: "\(pair.origin.machineID.uuidString) → \(pair.worker.machineID.uuidString) · \(pair.revoked ? "revoked" : pair.accepted ? "paired" : "awaiting acceptance") · expires \(pair.expiresAt.formatted())") {
                    if !pair.accepted && !pair.revoked && pair.worker.machineID == status?.machineID {
                        Button("Accept verified peer") { Task { await perform(.init(action: .accept, confirmedFingerprint: fingerprint.trimmingCharacters(in: .whitespacesAndNewlines), pair: pair)); await refresh() } }.buttonStyle(.settings).disabled(busy || fingerprint.isEmpty)
                    }
                    if !pair.revoked {
                        Button("Revoke") { Task { await perform(.init(action: .revoke, pairID: pair.id)); await refresh() } }.buttonStyle(.settings).disabled(busy)
                    }
                }
            }
            if let error { SettingsNotice(error, tone: .error) }
        }
    }
    private func decoder() -> JSONDecoder { JSONDecoder() }
    private func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            status = try decoder().decode(RuntimePeerStatus.self, from: await model.peerControl(.init(action: .status)))
            // Local identity/status remain visible even before the relay is deployed.
            if status?.enabled == true {
                identities = try decoder().decode([RemotePeerPublicIdentity].self, from: await model.peerControl(.init(action: .identities)))
                pairs = try decoder().decode([RemotePeerPair].self, from: await model.peerControl(.init(action: .pairs)))
            } else { identities = []; pairs = [] }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func perform(_ control: RuntimePeerControl) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await model.peerControl(control); error = nil; fingerprint = "" }
        catch { self.error = error.localizedDescription }
    }
    private func selectConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65_536 else { throw RemotePeerError.invalidConfiguration }
            let data = try Data(contentsOf: file)
            Task {
                guard !busy else { return }; busy = true; defer { busy = false }
                do { preview = try decoder().decode(RuntimePeerConfiguration.self, from: await model.peerControl(.init(action: .preview, configuration: data))); staged = data; error = nil }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func applyConfiguration() async {
        guard let staged else { return }
        await perform(.init(action: .importConfiguration, configuration: staged))
        if error == nil { self.staged = nil; preview = nil; await refresh() }
    }
}
