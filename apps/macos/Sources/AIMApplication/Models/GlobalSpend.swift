import Foundation

public enum SpendPeriod: String, Codable, Hashable, Sendable {
    case day, calendarMonth, envelope
}

public enum SpendBudgetProtection: String, CaseIterable, Codable, Sendable {
    case estimated, strict
}

/// Amounts are canonical decimal USD strings; no binary floating-point money.
public struct GlobalSpendPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var limitUSD: String?
    public var period: SpendPeriod
    public var timeZoneID: String
    /// Persisted name retained for compatibility with v52. Strict protection
    /// covers both unbounded web requests and unpriced historical attempts.
    /// Nil in earlier policies means estimated protection.
    public var requiresVerifiedWebSearch: Bool?
    public var protection: SpendBudgetProtection {
        get { requiresVerifiedWebSearch == true ? .strict : .estimated }
        set { requiresVerifiedWebSearch = newValue == .strict }
    }

    public init(enabled: Bool = false, limitUSD: String? = nil,
                period: SpendPeriod = .calendarMonth,
                timeZoneID: String = TimeZone.current.identifier, requiresVerifiedWebSearch: Bool? = false) {
        self.enabled = enabled
        self.limitUSD = limitUSD
        self.period = period
        self.timeZoneID = timeZoneID
        self.requiresVerifiedWebSearch = requiresVerifiedWebSearch
    }
}

public enum SpendAttemptState: String, Codable, Sendable {
    case reserved, sent, unknown, confirmed, notSent
}

public struct SpendAttempt: Codable, Sendable, Identifiable {
    public let id: UUID
    public let provider: String
    public let modelID: String
    public let feature: String
    public let conversationID: UUID?
    public let maximumUSD: String?
    public var estimatedUSD: String? = nil
    public let actualUSD: String?
    public let state: SpendAttemptState
    public let isException: Bool
    public let createdAt: Date
}

public struct SpendSnapshot: Codable, Sendable {
    public let policy: GlobalSpendPolicy
    public let countedUSD: String
    public let confirmedUSD: String
    public let reservedUSD: String
    public var estimatedUSD: String = "0"
    public let unknownAttempts: Int
    public let periodStart: Date?
    public let periodEnd: Date?
    public init(policy: GlobalSpendPolicy, countedUSD: String, confirmedUSD: String, reservedUSD: String,
                unknownAttempts: Int, periodStart: Date?, periodEnd: Date?, estimatedUSD: String = "0") {
        self.policy = policy; self.countedUSD = countedUSD; self.confirmedUSD = confirmedUSD
        self.reservedUSD = reservedUSD; self.unknownAttempts = unknownAttempts
        self.periodStart = periodStart; self.periodEnd = periodEnd; self.estimatedUSD = estimatedUSD
    }
    private enum CodingKeys: String, CodingKey {
        case policy, countedUSD, confirmedUSD, reservedUSD, estimatedUSD, unknownAttempts, periodStart, periodEnd
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        policy = try values.decode(GlobalSpendPolicy.self, forKey: .policy)
        countedUSD = try values.decode(String.self, forKey: .countedUSD)
        confirmedUSD = try values.decode(String.self, forKey: .confirmedUSD)
        reservedUSD = try values.decode(String.self, forKey: .reservedUSD)
        estimatedUSD = try values.decodeIfPresent(String.self, forKey: .estimatedUSD) ?? "0"
        unknownAttempts = try values.decode(Int.self, forKey: .unknownAttempts)
        periodStart = try values.decodeIfPresent(Date.self, forKey: .periodStart)
        periodEnd = try values.decodeIfPresent(Date.self, forKey: .periodEnd)
    }
}

public enum SpendBreakdownDimension: String, Sendable {
    case provider, model, feature
}

/// Grouped billing metadata for the policy's current period. Amounts remain
/// decimal USD strings; unknown attempts never masquerade as zero-cost usage.
public struct SpendBreakdownRow: Sendable, Identifiable {
    public let id: String
    public var estimatedUSD: String = "0"
    public let dimension: SpendBreakdownDimension
    public let label: String
    public let confirmedUSD: String
    public let reservedUSD: String
    public let unknownAttempts: Int
    public let attemptCount: Int
    public let exceptionCount: Int

}

public struct SpendBreakdown: Sendable {
    public let providers: [SpendBreakdownRow]
    public let models: [SpendBreakdownRow]
    public let features: [SpendBreakdownRow]
    public let periodStart: Date?
    public let periodEnd: Date?
}

public struct SpendCostCorrection: Sendable, Identifiable {
    public let id: UUID
    public let attemptID: UUID
    public let provider: String
    public let modelID: String
    public let feature: String
    public let previousUSD: String
    public let correctedUSD: String
    public let sourceID: String
    public let occurredAt: Date
}

/// Host-owned question for one billable attempt. The model never chooses its
/// own exception or widens this decision to a retry.
public struct PendingSpendException: Sendable, Identifiable {
    public let id: UUID
    public let provider: String
    public let modelID: String
    public let feature: String
    public let conversationID: UUID?
    public let maximumUSD: String?
    public let snapshot: SpendSnapshot
}

public enum SpendAdmissionError: LocalizedError, Equatable, Sendable {
    case invalidAmount, invalidPolicy, duplicateAttempt, duplicateCorrection, unknownBound, limitReached, exceptionDeclined, invalidTransition

    public var errorDescription: String? {
        switch self {
        case .invalidAmount: "The USD amount is not a valid nonnegative decimal value."
        case .invalidPolicy: "The global spending policy is incomplete or invalid."
        case .duplicateAttempt: "This billable attempt was already admitted. It cannot be sent twice."
        case .duplicateCorrection: "This billing correction source was already applied to the attempt."
        case .unknownBound: "AIM cannot bound this charge under the active global limit. This attempt needs an explicit exception."
        case .limitReached: "The global spending limit has no room for this attempt."
        case .exceptionDeclined: "This billable attempt was not authorized and was not sent."
        case .invalidTransition: "The attempt's billing state cannot make that transition."
        }
    }
}

public protocol GlobalSpendLedger: Sendable {
    /// Accounting alone is not a spending cap. Scoped ledgers override this
    /// when a mission/run cap is active even if the global budget is disabled.
    func requiresVerifiedBound(at date: Date) async throws -> Bool
    func allowsEstimatedWebSearch(at date: Date) async throws -> Bool
    func admit(id: UUID, provider: String, modelID: String, feature: String,
               conversationID: UUID?, maximumUSD: String?, exception: Bool, at date: Date) async throws -> SpendAttempt
    /// An execution/run ceiling cannot inherit estimated personal-history admission.
    func admitRequiringReconciledHistory(id: UUID, provider: String, modelID: String, feature: String,
                                        conversationID: UUID?, maximumUSD: String?, exception: Bool, at date: Date) async throws -> SpendAttempt
    /// Estimates are separate from verified maxima. Capped/custom ledgers refuse by default.
    func admitEstimated(id: UUID, provider: String, modelID: String, feature: String,
                        conversationID: UUID?, estimatedUSD: String, at date: Date) async throws -> SpendAttempt
    func completeEstimated(id: UUID, estimatedUSD: String?, at date: Date) async throws
    func markSent(id: UUID, at date: Date) async throws
    func markNotSent(id: UUID, at date: Date) async throws
    func markUnknown(id: UUID) async throws
    /// The local operation ended, but its provider did not report a charge. This is
    /// not a zero receipt or permission to release a managed execution ceiling.
    func markCompletedUnknown(id: UUID, at date: Date) async throws
    func reconcile(id: UUID, actualUSD: String, at date: Date) async throws
    func snapshot(at date: Date) async throws -> SpendSnapshot
    /// True when an attempt refused for lack of room would fit once the requests already sent
    /// settle, so it can wait for them instead of failing.
    func fitsOnceInFlightSettle(maximumUSD: String?, at date: Date) async throws -> Bool
}

public extension GlobalSpendLedger {
    func admitEstimated(id: UUID, provider: String, modelID: String, feature: String,
                        conversationID: UUID?, estimatedUSD: String, at date: Date) async throws -> SpendAttempt {
        throw SpendAdmissionError.unknownBound
    }
    func completeEstimated(id: UUID, estimatedUSD: String?, at date: Date) async throws {
        try await markCompletedUnknown(id: id, at: date)
    }
    // Custom ledgers remain conservative unless they implement completed accounting.
    func markCompletedUnknown(id: UUID, at date: Date) async throws { try await markUnknown(id: id) }

    func admitRequiringReconciledHistory(id: UUID, provider: String, modelID: String, feature: String,
                                        conversationID: UUID?, maximumUSD: String?, exception: Bool, at date: Date) async throws -> SpendAttempt {
        guard try await snapshot(at: date).unknownAttempts == 0 else { throw SpendAdmissionError.unknownBound }
        return try await admit(id: id, provider: provider, modelID: modelID, feature: feature,
            conversationID: conversationID, maximumUSD: maximumUSD, exception: exception, at: date)
    }
    // Custom/run/peer ledgers must opt in explicitly; a remote budget snapshot
    // alone cannot widen the execution's spending authorization.
    func allowsEstimatedWebSearch(at date: Date) async throws -> Bool { false }
    func requiresVerifiedBound(at date: Date) async throws -> Bool {
        try await snapshot(at: date).policy.enabled
    }
    func fitsOnceInFlightSettle(maximumUSD: String?, at date: Date) async throws -> Bool { false }
}
