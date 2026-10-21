import AIMCore
import Foundation

/// A command the app could not carry out, with the protocol's error code (§4).
public struct RemoteHostCommandFailure: Error, Equatable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

/// What the app provides to the host: its conversations, what it can run, and
/// the execution of phone commands (on the same paths as on-screen actions,
/// with the same approvals).
public protocol RemoteHostDelegate: Sendable {
    func remoteStop(commandIDs: Set<String>, conversationIDs: Set<String>) async throws
    func remoteSnapshots() async -> [RemoteHostSessionSnapshot]
    func remoteCapabilities() async -> RemoteCapabilities
    func remoteSessionLimit() async -> Int?
    func remoteSnapshotReadSucceeded() async -> Bool
    /// Executes a command; returns its result (nil for none) or throws `RemoteHostCommandFailure`.
    /// `attachments` are the phone's files of a `user_message`, already verified.
    func remoteExecute(type: String, sessionID: String?, payload: RemoteJSONValue,
                       attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue?
    func remoteExecute(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue,
                       attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue?
}
public extension RemoteHostDelegate {
    func remoteStop(commandIDs: Set<String>, conversationIDs: Set<String>) async throws { throw RemoteHostCommandFailure("stop_confirmation_unsupported") }
    func remoteSnapshotReadSucceeded() async -> Bool { true }
    func remoteSessionLimit() async -> Int? { RemoteHostMirror.totalSessionLimit }
    func remoteExecute(commandID: String, type: String, sessionID: String?, payload: RemoteJSONValue,
                       attachments: [RemoteHostAttachment]) async throws -> RemoteJSONValue? {
        try await remoteExecute(type: type, sessionID: sessionID, payload: payload, attachments: attachments)
    }
}

/// Runs this Mac as a Remote host (protocol v2): heartbeat, pairing, end-to-end
/// keys, the encrypted mirror of recent Agent conversations and phone commands.
/// Off by default; it only runs while the person enabled it and is signed in.
public actor RemoteHost {
    public enum Status: Codable, Equatable, Sendable {
        case stopped
        case starting
        case online(devices: Int)
        case failed(String)
    }

    private let backend: any RemoteHostBackend
    private let store: RemoteHostIdentityStore
    private let currentAccountID: (@Sendable () async -> UUID?)?
    private var boundAccount: String?
    private var lifecycleGeneration = UUID()
    private var isRunning = false
    private let delegate: any RemoteHostDelegate
    private let journal: (any RemoteHostCommandJournal)?
    private let machineName: String
    private let appVersion: String
    private let heartbeat: Duration
    private let poll: Duration
    private var identity: RemoteHostIdentity?
    // A persisted fingerprint proves a past ACK, not current relay presence.
    // Every start revalidates publication; a failed force must be retried by
    // heartbeat even when the device/public key has not changed.
    private var keysNeedPublication = true
    private var keySyncTask: Task<Int, Error>?
    private var keySyncID = UUID()
    private var keySyncForced = false
    private var diagnosticEntries: [RemoteDiagnosticEntry] = []
    private var linkDiagnostics: [String: RemoteLinkDiagnostic] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var privacyTask: Task<Void, Never>?
    private var published: [String: Int] = [:]
    private var publishedMessages: [String: Int] = [:]
    private var publishPending = false
    private var cleanedRelay = false
    private var publishTask: Task<Void, Never>?
    private var processing: Set<String> = []
    private var commandTasks: [String: Task<Void, Never>] = [:]
    private var commandGeneration = UUID()
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]
    public private(set) var status: Status = .stopped {
        didSet { for continuation in statusContinuations.values { continuation.yield(status) } }
    }

    public init(backend: any RemoteHostBackend, store: RemoteHostIdentityStore = RemoteHostIdentityStore(),
                currentAccountID: (@Sendable () async -> UUID?)? = nil, delegate: any RemoteHostDelegate, machineName: String = Host.current().localizedName ?? "Mac",
                appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                heartbeat: Duration = .seconds(30), poll: Duration = .seconds(3),
                journal: (any RemoteHostCommandJournal)? = nil) {
        self.backend = backend
        self.store = store
        self.currentAccountID = currentAccountID
        boundAccount = store.accountID?.uuidString.lowercased()
        self.delegate = delegate
        self.journal = journal
        self.machineName = machineName
        self.appVersion = appVersion
        self.heartbeat = heartbeat
        self.poll = poll
    }

    public func statusUpdates() -> AsyncStream<Status> {
        let id = UUID()
        return AsyncStream { continuation in
            statusContinuations[id] = continuation
            continuation.yield(status)
            continuation.onTermination = { _ in Task { await self.removeStatusContinuation(id) } }
        }
    }

    private func removeStatusContinuation(_ id: UUID) { statusContinuations[id] = nil }

    public var machineID: String? { identity?.machineID }

    public func diagnosticReport() async -> RemoteDiagnosticReport {
        .init(formatVersion: 2, appVersion: appVersion, entries: diagnosticEntries,
              links: linkDiagnostics.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier },
              installationIdentifier: Bundle.main.bundleIdentifier,
              buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              relayIdentifier: await backend.diagnosticRelayIdentifier())
    }

    private func record(_ type: String, commandID: String? = nil, stage: RemoteCommandStage,
                        status: String, code: String? = nil) {
        let known = ["key_publication_refused", "key_publication_receipt_missing", "key_publication_incomplete",
            "machine_secret_mismatch", "not_authenticated", "invalid_envelopes", "invalid_version", "transition_refused"]
        let safe = code.map { known.contains($0) ? $0 : "remote_transport_failed" }
        diagnosticEntries.append(.init(commandIdentifier: commandID.map { RemoteDiagnosticPrivacy.identifier($0.lowercased()) } ?? "",
            machineIdentifier: identity.map { RemoteDiagnosticPrivacy.identifier($0.machineID.lowercased()) } ?? "",
            type: type, stage: stage, status: status, durationMilliseconds: 0,
            errorCode: safe.map { RemoteCommandErrorCode.classify($0) }, serverCode: safe))
        if diagnosticEntries.count > 200 { diagnosticEntries.removeFirst(diagnosticEntries.count - 200) }
    }


    // MARK: Lifecycle

    public func start() async {
        guard !AIMNetworkPrivacyPolicy.isEnabled else { stop(); return }
        guard !isRunning else { return }
        isRunning = true; lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        let changes = AIMNetworkPrivacyPolicy.changes()
        privacyTask = Task { [weak self] in
            for await enabled in changes where enabled { await self?.stop() }
        }
        status = .starting
        do {
            if boundAccount == nil { boundAccount = Self.accountKey(try await backend.userID()) }
            try await requireCurrent(generation)
            let registered = try await store.resolveForRegistration(isCurrent: { [weak self] in
                guard let self else { throw RemoteHostError.accountChanged }
                try await self.requireCurrent(generation)
            }, register: { [weak self] candidate in
                guard let self else { throw RemoteHostError.accountChanged }
                try await self.register(candidate, generation: generation)
            })
            try await requireCurrent(generation)
            identity = registered
            let count = try await syncKeys()
            try await requireCurrent(generation)
            status = .online(devices: count)
        } catch {
            guard isRunning, generation == lifecycleGeneration else { return }
            isRunning = false; privacyTask?.cancel(); privacyTask = nil
            status = .failed(error.localizedDescription)
            return
        }
        guard isRunning, generation == lifecycleGeneration else { return }
        let heartbeat = self.heartbeat, poll = self.poll
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeat)
                guard let self, !Task.isCancelled else { return }
                do { try await self.beat() } catch { await self.fail(error) }
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.processCommands()
                try? await Task.sleep(for: poll)
            }
        })
        if let machineID = identity?.machineID {
            let signals = await backend.commandSignals(machineID: machineID)
            guard isRunning, generation == lifecycleGeneration else { return }
            tasks.append(Task { [weak self] in
                for await _ in signals { await self?.processCommands() }
            })
        }
        await publish()
    }

    public func stop() {
        isRunning = false; lifecycleGeneration = UUID()
        identity = nil
        keySyncTask?.cancel(); keySyncTask = nil; keySyncID = UUID()
        keysNeedPublication = true
        privacyTask?.cancel(); privacyTask = nil
        commandGeneration = UUID()
        for task in commandTasks.values { task.cancel() }
        commandTasks.removeAll(); processing.removeAll()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        publishTask?.cancel()
        publishTask = nil
        publishPending = false
        status = .stopped
    }

    private func fail(_ error: Error) { if isRunning { status = .failed(error.localizedDescription) } }

    private static func accountKey(_ value: String) -> String { UUID(uuidString: value)?.uuidString.lowercased() ?? value }
    private func requireCurrent(_ generation: UUID? = nil) async throws {
        let expected = generation ?? lifecycleGeneration
        guard isRunning, expected == lifecycleGeneration, let boundAccount else { throw RemoteHostError.accountChanged }
        if let currentAccountID {
            guard let current = await currentAccountID(), current.uuidString.lowercased() == boundAccount else { throw RemoteHostError.accountChanged }
        }
        guard Self.accountKey(try await backend.userID()) == boundAccount else { throw RemoteHostError.accountChanged }
        if let currentAccountID {
            guard let current = await currentAccountID(), current.uuidString.lowercased() == boundAccount else { throw RemoteHostError.accountChanged }
        }
        guard isRunning, expected == lifecycleGeneration else { throw RemoteHostError.accountChanged }
    }
    private func register(_ candidate: RemoteHostIdentity, generation: UUID) async throws {
        try await requireCurrent(generation)
        let capabilities = try RemoteHostMirror.capabilities(await delegate.remoteCapabilities(), machineID: candidate.machineID,
            key: candidate.currentKey, version: candidate.keyVersion)
        try await requireCurrent(generation)
        try await backend.register(machineID: candidate.machineID, secret: candidate.secret, name: machineName, appVersion: appVersion, capabilities: capabilities)
        try await requireCurrent(generation)
    }

    /// Heartbeat: presence + capabilities, then keys for active devices.
    private func beat() async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        try await requireCurrent()
        guard let identity else { return }
        let generation = lifecycleGeneration
        try await register(identity, generation: generation)
        let devices = try await syncKeys()
        try await requireCurrent(generation)
        status = .online(devices: devices)
    }

    // MARK: Pairing and devices

    public func pairingCode() async throws -> RemotePairingCode {
        try await requireCurrent()
        let generation = lifecycleGeneration
        guard let identity else { throw RemoteHostError.server("registration_required") }
        let code = try await backend.createPairingCode(machineID: identity.machineID, secret: identity.secret)
        try await requireCurrent(generation)
        return code
    }

    public func devices() async throws -> [RemoteHostDevice] {
        try await requireCurrent()
        let generation = lifecycleGeneration
        let devices = try await backend.devices()
        try await requireCurrent(generation)
        return devices
    }

    public func revoke(deviceID: String) async throws {
        try await requireCurrent()
        let generation = lifecycleGeneration
        try await backend.revoke(deviceID: deviceID)
        try await requireCurrent(generation)
        _ = try await syncKeys()
    }

    /// Envelopes for every active device with a public key; a revoked or expired
    /// device that held the key forces a new key and a full republication (§6.4.5).
    @discardableResult
    func syncKeys(forceRepublish: Bool = false) async throws -> Int {
        try await requireCurrent()
        let generation = lifecycleGeneration
        if let task = keySyncTask {
            let forced = keySyncForced
            let operation = keySyncID
            let count = try await task.value
            try await requireCurrent(generation)
            if !forceRepublish || forced { return count }
            if keySyncID == operation { keySyncTask = nil }
            return try await syncKeys(forceRepublish: true)
        }
        let operation = UUID(); keySyncID = operation; keySyncForced = forceRepublish
        let task = Task { try await self.performKeySync(forceRepublish: forceRepublish) }
        keySyncTask = task
        defer { if keySyncID == operation { keySyncTask = nil } }
        return try await task.value
    }

    private func performKeySync(forceRepublish: Bool) async throws -> Int {
        try await requireCurrent()
        let generation = lifecycleGeneration
        guard var identity else { return 0 }
        let devices = try await backend.devices()
        try await requireCurrent(generation)
        let active = devices.filter { $0.isActive() && $0.public_key != nil }
        let activeIDs = Set(active.map(\.id))
        let fingerprints = Dictionary(uniqueKeysWithValues: active.map { ($0.id, RemoteHostIdentity.publicKeyFingerprint($0.public_key!)) })
        if !identity.keyedDevices.isSubset(of: activeIDs) {
            identity.rotate()
            published.removeAll()
            publishedMessages.removeAll()
        }
        let missing = active.filter { !identity.keyedDevices.contains($0.id) || identity.keyedDeviceFingerprints[$0.id] != fingerprints[$0.id] }
        if !missing.isEmpty || (forceRepublish || keysNeedPublication) && !active.isEmpty {
            keysNeedPublication = true
            let envelopes = try active.map { device in
                (deviceID: device.id, envelope: try RemoteCrypto.wrapMirrorKey(identity.currentKey,
                    devicePublicKeyBase64: device.public_key!, machineID: identity.machineID,
                    deviceID: device.id, version: identity.keyVersion))
            }
            record("key_publication", stage: .rpc, status: "publishing")
            do {
                try await backend.putKeys(machineID: identity.machineID, secret: identity.secret,
                                          version: identity.keyVersion, envelopes: envelopes)
            } catch {
                record("key_publication", stage: .failed, status: "publication_failed",
                       code: (error as? RemoteHostError).flatMap { if case .server(let code) = $0 { code } else { nil } })
                throw error
            }
            try await requireCurrent(generation)
            record("key_publication", stage: .published, status: "stored_complete")
            for device in active {
                linkDiagnostics[device.id] = .init(accountID: boundAccount ?? "", deviceID: device.id,
                    machineID: identity.machineID, localPublicKey: nil, registeredPublicKey: device.public_key,
                    currentKeyVersion: identity.keyVersion, envelopeVersions: [identity.keyVersion],
                    openedVersions: [], unreadableVersions: [], readState: .unknown)
            }
            try await requireCurrent(generation)
            identity.keyedDevices = activeIDs
            identity.keyedDeviceFingerprints = fingerprints
        }
        try await requireCurrent(generation)
        if identity != self.identity {
            try store.save(identity)
            let rotated = identity.keyVersion != self.identity?.keyVersion
            self.identity = identity
            if rotated { await publish() }
        }
        keysNeedPublication = false
        return active.count
    }

    // MARK: Mirror

    /// Called by the app whenever a conversation changed; coalesced (~400 ms).
    public func mirrorChanged() {
        guard !tasks.isEmpty, !publishPending else { return }
        publishPending = true
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await self?.publish()
        }
    }

    func publish() async {
        guard !AIMNetworkPrivacyPolicy.isEnabled else { stop(); return }
        publishPending = false
        guard (try? await requireCurrent()) != nil, let identity else { return }
        let generation = lifecycleGeneration
        let available = await delegate.remoteSnapshots().sorted { $0.updatedAt > $1.updatedAt }
        guard await delegate.remoteSnapshotReadSucceeded() else { return }
        let limit = await delegate.remoteSessionLimit()
        let snapshots = limit.map { Array(available.prefix(max(0, $0))) } ?? available
        var sessionRows: [RemoteSessionRow] = []
        var messageRows: [RemoteMessageRow] = []
        var trims: [(String, Int)] = []
        do {
            for snapshot in snapshots {
                var plain = snapshot
                plain.messages = Array(snapshot.messages.suffix(RemoteHostMirror.messageWindow))
                let sessionHash = Self.hash(snapshot, includeMessages: false)
                if published[snapshot.id] != sessionHash {
                    sessionRows.append(try RemoteHostMirror.sessionRow(snapshot, machineID: identity.machineID,
                                                                       key: identity.currentKey, version: identity.keyVersion))
                }
                var changed = plain
                changed.messages = plain.messages.filter { publishedMessages[$0.id] != Self.hash($0) }
                if !changed.messages.isEmpty {
                    messageRows += try RemoteHostMirror.messageRows(changed, key: identity.currentKey, version: identity.keyVersion)
                }
                if let first = plain.messages.first, snapshot.messages.count > plain.messages.count {
                    trims.append((snapshot.id, first.sequence))
                }
            }
            try await requireCurrent(generation)
            try await backend.upsert(sessions: sessionRows, messages: messageRows)
            try await requireCurrent(generation)
            for snapshot in snapshots {
                var plain = snapshot
                plain.messages = Array(snapshot.messages.suffix(RemoteHostMirror.messageWindow))
                published[snapshot.id] = Self.hash(snapshot, includeMessages: false)
                for message in plain.messages { publishedMessages[message.id] = Self.hash(message) }
            }
            for (session, sequence) in trims {
                try await requireCurrent(generation)
                try? await backend.deleteMessages(sessionID: session, beforeSequence: sequence)
            }
            let kept = Set(snapshots.map(\.id))
            // The first publication also removes rows left by an earlier run of this Mac.
            if !cleanedRelay || published.keys.contains(where: { !kept.contains($0) }) {
                try await requireCurrent(generation)
                cleanedRelay = true
                try? await backend.deleteSessions(machineID: identity.machineID, keeping: kept)
                published = published.filter { kept.contains($0.key) }
            }
        } catch {
            if isRunning, generation == lifecycleGeneration { status = .failed("Mirror: \(error.localizedDescription)") }
        }
    }

    static func hash(_ snapshot: RemoteHostSessionSnapshot, includeMessages: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.title); hasher.combine(snapshot.workspace); hasher.combine(snapshot.modelID)
        hasher.combine(snapshot.approvalMode); hasher.combine(snapshot.status); hasher.combine(snapshot.phase)
        hasher.combine(snapshot.executionDeviceIDs); hasher.combine(snapshot.latestResponseVersion)
        hasher.combine(RemoteHostMirror.json(snapshot.pendingApproval ?? .null)); hasher.combine(snapshot.interrupted)
        hasher.combine(snapshot.silence); hasher.combine(snapshot.messages.count); hasher.combine(snapshot.updatedAt)
        hasher.combine(snapshot.runStartedAt); hasher.combine(snapshot.archivedAt)
        return hasher.finalize()
    }

    static func hash(_ message: RemoteHostMessageSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(message.content); hasher.combine(message.reasoning); hasher.combine(message.model)
        hasher.combine(RemoteHostMirror.json(message.toolCalls ?? .null)); hasher.combine(RemoteHostMirror.json(message.timeline ?? .null))
        hasher.combine(RemoteHostMirror.json(message.runStats ?? .null))
        return hasher.finalize()
    }

    // MARK: Commands

    private var checkingStops = false
    public func processAccountStopRequests() async throws {
        guard !checkingStops, let identity else { return }
        checkingStops = true; defer { checkingStops = false }
        for request in try await backend.stopRequests(machineID: identity.machineID, secret: identity.secret) {
            let tasks = request.command_ids.compactMap { commandTasks[$0] }
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
            try await delegate.remoteStop(commandIDs: Set(request.command_ids), conversationIDs: Set(request.conversation_ids))
            try await backend.acknowledgeStop(machineID: identity.machineID, secret: identity.secret, requestID: request.id)
        }
    }

    func processCommands() async {
        guard !AIMNetworkPrivacyPolicy.isEnabled else { stop(); return }
        do { try await processAccountStopRequests() } catch { fail(RemoteHostError.server("session_stop_confirmation_pending")); return }
        guard (try? await requireCurrent()) != nil, let identity, !tasks.isEmpty || status != .stopped else { return }
        let generation = commandGeneration
        if let journal, let account = try? await backend.userID(),
           let receipts = try? await journal.pending(accountID: account, machineID: identity.machineID) {
            guard (try? await requireCurrent()) != nil else { return }
            for receipt in receipts where !processing.contains(receipt.command.id) {
                guard generation == commandGeneration, !Task.isCancelled else { return }
                processing.insert(receipt.command.id)
                commandTasks[receipt.command.id] = Task { [weak self] in
                    await self?.run(receipt.command)
                    await self?.finished(receipt.command.id, generation: generation)
                }
            }
        }
        let commands: [RemoteHostCommand]
        do {
            commands = try await backend.pendingCommands(machineID: identity.machineID)
            try await requireCurrent()
        } catch {
            guard (try? await requireCurrent()) != nil else { return }
            fail(RemoteHostError.server("remote_commands_poll_failed"))
            return
        }
        for command in commands where !processing.contains(command.id) {
            guard generation == commandGeneration, !Task.isCancelled else { return }
            processing.insert(command.id)
            commandTasks[command.id] = Task { [weak self] in
                await self?.run(command)
                await self?.finished(command.id, generation: generation)
            }
        }
    }

    private func finished(_ id: String, generation: UUID) {
        guard generation == commandGeneration else { return }
        processing.remove(id); commandTasks.removeValue(forKey: id)
    }

    /// pending → ack → done|error, executed once (a refused transition means another run took it).
    func run(_ command: RemoteHostCommand) async {
        guard (try? await requireCurrent()) != nil, let identity, !Task.isCancelled else { return }
        do {
            guard try await backend.authorizeCommand(machineID: identity.machineID, secret: identity.secret, commandID: command.id, conversationID: command.session_id) else { return }
        } catch { fail(RemoteHostError.server("command_authorization_failed")); return }
        if let payload = try? RemoteHostMirror.payload(command.payload, command: command.identity, keys: identity.keys),
           RemoteContinuityAction(rawValue: command.type) != nil || payload.objectValue?["goal"]?.objectValue?["continuous"] == .bool(true)
            || ["request_history", "request_detail", "rename_session", "archive_session", "delete_session", "request_diff",
                "run_command", "stop_command", "start_preview", "stop_preview"].contains(command.type) && journal != nil {
            await runDurable(command, payload: payload, identity: identity)
            return
        }
        do {
            try await backend.updateCommand(machineID: identity.machineID, secret: identity.secret, commandID: command.id,
                                            status: "ack", error: nil, result: nil)
        } catch {
            record(command.type, commandID: command.id, stage: .failed, status: "ack_failed",
                   code: (error as? RemoteHostError).flatMap { if case .server(let code) = $0 { code } else { nil } })
            fail(RemoteHostError.server("command_ack_failed"))
            return
        }
        record(command.type, commandID: command.id, stage: .acknowledged, status: "ack")
        var errorCode: String?
        var result: RemoteJSONValue?
        do {
            let payload = try RemoteHostMirror.payload(command.payload, command: command.identity, keys: identity.keys)
            result = try await withTimeout(Self.budget(command.type)) {
                try await self.execute(command, payload: payload)
            }
            try await verifyResultOwner(command, result: result, identity: identity)
            if command.type == "set_model_added" {
                // Publish the actual library state before returning the receipt
                // so the iPhone refresh does not read a stale heartbeat.
                try await register(identity, generation: lifecycleGeneration)
            }
        } catch let failure as RemoteHostCommandFailure {
            errorCode = failure.code
        } catch let failure as RemoteHostMirror.CommandError {
            errorCode = failure.rawValue
        } catch is TimeoutError {
            errorCode = "interface_indisponible"
        } catch let failure as RemoteHostError where command.type == "request_keys" {
            let known = ["key_publication_refused", "key_publication_receipt_missing", "key_publication_incomplete", "machine_secret_mismatch", "not_authenticated", "invalid_envelopes", "invalid_version"]
            if case .server(let code) = failure, known.contains(code) { errorCode = code }
            else { errorCode = "key_publication_failed" }
            fail(RemoteHostError.server(errorCode!))
        } catch {
            errorCode = "erreur_interne"
            if command.type == "request_keys" { fail(RemoteHostError.server("key_publication_failed")) }
        }
        guard (try? await requireCurrent()) != nil, !Task.isCancelled else { return }
        let current = self.identity ?? identity
        let sealed = try? result.map { try RemoteHostMirror.result($0, command: command.identity, key: current.currentKey, version: current.keyVersion) }
        do {
            try await backend.updateCommand(machineID: current.machineID, secret: current.secret, commandID: command.id,
                                            status: errorCode == nil ? "done" : "error", error: errorCode, result: sealed ?? nil)
            record(command.type, commandID: command.id, stage: errorCode == nil ? .completed : .failed,
                   status: errorCode == nil ? "done" : "error", code: errorCode)
        } catch {
            record(command.type, commandID: command.id, stage: .failed, status: "terminal_update_failed",
                   code: (error as? RemoteHostError).flatMap { if case .server(let code) = $0 { code } else { nil } })
            fail(RemoteHostError.server("command_terminal_update_failed"))
        }
        mirrorChanged()
    }

    private func execute(_ command: RemoteHostCommand, payload: RemoteJSONValue) async throws -> RemoteJSONValue? {
        try Task.checkCancellation()
        try await requireCurrent()
        guard let identity, try await backend.authorizeCommand(machineID: identity.machineID, secret: identity.secret, commandID: command.id, conversationID: command.session_id) else { throw RemoteHostCommandFailure("session_revoked") }
        switch command.type {
        case "request_keys":
            let count = try await syncKeys(forceRepublish: true)
            status = .online(devices: count)
            return nil
        case "list_folders":
            return try RemoteHostFolders.list(payload.objectValue?["path"]?.stringValue)
        case "create_folder":
            return try RemoteHostFolders.create(parent: payload.objectValue?["parent"]?.stringValue,
                                                name: payload.objectValue?["name"]?.stringValue)
        case "user_message":
            let files = try await RemoteHostAttachments.fetch(payload: payload, sessionID: command.session_id,
                machineID: command.machine_id, keys: identity.keys, backend: backend)
            try await requireCurrent()
            return try await delegate.remoteExecute(commandID: command.id, type: command.type, sessionID: command.session_id, payload: payload,
                                                    attachments: files)
        default:
            return try await delegate.remoteExecute(commandID: command.id, type: command.type, sessionID: command.session_id, payload: payload,
                                                    attachments: [])
        }
    }

    private func verifyResultOwner(_ command: RemoteHostCommand, result: RemoteJSONValue?, identity: RemoteHostIdentity) async throws {
        let conversationID = result?.objectValue?["session_id"]?.stringValue ?? command.session_id
        guard try await backend.authorizeCommand(machineID: identity.machineID, secret: identity.secret,
            commandID: command.id, conversationID: conversationID) else {
            try await delegate.remoteStop(commandIDs: [command.id], conversationIDs: Set([conversationID].compactMap { $0 }))
            throw RemoteHostCommandFailure("session_revoked")
        }
    }

    /// A cloud ack means local durable admission, never merely receipt by a view.
    /// Completed receipts can finish delivery after a crash without re-executing effects.
    private func runDurable(_ command: RemoteHostCommand, payload: RemoteJSONValue, identity: RemoteHostIdentity) async {
        guard let journal, command.machine_id == identity.machineID else { return }
        do {
            try await requireCurrent()
            let account = try await backend.userID()
            try await requireCurrent()
            try Task.checkCancellation()
            var receipt = try await journal.prepare(command, accountID: account)
            if !receipt.completed {
                try Task.checkCancellation()
                var result: RemoteJSONValue?
                var errorCode: String?
                let oneShot = command.type == "run_command" || command.type == "start_preview" && payload.objectValue?["browser"]?.objectValue?["name"]?.stringValue.map { $0 != "browser_snapshot" } == true
                if oneShot && receipt.effectStarted == true {
                    errorCode = "execution_outcome_unknown"
                } else {
                    if oneShot { _ = try await journal.markEffectStarted(command.id, accountID: account, machineID: command.machine_id) }
                    do {
                        result = try await withTimeout(Self.budget(command.type)) { try await self.execute(command, payload: payload) }
                        try await verifyResultOwner(command, result: result, identity: identity)
                    }
                    catch let error as RemoteHostCommandFailure { errorCode = error.code }
                    catch is TimeoutError { if oneShot { errorCode = "execution_outcome_unknown" } else { return } }
                    catch { if oneShot { errorCode = "execution_outcome_unknown" } else { return } }
                }
                // Result is durable before acknowledgement or network delivery.
                guard !Task.isCancelled, (try? await requireCurrent()) != nil, try await backend.userID() == account else { return }
                let current = self.identity ?? identity
                let sealed = try result.map { try RemoteHostMirror.result($0, command: command.identity,
                    key: current.currentKey, version: current.keyVersion) }
                receipt = try await journal.complete(command.id, accountID: account, machineID: command.machine_id,
                                                     result: sealed, error: errorCode)
            }
            guard !Task.isCancelled, (try? await requireCurrent()) != nil, try await backend.userID() == account else { return }
            if !receipt.acknowledged {
                do {
                    try await backend.updateCommand(machineID: identity.machineID, secret: identity.secret,
                        commandID: command.id, status: "ack", error: nil, result: nil)
                } catch {
                    guard let state = try await backend.commandStatus(commandID: command.id, machineID: identity.machineID),
                          ["ack", "done", "error"].contains(state) else { throw error }
                    if state == "done" || state == "error" {
                        _ = try await journal.acknowledge(command.id, accountID: account, machineID: command.machine_id)
                        try await journal.delivered(command.id, accountID: account, machineID: command.machine_id)
                        return
                    }
                }
                receipt = try await journal.acknowledge(command.id, accountID: account, machineID: command.machine_id)
            }
            let outgoing = try await deliveryResult(receipt.result, command: command, identity: self.identity ?? identity)
            try await backend.updateCommand(machineID: identity.machineID, secret: identity.secret,
                commandID: command.id, status: receipt.error == nil ? "done" : "error", error: receipt.error, result: outgoing)
            try await journal.delivered(command.id, accountID: account, machineID: command.machine_id)
            mirrorChanged()
        } catch { /* retain the local receipt for reconnect */ }
    }

    private func deliveryResult(_ sealed: RemoteJSONValue?, command: RemoteHostCommand, identity: RemoteHostIdentity) async throws -> RemoteJSONValue? {
        guard let sealed, let encrypted = sealed.objectValue?["e"]?.stringValue,
              encrypted.utf8.count > 256 * 1_024, let session = command.session_id else { return sealed }
        let text = try RemoteCrypto.decryptField(encrypted, keys: identity.keys, context: command.identity.context(for: .result))
        let transfer = try RemoteTransferCrypto.prepareDetail(data: Data(text.utf8), key: identity.currentKey,
            keyVersion: identity.keyVersion, transferID: command.id.lowercased(), machineID: identity.machineID, sessionID: session)
        try await backend.publishResultTransfer(transfer, key: identity.currentKey)
        return try RemoteHostMirror.result(.object(["transfer_id": .string(transfer.manifest.transferID)]),
            command: command.identity, key: identity.currentKey, version: identity.keyVersion)
    }

    /// Execution budgets of §4 (seconds).
    static func budget(_ type: String) -> Duration {
        switch type {
        case "user_message": .seconds(120) // up to 4 × 20 MiB of attachments to download and verify
        case "run_command", "stop_command": .seconds(135)
        case "start_preview", "stop_preview": .seconds(75)
        default: .seconds(20)
        }
    }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: duration); throw TimeoutError() }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// `list_folders` / `create_folder` (§4): the home folder's visible directories,
/// never hidden folders, never outside the home folder.
public enum RemoteHostFolders {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() }

    public static func allowed(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL
        let root = home.standardizedFileURL.path
        guard url.path == root || url.path.hasPrefix(root + "/"),
              !url.pathComponents.dropFirst(home.pathComponents.count).contains(where: { $0.hasPrefix(".") }) else { return nil }
        return url
    }

    public static func list(_ path: String?) throws -> RemoteJSONValue {
        func entries(_ folder: URL) throws -> [RemoteJSONValue] {
            let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles])
            return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .prefix(500)
                .map { .object(["path": .string($0.path), "name": .string($0.lastPathComponent)]) }
        }
        let projects = ["Developer", "Projects", "Code"].map { home.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let path else {
            var roots: [RemoteJSONValue] = [.object(["path": .string(home.path), "name": .string(home.lastPathComponent)])]
            for name in ["Desktop", "Documents", "Downloads"] {
                let url = home.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    roots.append(.object(["path": .string(url.path), "name": .string(name)]))
                }
            }
            if let projects {
                roots.append(.object(["path": .string(projects.path), "name": .string(projects.lastPathComponent), "isProjects": .bool(true)]))
            }
            return .object(["roots": .array(roots), "projectsDir": projects.map { .string($0.path) } ?? .null])
        }
        guard let folder = allowed(path) else { throw RemoteHostCommandFailure("chemin_refuse") }
        do { return .object(["entries": .array(try entries(folder))]) }
        catch { throw RemoteHostCommandFailure("listing_impossible") }
    }

    public static func create(parent: String?, name: String?) throws -> RemoteJSONValue {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 120,
              !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { throw RemoteHostCommandFailure("nom_invalide") }
        guard let parent, let folder = allowed(parent) else { throw RemoteHostCommandFailure("chemin_refuse") }
        let target = folder.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw RemoteHostCommandFailure("dossier_existe") }
        do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
        catch { throw RemoteHostCommandFailure("creation_impossible") }
        return .object(["path": .string(target.path)])
    }
}
