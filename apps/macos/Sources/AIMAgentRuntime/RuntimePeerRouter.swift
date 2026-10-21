import AIMCore
import AIMApplication
import AIMAgentKit
import AIMMacPlatform
import Foundation
import Darwin

package struct RuntimePeerPermission: Codable, Equatable, Sendable {
    package let pairID: UUID
    package let remoteIdentity: RemotePeerPublicIdentity
    package let parentExecutionIDs: Set<UUID>
    package let workspaces: [String: String]
    package let actions: Set<RemotePeerAction>
    package let allowedToolNames: Set<String>
    package let providerModels: [String: Set<String>]
    package let writer: Bool
    package let workspaceFiles: [String: [String]]?
    package let expiresAt: Date
}
package struct RuntimePeerConfiguration: Codable, Equatable, Sendable {
    package let version: Int
    package let enabled: Bool
    package let accountID: UUID
    package let machineID: UUID
    package let experimentalUnqualifiedRelayOptIn: Bool
    package let peers: [RuntimePeerPermission]
}
package struct RuntimePeerStatus: Codable, Sendable {
    package let enabled: Bool
    package let machineID: UUID
    package let identity: RemotePeerPublicIdentity
    package let fingerprint: String
    package let relayProtocolAvailable: Bool
    package let qualified: Bool
    package let diagnostic: String?
}

/// Runtime-owned paired transport. The handler is admitted only after immutable
/// encrypted input is persisted. Handler failures/crashes require reconciliation.
package actor RuntimePeerRouter: RemotePeerTransport {
    package typealias Authority = @Sendable (RemotePeerRequest, RemotePeerGrant) async -> Bool
    package typealias Handler = @Sendable (RemotePeerRequest, RemotePeerGrant, Bool) async throws -> Data
    private struct Receipt: Codable, Sendable {
        var request: RemotePeerRequest
        var packet: RemotePeerPacket
        var state: String
        var reply: RemotePeerReply?
        var replyPacket: RemotePeerPacket?
    }
    private let relay: any RemotePeerRelaying
    private let host: RemoteHostIdentity
    private let identity: RemotePeerPrivateIdentity
    private let directory: URL
    private let accountID: @Sendable () async -> UUID?
    private let authority: Authority
    private let handler: Handler
    private let revokeHandler: @Sendable (RemotePeerGrant) async -> Void
    private let qualification: @Sendable () async -> Bool
    private var configuration: RuntimePeerConfiguration?
    private var receipts: [String: Receipt] = [:]
    private var receiptLRU: [String] = []
    private var workerGrants: [UUID: RemotePeerGrant] = [:]
    private var pairs: [UUID: RemotePeerPair] = [:]
    private var running = false
    private var polling: Task<Void, Never>?
    private var controlDrain: Task<Void, Never>?
    private var controlCursor: String?
    private var inFlight: Set<UUID> = []
    private var relayAvailable = false
    private var diagnostic: String?

    package init(relay: any RemotePeerRelaying, hostIdentity: RemoteHostIdentity, secureStore: any SecureStoring,
        directory: URL, accountID: @escaping @Sendable () async -> UUID?, authority: @escaping Authority,
        handler: @escaping Handler, onRevocation: @escaping @Sendable (RemotePeerGrant) async -> Void,
        qualification: @escaping @Sendable () async -> Bool = { false }) throws {
        guard let machine = UUID(uuidString: hostIdentity.machineID) else { throw RemotePeerError.invalidConfiguration }
        self.relay = relay; self.host = hostIdentity; self.directory = directory; self.accountID = accountID
        self.authority = authority; self.handler = handler; revokeHandler = onRevocation; self.qualification = qualification
        identity = try RemotePeerPrivateIdentity.loadOrCreate(machineID: machine, store: secureStore)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw RemotePeerError.invalidConfiguration
        }
        let configFile = directory.appendingPathComponent("configuration-v1.json")
        if FileManager.default.fileExists(atPath: configFile.path) {
            configuration = try RemotePeerCoding.decode(RuntimePeerConfiguration.self, Data(contentsOf: configFile))
        }
        for name in ["Commands", "ActiveGrants", "ControlOutbox"] {
            _ = try RemotePeerPrivateDirectory.ensureChild(parent: directory, name: name)
        }
        let grantsDirectory = directory.appending(path: "ActiveGrants")
        for file in try FileManager.default.contentsOfDirectory(at: grantsDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) where file.pathExtension == "json" {
            let attrs = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 65536 else { throw RemotePeerError.invalidConfiguration }
            let grant = try RemotePeerCoding.decode(RemotePeerGrant.self, Data(contentsOf: file))
            guard grant.workerMachineID == identity.machineID else { throw RemotePeerError.invalidConfiguration }
            workerGrants[grant.id] = grant
        }
    }
    package func start() async { running = true; await tick() }
    package func stop() async {
        running = false; polling?.cancel(); controlDrain?.cancel(); await polling?.value; await controlDrain?.value; polling = nil; controlDrain = nil; relayAvailable = false; pairs = [:]
        for grant in activeWorkerGrants() { await revokeHandler(grant) }
    }
    package func tick() async {
        guard running, !RuntimePrivacyPolicy.isEnabled,
              let config = configuration, config.enabled, await accountID() == config.accountID else {
            polling?.cancel(); controlDrain?.cancel(); await polling?.value; await controlDrain?.value; polling = nil; controlDrain = nil; relayAvailable = false; pairs = [:]
            for grant in activeWorkerGrants() { await revokeHandler(grant) }; return
        }
        for grant in activeWorkerGrants() {
            // Live pairing/config/account and host authority are enough for an
            // index revocation check; signature was verified before persisting.
            let permitted = await indexedGrantAuthorized(grant)
            if !permitted { await revokeHandler(grant); try? removeWorkerGrant(grant.id) }
        }
        if polling == nil { polling = Task { [weak self] in await self?.pollLoop() } }
        if controlDrain == nil { controlDrain = Task { [weak self] in await self?.drainControlLoop() } }
    }
    package func status() async throws -> RuntimePeerStatus {
        let currentAccount = await accountID()
        let isQualified = await qualification()
        let enabled = configuration?.enabled == true && currentAccount == configuration?.accountID
        return try RuntimePeerStatus(enabled: enabled, machineID: identity.machineID, identity: identity.publicIdentity,
            fingerprint: RemotePeerPrivateIdentity.fingerprint(identity.publicIdentity), relayProtocolAvailable: relayAvailable,
            qualified: relayAvailable && isQualified, diagnostic: diagnostic)
    }
    package func previewConfiguration(_ data: Data) async throws -> RuntimePeerConfiguration {
        guard data.count <= 65536 else { throw RemotePeerError.invalidConfiguration }
        let config = try RemotePeerCoding.decode(RuntimePeerConfiguration.self, data)
        guard config.version == 1, config.machineID == identity.machineID, await accountID() == config.accountID,
              config.peers.count <= 32, Set(config.peers.map(\.pairID)).count == config.peers.count else {
            throw RemotePeerError.invalidConfiguration
        }
        for peer in config.peers {
            guard peer.remoteIdentity.version == 1, peer.remoteIdentity.machineID != identity.machineID,
                  !peer.parentExecutionIDs.isEmpty, peer.expiresAt > .now, !peer.actions.isEmpty,
                  peer.allowedToolNames.count <= 256, !peer.providerModels.isEmpty else { throw RemotePeerError.invalidConfiguration }
            _ = try RemotePeerPrivateIdentity.fingerprint(peer.remoteIdentity)
            for (workspaceID, paths) in peer.workspaceFiles ?? [:] {
                guard peer.workspaces[workspaceID] != nil, !paths.isEmpty, paths.count <= 2048, Set(paths).count == paths.count else { throw RemotePeerError.invalidConfiguration }
                for path in paths { try RemotePeerArtifactManifest.validatePath(path) }
            }
            for (key, path) in peer.workspaces {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard !key.isEmpty, key.utf8.count <= 128, path.hasPrefix("/"), url.path == path,
                      url.resolvingSymlinksInPath().path == path,
                      try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else {
                    throw RemotePeerError.invalidConfiguration
                }
            }
        }
        return config
    }
    package func importConfiguration(_ data: Data) async throws {
        let config = try await previewConfiguration(data)
        await stop(); try save(config, file: "configuration-v1.json"); configuration = config
        running = true; await tick()
    }
    package func registerIdentity() async throws {
        try await networkAuthorized()
        _ = try await call(.register, identity.publicIdentity)
    }
    package func identities() async throws -> [RemotePeerPublicIdentity] {
        try await networkAuthorized(); return try RemotePeerCoding.decode([RemotePeerPublicIdentity].self, await call(.identities, Empty()))
    }
    /// Both endpoints explicitly verify the supplied peer fingerprint before proposing/accepting.
    package func propose(pairID: UUID, peer: RemotePeerPublicIdentity, confirmedFingerprint: String, expiresAt: Date) async throws -> RemotePeerPair {
        try await networkAuthorized()
        guard confirmedFingerprint == (try RemotePeerPrivateIdentity.fingerprint(peer)), peer.machineID != identity.machineID,
              expiresAt > .now, expiresAt <= .distantFuture else { throw RemotePeerError.invalidConfiguration }
        struct Proposal: Encodable { let pairID: UUID; let peer: RemotePeerPublicIdentity; let expiresAt: Date }
        return try RemotePeerCoding.decode(RemotePeerPair.self, await call(.propose, Proposal(pairID: pairID, peer: peer, expiresAt: expiresAt)))
    }
    package func listedPairs() async throws -> [RemotePeerPair] {
        try await networkAuthorized(); return try RemotePeerCoding.decode([RemotePeerPair].self, await call(.pairs, Empty()))
    }
    package func accept(_ pair: RemotePeerPair, confirmedFingerprint: String) async throws {
        try await networkAuthorized()
        guard pair.worker.machineID == identity.machineID, pair.worker == (try identity.publicIdentity),
              pair.accountID == (await accountID()), confirmedFingerprint == (try RemotePeerPrivateIdentity.fingerprint(pair.origin)) else {
            throw RemotePeerError.unauthorized
        }
        _ = try await call(.accept, PairReference(pairID: pair.id))
    }
    package func revoke(pairID: UUID) async throws {
        try await networkAuthorized(); _ = try await call(.revoke, PairReference(pairID: pairID)); pairs[pairID] = nil
        for grant in activeWorkerGrants() where grant.pairID == pairID { await revokeHandler(grant) }
    }
    package func sign(_ grant: RemotePeerGrant) async throws -> RemotePeerSignedGrant {
        try grant.validate(); return try identity.sign(grant)
    }
    package func prepareGrant(parent: AgentExecution, childID: UUID, conversationID: UUID, machineID: UUID,
        workspace: String, provider: String, modelID: String, writer: Bool = false, budgetAuthorization: Data) async throws -> RemotePeerSignedGrant {
        try await refreshPairs()
        guard let config = configuration, parent.accountID == config.accountID,
              let permission = config.peers.first(where: { $0.remoteIdentity.machineID == machineID && $0.parentExecutionIDs.contains(parent.id) }),
              permission.expiresAt > .now, let pair = pairs[permission.pairID], pair.origin.machineID == identity.machineID,
              permission.providerModels[provider]?.contains(modelID) == true,
              let workspaceID = permission.workspaces.first(where: { $0.value == workspace })?.key else { throw RemotePeerError.unauthorized }
        guard !writer || permission.writer else { throw RemotePeerError.unauthorized }
        let permitted: Set<String> = writer ? ["read_file", "list_dir", "search_files", "find_files", "apply_edit", "create_directory", "move_path", "copy_path", "trash_path"] : ["read_file", "list_dir", "search_files", "find_files"]
        let parentRequest = try RemotePeerCoding.decode(AgentRequest.self, parent.request)
        guard !writer || parentRequest.workspaceEditsEnabled == true else { throw RemotePeerError.unauthorized }
        var tools = permission.allowedToolNames.intersection(permitted)
        if let inherited = parentRequest.allowedToolNames { tools.formIntersection(inherited) }
        let actions: Set<RemotePeerAction> = [.start, .snapshot, .events, .pause, .resume, .cancel, .correction, .approval, .budget, .interactions, .answer,
            .artifactManifest, .artifactChunk, .artifactCommit]
        guard !tools.isEmpty, actions.isSubset(of: permission.actions) else { throw RemotePeerError.unauthorized }
        let grant = RemotePeerGrant(id: UUID(), pairID: pair.id, accountID: config.accountID,
            originMachineID: identity.machineID, workerMachineID: machineID, parentExecutionID: parent.id,
            childExecutionID: childID, childConversationID: conversationID, workspaceID: workspaceID,
            actions: actions, allowedToolNames: tools, provider: provider, modelID: modelID,
            writer: writer, budgetAuthorization: budgetAuthorization, expiresAt: min(permission.expiresAt, pair.expiresAt))
        return try identity.sign(grant)
    }
    package func bindWorkspace(_ signed: RemotePeerSignedGrant, commit: RemotePeerArtifactCommit) throws -> RemotePeerSignedGrant {
        guard signed.grant.originMachineID == identity.machineID else { throw RemotePeerError.unauthorized }
        return try identity.sign(signed.grant.bindingWorkspace(commit))
    }
    package func transferPaths(for grant: RemotePeerGrant) -> [String]? {
        configuration?.peers.first(where: { $0.pairID == grant.pairID })?.workspaceFiles?[grant.workspaceID]
    }
    package func authorizeGrant(_ signed: RemotePeerSignedGrant) async -> Bool {
        let request = RemotePeerRequest(commandID: UUID(), action: .budget, grant: signed, payload: Data())
        return (try? await authorized(request, refresh: true)) != nil
    }
    package func workspace(for grant: RemotePeerGrant) async throws -> String {
        guard let permission = configuration?.peers.first(where: { $0.pairID == grant.pairID }),
              let path = permission.workspaces[grant.workspaceID] else { throw RemotePeerError.unauthorized }
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else { throw RemotePeerError.unauthorized }
        return path
    }
    package func request(_ request: RemotePeerRequest, timeout: TimeInterval = 30) async throws -> Data {
        let pair = try await authorized(request, refresh: true)
        let grant = request.grant.grant
        let destination = identity.machineID == grant.originMachineID ? grant.workerMachineID : grant.originMachineID
        try validateDirection(request, from: identity.machineID, to: destination)
        let key = receiptKey(commandID: request.commandID, outgoing: true)
        if let old = try self.receipt(key) {
            guard old.request == request, old.packet.to == destination else { throw RemotePeerError.conflictingCommand }
            if let result = old.reply { return try resultPayload(result) }
        } else {
            let packet = try identity.seal(request, pair: pair, to: destination, commandID: request.commandID, kind: .request)
            let receipt = Receipt(request: request, packet: packet, state: "persisted")
            try persist(receipt, key: key)
        }
        guard timeout > 0, timeout <= 120, var receipt = try self.receipt(key) else { throw RemotePeerError.invalidConfiguration }
        receipt.state = "sending"; try persist(receipt, key: key)
        do { _ = try await call(.submit, receipt.packet) }
        catch {
            receipt.state = "outcome_unknown"; try persist(receipt, key: key); throw error
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation(); _ = try await authorized(request, refresh: true)
            if let data = try await fetchReply(receipt.packet, pair: pair) {
                _ = try await authorized(request, refresh: false); return data
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        receipt = try self.receipt(key) ?? receipt; receipt.state = "outcome_unknown"; try persist(receipt, key: key)
        throw RemotePeerError.outcomeUnknown
    }
    /// Journal a reconstructed pause/cancel before the independent outbox sends
    /// it. Existing commands retain their exact ciphertext and immutable ID.
    package func enqueueControl(_ request: RemotePeerRequest) async throws {
        guard [.pause, .cancel].contains(request.action), request.payload.isEmpty else { throw RemotePeerError.invalidEnvelope }
        let key = receiptKey(commandID: request.commandID, outgoing: true)
        if let old = try receipt(key) {
            guard old.request == request else { throw RemotePeerError.conflictingCommand }
            if old.reply == nil { try persist(old, key: key) }
            return
        }
        let pair = try await authorized(request, refresh: false)
        let destination = request.grant.grant.workerMachineID
        try validateDirection(request, from: identity.machineID, to: destination)
        let packet = try identity.seal(request, pair: pair, to: destination, commandID: request.commandID, kind: .request)
        try persist(Receipt(request: request, packet: packet, state: "persisted"), key: key)
    }
    private func fetchReply(_ packet: RemotePeerPacket, pair: RemotePeerPair) async throws -> Data? {
        struct Reference: Encodable { let pairID: UUID; let commandID: UUID }
        let data = try await call(.receipt, Reference(pairID: packet.pairID, commandID: packet.commandID))
        guard let replyPacket = try RemotePeerCoding.decode(RemotePeerPacket?.self, data) else { return nil }
        guard replyPacket.kind == .reply, replyPacket.commandID == packet.commandID, replyPacket.from == packet.to else {
            throw RemotePeerError.invalidEnvelope
        }
        let reply = try identity.open(RemotePeerReply.self, packet: replyPacket, pair: pair)
        guard reply.commandID == packet.commandID else { throw RemotePeerError.invalidEnvelope }
        let key = receiptKey(commandID: packet.commandID, outgoing: true)
        guard var receipt = try self.receipt(key) else { throw RemotePeerError.conflictingCommand }
        receipt.reply = reply; receipt.replyPacket = replyPacket; receipt.state = reply.state.rawValue; try persist(receipt, key: key)
        if reply.state != .outcomeUnknown { try removeControlReference(key) }
        return try resultPayload(reply)
    }
    private func pollLoop() async {
        defer { polling = nil }
        while running && !Task.isCancelled {
            do {
                try await refreshPairs()
                let packets = try RemotePeerCoding.decode([RemotePeerPacket].self, await call(.pending, Empty()))
                guard packets.count <= 20 else { throw RemotePeerError.invalidEnvelope }
                for packet in packets { try Task.checkCancellation(); try await receive(packet) }
                diagnostic = nil
            } catch { diagnostic = String(describing: error); relayAvailable = false }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    private func receive(_ packet: RemotePeerPacket) async throws {
        guard packet.kind == .request, !inFlight.contains(packet.commandID), let pair = pairs[packet.pairID] else {
            throw RemotePeerError.unauthorized
        }
        inFlight.insert(packet.commandID); defer { inFlight.remove(packet.commandID) }
        let request = try identity.open(RemotePeerRequest.self, packet: packet, pair: pair)
        guard request.commandID == packet.commandID else { throw RemotePeerError.invalidEnvelope }
        try validateDirection(request, from: packet.from, to: packet.to)
        let key = receiptKey(commandID: request.commandID, outgoing: false)
        var receipt: Receipt
        if let old = try self.receipt(key) {
            guard old.packet == packet, old.request == request else { throw RemotePeerError.conflictingCommand }; receipt = old
        } else {
            receipt = Receipt(request: request, packet: packet, state: "received"); try persist(receipt, key: key)
        }
        if receipt.reply == nil {
            do {
                _ = try await authorized(request, refresh: false)
                if packet.to == identity.machineID, [.start, .resume, .correction, .approval, .answer, .artifactManifest].contains(request.action) {
                    try persistWorkerGrant(request.grant.grant)
                }
                let recovery = receipt.state == "executing"
                receipt.state = "executing"; try persist(receipt, key: key)
                let data = try await handler(request, request.grant.grant, recovery)
                guard data.count <= 240000 else { throw RemotePeerError.invalidEnvelope }
                receipt.reply = RemotePeerReply(commandID: request.commandID, state: .completed, payload: data)
            } catch {
                receipt.reply = RemotePeerReply(commandID: request.commandID,
                    state: receipt.state == "executing" ? .outcomeUnknown : .rejected,
                    diagnostic: String(describing: error))
            }
            receipt.state = receipt.reply!.state.rawValue
            receipt.replyPacket = try identity.seal(receipt.reply!, pair: pair, to: packet.from, commandID: packet.commandID, kind: .reply)
            try persist(receipt, key: key)
        }
        if let reply = receipt.reply, reply.state == .completed {
            if request.action == .snapshot,
               let value = try? RemotePeerCoding.decode(RuntimePeerExecutionSnapshot.self, reply.payload),
               value.execution.state.isTerminal || value.execution.state == .awaitingReview || value.execution.state == .paused {
                try removeWorkerGrant(request.grant.grant.id)
            } else if request.action == .pause || request.action == .cancel { try removeWorkerGrant(request.grant.grant.id) }
        }
        try await networkAuthorized()
        if receipt.reply?.state != .rejected { _ = try await authorized(request, refresh: false) }
        guard let reply = receipt.replyPacket else { throw RemotePeerError.invalidEnvelope }
        // ACK is the durable exact reply. A lost ACK retransmits these same bytes.
        _ = try await call(.reply, reply)
    }
    private func validateDirection(_ request: RemotePeerRequest, from: UUID, to: UUID) throws {
        let grant = request.grant.grant
        if request.action == .budget {
            guard from == grant.workerMachineID, to == grant.originMachineID else { throw RemotePeerError.unauthorized }
        } else if [.artifactManifest, .artifactChunk, .artifactCommit].contains(request.action) {
            guard Set([from, to]) == Set([grant.originMachineID, grant.workerMachineID]) else { throw RemotePeerError.unauthorized }
        } else {
            guard from == grant.originMachineID, to == grant.workerMachineID else { throw RemotePeerError.unauthorized }
        }
    }
    private func authorized(_ request: RemotePeerRequest, refresh: Bool) async throws -> RemotePeerPair {
        try await networkAuthorized(); if refresh { try await refreshPairs() }
        let grant = request.grant.grant; try grant.validate()
        guard request.version == 1, request.payload.count <= 196608, grant.accountID == (await accountID()),
              let config = configuration, let pair = pairs[grant.pairID], pair.accepted, !pair.revoked, pair.expiresAt > .now,
              pair.accountID == grant.accountID, pair.origin.machineID == grant.originMachineID, pair.worker.machineID == grant.workerMachineID,
              let permission = config.peers.first(where: { $0.pairID == pair.id }), permission.expiresAt > .now,
              permission.remoteIdentity == (try pair.identity(for: identity.machineID == pair.origin.machineID ? pair.worker.machineID : pair.origin.machineID)),
              permission.parentExecutionIDs.contains(grant.parentExecutionID), permission.workspaces[grant.workspaceID] != nil,
              grant.actions.contains(request.action), grant.actions.isSubset(of: permission.actions),
              grant.allowedToolNames.isSubset(of: permission.allowedToolNames), (!grant.writer || permission.writer),
              permission.providerModels[grant.provider]?.contains(grant.modelID) == true else { throw RemotePeerError.unauthorized }
        try RemotePeerPrivateIdentity.verify(request.grant, origin: pair.origin)
        guard await authority(request, grant), configuration == config, pairs[grant.pairID] == pair,
              running, !RuntimePrivacyPolicy.isEnabled else { throw RemotePeerError.unauthorized }
        return pair
    }
    private func refreshPairs() async throws {
        try await networkAuthorized()
        struct Contract: Decodable { let version: Int }
        guard try RemotePeerCoding.decode(Contract.self, await call(.status, Empty())).version == 1 else {
            throw RemotePeerError.protocolUnavailable
        }
        let isQualified = await qualification()
        guard configuration?.experimentalUnqualifiedRelayOptIn == true || isQualified else {
            throw RemotePeerError.protocolUnavailable
        }
        let result = try RemotePeerCoding.decode([RemotePeerPair].self, await call(.pairs, Empty()))
        pairs = Dictionary(uniqueKeysWithValues: result.filter { $0.accepted && !$0.revoked && $0.expiresAt > .now }.map { ($0.id, $0) })
        relayAvailable = true
    }
    private func networkAuthorized() async throws {
        try RuntimePrivacyPolicy.requireNetwork()
        guard running, let config = configuration, config.enabled, config.version == 1, config.machineID == identity.machineID,
              await accountID() == config.accountID, configuration == config, running else { throw RemotePeerError.unauthorized }
        try RuntimePrivacyPolicy.requireNetwork()
    }
    private struct Empty: Codable {}
    private struct PairReference: Codable { let pairID: UUID }
    private func call<T: Encodable>(_ operation: RemotePeerRelayOperation, _ payload: T) async throws -> Data {
        try await networkAuthorized()
        return try await relay.call(operation, machineID: identity.machineID, secret: host.secret, payload: RemotePeerCoding.encode(payload))
    }
    private func receiptKey(commandID: UUID, outgoing: Bool) -> String {
        "command-\(outgoing ? "out" : "in")-\(commandID.uuidString.lowercased())"
    }
    private func receipt(_ key: String) throws -> Receipt? {
        if let value = receipts[key] { cache(value, key: key); return value }
        let url = directory.appending(path: "Commands").appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 2 * 1024 * 1024 else { throw RemotePeerError.invalidConfiguration }
        let value = try RemotePeerCoding.decode(Receipt.self, Data(contentsOf: url)); cache(value, key: key); return value
    }
    private func cache(_ receipt: Receipt, key: String) {
        receiptLRU.removeAll { $0 == key }; receiptLRU.append(key); receipts[key] = receipt
        while receiptLRU.count > 32 { let oldest = receiptLRU.removeFirst(); receipts[oldest] = nil }
    }
    private func persist(_ receipt: Receipt, key: String) throws {
        try save(receipt, file: "Commands/" + key + ".json"); cache(receipt, key: key)
        if receipt.packet.kind == .request, receipt.packet.from == identity.machineID,
           [.pause, .cancel].contains(receipt.request.action), receipt.reply == nil {
            try save(ControlReference(key: key), file: "ControlOutbox/" + key + ".json")
        }
    }
    private struct ControlReference: Codable { let key: String }
    private func removeControlReference(_ key: String) throws {
        let file = directory.appending(path: "ControlOutbox").appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
            let fd = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw RemotePeerError.invalidConfiguration }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw RemotePeerError.invalidConfiguration }
        }
    }
    private func controlReferences() throws -> [String] {
        let folder = directory.appending(path: "ControlOutbox")
        let keys = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        guard !keys.isEmpty else { controlCursor = nil; return [] }
        let first = controlCursor.flatMap { cursor in keys.firstIndex(where: { $0 > cursor }) } ?? 0
        let count = min(20, keys.count)
        let selected = (0..<count).map { keys[(first + $0) % keys.count] }
        controlCursor = selected.last
        return selected
    }
    private func validateControlReference(_ key: String) throws {
        guard key.hasPrefix("command-out-"), UUID(uuidString: String(key.dropFirst(12))) != nil else { throw RemotePeerError.invalidConfiguration }
        let file = directory.appending(path: "ControlOutbox").appendingPathComponent(key + ".json")
        let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 256,
              try RemotePeerCoding.decode(ControlReference.self, Data(contentsOf: file)).key == key else { throw RemotePeerError.invalidConfiguration }
    }
    private func drainControlLoop() async {
        defer { controlDrain = nil }
        while running && !Task.isCancelled {
            if relayAvailable {
                do {
                    for key in try controlReferences() {
                        do {
                            try Task.checkCancellation(); try validateControlReference(key)
                            guard let receipt = try self.receipt(key), [.pause, .cancel].contains(receipt.request.action),
                                  receipt.packet.from == identity.machineID else { throw RemotePeerError.invalidConfiguration }
                            if receipt.reply != nil { try removeControlReference(key); continue }
                            let pair = try await authorized(receipt.request, refresh: false)
                            _ = try await call(.submit, receipt.packet) // Same ciphertext/ID only.
                            _ = try await fetchReply(receipt.packet, pair: pair)
                        } catch {
                            if Task.isCancelled { return }
                            diagnostic = "peer_control_recovery_pending"
                        }
                    }
                } catch { diagnostic = "peer_control_recovery_pending" }
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    private func persistWorkerGrant(_ grant: RemotePeerGrant) throws {
        if workerGrants[grant.id] == grant { return }
        if let old = workerGrants[grant.id], old != grant { throw RemotePeerError.conflictingCommand }
        try save(grant, file: "ActiveGrants/" + grant.id.uuidString.lowercased() + ".json"); workerGrants[grant.id] = grant
    }
    private func removeWorkerGrant(_ id: UUID) throws {
        let file = directory.appending(path: "ActiveGrants").appendingPathComponent(id.uuidString.lowercased() + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        workerGrants[id] = nil
    }
    private func indexedGrantAuthorized(_ grant: RemotePeerGrant) async -> Bool {
        guard running, !RuntimePrivacyPolicy.isEnabled, await accountID() == grant.accountID,
              let config = configuration, config.enabled, grant.expiresAt > .now,
              let permission = config.peers.first(where: { $0.pairID == grant.pairID }), permission.expiresAt > .now,
              permission.parentExecutionIDs.contains(grant.parentExecutionID),
              permission.workspaces[grant.workspaceID] != nil, grant.actions.isSubset(of: permission.actions),
              grant.allowedToolNames.isSubset(of: permission.allowedToolNames), (!grant.writer || permission.writer),
              permission.providerModels[grant.provider]?.contains(grant.modelID) == true else { return false }
        if relayAvailable {
            guard let pair = pairs[grant.pairID], pair.accepted, !pair.revoked, pair.expiresAt > .now,
                  permission.remoteIdentity == pair.origin else { return false }
        }
        return true
    }
    private func save<T: Encodable>(_ value: T, file: String) throws {
        let url = directory.appendingPathComponent(file)
        let parent = url.deletingLastPathComponent()
        guard parent.path == parent.resolvingSymlinksInPath().path else { throw RemotePeerError.invalidConfiguration }
        let dirFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else { throw RemotePeerError.invalidConfiguration }
        defer { close(dirFD) }
        let temporary = ".peer-" + UUID().uuidString.lowercased()
        let fd = openat(dirFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RemotePeerError.invalidConfiguration }
        defer { close(fd); unlinkat(dirFD, temporary, 0) }
        let data = try RemotePeerCoding.encode(value)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw RemotePeerError.invalidConfiguration }
                offset += written
            }
        }
        // Flush the complete private file before publication, then its directory.
        guard fsync(fd) == 0 else { throw RemotePeerError.invalidConfiguration }
        if fcntl(fd, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP { throw RemotePeerError.invalidConfiguration }
        guard renameat(dirFD, temporary, dirFD, url.lastPathComponent) == 0, fsync(dirFD) == 0 else { throw RemotePeerError.invalidConfiguration }
    }
    private func resultPayload(_ reply: RemotePeerReply) throws -> Data {
        switch reply.state {
        case .completed: return reply.payload
        case .outcomeUnknown: throw RemotePeerError.outcomeUnknown
        case .rejected: throw RemotePeerError.rejected(reply.diagnostic ?? "peer_rejected")
        }
    }
    private func activeWorkerGrants() -> [RemotePeerGrant] { Array(workerGrants.values) }
}
