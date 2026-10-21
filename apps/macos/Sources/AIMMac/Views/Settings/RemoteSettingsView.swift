import AIMMacPlatform
import SwiftUI

/// Control this Mac's AIM Agent from the AIM iPhone app or the website.
struct RemoteSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var code: RemotePairingCode?
    @State private var qrImage: NSImage?
    @State private var devices: [RemoteHostDevice] = []
    @State private var message: String?
    @State private var busy = false
    @State private var diagnosticFile: URL?
    @State private var cloudExpanded = false
    @State private var cloudExpansionInitialized = false
    private let machineName = HostBundleResources.remoteMachineName

    var body: some View {
        SettingsPage("Remote", subtitle: "Connect your iPhone to this Mac to continue your work from AIM.") {
            if let direct = model.directRemote { MacDirectRemoteSettings(direct: direct).id(direct.profileID) }
            if let error = model.directRemoteError { SettingsNotice(error, tone: .warning) }
            DisclosureGroup("Cloud Remote (optional)", isExpanded: $cloudExpanded) {
                VStack(alignment: .leading, spacing: 24) {
                    if model.account.accessUser != nil, model.account.isConfigured {
                        cloudRemote
                    } else {
                        SettingsNotice("Cloud Remote uses a separate configured AIM account. You can pair an iPhone above without signing in.")
                    }
                }.padding(.top, 16)
            }
            .font(.system(size: 14, weight: .medium))
        }
        .task(id: model.account.accessUser?.id) {
            if !cloudExpansionInitialized {
                cloudExpanded = model.account.accessUser != nil && model.account.isConfigured
                cloudExpansionInitialized = true
            }
            await model.refreshDirectRemote()
            let accountID = model.account.accessUser?.id
            code = nil; qrImage = nil; devices = []; message = nil; busy = false; diagnosticFile = nil
            await refresh()
            while !Task.isCancelled, model.account.accessUser?.id == accountID {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
                await model.refreshRemoteState()
                guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
                if !model.remoteEnabled || !model.remoteHostAvailable { code = nil; qrImage = nil; devices = [] }
            }
        }
    }

    private var cloudRemote: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup {
                SettingsRow("Allow control from my phone", description: statusText) {
                    SettingsSwitch(isOn: Binding(get: { model.remoteEnabled }, set: { value in
                        Task { await model.setRemoteEnabled(value); await refresh() }
                    }), label: "Allow control from my phone")
                    .disabled(model.account.accessUser == nil || !model.account.isConfigured || model.isChangingRemote)
                }
            }
            if let message, message != failureMessage { SettingsNotice(message) }
            if case .failed(let reason) = model.remoteStatus { SettingsNotice(reason, tone: .warning) }
            if model.remoteEnabled, model.remoteHostAvailable {
                SettingsGroup("Pair a device", footer: "Only someone who can see this screen can pair: the code works once and only for 5 minutes. Being signed in to your account is not enough to control this Mac.") {
                    if let code, code.expiresAt > .now {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, Int(code.expiresAt.timeIntervalSince(context.date)))
                            HStack(alignment: .center, spacing: 24) {
                                if left > 0, let image = qrImage {
                                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 168, height: 168)
                                        .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
                                        .accessibilityLabel("Pairing QR code")
                                }
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Scan with your iPhone's camera, or type the code in AIM → Remote → Pair a computer.")
                                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Text(left > 0 ? code.code : "Expired")
                                        .font(.system(size: 30, weight: .semibold, design: .monospaced)).kerning(3).textSelection(.enabled)
                                    Text(left > 0 ? String(format: "Single use · expires in %d:%02d", left / 60, left % 60) : "Generating a new code…")
                                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.vertical, 18)
                            .onChange(of: left == 0) { _, expired in if expired { Task { await pair() } } }
                        }
                    }
                    SettingsRow(code == nil ? "Pairing code" : "Need another code?",
                                description: code == nil ? "Shows a QR code and a 6-character code for your phone." : nil) {
                        if code != nil { Button("Hide") { code = nil; qrImage = nil }.buttonStyle(.settings) }
                        Button(code == nil ? "Show a pairing code" : "New code") { Task { await pair() } }
                            .buttonStyle(code == nil ? .settingsPrimary : .settings).disabled(busy)
                    }
                }
                SettingsGroup("Remote diagnostics", footer: "A redacted report contains only stages, identifiers and public-key fingerprints. It does not prove that the iPhone opened its key.") {
                    SettingsRow("Diagnostic report") {
                        Button("Create diagnostic report") { Task { await exportDiagnostic() } }.buttonStyle(.settings)
                        if let diagnosticFile { ShareLink("Share diagnostic report", item: diagnosticFile).buttonStyle(.settings) }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Devices on this account").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("Refresh") { Task { await refresh() } }.buttonStyle(.settings)
                    }
                    Text("These devices are registered with your account. Their presence here does not confirm that this Mac is connected.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    SettingsCard {
                        if devices.isEmpty { SettingsRow("No device yet", description: "Pair your iPhone with the code above.") }
                        ForEach(devices) { device in
                            SettingsRow(title: device.name, description: deviceDetail(device), leading: {
                                Image(systemName: "iphone").font(.system(size: 15)).foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }) {
                                if device.isActive() {
                                    Button("Revoke") { Task { await revoke(device) } }.buttonStyle(.settingsDestructive)
                                        .help("This device loses access at once; this Mac switches to a new encryption key.")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func exportDiagnostic() async {
        let accountID = model.account.accessUser?.id
        do {
            let report = try await model.remoteDiagnosticReport()
            guard accountID == model.account.accessUser?.id else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("aim-mac-remote-diagnostic-\(Int(Date().timeIntervalSince1970)).json")
            try report.encodedData().write(to: url, options: .atomic)
            diagnosticFile = url
        } catch { message = "Remote diagnostic report unavailable." }
    }

    private var failureMessage: String? {
        if case .failed(let reason) = model.remoteStatus { return reason }
        return nil
    }

    private var statusText: String {
        switch model.remoteStatus {
        case .stopped: model.remoteEnabled ? "Not connected." : "Off."
        case .starting: "Connecting to the AIM relay…"
        case .online(let count): "On — this Mac is online. \(count) device(s) can read and control it."
        case .failed: "Not connected."
        }
    }

    private func deviceDetail(_ device: RemoteHostDevice) -> String {
        var parts: [String] = []
        if let paired = device.paired_at { parts.append("paired \(paired.formatted(date: .abbreviated, time: .omitted))") }
        if let used = device.last_used_at { parts.append("last used \(used.formatted(.relative(presentation: .named)))") }
        if device.revoked_at != nil { parts.append("revoked") }
        else if !device.isActive() { parts.append("expired") }
        else if device.public_key == nil { parts.append("waiting for its encryption key") }
        return parts.joined(separator: " · ")
    }

    private func refresh() async {
        let accountID = model.account.accessUser?.id
        await model.refreshRemoteState()
        guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
        guard model.remoteEnabled, model.remoteHostAvailable else { devices = []; return }
        do {
            let fresh = try await model.remoteDevices()
            guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
            devices = fresh; message = nil
        } catch {
            guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
            message = error.localizedDescription
        }
    }

    private func pair() async {
        guard let accountID = model.account.accessUser?.id, model.remoteEnabled, model.remoteHostAvailable else { return }
        busy = true
        defer { if model.account.accessUser?.id == accountID { busy = false } }
        do {
            let fresh = try await model.remotePairingCode()
            guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
            qrImage = RemotePairingLink.image(for: RemotePairingLink.url(code: fresh.code, machineName: machineName))
            code = fresh
            message = nil
        } catch {
            guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
            message = error.localizedDescription
        }
    }

    private func revoke(_ device: RemoteHostDevice) async {
        guard let accountID = model.account.accessUser?.id, model.remoteEnabled, model.remoteHostAvailable else { return }
        do {
            try await model.revokeRemoteDevice(device.id)
            guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
            message = "\(device.name) can no longer access this Mac."
        } catch {
            guard !Task.isCancelled, model.account.accessUser?.id == accountID else { return }
            message = error.localizedDescription
        }
        guard model.account.accessUser?.id == accountID else { return }
        await refresh()
    }
}
