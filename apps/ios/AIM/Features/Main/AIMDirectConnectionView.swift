import AIMCore
import AIMDirectNative
import Observation
import SwiftUI
import UIKit

@MainActor @Observable final class AIMDirectConnectionStore {
    let controller: DirectRemoteController
    let service: DirectRemoteClientService
    private(set) var records: [DirectRemoteSavedPair] = []
    private(set) var state = DirectRemoteConnectionState.disconnected
    private(set) var busy = false
    private(set) var selectedPairID: UUID?
    var message: String?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var restored = false
    private let reconnectPreference: AIMDirectReconnectPreference
    init(profile: LocalProfile, secureStore: (any SecureStoring)? = nil) throws {
        let secrets: any SecureStoring = secureStore ?? KeychainSecureStore()
        let identity = try DirectRemoteIdentity.loadOrCreate(profile: profile, role: .phone, name: UIDevice.current.name, store: secrets)
        let controller = try DirectRemoteController(identity: identity, store: secrets)
        self.controller = controller
        reconnectPreference = .init(profileID: profile.id)
        #if DEBUG
        let qa = AIMQAContext.current
        let faults = AIMQAFaultState()
        let trace = qa.map { AIMQATraceRecorder(context: $0, role: .phone) }
        let fault = qa == nil ? nil : ProcessInfo.processInfo.environment["AIM_QA_FAULT"].flatMap(AIMQATransportFault.init(rawValue:))
        service = DirectRemoteClientService(profile: profile, store: secrets) {
            let session = try await controller.selectedSession()
            guard qa != nil else { return session }
            return AIMQAFaultTransport(base: session, fault: fault, state: faults, trace: trace)
        }
        #else
        service = DirectRemoteClientService(profile: profile, store: secrets) { try await controller.selectedSession() }
        #endif
    }
    func start() async {
        await refresh()
        if observer == nil {
            observer = Task { [weak self, controller] in
                for await _ in controller.events {
                    guard !Task.isCancelled else { return }; await self?.refresh()
                }
            }
        }
        if !restored {
            restored = true
            if !AIMNetworkPrivacyPolicy.isEnabled, let id = reconnectPreference.candidate(available: records.filter { !$0.pair.revoked }.map(\.pair.id)) {
                await connect(id)
            }
        }
    }
    func refresh() async {
        do {
            records = try await controller.records()
            state = await controller.connectionState(); selectedPairID = await controller.selectedPairID()
            if case .connected = state { message = nil }
        }
        catch { message = "Saved device permissions could not be opened. Existing pairings are preserved." }
    }
    func connect(_ id: UUID) async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        reconnectPreference.select(id)
        do { try await controller.connect(pairID: id); await refresh() }
        catch { message = "Mac unavailable. Check that AIM is open, direct access is enabled, and both devices can reach each other."; await refresh() }
    }
    func pair(_ invitation: DirectRemoteInvite) async {
        guard !busy else { return }; busy = true; message = "Confirm this iPhone on the Mac."
        defer { busy = false }
        do {
            let record = try await controller.pair(inviteURL: invitation.qrURL())
            reconnectPreference.select(record.pair.id)
            message = "Paired. Connecting to the Mac…"
            await refresh()
        } catch { message = "Pairing did not complete. Check the confirmation on the Mac or generate a new QR code."; await refresh() }
    }
    /// Background suspends the transport but preserves the user's reconnect
    /// intent. Only the explicit Disconnect/profile-exit path clears it.
    func setForeground(_ active: Bool) async {
        await controller.setForeground(active)
        await refresh()
    }
    func disconnect(rememberChoice: Bool = true) async {
        if rememberChoice { reconnectPreference.disable() }
        message = nil; await controller.disconnect(); await refresh()
    }
    var statusText: String {
        switch state {
        case .connected(.lan): "Direct · local network"
        case .connected(.peerToPeer): "Direct · peer to peer"
        case .connected(.turn): "Relayed · encrypted TURN transport"
        case .disconnected: "Not connected"
        case .signalling: "Contacting Mac"
        case .gatheringICE, .checkingICE: "Connecting"
        case .reconnecting: "Reconnecting"
        case .revoked: "Access revoked on the Mac"
        case .failed: "Mac unavailable"
        }
    }
    isolated deinit { observer?.cancel() }
}

struct AIMDirectConnectionView: View {
    let direct: AIMDirectConnectionStore
    let remote: MainExperienceStore
    let back: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var camera = AIMPairingCameraState()
    @State private var pairingSheet = false
    @State private var manual = false
    @State private var pasted = ""
    @State private var invitation: DirectRemoteInvite?
    @State private var invalidCode = false
    @State private var cameraFailed = false
    @State private var lastScannedValue: String?

    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: copy("Computer connection", "Connexion au Mac"), back: back)
            AIMSettingsForm {
                if direct.records.isEmpty && dynamicTypeSize.isAccessibilitySize { addMacSection }
                if direct.records.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(copy("Your Mac, on your iPhone", "Votre Mac, sur votre iPhone"))
                                .font(.title3.weight(.semibold))
                            Text(copy("Connect to AIM on your Mac to find your conversations and continue your work.",
                                      "Connectez-vous à AIM sur votre Mac pour retrouver vos conversations et poursuivre votre travail."))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
                }
                ForEach(orderedRecords, id: \.pair.id) { record in
                    Section {
                        Button {
                            guard !isSelected(record) || (!isConnected && !isConnecting) else { return }
                            Task { await direct.connect(record.pair.id); await updateRemote() }
                        } label: { computer(record).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .disabled(record.pair.revoked || direct.busy || (isSelected(record) && isConnecting))
                        .accessibilityHint(Text(copy("Connect to this Mac", "Connecter ce Mac")))
                        .accessibilityIdentifier("direct-computer-\(record.pair.id)")
                        if !record.pair.revoked {
                            if isSelected(record), isConnected {
                                Button(copy("Disconnect", "Déconnecter")) {
                                    Task { await direct.disconnect(); remote.invalidateRemoteSecurityContext() }
                                }
                                .disabled(direct.busy)
                                .accessibilityIdentifier("direct-disconnect-\(record.pair.id)")
                            } else if isSelected(record), isConnecting {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text(connectionStatus).foregroundStyle(.secondary)
                                }
                            } else {
                                Button(copy("Connect", "Connecter")) {
                                    Task { await direct.connect(record.pair.id); await updateRemote() }
                                }
                                .disabled(direct.busy)
                                .accessibilityIdentifier("direct-connect-\(record.pair.id)")
                            }
                        }
                        DisclosureGroup(copy("Security details", "Détails de sécurité")) {
                            fingerprint(record.pair.host.fingerprint)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(copy("Permissions granted by this Mac", "Autorisations accordées par ce Mac"))
                                    .font(.subheadline.weight(.medium))
                                Text(record.pair.permissions.sorted { $0.rawValue < $1.rawValue }.map(permissionName).joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.font(.subheadline)
                    }
                }
                if !direct.records.isEmpty || !dynamicTypeSize.isAccessibilitySize { addMacSection }
                if direct.busy || direct.message != nil {
                    Section {
                        if direct.busy { ProgressView(copy("Waiting for the Mac…", "En attente du Mac…")) }
                        if let message = direct.message {
                            AIMSettingsMessage(text: localizedMessage(message))
                                .accessibilityIdentifier("direct-connection-message")
                        }
                    }
                }
            }
        }
        .font(.system(.body)).tint(.primary)
        .accessibilityIdentifier("direct-computer-connections")
        .sheet(isPresented: $pairingSheet, onDismiss: clearPairingDraft) {
            pairingPanel
        }
        .task { await direct.start() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2)); guard !Task.isCancelled else { return }
                await direct.refresh()
                if isConnected { await updateRemote() }
            }
        }
    }

    private var addMacSection: some View {
                Section {
                    AIMSettingsAction(title: copy(direct.records.isEmpty ? "Scan a Mac QR code" : "Add a Mac",
                                                   direct.records.isEmpty ? "Scanner le QR code du Mac" : "Ajouter un Mac"),
                                      icon: "qrcode.viewfinder") { openPairing() }
                        .disabled(direct.busy)
                        .accessibilityIdentifier("direct-add-mac")
                } footer: {
                    if direct.records.isEmpty {
                        Text(copy("On your Mac: AIM Settings → Remote → Add iPhone.",
                                  "Sur votre Mac : Réglages AIM → Remote → Ajouter un iPhone."))
                    }
                }
    }

    private var orderedRecords: [DirectRemoteSavedPair] {
        direct.records.sorted { lhs, rhs in
            let leftSelected = lhs.pair.id == direct.selectedPairID
            let rightSelected = rhs.pair.id == direct.selectedPairID
            if leftSelected != rightSelected { return leftSelected }
            return lhs.pair.host.name.localizedStandardCompare(rhs.pair.host.name) == .orderedAscending
        }
    }
    private var isConnected: Bool { if case .connected = direct.state { return true }; return false }
    private var isConnecting: Bool {
        switch direct.state {
        case .signalling, .gatheringICE, .checkingICE, .reconnecting: true
        default: false
        }
    }
    private func isSelected(_ record: DirectRemoteSavedPair) -> Bool { record.pair.id == direct.selectedPairID }
    private var connectionStatus: String {
        switch direct.state {
        case .connected(.lan): copy("Connected · local network", "Connecté · réseau local")
        case .connected(.peerToPeer): copy("Connected · direct", "Connecté · direct")
        case .connected(.turn): copy("Connected · encrypted relay", "Connecté · relais chiffré")
        case .disconnected: copy("Not connected", "Déconnecté")
        case .signalling: copy("Contacting Mac…", "Connexion au Mac…")
        case .gatheringICE, .checkingICE: copy("Connecting…", "Connexion en cours…")
        case .reconnecting: copy("Reconnecting…", "Reconnexion en cours…")
        case .revoked: copy("Access revoked on the Mac", "Accès révoqué sur le Mac")
        case .failed: copy("Mac unavailable", "Mac indisponible")
        }
    }
    private func computer(_ record: DirectRemoteSavedPair) -> some View {
        let connected = isSelected(record) && isConnected && !record.pair.revoked
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.secondary)
                .frame(width: 32).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.pair.host.name).font(.headline)
                Label(record.pair.revoked ? copy("Access revoked", "Accès révoqué") :
                        isSelected(record) ? connectionStatus : copy("Not connected", "Déconnecté"),
                      systemImage: connected ? "checkmark.circle.fill" : record.pair.revoked ? "lock.fill" : "circle")
                    .font(.subheadline).foregroundStyle(connected ? Color.green : Color.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }

    private var pairingPanel: some View {
        NavigationStack {
            AIMSettingsForm {
                if let invitation {
                    Section {
                        Label(invitation.host.name, systemImage: "desktopcomputer").font(.title3.weight(.semibold))
                            .padding(.vertical, 6)
                        Text(copy("Check the Mac’s name, then confirm the connection in AIM on your Mac.",
                                  "Vérifiez le nom du Mac, puis confirmez la connexion dans AIM sur votre Mac."))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(copy("Connect to this Mac", "Connecter ce Mac")) {
                            let chosen = invitation
                            pairingSheet = false
                            Task { await direct.pair(chosen); await updateRemote() }
                        }.fontWeight(.semibold).disabled(direct.busy)
                            .accessibilityIdentifier("direct-confirm-mac")
                    }
                    Section {
                        DisclosureGroup(copy("Security details", "Détails de sécurité")) {
                            fingerprint(invitation.host.fingerprint)
                            fingerprint(direct.controller.identity.publicIdentity.fingerprint,
                                        title: copy("This iPhone’s fingerprint", "Empreinte de cet iPhone"))
                            if let host = invitation.coordinatorURL?.host {
                                LabeledContent(copy("Connection service", "Service de connexion"), value: host)
                                    .font(.footnote)
                            }
                            Text(copy("This QR code expires after two minutes. The Mac confirms your iPhone and its permissions.",
                                      "Ce QR code expire après deux minutes. Le Mac confirme votre iPhone et ses autorisations."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button(copy("Scan another code", "Scanner un autre code")) {
                            clearPairingDraft()
                            Task { await camera.request() }
                        }
                    }
                } else if manual {
                    AIMDirectManualPairingSection(pasted: $pasted, busy: direct.busy,
                        fieldTitle: copy("AIM pairing link", "Lien d’association AIM"),
                        buttonTitle: copy("Verify this Mac", "Vérifier ce Mac"),
                        footer: copy("Paste the pairing link shown in AIM on your Mac.", "Collez le lien d’association affiché dans AIM sur votre Mac."),
                        verify: read)
                    if invalidCode { invalidCodeMessage }
                    Section {
                        Button(copy("Use the camera", "Utiliser la caméra"), systemImage: "qrcode.viewfinder") {
                            manual = false; invalidCode = false; cameraFailed = false; lastScannedValue = nil
                            Task { await camera.request() }
                        }
                    }
                } else {
                    Section {
                        cameraPanel
                            .listRowInsets(EdgeInsets())
                        Text(copy("Show the pairing QR code in AIM on your Mac, then place it in the frame.",
                                  "Affichez le QR code d’association dans AIM sur votre Mac, puis placez-le dans le cadre."))
                            .font(.subheadline).foregroundStyle(.secondary)
                    } footer: {
                        Text(copy("Mac: AIM Settings → Remote → Add iPhone.", "Mac : Réglages AIM → Remote → Ajouter un iPhone."))
                    }
                    if invalidCode { invalidCodeMessage }
                    Section {
                        Button(copy("Paste a pairing link instead", "Coller un lien d’association"), systemImage: "link") {
                            manual = true; invalidCode = false
                        }.accessibilityIdentifier("direct-manual-pairing")
                    }
                }
            }
            .accessibilityIdentifier("direct-pairing-form")
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(invitation != nil ? copy("Verify your Mac", "Vérifier votre Mac") :
                                manual ? copy("Pairing link", "Lien d’association") : copy("Scan the Mac QR code", "Scanner le QR code du Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copy("Close", "Fermer"), systemImage: "xmark") { pairingSheet = false }
                        .labelStyle(.iconOnly).accessibilityIdentifier("direct-close-pairing")
                }
            }
        }
        .tint(.primary).aimUniversalPanelSurface()
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, invitation == nil, !manual { Task { await camera.request() } }
        }
    }

    @ViewBuilder private var cameraPanel: some View {
        if camera.permission == .authorized && !cameraFailed {
            AIMPairingCameraPreview(active: scenePhase == .active && pairingSheet && invitation == nil && !manual && !direct.busy,
                detected: { value in
                    guard pairingSheet, !manual, !direct.busy, invitation == nil else { return }
                    guard let value else { lastScannedValue = nil; return }
                    guard value != lastScannedValue else { return }
                    lastScannedValue = value; read(value)
                }, failure: { _ in cameraFailed = true })
                .aspectRatio(1.15, contentMode: .fit).clipped()
                .accessibilityLabel(copy("Pairing QR code camera", "Caméra du QR code d’association"))
        } else if camera.permission == .checking && !cameraFailed {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "camera.fill").font(.largeTitle).accessibilityHidden(true)
                Text(copy("Camera unavailable. You can paste a pairing link.",
                          "Caméra indisponible. Vous pouvez coller un lien d’association."))
                    .font(.subheadline).multilineTextAlignment(.center)
                if camera.permission == .denied {
                    Button(copy("Open iPhone Settings", "Ouvrir les réglages iPhone")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.frame(minHeight: 44)
                }
            }.frame(maxWidth: .infinity).padding(24)
                .background(Color(uiColor: .tertiarySystemBackground))
        }
    }
    private var invalidCodeMessage: some View {
        Section {
            Label(copy("This code is invalid or expired. Show a new QR code on your Mac.",
                       "Ce code est invalide ou expiré. Affichez un nouveau QR code sur votre Mac."), systemImage: "exclamationmark.circle")
                .font(.footnote).foregroundStyle(.red).accessibilityIdentifier("direct-invalid-code")
        }
    }
    private func fingerprint(_ value: String, title: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title ?? copy("Mac fingerprint", "Empreinte du Mac")).font(.subheadline.weight(.medium))
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("direct-mac-fingerprint")
        }.padding(.vertical, 4)
    }
    private func openPairing() {
        clearPairingDraft(); pairingSheet = true
        Task { await camera.request() }
    }
    private func clearPairingDraft() {
        invitation = nil; pasted = ""; manual = false; invalidCode = false
        cameraFailed = false; lastScannedValue = nil
    }
    private func read(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let candidate = try? DirectRemoteInvite.decodeQR(url) else { invalidCode = true; return }
        invalidCode = false; invitation = candidate
    }
    private func permissionName(_ permission: DirectRemotePermission) -> String {
        switch permission {
        case .read: copy("Read", "Lecture")
        case .chat: "Chat"
        case .code: "Code"
        case .agent: "Agent"
        case .control: copy("Control", "Contrôle")
        case .approve: copy("Approvals", "Approbations")
        case .settings: copy("Settings", "Réglages")
        case .terminal: "Terminal"
        }
    }
    private func localizedMessage(_ message: String) -> String {
        switch message {
        case "Saved device permissions could not be opened. Existing pairings are preserved.":
            copy(message, "Impossible de lire les autorisations des appareils. Les associations existantes sont conservées.")
        case "Mac unavailable. Check that AIM is open, direct access is enabled, and both devices can reach each other.":
            copy(message, "Mac indisponible. Vérifiez qu’AIM est ouvert, que l’accès direct est activé et que les appareils peuvent se joindre.")
        case "Confirm this iPhone on the Mac.": copy(message, "Confirmez cet iPhone sur le Mac.")
        case "Paired. Connecting to the Mac…": copy(message, "Mac associé. Connexion en cours…")
        case "Pairing did not complete. Check the confirmation on the Mac or generate a new QR code.":
            copy(message, "L’association n’a pas abouti. Vérifiez la confirmation sur le Mac ou affichez un nouveau QR code.")
        default: message
        }
    }
    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
    private func updateRemote() async { await remote.loadRemoteSecurity(); await remote.load(); await remote.probeSelectedRemoteHealth() }
}

// Keep focus ownership inside the presented sheet rather than its presenting view.
private struct AIMDirectManualPairingSection: View {
    @Binding var pasted: String
    let busy: Bool
    let fieldTitle: String
    let buttonTitle: String
    let footer: String
    let verify: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Section {
            TextField(fieldTitle, text: $pasted, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                .focused($focused)
                .accessibilityIdentifier("direct-pairing-link")
            Button(buttonTitle) {
                focused = false
                verify(pasted)
            }
            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        } footer: { Text(footer) }
    }
}

/// Connection preference is separate from the device selected to execute Chat.
/// A missing preference may restore one unambiguous existing pair; a stale choice
/// never silently connects to a different Mac. No keys or invite tokens are stored.
struct AIMDirectReconnectPreference {
    private let defaults: UserDefaults
    private let key: String
    init(profileID: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "aim.direct-reconnect." + profileID.uuidString.lowercased()
    }
    func candidate(available: [UUID]) -> UUID? {
        guard let saved = defaults.string(forKey: key) else { return available.count == 1 ? available.first : nil }
        guard let id = UUID(uuidString: saved), available.contains(id) else { return nil }
        return id
    }
    func select(_ id: UUID) { defaults.set(id.uuidString.lowercased(), forKey: key) }
    func disable() { defaults.set("off", forKey: key) }
}
