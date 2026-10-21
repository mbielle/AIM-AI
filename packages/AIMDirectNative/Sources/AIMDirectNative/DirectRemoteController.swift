import AIMCore
import Foundation

public enum DirectRemoteRoutePreference: Sendable { case automatic, localNetworkOnly, coordinatorOnly }
public enum DirectRemoteControllerEvent: Sendable {
    case changed, claim(DirectRemotePublicIdentity), paired(DirectRemoteSavedPair), failed(String)
}
private struct DirectRemoteLinkContext {
    let link: any DirectRemoteControlLink
    let lan: Bool
    var room: UUID?
    var generation: UUID
    var remote: DirectRemotePublicIdentity?
    var nonce: String?
    var invitation: DirectRemoteInvite?
    var signal: DirectRemoteSignalLink?
    var session: DirectRemoteSession?
    var iceServers: [DirectRemoteICEServer] = []
    var peerReady = false
    var receivedICE = false
    var receivedGrant = false
    var pendingSignals: [Data] = []
}
/// One controller belongs to one persistent local profile. No cloud session or
/// account token is created by direct pairing, discovery, or reconnecting.
public actor DirectRemoteController {
    public nonisolated let events: AsyncStream<DirectRemoteControllerEvent>
    public nonisolated let identity: DirectRemoteIdentity
    private let continuation: AsyncStream<DirectRemoteControllerEvent>.Continuation
    private let routePreference: DirectRemoteRoutePreference
    private var privacyTask: Task<Void,Never>?
    private let relayOnly: Bool
    private let store: any SecureStoring
    private let pairs: DirectRemotePairStore
    private let host: DirectRemotePairingHost?
    private let endpoint: (any DirectRemoteRequestHandling)?
    private var listener: DirectRemoteLANListener?
    private var listenerTask: Task<Void,Never>?
    private var links: [UUID: DirectRemoteLinkContext] = [:]
    private var monitors: [UUID: Task<Void,Never>] = [:]
    private var readers: [UUID: Task<Void,Never>] = [:]
    private var proposals: [UUID: DirectRemotePublicIdentity] = [:]
    private var invite: DirectRemoteInvite?
    private var waiting: CheckedContinuation<DirectRemoteSavedPair, any Error>?
    private var foreground = true
    private var desiredPairID: UUID?
    private var updatingPairs = Set<UUID>()
    private var intentGeneration = UUID()
    private var deniedPairs = Set<UUID>()
    private var reconnectAttempts: [UUID:Int] = [:]
    private var connecting: [UUID:(generation: UUID, attempt: UUID)] = [:]
    private var terminalState: DirectRemoteConnectionState?
    private var selected: UUID?
    private var reconnectTasks: [UUID: Task<Void,Never>] = [:]
    private let sequence: DirectRemoteSequenceStore
    public init(identity: DirectRemoteIdentity, store: any SecureStoring, endpoint: (any DirectRemoteRequestHandling)? = nil, journalDirectory: URL? = nil, routePreference: DirectRemoteRoutePreference = .automatic, relayOnly: Bool = false) throws {
        self.identity = identity; self.store = store; self.routePreference = routePreference; self.relayOnly = relayOnly
        sequence = .init(profile: .init(id: identity.publicIdentity.localProfileID), deviceID: identity.publicIdentity.id, store: store)
        pairs = .init(profile: .init(id: identity.publicIdentity.localProfileID), store: store)
        host = identity.publicIdentity.role == .mac ? try DirectRemotePairingHost(identity: identity, store: store) : nil
        if let endpoint {
            guard let host, let journalDirectory else { throw DirectRemoteError.invalidConfiguration }
            self.endpoint = try DirectRemoteHostDispatcher(identity: identity, pairingHost: host, endpoint: endpoint, journalDirectory: journalDirectory)
        } else { self.endpoint = nil }
        let stream = AsyncStream<DirectRemoteControllerEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        events = stream.stream; continuation = stream.continuation
    }
    deinit {
        privacyTask?.cancel(); listenerTask?.cancel(); listener?.close()
        readers.values.forEach { $0.cancel() }; monitors.values.forEach { $0.cancel() }; reconnectTasks.values.forEach { $0.cancel() }
        for context in links.values { context.link.close(); if let session = context.session { Task { await session.close() } } }
        continuation.finish()
    }
    public func publishOverviewChanged() async {
        guard identity.publicIdentity.role == .mac, !AIMNetworkPrivacyPolicy.isEnabled else { return }
        for context in links.values { try? await context.session?.publishOverviewChanged() }
    }
    public func records() throws -> [DirectRemoteSavedPair] { try pairs.pairs() }
    public func pendingClaims() -> [DirectRemotePublicIdentity] { Array(proposals.values) }
    public func selectedPairID() -> UUID? { selected.flatMap { links[$0]?.room } ?? desiredPairID }
    public func selectedSession() throws -> any DirectRemoteRPCTransport {
        guard let selected, let session = links[selected]?.session else { throw DirectRemoteError.unavailable("direct_session_unavailable") }; return session
    }
    public func connectionState() async -> DirectRemoteConnectionState {
        guard let selected, let context = links[selected] else {
            if let terminalState { return terminalState }
            if let desiredPairID, reconnectTasks[desiredPairID] != nil { return .reconnecting }
            return .disconnected
        }
        guard let session = context.session else { return .signalling }; return await session.connectionState()
    }
    public func startHost() throws {
        try AIMNetworkPrivacyPolicy.requireNetwork(); observePrivacy()
        guard host != nil, listener == nil else { return }
        let listener = try DirectRemoteLANListener(serviceName: "AIM-" + identity.publicIdentity.id.uuidString.lowercased())
        self.listener = listener; intentGeneration = UUID()
        Task { [weak self] in await self?.resumeCoordinatorConnections() }
        listenerTask = Task { [weak self] in for await link in listener.connections { await self?.add(link, lan: true) } }
    }
    private func resumeCoordinatorConnections() async {
        guard let records = try? records() else { return }
        for record in records where !record.pair.revoked && record.location.coordinatorURL != nil {
            guard !links.values.contains(where: { $0.room == record.pair.id && !$0.lan }) else { continue }
            do { try await connectPair(pairID: record.pair.id, generation: intentGeneration) } catch { continuation.yield(.failed("coordinator_unreachable")) }
        }
    }
    public func cancelInvitation() async throws {
        var failure: (any Error)?
        do { try await host?.cancelInvitation() } catch { failure = error }
        invite = nil; proposals = [:]
        let pendingIDs = links.filter { $0.value.session == nil && $0.value.invitation != nil }.map(\.key)
        for id in pendingIDs { links[id]?.link.close(); links[id] = nil; readers.removeValue(forKey: id)?.cancel() }
        failPair("pairing_cancelled"); continuation.yield(.changed)
        if let failure { throw failure }
    }
    public func stopHost() async throws {
        var failure: (any Error)?
        do { try await cancelInvitation() } catch { failure = error }
        let oldListener = listener; oldListener?.close(); listener = nil; listenerTask?.cancel(); listenerTask = nil
        await disconnect()
        do { try await oldListener?.waitUntilClosed() } catch { failure = failure ?? error }
        if let cleanup = endpoint as? any DirectRemoteRevocationHandling, let values = try? records() {
            for record in values { await cleanup.suspendAccess(pairID: record.pair.id) }
        }
        if let failure { throw failure }
    }
    public func createInvite(coordinatorURL: URL? = nil) async throws -> DirectRemoteInvite {
        guard let host else { throw DirectRemoteError.unauthorized }; try startHost()
        try await cancelInvitation()
        let invitation = try await host.createInvite(coordinatorURL: coordinatorURL)
        invite = invitation; proposals = [:]
        if let url = coordinatorURL {
            let link = try DirectRemoteWebSocketLink(url: url)
            let key = add(link, lan: false, room: invitation.id)
            links[key]?.invitation = invitation
            try await link.send(.init(type: "host", room: invitation.id, identity: identity.publicIdentity))
        }
        return invitation
    }
    public func pair(inviteURL: URL) async throws -> DirectRemoteSavedPair {
        try AIMNetworkPrivacyPolicy.requireNetwork(); observePrivacy()
        guard identity.publicIdentity.role == .phone, foreground, waiting == nil else { throw DirectRemoteError.unauthorized }
        let invitation = try DirectRemoteInvite.decodeQR(inviteURL)
        desiredPairID = nil; terminalState = nil; intentGeneration = UUID()
        let generation = intentGeneration
        await closeTransports()
        guard generation == intentGeneration else { throw DirectRemoteError.unavailable("connection_cancelled") }
        guard foreground else { throw DirectRemoteError.unavailable("foreground_required") }
        let claim = try DirectRemoteClaim(invite: invitation, client: identity.publicIdentity)
        let (link, lan) = try await connectLink(location: .init(invite: invitation))
        guard generation == intentGeneration, foreground else { link.close(); throw DirectRemoteError.unavailable("connection_cancelled") }
        let key = add(link, lan: lan, room: invitation.id); links[key]?.invitation = invitation; selected = key
        return try await withCheckedThrowingContinuation { c in
            waiting = c
            Task { [weak self] in
                do { try await link.send(.init(type: "claim", room: invitation.id, claim: DirectRemoteCoding.encode(claim))) }
                catch { await self?.failPair("pairing_send_failed", generation: generation) }
                try? await Task.sleep(for: .seconds(120)); await self?.failPair("pairing_expired", generation: generation)
            }
        }
    }
    public func confirm(deviceID: UUID, permissions: Set<DirectRemotePermission>) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard let host, let invitation = invite, proposals[deviceID] != nil else { throw DirectRemoteError.unauthorized }
        let confirmation = try await host.confirmDevice(deviceID, permissions: permissions)
        let pair = try DirectRemoteCoding.decode(DirectRemotePair.self, confirmation.pairBytes)
        let record = DirectRemoteSavedPair(pair: pair, location: .init(invite: invitation))
        try pairs.save(record); proposals = [:]; invite = nil
        let matching = links.filter { $0.value.room == pair.id && ($0.value.remote?.id == deviceID || !$0.value.lan) }
        for (id, context) in matching {
            try await context.link.send(.init(type: "confirm", room: pair.id, confirmation: DirectRemoteCoding.encode(confirmation)))
            links[id]?.invitation = nil
            if context.lan { try await activate(id: id, pair: pair) }
        }
        continuation.yield(.paired(record))
    }
    public func setForeground(_ active: Bool) async {
        guard identity.publicIdentity.role == .phone else { return }
        foreground = active
        if !active {
            failPair("pairing_suspended"); intentGeneration = UUID()
            await closeTransports()
        }
        else if let desiredPairID, !AIMNetworkPrivacyPolicy.isEnabled {
            do { try await connectPair(pairID: desiredPairID, generation: intentGeneration) }
            catch { scheduleReconnect(room: desiredPairID, generation: intentGeneration) }
        }
    }
    public func connect(pairID: UUID) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork(); observePrivacy()
        guard foreground || identity.publicIdentity.role == .mac else { throw DirectRemoteError.unavailable("foreground_required") }
        if identity.publicIdentity.role == .mac { try startHost() }
        if desiredPairID != pairID || deniedPairs.contains(pairID) {
            desiredPairID = pairID; intentGeneration = UUID(); terminalState = nil
            deniedPairs.remove(pairID); reconnectAttempts[pairID] = 0
            if identity.publicIdentity.role == .phone { await closeTransports() }
        }
        reconnectAttempts[pairID] = 0
        let generation = intentGeneration
        do { try await connectPair(pairID: pairID, generation: generation) }
        catch {
            // Initial discovery can fail while the Mac starts or Wi-Fi returns.
            // Use the existing bounded retry policy and preserve explicit stop.
            scheduleReconnect(room: pairID, generation: generation)
            throw error
        }
    }
    private func connectPair(pairID: UUID, generation: UUID) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard generation == intentGeneration, !deniedPairs.contains(pairID), !updatingPairs.contains(pairID),
              identity.publicIdentity.role == .mac ? listener != nil : (foreground && desiredPairID == pairID) else { throw DirectRemoteError.unavailable("connection_cancelled") }
        guard let record = try records().first(where: { $0.pair.id == pairID }), !record.pair.revoked else { throw DirectRemoteError.revoked }
        if connecting[pairID]?.generation == generation { return }
        let attempt = UUID(); connecting[pairID] = (generation, attempt)
        defer { if connecting[pairID]?.attempt == attempt { connecting[pairID] = nil } }
        _ = try record.pair.other(than: identity.publicIdentity)
        for (id, context) in links where context.room == pairID {
            if let session = context.session {
                switch await session.connectionState() {
                case .failed, .disconnected, .revoked: links[id] = nil; context.link.close(); await session.close()
                default: selected = id; return
                }
            } else { selected = id; return }
        }
        if identity.publicIdentity.role == .mac { try startHost() }
        let (link, lan) = try await connectLink(location: record.location)
        guard generation == intentGeneration, !deniedPairs.contains(pairID), !updatingPairs.contains(pairID), identity.publicIdentity.role == .mac ? listener != nil : foreground else { link.close(); throw DirectRemoteError.unavailable("connection_cancelled") }
        let id = add(link, lan: lan, room: pairID); selected = id
        try await link.send(.init(type: identity.publicIdentity.role == .mac ? "host" : "join", room: pairID, identity: identity.publicIdentity))
    }
    public func disconnect() async {
        failPair("pairing_cancelled")
        desiredPairID = nil; intentGeneration = UUID(); terminalState = nil
        await closeTransports()
    }
    private func closeTransports() async {
        // Detach every old resource before the first suspension. A foreground
        // resume may create a new generation while native cancellation awaits.
        let oldLinks = Array(links.values), oldReaders = readers, oldMonitors = monitors, oldReconnect = reconnectTasks
        links = [:]; readers = [:]; monitors = [:]; reconnectTasks = [:]; selected = nil
        oldReconnect.values.forEach { $0.cancel() }; oldReaders.values.forEach { $0.cancel() }; oldMonitors.values.forEach { $0.cancel() }
        for context in oldLinks { if let session = context.session { await session.close() }; context.link.close() }
        for context in oldLinks { do { try await context.link.waitUntilClosed() } catch { continuation.yield(.failed("direct_transport_still_closing")) } }
        continuation.yield(.changed)
    }
    public func updatePermissions(pairID: UUID, permissions: Set<DirectRemotePermission>) async throws {
        guard let host, !updatingPairs.contains(pairID) else { throw DirectRemoteError.unauthorized }
        updatingPairs.insert(pairID)
        defer { updatingPairs.remove(pairID) }
        let previous = try await host.pair(pairID)
        let updated = try await host.updatePermissions(pairID, permissions: permissions)
        guard updated.pair != previous else { return }
        // Detach old links before any native/endpoint cleanup can suspend. A
        // late session callback must never reactivate the superseded revision.
        let affected = links.filter { $0.value.room == pairID }
        reconnectTasks.removeValue(forKey: pairID)?.cancel()
        connecting[pairID] = nil
        for id in affected.keys {
            links[id] = nil; readers.removeValue(forKey: id)?.cancel()
            monitors.removeValue(forKey: id)?.cancel()
            if selected == id { selected = nil }
        }
        await (endpoint as? any DirectRemoteRevocationHandling)?.updatePermissions(pair: updated.pair)
        for context in affected.values {
            if let session = context.session { await session.close() }
            context.link.close()
        }
        continuation.yield(.changed)
        // The phone reconnects with the existing pinned keys. Internet hosts
        // re-register the room, then send the latest signed grant before SDP.
        if updated.location.coordinatorURL != nil { scheduleReconnect(room: pairID, generation: intentGeneration) }
    }
    public func revoke(pairID: UUID) async throws {
        guard let host, var record = try records().first(where: { $0.pair.id == pairID }) else { throw DirectRemoteError.unauthorized }
        try await host.revoke(pairID)
        deniedPairs.insert(pairID); reconnectTasks.removeValue(forKey: pairID)?.cancel()
        if desiredPairID == pairID { desiredPairID = nil; terminalState = .revoked }
        var pair = record.pair; pair.revoked = true; pair.revision += 1
        record = .init(pair: pair, location: record.location)
        var failure: (any Error)?
        do { try pairs.save(record) } catch { failure = error }
        await (endpoint as? any DirectRemoteRevocationHandling)?.revokeAccess(pairID: pairID)
        for (id, context) in links where context.room == pairID {
            if !context.lan { try? await context.link.send(.init(type: "revoke", room: pairID)) }
            if let session = context.session { await session.revoke() }; context.link.close(); links[id] = nil; readers.removeValue(forKey: id)?.cancel()
        }
        continuation.yield(.changed)
        if let failure { throw failure }
    }
    private func connectLink(location: DirectRemoteLocation) async throws -> (any DirectRemoteControlLink, Bool) {
        var lanFailure: (any Error)?
        if identity.publicIdentity.role == .phone && routePreference != .coordinatorOnly {
            do { return (try await DirectRemoteLANDiscovery.connect(serviceName: location.lanService), true) }
            catch { lanFailure = error }
        }
        guard routePreference != .localNetworkOnly, let url = location.coordinatorURL else {
            // Preserve the typed LAN failure for diagnostics instead of erasing
            // it behind a generic reachability string. UI still uses its normal error mapping.
            if let lanFailure { throw lanFailure }
            throw DirectRemoteError.unavailable("mac_unreachable_on_local_network")
        }
        return (try DirectRemoteWebSocketLink(url: url), false)
    }
    @discardableResult private func add(_ link: any DirectRemoteControlLink, lan: Bool, room: UUID? = nil) -> UUID {
        let id = UUID(); guard links.count < 64 else { link.close(); return id }
        links[id] = .init(link: link, lan: lan, room: room, generation: intentGeneration)
        if lan { Task { [weak self] in
            try? await Task.sleep(for: .seconds(15)); await self?.closeUnclaimed(id)
        } }
        readers[id] = Task { [weak self] in
            for await message in link.messages { await self?.receive(message, id: id) }
            await self?.linkEnded(id)
        }
        return id
    }
    private func closeUnclaimed(_ id: UUID) {
        guard let context = links[id], context.room == nil else { return }; context.link.close()
    }
    private func linkEnded(_ id: UUID) async {
        guard let context = links.removeValue(forKey: id) else { return }
        if let session = context.session { await session.close() }
        monitors.removeValue(forKey: id)?.cancel(); readers[id] = nil
        if selected == id { selected = nil }; continuation.yield(.changed)
        if let room = context.room { scheduleReconnect(room: room, generation: context.generation) }
    }
    private func mayReconnect(_ room: UUID, generation: UUID) -> Bool {
        guard generation == intentGeneration, !AIMNetworkPrivacyPolicy.isEnabled, !deniedPairs.contains(room),
              (try? records().contains(where: { $0.pair.id == room && !$0.pair.revoked })) == true else { return false }
        return identity.publicIdentity.role == .mac ? listener != nil : (foreground && desiredPairID == room)
    }
    private func scheduleReconnect(room: UUID, generation: UUID) {
        guard mayReconnect(room, generation: generation) else { return }
        let attempt = reconnectAttempts[room] ?? 0
        guard attempt < 8 else { terminalState = .failed("reconnect_exhausted"); continuation.yield(.changed); return }
        reconnectAttempts[room] = attempt + 1
        reconnectTasks[room]?.cancel()
        reconnectTasks[room] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(30, 2 << min(attempt, 4))))
            guard !Task.isCancelled else { return }; await self?.reconnect(room: room, generation: generation)
        }
        continuation.yield(.changed)
    }
    private func reconnect(room: UUID, generation: UUID) async {
        guard mayReconnect(room, generation: generation) else { return }
        reconnectTasks[room] = nil
        do { try await connectPair(pairID: room, generation: generation) }
        catch { scheduleReconnect(room: room, generation: generation) }
    }
    private func failPair(_ code: String, generation: UUID? = nil) {
        if let generation, generation != intentGeneration { return }
        let old = waiting; waiting = nil; old?.resume(throwing: DirectRemoteError.unavailable(code)); if old != nil { continuation.yield(.failed(code)) }
    }
    private func receive(_ message: DirectRemoteControlMessage, id: UUID) async {
        do {
            guard var context = links[id], let room = message.room.flatMap(UUID.init(uuidString:)) ?? context.room,
                  context.room == nil || context.room == room else { throw DirectRemoteError.invalidPacket }
            guard !updatingPairs.contains(room) else { throw DirectRemoteError.unavailable("permissions_updating") }
            context.room = room; links[id] = context
            switch message.type {
            case "claim":
                guard let host, let bytes = message.claim else { throw DirectRemoteError.unauthorized }
                let claim = try DirectRemoteCoding.decode(DirectRemoteClaim.self, bytes)
                guard room == claim.inviteID else { throw DirectRemoteError.unauthorized }
                let client = try await host.propose(claim); links[id]?.invitation = invite; links[id]?.remote = client; proposals[client.id] = client
                continuation.yield(.claim(client))
            case "confirm":
                guard let invitation = context.invitation, let bytes = message.confirmation else { throw DirectRemoteError.unauthorized }
                let confirmation = try DirectRemoteCoding.decode(DirectRemotePairConfirmation.self, bytes)
                let pair = try confirmation.accept(invite: invitation, client: identity)
                let record = DirectRemoteSavedPair(pair: pair, location: .init(invite: invitation)); try pairs.save(record)
                links[id]?.invitation = nil; desiredPairID = pair.id; terminalState = nil
                if context.lan { try await activate(id: id, pair: pair) }
                else { try await context.link.send(.init(type: "join", room: pair.id, identity: identity.publicIdentity)) }
                let old = waiting; waiting = nil; old?.resume(returning: record); continuation.yield(.paired(record))
            case "join" where context.lan:
                guard let host, let other = message.identity else { throw DirectRemoteError.unauthorized }
                let pair = try await host.pair(room); guard other == pair.client else { throw DirectRemoteError.unauthorized }
                let nonce = UUID().uuidString + UUID().uuidString
                links[id]?.nonce = nonce; links[id]?.remote = other
                try await context.link.send(.init(type: "challenge", room: room, nonce: nonce))
            case "challenge":
                guard let nonce = message.nonce, nonce.utf8.count <= 256 else { throw DirectRemoteError.invalidPacket }
                let bytes = Data(("aim-direct-auth/v1/" + room.uuidString + "/" + nonce).utf8)
                try await context.link.send(.init(type: "auth", room: room, signature: identity.sign(bytes)))
            case "auth" where context.lan:
                guard let host, let nonce = context.nonce, let other = context.remote, let signature = message.signature else { throw DirectRemoteError.unauthorized }
                links[id]?.nonce = nil
                let pair = try await host.pair(room)
                try DirectRemoteIdentity.verify(signature, bytes: Data(("aim-direct-auth/v1/" + room.uuidString + "/" + nonce).utf8), signer: other)
                try await context.link.send(.init(type: "grant", room: room, confirmation: DirectRemoteCoding.encode(try await host.signedGrant(room))))
                try await context.link.send(.init(type: "peerReady", room: room)); try await activate(id: id, pair: pair)
            case "peerReady":
                guard let record = try records().first(where: { $0.pair.id == room }), !record.pair.revoked else { throw DirectRemoteError.unauthorized }
                links[id]?.peerReady = true
                if let host, !context.lan {
                    try await context.link.send(.init(type: "grant", room: room, confirmation: DirectRemoteCoding.encode(try await host.signedGrant(room))))
                }
                if context.lan || (context.receivedICE && (identity.publicIdentity.role == .mac || context.receivedGrant)) {
                    try await activate(id: id, pair: record.pair)
                } else if !context.lan { try await context.link.send(.init(type: "turn", room: room)) }
            case "grant":
                guard identity.publicIdentity.role == .phone, let bytes = message.confirmation,
                      let prior = try records().first(where: { $0.pair.id == room }) else { throw DirectRemoteError.unauthorized }
                let confirmation = try DirectRemoteCoding.decode(DirectRemotePairConfirmation.self, bytes)
                let pair = try confirmation.acceptUpdate(current: prior.pair, client: identity)
                try pairs.save(.init(pair: pair, location: prior.location))
                links[id]?.receivedGrant = true
                if context.peerReady && (context.lan || context.receivedICE) { try await activate(id: id, pair: pair) }
                continuation.yield(.changed)
            case "authenticated":
                if try records().contains(where: { $0.pair.id == room }) { try await context.link.send(.init(type: "turn", room: room)) }
            case "ice":
                links[id]?.iceServers = message.servers ?? []; links[id]?.receivedICE = true
                if context.peerReady, (identity.publicIdentity.role == .mac || context.receivedGrant),
                   let record = try records().first(where: { $0.pair.id == room }) { try await activate(id: id, pair: record.pair) }
            case "peerOffline":
                links[id]?.session = nil; links[id]?.signal = nil; links[id]?.peerReady = false
                links[id]?.receivedICE = false; links[id]?.receivedGrant = false; links[id]?.iceServers = []; links[id]?.pendingSignals = []
                monitors.removeValue(forKey: id)?.cancel()
                if let session = context.session { await session.close() }; continuation.yield(.changed)
            case "revoked":
                deniedPairs.insert(room); reconnectTasks.removeValue(forKey: room)?.cancel()
                if desiredPairID == room { desiredPairID = nil }; terminalState = .revoked; context.link.close()
            case "signal":
                guard let bytes = message.payload, bytes.count <= 196608 else { throw DirectRemoteError.invalidPacket }
                if let signal = links[id]?.signal { signal.receive(bytes) }
                else {
                    // A coordinator may deliver SDP before this endpoint's ICE
                    // response. Keep bounded encrypted bytes; decrypt only once
                    // the authenticated signed grant and transport are ready.
                    guard context.peerReady, context.pendingSignals.count < 64,
                          context.pendingSignals.reduce(0, { $0 + $1.count }) + bytes.count <= 1048576 else { throw DirectRemoteError.invalidPacket }
                    links[id]?.pendingSignals.append(bytes)
                }
            case "ready", "hostReady": break
            case "error":
                if ["relay_unavailable", "relay_quota"].contains(message.code ?? "") {
                    links[id]?.receivedICE = true
                    if context.peerReady, (identity.publicIdentity.role == .mac || context.receivedGrant),
                   let record = try records().first(where: { $0.pair.id == room }) { try await activate(id: id, pair: record.pair) }
                } else {
                    if ["unauthorized", "revoked"].contains(message.code ?? "") {
                        deniedPairs.insert(room); reconnectTasks.removeValue(forKey: room)?.cancel()
                        if desiredPairID == room { desiredPairID = nil }; terminalState = message.code == "revoked" ? .revoked : .failed("unauthorized")
                    }
                    throw DirectRemoteError.unavailable("coordinator_refused")
                }
            default: throw DirectRemoteError.invalidPacket
            }
        } catch {
            continuation.yield(.failed("direct_handshake_refused")); links[id]?.link.close()
            if waiting != nil { failPair("direct_handshake_refused") }
        }
    }
    private func observePrivacy() {
        guard privacyTask == nil else { return }
        let privacyChanges = AIMNetworkPrivacyPolicy.changes()
        privacyTask = Task { [weak self] in
            for await enabled in privacyChanges { if enabled { try? await self?.stopHost() } }
        }
    }
    private func nativeState(_ state: DirectRemoteConnectionState, id: UUID, session: DirectRemoteSession) async {
        continuation.yield(.changed)
        guard let context = links[id], context.session === session else { return }
        switch state {
        case .connected: if let room = context.room { reconnectAttempts[room] = 0 }; terminalState = nil
        case .failed, .disconnected, .reconnecting:
            guard let room = context.room, mayReconnect(room, generation: context.generation) else { return }
            context.link.close(); await linkEnded(id)
        case .revoked:
            if let room = context.room { deniedPairs.insert(room); if desiredPairID == room { desiredPairID = nil } }
            terminalState = .revoked; context.link.close(); await linkEnded(id)
        default: break
        }
    }
    private func activate(id: UUID, pair: DirectRemotePair) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard let context = links[id], context.session == nil, !updatingPairs.contains(pair.id) else { return }
        let signal = DirectRemoteSignalLink(link: context.link, room: pair.id)
        let channel = try LibDataChannel(iceServers: context.iceServers, relayOnly: relayOnly)
        let session = try DirectRemoteSession(identity: identity, pair: pair, channel: channel, signalling: signal, store: store, endpoint: endpoint, sequenceStore: sequence)
        links[id]?.signal = signal; links[id]?.session = session; selected = id
        monitors[id] = Task { [weak self] in for await state in session.stateEvents { await self?.nativeState(state, id: id, session: session) } }
        try await session.start(offerer: identity.publicIdentity.role == .mac)
        let buffered = links[id]?.pendingSignals ?? []; links[id]?.pendingSignals = []
        for bytes in buffered { signal.receive(bytes) }
        continuation.yield(.changed)
    }
}
