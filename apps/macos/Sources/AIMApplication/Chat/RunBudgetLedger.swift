import Foundation

/// A per-run ceiling layered on the global ledger: every attempt is still
/// recorded globally, but once this run's confirmed cost reaches its cap (or
/// too many attempts end with an unknown cost) no further request is admitted.
public actor RunBudgetLedger: GlobalSpendLedger {
    private let inner: any GlobalSpendLedger
    private let capUSD: Decimal?
    private let maximumUnknownAttempts: Int?
    private var confirmed: Decimal = 0
    private var unknown = 0
    private var admitted: Set<UUID> = []
    private var reserved: [UUID: Decimal] = [:]
    private var unknownIDs: Set<UUID> = []

    public init(inner: any GlobalSpendLedger, capUSD: Decimal?, maximumUnknownAttempts: Int? = nil) {
        self.inner = inner
        self.capUSD = capUSD
        self.maximumUnknownAttempts = maximumUnknownAttempts
    }

    public var confirmedUSD: Decimal { confirmed }
    public var unknownAttempts: Int { unknown }
    public var exhausted: Bool {
        capUSD.map { confirmed >= $0 || maximumUnknownAttempts.map { unknown >= $0 } == true } ?? false
    }

    public func admit(id: UUID, provider: String, modelID: String, feature: String, conversationID: UUID?,
                      maximumUSD: String?, exception: Bool, at date: Date) async throws -> SpendAttempt {
        guard !exhausted else { throw SpendAdmissionError.limitReached }
        guard !admitted.contains(id), reserved[id] == nil else { throw SpendAdmissionError.duplicateAttempt }
        var provisional: Decimal?
        if let capUSD {
            guard let value = maximumUSD, let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
                  !amount.isNaN, amount >= 0 else { throw SpendAdmissionError.unknownBound }
            guard confirmed + reserved.values.reduce(0, +) + amount <= capUSD else { throw SpendAdmissionError.limitReached }
            provisional = amount
        }
        // Reserve before awaiting the global ledger so concurrent children
        // cannot each admit against the same remaining run allowance.
        reserved[id] = provisional
        let attempt: SpendAttempt
        do {
            if capUSD != nil {
                attempt = try await inner.admitRequiringReconciledHistory(id: id, provider: provider, modelID: modelID, feature: feature,
                    conversationID: conversationID, maximumUSD: maximumUSD, exception: exception, at: date)
            } else {
                attempt = try await inner.admit(id: id, provider: provider, modelID: modelID, feature: feature,
                    conversationID: conversationID, maximumUSD: maximumUSD, exception: exception, at: date)
            }
        } catch { reserved[id] = nil; throw error }
        admitted.insert(id)
        if let value = maximumUSD, let amount = Decimal(string: value) { reserved[id] = amount }
        return attempt
    }

    public func admitEstimated(id: UUID, provider: String, modelID: String, feature: String,
                               conversationID: UUID?, estimatedUSD: String, at date: Date) async throws -> SpendAttempt {
        guard capUSD == nil, maximumUnknownAttempts == nil else { throw SpendAdmissionError.unknownBound }
        return try await inner.admitEstimated(id: id, provider: provider, modelID: modelID, feature: feature,
            conversationID: conversationID, estimatedUSD: estimatedUSD, at: date)
    }
    public func completeEstimated(id: UUID, estimatedUSD: String?, at date: Date) async throws {
        guard capUSD == nil, maximumUnknownAttempts == nil else { throw SpendAdmissionError.unknownBound }
        try await inner.completeEstimated(id: id, estimatedUSD: estimatedUSD, at: date)
    }
    public func markSent(id: UUID, at date: Date) async throws { try await inner.markSent(id: id, at: date) }
    public func markNotSent(id: UUID, at date: Date) async throws {
        try await inner.markNotSent(id: id, at: date)
        reserved[id] = nil
    }

    public func markUnknown(id: UUID) async throws {
        try await inner.markUnknown(id: id)
        if admitted.contains(id), unknownIDs.insert(id).inserted { unknown += 1 }
    }

    public func markCompletedUnknown(id: UUID, at date: Date) async throws {
        try await inner.markCompletedUnknown(id: id, at: date)
        // Preserve this mission's conservative unknown exposure and ceiling.
        if admitted.contains(id), unknownIDs.insert(id).inserted { unknown += 1 }
    }

    public func reconcile(id: UUID, actualUSD: String, at date: Date) async throws {
        try await inner.reconcile(id: id, actualUSD: actualUSD, at: date)
        if admitted.remove(id) != nil, let amount = Decimal(string: actualUSD) {
            confirmed += amount; reserved[id] = nil
            if unknownIDs.remove(id) != nil { unknown -= 1 }
        }
    }

    public func snapshot(at date: Date) async throws -> SpendSnapshot { try await inner.snapshot(at: date) }
    public func fitsOnceInFlightSettle(maximumUSD: String?, at date: Date) async throws -> Bool {
        guard !exhausted else { return false }
        if let capUSD {
            guard let value = maximumUSD, let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
                  confirmed + amount <= capUSD else { return false }
            if !reserved.isEmpty, confirmed + reserved.values.reduce(0, +) + amount > capUSD { return true }
        }
        return try await inner.fitsOnceInFlightSettle(maximumUSD: maximumUSD, at: date)
    }
    public func requiresVerifiedBound(at date: Date) async throws -> Bool {
        if capUSD != nil { return true }
        return try await inner.requiresVerifiedBound(at: date)
    }
}
