import Darwin
import Foundation

public struct AIMNetworkPrivacyPreparation: Codable, Equatable, Sendable {
    public let version: Int
    public let transactionID: UUID
    public let ownerGeneration: UUID?
    public let applicationPID: Int32
    public init(transactionID: UUID = UUID(), ownerGeneration: UUID?, applicationPID: Int32 = getpid()) {
        version = 1; self.transactionID = transactionID
        self.ownerGeneration = ownerGeneration; self.applicationPID = applicationPID
    }
}
public struct AIMNetworkPrivacyReceipt: Codable, Equatable, Sendable {
    public let preparation: AIMNetworkPrivacyPreparation
    public let ownerGeneration: UUID?
    public let processID: Int32
    public init(preparation: AIMNetworkPrivacyPreparation, ownerGeneration: UUID?, processID: Int32 = getpid()) {
        self.preparation = preparation; self.ownerGeneration = ownerGeneration; self.processID = processID
    }
}
public enum AIMNetworkPrivacyTransactionError: LocalizedError, Sendable {
    case transactionRequired, conflictingTransaction, invalidReceipt, ownerChanged, transportStillActive, alreadyCommitted
    public var errorDescription: String? {
        switch self {
        case .transactionRequired: "Application private mode requires a prepared application/runtime transaction."
        case .conflictingTransaction: "Another privacy preparation is pending. Keep admission closed and reconcile its current runtime owner before retrying."
        case .invalidReceipt: "The privacy acknowledgement does not match its transaction, process or owner. Admission remains closed."
        case .ownerChanged: "The runtime owner changed during privacy preparation. Commit was refused."
        case .transportStillActive: "An AIM-managed transport has not completed cancellation. Private mode commit was refused."
        case .alreadyCommitted: "The private-mode transaction already committed; it cannot be reopened by abort."
        }
    }
}

/// Persisted admission fence, distinct from the user-visible committed flag.
/// It is intentionally left closed after a crash or an unknown commit outcome.
public enum AIMNetworkPrivacyAdmission {
    private struct State: Codable {
        var preparation: AIMNetworkPrivacyPreparation
        var applicationReceipt: AIMNetworkPrivacyReceipt?
        var ownerReceipt: AIMNetworkPrivacyReceipt?
        var committed = false
    }
    public static var isPreparing: Bool {
        do { return try readState().map { !$0.committed } ?? false } catch { return true }
    }
    public static var isClosed: Bool {
        do { return try readState() != nil } catch { return true }
    }
    public static func pending() throws -> AIMNetworkPrivacyPreparation? { try readState()?.preparation }
    public static func isCommitted(_ preparation: AIMNetworkPrivacyPreparation) throws -> Bool {
        guard let state = try readState(), state.preparation == preparation else { return false }
        return state.committed
    }
    public static func begin(_ preparation: AIMNetworkPrivacyPreparation) throws {
        guard preparation.version == 1, preparation.applicationPID == getpid(), preparation.applicationPID > 0 else {
            throw AIMNetworkPrivacyTransactionError.invalidReceipt
        }
        try mutate { state in
            if let existing = state {
                if existing.preparation == preparation { return }
                let replacingCommitted = existing.committed && AIMNetworkPrivacyPolicy.isConfiguredEnabled
                let reclaimingDeadApplication = !existing.committed
                    && existing.preparation.transactionID == preparation.transactionID
                    && existing.preparation.ownerGeneration == preparation.ownerGeneration
                    && existing.preparation.applicationPID != getpid()
                    && kill(existing.preparation.applicationPID, 0) != 0 && errno == ESRCH
                guard replacingCommitted || reclaimingDeadApplication else {
                    throw AIMNetworkPrivacyTransactionError.conflictingTransaction
                }
                state = State(preparation: preparation)
            } else { state = State(preparation: preparation) }
        }
        NotificationCenter.default.post(name: AIMNetworkPrivacyPolicy.changedNotification, object: nil)
        AIMManagedNetworkSession.cancelDisallowedTasks()
    }
    public static func require(_ preparation: AIMNetworkPrivacyPreparation) throws {
        guard let state = try readState(), state.preparation == preparation else {
            throw AIMNetworkPrivacyTransactionError.conflictingTransaction
        }
    }
    public static func acknowledgeApplication(_ preparation: AIMNetworkPrivacyPreparation) throws {
        guard preparation.applicationPID == getpid() else { throw AIMNetworkPrivacyTransactionError.invalidReceipt }
        try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()
        try mutate { state in
            guard state?.preparation == preparation, state?.committed == false else { throw AIMNetworkPrivacyTransactionError.invalidReceipt }
            state?.applicationReceipt = AIMNetworkPrivacyReceipt(preparation: preparation, ownerGeneration: nil)
        }
    }
    public static func acknowledgeOwner(_ receipt: AIMNetworkPrivacyReceipt) throws {
        guard receipt.processID == getpid(), let owner = receipt.ownerGeneration,
              receipt.preparation.ownerGeneration == owner else { throw AIMNetworkPrivacyTransactionError.invalidReceipt }
        try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()
        try mutate { state in
            guard state?.preparation == receipt.preparation, state?.committed == false else { throw AIMNetworkPrivacyTransactionError.invalidReceipt }
            state?.ownerReceipt = receipt
        }
    }
    public static func commit(_ preparation: AIMNetworkPrivacyPreparation, ownerReceipt: AIMNetworkPrivacyReceipt?) throws {
        try mutate { state in
            guard var value = state, value.preparation == preparation,
                  value.applicationReceipt?.preparation == preparation,
                  value.applicationReceipt?.processID == preparation.applicationPID else {
                throw AIMNetworkPrivacyTransactionError.invalidReceipt
            }
            if let owner = preparation.ownerGeneration {
                guard let ownerReceipt, ownerReceipt.processID == getpid(), ownerReceipt.ownerGeneration == owner,
                      value.ownerReceipt == ownerReceipt else { throw AIMNetworkPrivacyTransactionError.invalidReceipt }
            } else {
                guard ownerReceipt == nil, preparation.applicationPID == getpid() else { throw AIMNetworkPrivacyTransactionError.invalidReceipt }
            }
            try AIMNetworkPrivacyPolicy.writeConfiguredEnabled(true)
            value.committed = true; state = value
        }
    }
    public static func abort(_ preparation: AIMNetworkPrivacyPreparation) throws {
        try mutate { state in
            guard state?.preparation == preparation else { throw AIMNetworkPrivacyTransactionError.conflictingTransaction }
            guard state?.committed == false, !AIMNetworkPrivacyPolicy.isConfiguredEnabled else {
                throw AIMNetworkPrivacyTransactionError.alreadyCommitted
            }
            state = nil
        }
        NotificationCenter.default.post(name: AIMNetworkPrivacyPolicy.changedNotification, object: nil)
    }
    static func disable() throws {
        try mutate { state in try AIMNetworkPrivacyPolicy.writeConfiguredEnabled(false); state = nil }
        NotificationCenter.default.post(name: AIMNetworkPrivacyPolicy.changedNotification, object: nil)
    }
    private static func folder() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AIMNetworkPrivacyError.barrierUnavailable
        }
        let folder = support.appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/Privacy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AIMNetworkPrivacyError.barrierUnavailable
        }
        return folder
    }
    private static func withLock<T>(exclusive: Bool, body: (URL) throws -> T) throws -> T {
        let folder = try folder()
        let descriptor = open(folder.appendingPathComponent("network-admission-v1.lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AIMNetworkPrivacyError.barrierUnavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            throw AIMNetworkPrivacyError.barrierUnavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body(folder.appendingPathComponent("network-admission-v1.json"))
    }
    private static func load(_ url: URL) throws -> State? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8192 else {
            throw AIMNetworkPrivacyError.barrierUnavailable
        }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        guard state.preparation.version == 1, state.preparation.applicationPID > 0 else {
            throw AIMNetworkPrivacyTransactionError.invalidReceipt
        }
        return state
    }
    private static func readState() throws -> State? { try withLock(exclusive: false) { try load($0) } }
    private static func mutate(_ body: (inout State?) throws -> Void) throws {
        try withLock(exclusive: true) { url in
            var state = try load(url)
            try body(&state)
            if let state {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                try encoder.encode(state).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
