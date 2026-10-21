import Foundation

/// Parent and children share one durable admission scope, including compaction.
public struct ExecutionScopedSpendLedger: GlobalSpendLedger {
    private let ledger: SQLiteGlobalSpendLedger
    private let executionID: UUID
    private let owner: UUID
    private let capUSD: String?
    public init(ledger: SQLiteGlobalSpendLedger, executionID: UUID, owner: UUID, capUSD: String?) {
        self.ledger = ledger; self.executionID = executionID; self.owner = owner; self.capUSD = capUSD
    }
    public func admit(id: UUID, provider: String, modelID: String, feature: String, conversationID: UUID?, maximumUSD: String?, exception: Bool, at date: Date) async throws -> SpendAttempt {
        try await ledger.admitExecution(id: id, executionID: executionID, owner: owner, capUSD: capUSD,
            provider: provider, modelID: modelID, feature: feature, conversationID: conversationID, maximumUSD: maximumUSD, exception: exception, at: date)
    }
    public func admitEstimated(id: UUID, provider: String, modelID: String, feature: String,
                               conversationID: UUID?, estimatedUSD: String, at date: Date) async throws -> SpendAttempt {
        guard capUSD == nil else { throw SpendAdmissionError.unknownBound }
        return try await ledger.admitExecutionEstimated(id: id, executionID: executionID, owner: owner, provider: provider,
            modelID: modelID, feature: feature, conversationID: conversationID, estimatedUSD: estimatedUSD, at: date)
    }
    public func completeEstimated(id: UUID, estimatedUSD: String?, at date: Date) async throws {
        try await ledger.completeEstimated(id: id, estimatedUSD: estimatedUSD, at: date, executionID: executionID, owner: owner)
    }
    public func markSent(id: UUID, at date: Date) async throws { try await ledger.markExecutionSent(id: id, executionID: executionID, owner: owner, at: date) }
    public func markNotSent(id: UUID, at date: Date) async throws { try await ledger.finalizeExecutionAttempt(id: id, executionID: executionID, owner: owner, state: .notSent, at: date) }
    public func markUnknown(id: UUID) async throws { try await ledger.finalizeExecutionAttempt(id: id, executionID: executionID, owner: owner, state: .unknown) }
    public func markCompletedUnknown(id: UUID, at date: Date) async throws {
        try await ledger.finalizeExecutionAttempt(id: id, executionID: executionID, owner: owner, state: .unknown, at: date, completed: true)
    }
    public func reconcile(id: UUID, actualUSD: String, at date: Date) async throws { try await ledger.finalizeExecutionAttempt(id: id, executionID: executionID, owner: owner, state: .confirmed, actualUSD: actualUSD, at: date) }
    public func snapshot(at date: Date) async throws -> SpendSnapshot { try await ledger.executionSnapshot(executionID, at: date) }
    public func fitsOnceInFlightSettle(maximumUSD: String?, at date: Date) async throws -> Bool {
        try await ledger.fitsOnceInFlightSettle(maximumUSD: maximumUSD, executionID: executionID, capUSD: capUSD, at: date)
    }
    public func allowsEstimatedWebSearch(at date: Date) async throws -> Bool {
        // A mission cap is an execution authorization, not merely a personal estimate.
        if capUSD != nil { return false }
        return try await ledger.allowsEstimatedWebSearch(at: date)
    }
    public func requiresVerifiedBound(at date: Date) async throws -> Bool {
        if capUSD != nil { return true }
        return try await ledger.requiresVerifiedBound(at: date)
    }
}
