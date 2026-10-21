import AIMCore
import Foundation

/// Wraps exactly one provider attempt. With no installed ledger, existing
/// injected/test transports keep their current behavior. A sent request whose
/// receipt is absent remains unknown, including after timeout or cancellation.
public struct BillableRequestMeter: Sendable {
    private let ledger: (any GlobalSpendLedger)?
    private let exceptions: SpendExceptionBroker?

    public init(ledger: (any GlobalSpendLedger)? = nil, exceptions: SpendExceptionBroker? = nil) {
        self.ledger = ledger
        self.exceptions = exceptions
    }

    /// Preserve accounting when limits are off without changing the provider's
    /// output or routing. Admission itself rechecks the policy before sending.
    public func requiresVerifiedBound() async throws -> Bool {
        try await ledger?.requiresVerifiedBound(at: .now) ?? false
    }

    public func allowsEstimatedWebSearch() async throws -> Bool {
        try await ledger?.allowsEstimatedWebSearch(at: .now) ?? true
    }

    /// Requests running side by side (an agent and its sub-agents) each reserve their worst case.
    /// When only those reservations stand in the way, wait for them to settle instead of failing:
    /// they usually cost a small part of what they reserved.
    private func admitWaitingForRoom(_ ledger: any GlobalSpendLedger, id: UUID, provider: String, modelID: String,
                                     feature: String, conversationID: UUID?, maximumUSD: String?) async throws -> SpendAttempt {
        let deadline = Date.now.addingTimeInterval(Self.inFlightWaitSeconds)
        while true {
            do {
                return try await ledger.admit(id: id, provider: provider, modelID: modelID, feature: feature,
                    conversationID: conversationID, maximumUSD: maximumUSD, exception: false, at: .now)
            } catch SpendAdmissionError.limitReached {
                guard Date.now < deadline, !Task.isCancelled,
                      try await ledger.fitsOnceInFlightSettle(maximumUSD: maximumUSD, at: .now) else {
                    throw SpendAdmissionError.limitReached
                }
                try await Task.sleep(for: .milliseconds(Self.inFlightPollMilliseconds))
            }
        }
    }
    static let inFlightWaitSeconds: TimeInterval = 15 * 60
    static let inFlightPollMilliseconds = 500

    public func perform<Value: Sendable>(provider: String, modelID: String, feature: String,
                               conversationID: UUID? = nil, maximumUSD: String? = nil, attemptID: UUID? = nil,
                               completedWithoutReceipt: Bool = false, estimatedUSD: String? = nil,
                               estimatedReceiptUSD: @Sendable (Value) -> String? = { _ in nil },
                               receiptUSD: @Sendable (Value) -> String? = { _ in nil },
                               operation: @Sendable () async throws -> Value) async throws -> Value {
        // Local models run on this Mac: nothing is billed, nothing needs admission.
        guard let ledger, provider != ChatProvider.local.rawValue else { return try await operation() }
        // An admitted external pipe request supplies its durable wire identity.
        // Native SQLite admission rejects an existing ID before any send; this
        // parameter does not grant replay or idempotency to a provider API.
        let id = attemptID ?? UUID()
        let attempt: SpendAttempt
        do {
            attempt = try await admitWaitingForRoom(ledger, id: id, provider: provider, modelID: modelID,
                feature: feature, conversationID: conversationID, maximumUSD: maximumUSD)
        } catch SpendAdmissionError.unknownBound {
            if let estimatedUSD, try await ledger.allowsEstimatedWebSearch(at: .now) {
                attempt = try await ledger.admitEstimated(id: id, provider: provider, modelID: modelID, feature: feature,
                    conversationID: conversationID, estimatedUSD: estimatedUSD, at: .now)
            } else {
            guard let exceptions else { throw SpendAdmissionError.unknownBound }
            let snapshot = try await ledger.snapshot(at: .now)
            let request = PendingSpendException(id: id, provider: provider, modelID: modelID,
                feature: feature, conversationID: conversationID, maximumUSD: maximumUSD,
                snapshot: snapshot)
            guard await exceptions.request(request), !Task.isCancelled else {
                throw SpendAdmissionError.exceptionDeclined
            }
            // Same ID, admitted once after the host's one-attempt decision.
            // A retry of the provider operation gets a new ID and must ask again.
            attempt = try await ledger.admit(id: id, provider: provider, modelID: modelID,
                feature: feature, conversationID: conversationID, maximumUSD: maximumUSD,
                exception: true, at: .now)
            }
        }
        guard attempt.id == id, attempt.state == .reserved else { throw SpendAdmissionError.duplicateAttempt }
        do {
            try await ledger.markSent(id: attempt.id, at: .now)
        } catch {
            try? await ledger.markNotSent(id: attempt.id, at: .now)
            throw error
        }
        do {
            let value = try await operation()
            if let amount = receiptUSD(value) {
                try await ledger.reconcile(id: attempt.id, actualUSD: amount, at: .now)
            } else if let estimate = estimatedReceiptUSD(value) ?? attempt.estimatedUSD {
                try await ledger.completeEstimated(id: attempt.id, estimatedUSD: estimate, at: .now)
            } else if completedWithoutReceipt {
                try await ledger.markCompletedUnknown(id: attempt.id, at: .now)
            } else {
                try await ledger.markUnknown(id: attempt.id)
            }
            return value
        } catch {
            // The request crossed the send boundary. A cancellation, HTTP
            // failure or malformed response is not proof of a zero charge.
            if completedWithoutReceipt { try? await ledger.markCompletedUnknown(id: attempt.id, at: .now) }
            else { try? await ledger.markUnknown(id: attempt.id) }
            throw error
        }
    }
}
