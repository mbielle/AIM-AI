import AIMCore
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct MacDirectRemoteSettings: View {
    let direct: MacDirectRemoteCoordinator
    @State private var coordinatorURL = ""
    @State private var sheet: DirectRemoteSheet?
    @State private var revocation: UUID?
    @State private var working = false
    @State private var permissionDrafts: [UUID: Set<DirectRemotePermission>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("iPhone connection", footer: "Your Mac must stay available. Each iPhone needs your approval before it can connect.") {
                SettingsRow("Allow iPhone connections", description: connectionStatus) {
                    SettingsSwitch(isOn: Binding(get: { direct.enabled }, set: { value in
                        Task { await direct.setEnabled(value) }
                    }), label: "Allow iPhone connections")
                }
                if direct.enabled {
                    SettingsRow("Add an iPhone", description: "Scan a code in AIM, then confirm on this Mac.") {
                        Button("Add iPhone…") { openPairing() }.buttonStyle(.settingsPrimary)
                    }
                    ForEach(direct.pending, id: \.id) { device in
                        SettingsRow(device.name, description: "Waiting for your approval on this Mac.") {
                            Button("Review…") { sheet = .pairing }.buttonStyle(.settings)
                        }
                    }
                }
            }
            if direct.enabled {
                SettingsGroup("Paired iPhones") {
                    if direct.records.isEmpty {
                        SettingsRow("No iPhone paired yet", description: "Add an iPhone to access this Mac from AIM.")
                    }
                    ForEach(direct.records, id: \.pair.id) { record in
                        SettingsRow(title: record.pair.client.name,
                                    description: record.pair.revoked ? "Access removed" : permissionSummary(record.pair.permissions),
                                    leading: {
                            Image(systemName: "iphone").font(.system(size: 15)).foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }) {
                            if !record.pair.revoked {
                                Button("Permissions…") { sheet = .permissions(record.pair.id) }.buttonStyle(.settings)
                                Menu {
                                    Button("Remove access…", role: .destructive) { revocation = record.pair.id }
                                } label: {
                                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                                        .frame(width: 32, height: 32).contentShape(Rectangle())
                                }
                                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                                .accessibilityLabel("Actions for \(record.pair.client.name)")
                            }
                        }
                    }
                }
                SettingsDisclosure("Connection options") {
                    SettingsGroup("Custom connection server", footer: "Leave this empty to pair on the same Wi-Fi. To connect across networks, use the secure server address supplied by your administrator or your own AIM server.") {
                        SettingsBlock {
                            TextField("Secure server address (wss://…)", text: $coordinatorURL)
                                .textFieldStyle(.settings).privacySensitive()
                                .accessibilityLabel("Custom connection server address")
                            Text("This address is used for the next pairing. Existing iPhone connections keep their settings.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let message = direct.message { SettingsNotice(message, tone: .warning) }
        }
        .task {
            await direct.start()
            coordinatorURL = direct.coordinatorURL
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await direct.refresh()
            }
        }
        .sheet(item: $sheet) { selection in
            switch selection {
            case .pairing:
                pairingSheet
            case .permissions(let id):
                if let record = direct.records.first(where: { $0.pair.id == id && !$0.pair.revoked }) {
                    DirectRemotePermissionsEditor(direct: direct, record: record) { sheet = nil }.id(id)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("iPhone access unavailable").font(.title2.bold())
                        Text("This pairing is no longer active.").foregroundStyle(.secondary)
                        Button("Done") { sheet = nil }.buttonStyle(.settingsPrimary)
                    }.padding(28).frame(width: 420)
                }
            }
        }
        .onChange(of: direct.enabled) { _, enabled in if !enabled { sheet = nil } }
        .alert("Remove this iPhone’s access?", isPresented: Binding(get: { revocation != nil }, set: { if !$0 { revocation = nil } })) {
            Button("Remove access", role: .destructive) {
                if let id = revocation { Task { await direct.revoke(id) } }
                revocation = nil
            }
            Button("Cancel", role: .cancel) { revocation = nil }
        } message: {
            Text("This iPhone will need to pair again to connect to this Mac. Your conversations are preserved.")
        }
    }

    private var pairingSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(direct.pending.isEmpty ? "Add your iPhone" : "Confirm your iPhone").font(.system(size: 22, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if direct.pending.isEmpty {
                        Text("Open AIM on your iPhone, choose Computer connection, then scan this code.")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                        if let invite = direct.invitation {
                            invitationPreview(invite)
                        } else if working {
                            ProgressView("Preparing your code…").frame(maxWidth: .infinity).padding(24)
                        } else {
                            Button("Show pairing code") { createInvite() }.buttonStyle(.settingsPrimary)
                        }
                        Text("After scanning, come back here to approve the iPhone and choose its permissions.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        ForEach(direct.pending, id: \.id) { device in pendingApproval(device) }
                    }
                    if let message = direct.message { SettingsNotice(message, tone: .warning) }
                }
            }.frame(maxHeight: 520)
            HStack {
                Spacer()
                Button("Cancel pairing") {
                    working = true
                    Task {
                        await direct.cancelInvite()
                        permissionDrafts = [:]
                        working = false
                        sheet = nil
                    }
                }.buttonStyle(.settings).keyboardShortcut(.cancelAction).disabled(working)
            }
        }
        .padding(28).frame(width: 540, height: 600).interactiveDismissDisabled()
    }

    private func invitationPreview(_ invite: DirectRemoteInvite) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if invite.expiresAt > context.date {
                VStack(spacing: 12) {
                    if let image = qr(invite) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 208, height: 208)
                            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14))
                            .privacySensitive().accessibilityLabel("Pairing QR code")
                    } else {
                        SettingsNotice("The code could not be displayed. Try creating a new code.", tone: .warning)
                        Button("New pairing code") { createInvite() }.buttonStyle(.settings).disabled(working)
                    }
                    Text(invite.host.name).font(.system(size: 14, weight: .medium))
                    let seconds = max(0, Int(invite.expiresAt.timeIntervalSince(context.date)))
                    Text("Expires in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                fingerprintDetail(title: "Mac security details", fingerprint: invite.host.fingerprint)
            } else {
                SettingsNotice("This code has expired. Create a new one to continue.")
                Button("New pairing code") { createInvite() }.buttonStyle(.settingsPrimary).disabled(working)
            }
        }
    }

    private func pendingApproval(_ device: DirectRemotePublicIdentity) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(device.name, systemImage: "iphone").font(.headline)
            Text("Approve only the iPhone you just scanned with. It has no access until you confirm here.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Allowed access: \(permissionSummary(permissionDrafts[device.id] ?? [.read, .chat, .code, .agent]))")
                .font(.system(size: 13, weight: .medium))
            DisclosureGroup("Choose permissions") {
                DirectRemotePermissionRows(permissions: Binding(
                    get: { permissionDrafts[device.id] ?? [.read, .chat, .code, .agent] },
                    set: { permissionDrafts[device.id] = $0.union([.read]) }
                )).padding(.top, 10).disabled(working)
            }.font(.system(size: 13))
            fingerprintDetail(title: "iPhone security details", fingerprint: device.fingerprint)
            Button("Confirm iPhone") {
                working = true
                let permissions = (permissionDrafts[device.id] ?? [.read, .chat, .code, .agent]).union([.read])
                let invitationID = direct.invitation?.id
                Task {
                    await direct.confirm(device.id, permissions: permissions)
                    working = false
                    if direct.invitation == nil,
                       direct.records.contains(where: { $0.pair.id == invitationID && $0.pair.client.id == device.id && !$0.pair.revoked }) {
                        permissionDrafts[device.id] = nil
                        sheet = nil
                    }
                }
            }.buttonStyle(.settingsPrimary).disabled(working)
        }
    }

    private func openPairing() {
        sheet = .pairing
        if direct.invitation == nil && direct.pending.isEmpty { createInvite() }
    }

    private func createInvite() {
        guard !working else { return }
        working = true
        Task {
            await direct.createInvite(coordinator: coordinatorURL)
            working = false
        }
    }

    private var connectionStatus: String {
        guard direct.enabled else { return "Off" }
        return switch direct.state {
        case .connected(.lan): "Connected on the local network"
        case .connected(.peerToPeer): "Connected directly"
        case .connected(.turn): "Connected securely through a relay"
        case .disconnected: "Ready for your iPhone"
        case .signalling, .gatheringICE, .checkingICE: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .revoked: "iPhone access removed"
        case .failed: "Connection unavailable"
        }
    }

    private func qr(_ invite: DirectRemoteInvite) -> NSImage? {
        guard let url = try? invite.qrURL(), let data = url.absoluteString.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

private enum DirectRemoteSheet: Identifiable {
    case pairing, permissions(UUID)
    var id: String {
        switch self {
        case .pairing: "pairing"
        case .permissions(let id): id.uuidString
        }
    }
}

private struct DirectRemotePermissionsEditor: View {
    let direct: MacDirectRemoteCoordinator
    let record: DirectRemoteSavedPair
    let close: () -> Void
    @State private var permissions: Set<DirectRemotePermission>
    @State private var saving = false

    init(direct: MacDirectRemoteCoordinator, record: DirectRemoteSavedPair, close: @escaping () -> Void) {
        self.direct = direct
        self.record = record
        self.close = close
        _permissions = State(initialValue: record.pair.permissions.union([.read]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Permissions for \(record.pair.client.name)").font(.system(size: 22, weight: .semibold))
            Text("Choose what this iPhone can do in your current Mac profile. Saving reconnects the iPhone and stops its active controls to apply the new permissions.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DirectRemotePermissionRows(permissions: $permissions).disabled(saving)
                    fingerprintDetail(title: "iPhone security details", fingerprint: record.pair.client.fingerprint)
                    if let message = direct.message { SettingsNotice(message, tone: .warning) }
                }
            }.frame(maxHeight: 520)
            HStack {
                Spacer()
                Button("Cancel", action: close).buttonStyle(.settings).keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save permissions") {
                    saving = true
                    let selected = permissions.union([.read])
                    Task {
                        await direct.updatePermissions(record.pair.id, permissions: selected)
                        saving = false
                        if direct.records.contains(where: { $0.pair.id == record.pair.id && !$0.pair.revoked && $0.pair.permissions == selected }) { close() }
                    }
                }.buttonStyle(.settingsPrimary).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(28).frame(width: 540, height: 600).interactiveDismissDisabled(saving)
    }
}

private struct DirectRemotePermissionRows: View {
    @Binding var permissions: Set<DirectRemotePermission>
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("Access") {
                ForEach(DirectRemotePermission.allCases, id: \.self) { permission in
                    SettingsToggleRow(permissionTitle(permission), description: permissionDescription(permission), isOn: Binding(
                        get: { permission == .read || permissions.contains(permission) },
                        set: { enabled in
                            if enabled { permissions.insert(permission) } else { permissions.remove(permission) }
                            permissions.insert(.read)
                        }
                    )).disabled(permission == .read)
                }
            }
            Text("Provider budgets and Mac action approvals still apply.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

@MainActor private func fingerprintDetail(title: String, fingerprint: String) -> some View {
    DisclosureGroup(title) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare this fingerprint with the one shown on your iPhone to verify the device.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }.padding(.top, 8)
    }.font(.system(size: 13)).foregroundStyle(.secondary)
}

private func permissionSummary(_ permissions: Set<DirectRemotePermission>) -> String {
    if permissions == Set(DirectRemotePermission.allCases) { return "Full access" }
    return DirectRemotePermission.allCases.filter { permissions.contains($0) }.map(permissionTitle).joined(separator: " · ")
}

private func permissionTitle(_ permission: DirectRemotePermission) -> String {
    switch permission {
    case .read: "View activity"
    case .chat: "Chat"
    case .code: "Code"
    case .agent: "Agent"
    case .control: "Control tasks"
    case .approve: "Approve actions"
    case .settings: "Change settings"
    case .terminal: "Use terminal"
    }
}

private func permissionDescription(_ permission: DirectRemotePermission) -> String {
    switch permission {
    case .read: "View conversations and task progress. Required for a connection."
    case .chat: "Send messages to Chat on this Mac."
    case .code: "Start Code requests on this Mac."
    case .agent: "Start Agent requests on this Mac."
    case .control: "Pause, resume or cancel tasks and use remote task controls."
    case .approve: "Respond to action approval requests from the iPhone."
    case .settings: "Change settings available through the connection."
    case .terminal: "Access terminal features available through the connection."
    }
}
