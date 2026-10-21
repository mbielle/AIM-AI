import AIMAgentKit
import AIMApplication
import AIMCore
import CryptoKit
import Darwin
import Foundation

/// Host-selected scope. A resolver must own the admitted external execution;
/// looking up an arbitrary active native conversation is not such ownership.
public struct ExternalFinanceBinding: Sendable {
    public let executionID: UUID
    public let accountID: UUID
    public let allowedFeatures: Set<String>
    public let expiresAt: Date
    public init(executionID: UUID, accountID: UUID, allowedFeatures: Set<String>, expiresAt: Date) {
        self.executionID = executionID; self.accountID = accountID; self.allowedFeatures = allowedFeatures; self.expiresAt = expiresAt
    }
}

/// The native ledger admits each physical attempt before a bridge can send it.
/// Stdout supplies billing data, never owner/account/model/isolation authority.
public actor ExternalFinanceBroker {
    public typealias Authorize = @Sendable (ExternalFinanceGrant, ExternalFinanceRequest.Action) async throws -> Bool
    public typealias VerifyBound = @Sendable (ExternalFinanceGrant, ExternalFinanceRequest) async throws -> Bool
    public typealias VerifyReceipt = @Sendable (ExternalFinanceGrant, ExternalFinanceRequest) async throws -> Bool
    private struct Receipt: Codable { let request: ExternalFinanceRequest; var response: ExternalFinanceResponse? }
    private let ledger: SQLiteGlobalSpendLedger
    private let executions: SQLiteAgentExecutionRepository
    private let owner: UUID
    private let journal: ExternalFinanceJournal
    private let accountID: @Sendable () async -> UUID?
    private let authorize: Authorize
    private let verifyReceipt: VerifyReceipt
    private let verifyBound: VerifyBound
    private var handling: Set<UUID> = []

    public init(ledger: SQLiteGlobalSpendLedger, executions: SQLiteAgentExecutionRepository, owner: UUID,
                directory: URL, accountID: @escaping @Sendable () async -> UUID?,
                authorize: @escaping Authorize, verifyBound: @escaping VerifyBound = { _, _ in false },
                verifyReceipt: @escaping VerifyReceipt = { _, _ in false }) throws {
        self.ledger = ledger; self.executions = executions; self.owner = owner
        journal = try ExternalFinanceJournal(directory: directory)
        self.accountID = accountID; self.authorize = authorize; self.verifyReceipt = verifyReceipt; self.verifyBound = verifyBound
    }

    /// Concrete resolver construction; the host supplies and rechecks placement.
    /// No default binding is inferred from stdout, a conversation ID or a JSON config.
    public nonisolated func resolver(binding: @escaping @Sendable (AgentRequest, ExternalEngineConfiguration) async throws -> ExternalFinanceBinding) -> ExternalFinanceResolver {
        { [self] request, runID, configuration in
            try await open(request: request, runID: runID, configuration: configuration,
                           binding: binding(request, configuration))
        }
    }
    public func open(request: AgentRequest, runID: UUID, configuration: ExternalEngineConfiguration,
                     binding: ExternalFinanceBinding) async throws -> ExternalFinanceSession {
        try RuntimePrivacyPolicy.requireNetwork()
        try await executions.requireOwner(owner)
        guard configuration.version == 2, configuration.financeProtocolVersion == 1, configuration.enabled,
              configuration.allowModelCalls, configuration.isolationReceipt?.isEmpty == false,
              await accountID() == binding.accountID, binding.expiresAt > .now,
              !binding.allowedFeatures.isEmpty, binding.allowedFeatures.count <= 32,
              binding.allowedFeatures.allSatisfy({ validLabel($0, maximum: 50) }),
              let execution = try await executions.execution(binding.executionID), execution.ownerGeneration == owner,
              execution.accountID == binding.accountID, execution.conversationID == request.conversationID,
              [.running, .waitingEvent, .waitingNetwork].contains(execution.state), execution.boundaryPauseReason == nil else {
            throw SpendAdmissionError.invalidPolicy
        }
        let admitted = try JSONDecoder().decode(AgentRequest.self, from: execution.request)
        guard admitted.modelID == request.modelID, admitted.provider == request.provider,
              admitted.remoteSpendGrantData == nil, request.remoteSpendGrantData == nil,
              let provider = admitted.provider, validLabel(configuration.identity, maximum: 100),
              validLabel(configuration.engineVersion, maximum: 100), configuration.executableSHA256.count == 64,
              configuration.executableSHA256.allSatisfy(\.isHexDigit) else { throw SpendAdmissionError.invalidPolicy }
        let grant = ExternalFinanceGrant(id: runID, runID: runID, accountID: binding.accountID,
            executionID: execution.id, ownerGeneration: owner, conversationID: execution.conversationID,
            engineIdentity: configuration.identity, engineVersion: configuration.engineVersion,
            executableSHA256: configuration.executableSHA256.lowercased(), provider: provider.rawValue,
            modelID: admitted.modelID, allowedFeatures: binding.allowedFeatures.sorted(), expiresAt: binding.expiresAt)
        guard try await authorize(grant, .admit) else { throw SpendAdmissionError.invalidPolicy }
        try await validate(grant, action: .admit)
        let folder = try journal.scope(grant.id)
        if let old: ExternalFinanceGrant = try journal.read("grant.json", in: folder) {
            guard old == grant else { throw SpendAdmissionError.duplicateAttempt }
        } else { try journal.write(grant, name: "grant.json", in: folder) }
        guard !journal.exists("closed.json", in: folder) else { throw SpendAdmissionError.invalidTransition }
        return ExternalFinanceSession(grant: grant, receive: { [self] in try await handle($0, grant: grant) },
            finish: { [self] in try await close(grant) })
    }

    public func handle(_ request: ExternalFinanceRequest, grant: ExternalFinanceGrant) async throws -> ExternalFinanceResponse {
        try validateRequest(request, grant: grant)
        try await validate(grant, action: request.action)
        guard !handling.contains(request.requestID) else { throw SpendAdmissionError.duplicateAttempt }
        handling.insert(request.requestID); defer { handling.remove(request.requestID) }
        let folder = try journal.scope(grant.id)
        guard let saved: ExternalFinanceGrant = try journal.read("grant.json", in: folder), saved == grant,
              !journal.exists("closed.json", in: folder) else { throw SpendAdmissionError.invalidPolicy }
        let name = "request-" + request.requestID.uuidString.lowercased() + ".json"
        if let old: Receipt = try journal.read(name, in: folder) {
            guard old.request == request else { throw SpendAdmissionError.duplicateAttempt }
            if let response = old.response {
                if response.disposition == .accepted, [.admit, .sent].contains(request.action), let id = request.attemptID {
                    let attempt = try await ledger.executionAttempt(id, executionID: grant.executionID, owner: owner)
                    guard attempt?.state == (request.action == .admit ? .reserved : .sent) else { throw SpendAdmissionError.invalidTransition }
                }
                return response
            }
        }
        // One immutable request ID for each action/physical attempt. A second
        // sent request ID must not turn an old ACK into another send permission.
        if let id = request.attemptID {
            let actionName = "attempt-" + id.uuidString.lowercased() + "-" + request.action.rawValue + ".json"
            if let old: ExternalFinanceRequest = try journal.read(actionName, in: folder) {
                guard old == request else { throw SpendAdmissionError.duplicateAttempt }
            } else { try journal.write(request, name: actionName, in: folder) }
        }
        var receipt = Receipt(request: request)
        try journal.write(receipt, name: name, in: folder) // durable intent before SQLite mutation
        let response: ExternalFinanceResponse
        do {
            try await validate(grant, action: request.action)
            let execution = try await executions.execution(grant.executionID)
            guard let execution else { throw SpendAdmissionError.invalidPolicy }
            let admitted = try JSONDecoder().decode(AgentRequest.self, from: execution.request)
            let scoped = ExecutionScopedSpendLedger(ledger: ledger, executionID: grant.executionID,
                owner: owner, capUSD: admitted.continuityMaximumSpendUSD)
            if request.action == .snapshot {
                response = .init(request: request, disposition: .accepted, snapshot: try await scoped.snapshot(at: .now))
            } else {
                guard let id = request.attemptID else { throw SpendAdmissionError.invalidPolicy }
                var previous = try await ledger.executionAttempt(id, executionID: grant.executionID, owner: owner)
                if request.action == .admit {
                    // A stdout estimate is not a trusted price bound. Without
                    // one, native policy handles an explicitly unbounded attempt.
                    if request.maximumUSD != nil {
                        guard try await verifyBound(grant, request) else { throw SpendAdmissionError.unknownBound }
                    }
                    let tag = featureTag(grant, feature: request.feature!)
                    if let old = previous {
                        guard old.provider == grant.provider, old.modelID == grant.modelID, old.feature == tag,
                              old.conversationID == grant.conversationID, old.maximumUSD == request.maximumUSD,
                              old.state == .reserved else { throw SpendAdmissionError.duplicateAttempt }
                    } else {
                        previous = try await scoped.admit(id: id, provider: grant.provider, modelID: grant.modelID,
                            feature: tag, conversationID: grant.conversationID, maximumUSD: request.maximumUSD,
                            exception: false, at: .now)
                    }
                } else {
                    guard let old = previous, old.provider == grant.provider, old.modelID == grant.modelID,
                          old.conversationID == grant.conversationID, old.feature.hasPrefix("ext:" + grant.id.uuidString + ":") else {
                        throw SpendAdmissionError.invalidPolicy
                    }
                    switch request.action {
                    case .sent:
                        guard old.state == .reserved || old.state == .sent else { throw SpendAdmissionError.invalidTransition }
                        if old.state == .reserved { try await scoped.markSent(id: id, at: .now) }
                    case .notSent:
                        guard old.state == .reserved || old.state == .notSent else { throw SpendAdmissionError.invalidTransition }
                        if old.state == .reserved { try await scoped.markNotSent(id: id, at: .now) }
                    case .unknown:
                        guard old.state == .sent || old.state == .unknown || old.state == .confirmed else { throw SpendAdmissionError.invalidTransition }
                        if old.state == .sent { try await scoped.markUnknown(id: id) }
                    case .reconcile:
                        guard let actual = request.actualUSD, try await verifyReceipt(grant, request) else {
                            if old.state == .sent { try await scoped.markUnknown(id: id) }
                            throw SpendAdmissionError.invalidAmount
                        }
                        if old.state == .confirmed {
                            guard old.actualUSD == actual else { throw SpendAdmissionError.invalidTransition }
                        } else { try await scoped.reconcile(id: id, actualUSD: actual, at: .now) }
                    case .admit, .snapshot: throw SpendAdmissionError.invalidPolicy
                    }
                    previous = try await ledger.executionAttempt(id, executionID: grant.executionID, owner: owner)
                }
                response = .init(request: request, disposition: .accepted, attempt: previous)
            }
        } catch let error as SpendAdmissionError {
            response = .init(request: request, disposition: .denied, diagnostic: String(describing: error))
        }
        receipt.response = response
        try journal.write(receipt, name: name, in: folder) // durable result before stdio ACK
        // A revoke/pause during a write never returns a fresh send authorization.
        try await validate(grant, action: request.action)
        return response
    }
    public func close(_ grant: ExternalFinanceGrant) async throws {
        try await executions.requireOwner(owner)
        guard grant.ownerGeneration == owner, await accountID() == grant.accountID else { throw SpendAdmissionError.invalidPolicy }
        let folder = try journal.scope(grant.id)
        guard let saved: ExternalFinanceGrant = try journal.read("grant.json", in: folder), saved == grant else { throw SpendAdmissionError.invalidPolicy }
        try journal.write(true, name: "closed.json", in: folder)
        let scoped = ExecutionScopedSpendLedger(ledger: ledger, executionID: grant.executionID, owner: owner, capUSD: nil)
        for name in try journal.names(in: folder) where name.hasPrefix("attempt-") && name.hasSuffix("-admit.json") {
            guard let request: ExternalFinanceRequest = try journal.read(name, in: folder), let id = request.attemptID,
                  request.grantID == grant.id else { throw SpendAdmissionError.invalidPolicy }
            guard let attempt = try await ledger.executionAttempt(id, executionID: grant.executionID, owner: owner),
                  attempt.feature.hasPrefix("ext:" + grant.id.uuidString + ":") else { continue }
            if attempt.state == .sent { try await scoped.markUnknown(id: id) }
            else if attempt.state == .reserved { try await scoped.markNotSent(id: id, at: .now) }
        }
    }
    private func validate(_ grant: ExternalFinanceGrant, action: ExternalFinanceRequest.Action) async throws {
        let admitting = action == .admit || action == .sent
        if admitting { try RuntimePrivacyPolicy.requireNetwork() }
        try await executions.requireOwner(owner)
        guard grant.version == 1, grant.ownerGeneration == owner, await accountID() == grant.accountID,
              let execution = try await executions.execution(grant.executionID), execution.accountID == grant.accountID,
              execution.conversationID == grant.conversationID, try await authorize(grant, action) else { throw SpendAdmissionError.invalidPolicy }
        if admitting {
            guard !journal.exists("closed.json", in: try journal.scope(grant.id)), grant.expiresAt > .now, execution.ownerGeneration == owner,
                  [.running, .waitingEvent, .waitingNetwork].contains(execution.state), execution.boundaryPauseReason == nil else { throw SpendAdmissionError.invalidPolicy }
            try RuntimePrivacyPolicy.requireNetwork()
        }
        try await executions.requireOwner(owner)
    }
    private func validateRequest(_ request: ExternalFinanceRequest, grant: ExternalFinanceGrant) throws {
        guard request.version == 1, request.grantID == grant.id, (request.providerReceipt?.count ?? 0) <= 8192 else { throw SpendAdmissionError.invalidPolicy }
        if request.action == .snapshot {
            guard request.attemptID == nil else { throw SpendAdmissionError.invalidPolicy }
        } else { guard request.attemptID != nil else { throw SpendAdmissionError.invalidPolicy } }
        if request.action == .admit {
            guard request.provider == grant.provider, request.modelID == grant.modelID,
                  let feature = request.feature, grant.allowedFeatures.contains(feature), validLabel(feature, maximum: 50),
                  request.actualUSD == nil, request.providerReceipt == nil else { throw SpendAdmissionError.invalidPolicy }
        } else {
            guard request.provider == nil, request.modelID == nil, request.feature == nil, request.maximumUSD == nil else { throw SpendAdmissionError.invalidPolicy }
        }
        if request.action == .reconcile {
            guard request.actualUSD != nil, let evidence = request.providerReceipt, !evidence.isEmpty,
                  let source = request.receiptSourceID, validLabel(source, maximum: 255) else { throw SpendAdmissionError.invalidAmount }
        } else {
            guard request.actualUSD == nil, request.providerReceipt == nil, request.receiptSourceID == nil else { throw SpendAdmissionError.invalidPolicy }
        }
    }
    private func featureTag(_ grant: ExternalFinanceGrant, feature: String) -> String { "ext:" + grant.id.uuidString + ":" + feature }
    private func validLabel(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }
}

/// Private bounded records; no prompt, credential or engine output is journaled.
private struct ExternalFinanceJournal: Sendable {
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw SpendAdmissionError.invalidPolicy }
        try syncDirectory(directory.deletingLastPathComponent())
    }
    func scope(_ id: UUID) throws -> URL {
        let name = id.uuidString.lowercased()
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw SpendAdmissionError.invalidPolicy }
        defer { Darwin.close(parent) }
        // mkdir is idempotent only after verifying the existing object through
        // its parent descriptor; EEXIST may also name a file or a symlink.
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw SpendAdmissionError.invalidPolicy }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw SpendAdmissionError.invalidPolicy }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              folder.path == folder.resolvingSymlinksInPath().path,
              fsync(parent) == 0 else { throw SpendAdmissionError.invalidPolicy }
        return folder
    }
    private func syncDirectory(_ folder: URL) throws {
        let fd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw SpendAdmissionError.invalidPolicy }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw SpendAdmissionError.invalidPolicy }
    }
    func exists(_ name: String, in folder: URL) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
    func names(in folder: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path) }
    func read<T: Decodable>(_ name: String, in folder: URL) throws -> T? {
        guard exists(name, in: folder) else { return nil }
        let fd = open(folder.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw SpendAdmissionError.invalidPolicy }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 32768 else { throw SpendAdmissionError.invalidPolicy }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SpendAdmissionError.invalidPolicy }; offset += count
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func write<T: Encodable>(_ value: T, name: String, in folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        guard data.count <= 32768 else { throw SpendAdmissionError.invalidPolicy }
        let directoryFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw SpendAdmissionError.invalidPolicy }
        defer { Darwin.close(directoryFD) }
        let temporary = ".finance-" + UUID().uuidString.lowercased()
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SpendAdmissionError.invalidPolicy }
        defer { Darwin.close(fd); unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SpendAdmissionError.invalidPolicy }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw SpendAdmissionError.invalidPolicy }
        if fcntl(fd, F_FULLFSYNC) != 0 && errno != EINVAL && errno != ENOTSUP { throw SpendAdmissionError.invalidPolicy }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0, fsync(directoryFD) == 0 else { throw SpendAdmissionError.invalidPolicy }
    }
}
