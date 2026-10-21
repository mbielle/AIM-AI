import AIMCore
import AIMApplication
import AIMDirectNative
import Foundation
import Observation

@MainActor @Observable final class MacDirectRemoteCoordinator {
    let controller: DirectRemoteController
    let profileID: UUID
    private(set) var enabled = false
    private(set) var records: [DirectRemoteSavedPair] = []
    private(set) var pending: [DirectRemotePublicIdentity] = []
    private(set) var state = DirectRemoteConnectionState.disconnected
    private(set) var coordinatorURL = ""
    var invitation: DirectRemoteInvite?
    var message: String?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private weak var model: AppModel?
    private let preference: String
    init(model: AppModel, profile: LocalProfile, secureStore: (any SecureStoring)? = nil) throws {
        profileID = profile.id
        self.model = model
        let service = (Bundle.main.bundleIdentifier ?? "com.aimai.macos") + ".direct-remote"
        let secrets: any SecureStoring = secureStore ?? KeychainSecureStore(service: service)
        let identity = try DirectRemoteIdentity.loadOrCreate(profile: profile, role: .mac, name: Host.current().localizedName ?? "Mac", store: secrets)
        let journal = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(service, isDirectory: true).appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("remote-direct/jobs", isDirectory: true)
        controller = try DirectRemoteController(identity: identity, store: secrets,
            endpoint: try MacDirectRemoteHostBridge(model: model, profileID: profile.id, transferDirectory: journal.deletingLastPathComponent().appendingPathComponent("transfers", isDirectory: true)), journalDirectory: journal)
        preference = "aim.direct-remote.enabled." + profile.id.uuidString.lowercased()
        enabled = UserDefaults.standard.bool(forKey: preference)
        coordinatorURL = UserDefaults.standard.string(forKey: preference + ".coordinator") ?? ""
    }
    func start() async {
        if observer == nil {
            observer = Task { [weak self, controller] in
                for await event in controller.events {
                    guard !Task.isCancelled else { return }
                    if case .failed = event { self?.message = "Direct connection unavailable. Check the network and signalling configuration." }
                    await self?.refresh()
                }
            }
        }
        if enabled {
            do {
                try await controller.startHost()
                if mirrorTask == nil {
                    mirrorTask = Task { [weak self] in
                        var last: Int?
                        var lastCatalogRevision: UInt64?
                        while !Task.isCancelled {
                            guard let self, self.enabled, let model = self.model,
                                  model.account.identity?.isLocal == true, model.account.identity?.storageID == self.profileID else { return }
                            let fingerprint = model.directRemoteFingerprint
                            // An invalidation only asks the phone to reload native
                            // state. It never invents tool visits or text chunks.
                            let catalogRevision = await ModelCatalogCache.shared.revision
                            if last != fingerprint || lastCatalogRevision != catalogRevision || model.isSending {
                                last = fingerprint; lastCatalogRevision = catalogRevision
                                await self.controller.publishOverviewChanged()
                            }
                            try? await Task.sleep(for: .milliseconds(model.isSending ? 400 : 1000))
                        }
                    }
                }
            }
            catch { message = "Local network listener could not start. Check network permissions." }
        }
        await refresh()
    }
    func refresh() async {
        do { records = try await controller.records(); pending = await controller.pendingClaims(); state = await controller.connectionState() }
        catch { message = "Saved pairings could not be opened. Existing data is preserved." }
    }
    func setEnabled(_ value: Bool) async {
        enabled = value; UserDefaults.standard.set(value, forKey: preference)
        if value { await start() } else { await stop() }
    }
    func stop() async {
        mirrorTask?.cancel(); mirrorTask = nil
        invitation = nil; pending = []
        do { try await controller.stopHost() } catch { message = "Direct access stopped; invitation revocation could not be saved. Keep this Mac offline until retried." }
        await controller.disconnect()
        state = .disconnected
    }
    func createInvite(coordinator: String) async {
        do {
            let trimmed = coordinator.trimmingCharacters(in: .whitespacesAndNewlines)
            let url: URL?
            if trimmed.isEmpty { url = nil }
            else { guard let candidate = URL(string: trimmed), candidate.scheme == "wss", candidate.user == nil, candidate.password == nil else { throw DirectRemoteError.invalidConfiguration }; url = candidate }
            invitation = try await controller.createInvite(coordinatorURL: url)
            coordinatorURL = trimmed; UserDefaults.standard.set(trimmed, forKey: preference + ".coordinator")
            message = nil
        } catch { message = "Could not create the invitation. Use a valid WSS signalling URL, or leave it empty for local network only." }
    }
    func confirm(_ id: UUID, permissions: Set<DirectRemotePermission>) async {
        do { try await controller.confirm(deviceID: id, permissions: permissions); invitation = nil; message = nil; await refresh() }
        catch { message = "Confirmation failed or invitation expired. Generate a new code." }
    }
    func cancelInvite() async {
        do { try await controller.cancelInvitation(); invitation = nil; await refresh() }
        catch { message = "The invitation could not be cancelled. Wait for it to expire before trying again." }
    }
    func updatePermissions(_ id: UUID, permissions: Set<DirectRemotePermission>) async {
        do { try await controller.updatePermissions(pairID: id, permissions: permissions); message = nil; await refresh() }
        catch { message = "Permissions could not be saved. Existing access is preserved; retry when the Mac keychain is available."; await refresh() }
    }
    func revoke(_ id: UUID) async {
        do { try await controller.revoke(pairID: id); await refresh() }
        catch { message = "Revocation could not be saved. Retry while the Mac keychain is available." }
    }
    var statusText: String {
        if !enabled { return "Off" }
        return switch state {
        case .connected(.lan): "Direct · local network"
        case .connected(.peerToPeer): "Direct · peer to peer"
        case .connected(.turn): "Relayed · encrypted TURN transport"
        case .disconnected: "Ready for a paired iPhone"
        case .signalling: "Contacting device"
        case .gatheringICE, .checkingICE: "Connecting"
        case .reconnecting: "Reconnecting"
        case .revoked: "Revoked"
        case .failed: "Device unavailable"
        }
    }
    isolated deinit { observer?.cancel(); mirrorTask?.cancel() }
}
