import AIMApplication
import AIMCore
import Foundation
import Darwin

package enum RuntimePrivacyShutdownError: LocalizedError {
    case preparationPending, shutdownInProgress
    package var errorDescription: String? {
        switch self {
        case .preparationPending: "Normal runtime shutdown is refused while a private-mode change is pending. Finish or explicitly cancel that change before stopping the runtime."
        case .shutdownInProgress: "The runtime is stopping or transferring ownership. Private-mode preparation was refused; network admission remains closed if it was already prepared."
        }
    }
}

package struct RuntimePrivacyControl: Codable, Sendable {
    package enum Action: String, Codable, Sendable { case status, prepare, commit, abort }
    package var action: Action
    package var preparation: AIMNetworkPrivacyPreparation?
    package init(action: Action, preparation: AIMNetworkPrivacyPreparation? = nil) {
        self.action = action; self.preparation = preparation
    }
}
package struct RuntimePrivacyAcknowledgement: Codable, Sendable {
    package enum Phase: String, Codable, Sendable { case status, prepared, committed, aborted }
    package let version: Int
    package let phase: Phase
    package let ownerGeneration: UUID
    package let processID: Int32
    package let preparation: AIMNetworkPrivacyPreparation?
}

/// Local, signed host control only. No mission/tool authorization is granted.
/// A DB generation fence and the live owner are re-read around each await.
package actor RuntimePrivacyOwner {
    private let generation: UUID
    private let repository: SQLiteAgentExecutionRepository
    private var validateLiveOwner: (@Sendable () async throws -> Void)?
    private var quiesce: (@Sendable () async throws -> Void)?
    private var release: (@Sendable () async -> Void)?
    private var normalShutdown: (@Sendable () async throws -> Void)?
    private var preparing: (AIMNetworkPrivacyPreparation, Task<AIMNetworkPrivacyReceipt, Error>)?
    private var receipt: AIMNetworkPrivacyReceipt?
    private var privacyControlsInFlight = 0
    private var normalShutdownInFlight = false
    package init(generation: UUID, repository: SQLiteAgentExecutionRepository) {
        self.generation = generation; self.repository = repository
    }
    package func configure(validateLiveOwner: @escaping @Sendable () async throws -> Void,
        quiesce: @escaping @Sendable () async throws -> Void, release: @escaping @Sendable () async -> Void,
        normalShutdown: @escaping @Sendable () async throws -> Void) {
        self.validateLiveOwner = validateLiveOwner; self.quiesce = quiesce; self.release = release
        self.normalShutdown = normalShutdown
    }
    package func requireNormalShutdown() throws {
        guard !normalShutdownInFlight, privacyControlsInFlight == 0, !AIMNetworkPrivacyAdmission.isPreparing else {
            throw RuntimePrivacyShutdownError.preparationPending
        }
    }
    package func beginNormalShutdown() throws {
        try requireNormalShutdown()
        normalShutdownInFlight = true
    }
    package func endNormalShutdown() { normalShutdownInFlight = false }
    package func shutdownNormally() async throws {
        try requireNormalShutdown()
        guard let normalShutdown else { throw AgentHostTransportError.disconnected }
        try await normalShutdown()
    }
    private func requireOwner() async throws {
        guard let validateLiveOwner else { throw AgentHostTransportError.disconnected }
        try await validateLiveOwner()
        try await repository.requireOwner(generation)
    }
    private func require(_ preparation: AIMNetworkPrivacyPreparation) async throws {
        guard preparation.ownerGeneration == generation else { throw AIMNetworkPrivacyTransactionError.ownerChanged }
        try await requireOwner()
        try AIMNetworkPrivacyAdmission.require(preparation)
    }
    package func handle(_ command: AgentHostCommand) async throws -> Data {
        guard let payload = command.payload, payload.count <= 8192 else { throw AgentHostTransportError.invalidMessage }
        let control = try JSONDecoder().decode(RuntimePrivacyControl.self, from: payload)
        guard !normalShutdownInFlight else { throw RuntimePrivacyShutdownError.shutdownInProgress }
        let protectsAcknowledgement = control.action != .status
        if protectsAcknowledgement { privacyControlsInFlight += 1 }
        defer { if protectsAcknowledgement { privacyControlsInFlight -= 1 } }
        try await requireOwner()
        let phase: RuntimePrivacyAcknowledgement.Phase
        let preparation: AIMNetworkPrivacyPreparation?
        switch control.action {
        case .status:
            preparation = try AIMNetworkPrivacyAdmission.pending(); phase = .status
        case .prepare:
            guard let value = control.preparation else { throw AgentHostTransportError.invalidMessage }
            try await require(value)
            if let pending = preparing {
                guard pending.0 == value else { throw AIMNetworkPrivacyTransactionError.conflictingTransaction }
                receipt = try await pending.1.value
            } else if receipt?.preparation != value {
                let task = Task { [self] in try await performPrepare(value) }
                preparing = (value, task)
                do { receipt = try await task.value; preparing = nil }
                catch { preparing = nil; throw error }
            }
            try await require(value)
            preparation = value; phase = .prepared
        case .commit:
            guard let value = control.preparation, let receipt, receipt.preparation == value else {
                throw AIMNetworkPrivacyTransactionError.invalidReceipt
            }
            try await require(value)
            try await AIMManagedNetworkSession.quiesceDisallowedTasks()
            try await require(value)
            try AIMNetworkPrivacyAdmission.commit(value, ownerReceipt: receipt)
            await release?()
            preparation = value; phase = .committed
        case .abort:
            guard let value = control.preparation else { throw AgentHostTransportError.invalidMessage }
            try await require(value)
            if let pending = preparing {
                guard pending.0 == value else { throw AIMNetworkPrivacyTransactionError.conflictingTransaction }
                _ = try? await pending.1.value; preparing = nil
            }
            try await require(value)
            try AIMNetworkPrivacyAdmission.abort(value)
            receipt = nil; await release?()
            preparation = value; phase = .aborted
        }
        try await requireOwner()
        let value = RuntimePrivacyAcknowledgement(version: 1, phase: phase, ownerGeneration: generation,
            processID: getpid(), preparation: preparation)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    private func performPrepare(_ preparation: AIMNetworkPrivacyPreparation) async throws -> AIMNetworkPrivacyReceipt {
        try await require(preparation)
        guard let quiesce else { throw AgentHostTransportError.disconnected }
        try await quiesce()
        try await AIMManagedNetworkSession.quiesceDisallowedTasks()
        try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()
        try await require(preparation)
        let receipt = AIMNetworkPrivacyReceipt(preparation: preparation, ownerGeneration: generation)
        try AIMNetworkPrivacyAdmission.acknowledgeOwner(receipt)
        try await require(preparation)
        return receipt
    }
}
