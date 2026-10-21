import Foundation
import GRDB

/// Admission and reconciliation share one SQLite write transaction across all
/// AIM features. Nothing in this actor reads prompts, captures or credentials.
public actor SQLiteGlobalSpendLedger: GlobalSpendLedger {
    private let database: AIMDatabase
    private static let usdLocale = Locale(identifier: "en_US_POSIX")

    public init(database: AIMDatabase) { self.database = database }

    public func policy() throws -> GlobalSpendPolicy {
        try database.pool.read { db in try Self.readPolicy(db) }
    }

    public func allowsEstimatedWebSearch(at date: Date) async throws -> Bool {
        try policy().requiresVerifiedWebSearch != true
    }

    public func configure(_ policy: GlobalSpendPolicy) throws {
        guard TimeZone(identifier: policy.timeZoneID) != nil else { throw SpendAdmissionError.invalidPolicy }
        if policy.enabled {
            guard let raw = policy.limitUSD, let limit = Self.amount(raw), limit > 0 else {
                throw SpendAdmissionError.invalidPolicy
            }
        } else if let raw = policy.limitUSD, Self.amount(raw) == nil {
            throw SpendAdmissionError.invalidPolicy
        }
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO globalSpendPolicy (id, enabled, limitUSD, period, timeZoneID, updatedAt, requiresVerifiedWebSearch)
                VALUES (1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled, limitUSD=excluded.limitUSD,
                    period=excluded.period, timeZoneID=excluded.timeZoneID, updatedAt=excluded.updatedAt,
                    requiresVerifiedWebSearch=excluded.requiresVerifiedWebSearch
                """, arguments: [policy.enabled, policy.limitUSD, policy.period.rawValue,
                                   policy.timeZoneID, Date.now, policy.requiresVerifiedWebSearch == true])
        }
    }

    /// `exception` is accepted only from a host UI decision for this exact ID.
    /// Callers must invoke this before sending a request and then mark it sent.
    public func admit(id: UUID = UUID(), provider: String, modelID: String, feature: String,
                      conversationID: UUID? = nil, maximumUSD: String?, exception: Bool = false,
                      at date: Date = .now) throws -> SpendAttempt {
        try admitImpl(id: id, provider: provider, modelID: modelID, feature: feature, conversationID: conversationID,
                      maximumUSD: maximumUSD, exception: exception, at: date)
    }
    public func admitRequiringReconciledHistory(id: UUID, provider: String, modelID: String, feature: String,
                                               conversationID: UUID?, maximumUSD: String?, exception: Bool, at date: Date) async throws -> SpendAttempt {
        try admitImpl(id: id, provider: provider, modelID: modelID, feature: feature, conversationID: conversationID,
                      maximumUSD: maximumUSD, exception: exception, at: date, requireReconciledHistory: true)
    }
    public func admitExecution(id: UUID, executionID: UUID, owner: UUID, capUSD: String?, provider: String,
                               modelID: String, feature: String, conversationID: UUID?, maximumUSD: String?,
                               exception: Bool, at date: Date) throws -> SpendAttempt {
        try admitImpl(id: id, provider: provider, modelID: modelID, feature: feature, conversationID: conversationID,
                      maximumUSD: maximumUSD, exception: exception, at: date, executionID: executionID, owner: owner, capUSD: capUSD)
    }
    public func admitEstimated(id: UUID, provider: String, modelID: String, feature: String,
                               conversationID: UUID?, estimatedUSD: String, at date: Date) async throws -> SpendAttempt {
        try admitImpl(id: id, provider: provider, modelID: modelID, feature: feature, conversationID: conversationID,
                      maximumUSD: nil, exception: false, at: date, estimatedUSD: estimatedUSD)
    }
    public func admitExecutionEstimated(id: UUID, executionID: UUID, owner: UUID, provider: String,
                                       modelID: String, feature: String, conversationID: UUID?, estimatedUSD: String, at date: Date) throws -> SpendAttempt {
        try admitImpl(id: id, provider: provider, modelID: modelID, feature: feature, conversationID: conversationID,
                      maximumUSD: nil, exception: false, at: date, executionID: executionID, owner: owner, estimatedUSD: estimatedUSD)
    }
    public func completeEstimated(id: UUID, estimatedUSD: String?, at date: Date, executionID: UUID? = nil, owner: UUID? = nil) throws {
        if let estimatedUSD, Self.amount(estimatedUSD) == nil { throw SpendAdmissionError.invalidAmount }
        try database.pool.write { db in
            if let executionID, let owner {
                try Self.executionFence(db, executionID: executionID, owner: owner, admitting: false)
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentExecutionSpend WHERE attemptID=? AND executionID=? AND ownerGeneration=?",
                    arguments: [id.uuidString, executionID.uuidString, owner.uuidString]) == 1 else { throw ExecutionStoreError.staleOwner }
            }
            try db.execute(sql: "UPDATE spendAttempts SET state='unknown',estimatedUSD=COALESCE(?,estimatedUSD),finalizedAt=? WHERE id=? AND state='sent'",
                arguments: [estimatedUSD, date, id.uuidString])
            guard db.changesCount == 1 else { throw SpendAdmissionError.invalidTransition }
        }
    }
    // Exact protocol witness; the scoped variant retains its owner fence.
    public func completeEstimated(id: UUID, estimatedUSD: String?, at date: Date) async throws {
        try completeEstimated(id: id, estimatedUSD: estimatedUSD, at: date, executionID: nil, owner: nil)
    }
    private func admitImpl(id: UUID, provider: String, modelID: String, feature: String,
                           conversationID: UUID?, maximumUSD: String?, exception: Bool, at date: Date,
                           executionID: UUID? = nil, owner: UUID? = nil, capUSD: String? = nil,
                           requireReconciledHistory: Bool = false, estimatedUSD: String? = nil) throws -> SpendAttempt {
        guard Self.validLabel(provider, maximum: 100), Self.validLabel(modelID, maximum: 255),
              Self.validLabel(feature, maximum: 100) else { throw SpendAdmissionError.invalidPolicy }
        let bound: Decimal?
        if let maximumUSD {
            guard let parsed = Self.amount(maximumUSD) else { throw SpendAdmissionError.invalidAmount }
            bound = parsed
        } else { bound = nil }
        let estimate: Decimal?
        if let estimatedUSD {
            guard let parsed = Self.amount(estimatedUSD), bound == nil, capUSD == nil, !requireReconciledHistory else { throw SpendAdmissionError.invalidAmount }
            estimate = parsed
        } else { estimate = nil }
        return try database.pool.write { db in
            if let executionID, let owner {
                try Self.executionFence(db, executionID: executionID, owner: owner, admitting: true)
                if let capUSD {
                    guard let cap = Self.amount(capUSD), cap > 0 else { throw SpendAdmissionError.invalidAmount }
                    guard let bound else { throw SpendAdmissionError.unknownBound }
                    let usage = try Self.executionUsage(db, executionID: executionID)
                    guard !usage.unknown else { throw SpendAdmissionError.unknownBound }
                    guard usage.counted + bound <= cap else { throw SpendAdmissionError.limitReached }
                }
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spendAttempts WHERE id = ?",
                                   arguments: [id.uuidString]) == 0 else { throw SpendAdmissionError.duplicateAttempt }
            let policy = try Self.readPolicy(db)
            if requireReconciledHistory || (executionID != nil && capUSD != nil) {
                let usage = try Self.usage(db, policy: policy, at: date)
                guard !usage.unknown else { throw SpendAdmissionError.unknownBound }
            }
            if policy.enabled && !exception {
                if policy.protection == .strict, estimate != nil { throw SpendAdmissionError.unknownBound }
                guard let quote = bound ?? estimate else { throw SpendAdmissionError.unknownBound }
                let usage = try Self.usage(db, policy: policy, at: date)
                // An estimated personal budget counts known charges and all
                // reservations. Unpriced history stays unknown in the ledger
                // and reports, rather than blocking that profile indefinitely.
                // Managed execution/Remote admission remains fail-closed.
                guard !usage.unsettledUnknown else { throw SpendAdmissionError.unknownBound }
                if policy.protection == .strict || capUSD != nil {
                    guard !usage.unknown else { throw SpendAdmissionError.unknownBound }
                }
                guard let rawLimit = policy.limitUSD, let limit = Self.amount(rawLimit),
                      usage.counted + quote <= limit else { throw SpendAdmissionError.limitReached }
            }
            try db.execute(sql: """
                INSERT INTO spendAttempts
                (id, provider, modelID, feature, conversationID, maximumUSD, estimatedUSD, actualUSD,
                 state, isException, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 'reserved', ?, ?)
                """, arguments: [id.uuidString, provider, modelID, feature,
                                   conversationID?.uuidString, maximumUSD, estimatedUSD, exception, date])
            if let executionID, let owner {
                try db.execute(sql: "INSERT INTO agentExecutionSpend(attemptID,executionID,ownerGeneration) VALUES(?,?,?)",
                               arguments: [id.uuidString, executionID.uuidString, owner.uuidString])
            }
            return SpendAttempt(id: id, provider: provider, modelID: modelID, feature: feature,
                conversationID: conversationID, maximumUSD: maximumUSD, estimatedUSD: estimatedUSD, actualUSD: nil,
                state: .reserved, isException: exception, createdAt: date)
        }
    }

    /// Whether a refused attempt would fit once the requests already on their way settle. Their
    /// reservations are worst-case bounds; most end far below them, so the attempt can wait.
    public func fitsOnceInFlightSettle(maximumUSD: String?, executionID: UUID? = nil, capUSD: String? = nil,
                                       at date: Date = .now) throws -> Bool {
        guard let maximumUSD, let bound = Self.amount(maximumUSD) else { return false }
        return try database.pool.read { db in
            var inFlight = Decimal.zero
            if let executionID, let capUSD, let cap = Self.amount(capUSD) {
                let usage = try Self.executionUsage(db, executionID: executionID)
                let pending = try Self.inFlight(db, executionID: executionID)
                guard !usage.unknown, usage.counted - pending + bound <= cap else { return false }
                inFlight += pending
            }
            let policy = try Self.readPolicy(db)
            if policy.enabled {
                let usage = try Self.usage(db, policy: policy, at: date)
                let pending = try Self.inFlight(db, interval: Self.interval(policy: policy, at: date))
                guard !usage.unsettledUnknown,
                      !(usage.unknown && (policy.protection == .strict || capUSD != nil)),
                      let raw = policy.limitUSD, let limit = Self.amount(raw),
                      usage.counted - pending + bound <= limit else { return false }
                inFlight += pending
            }
            return inFlight > 0
        }
    }

    public func fitsOnceInFlightSettle(maximumUSD: String?, at date: Date) throws -> Bool {
        try fitsOnceInFlightSettle(maximumUSD: maximumUSD, executionID: nil, capUSD: nil, at: date)
    }

    private static func inFlight(_ db: Database, executionID: UUID? = nil, interval: DateInterval? = nil) throws -> Decimal {
        let rows: [Row]
        if let executionID {
            rows = try Row.fetchAll(db, sql: "SELECT COALESCE(a.maximumUSD,a.estimatedUSD) AS maximumUSD FROM spendAttempts a JOIN agentExecutionSpend e ON e.attemptID=a.id WHERE e.executionID=? AND a.state IN ('reserved','sent')",
                                    arguments: [executionID.uuidString])
        } else if let interval {
            rows = try Row.fetchAll(db, sql: "SELECT COALESCE(maximumUSD,estimatedUSD) AS maximumUSD FROM spendAttempts WHERE createdAt >= ? AND createdAt < ? AND state IN ('reserved','sent')",
                                    arguments: [interval.start, interval.end])
        } else {
            rows = try Row.fetchAll(db, sql: "SELECT COALESCE(maximumUSD,estimatedUSD) AS maximumUSD FROM spendAttempts WHERE state IN ('reserved','sent')")
        }
        return rows.reduce(Decimal.zero) { total, row in
            let raw: String? = row["maximumUSD"]
            return total + (raw.flatMap(amount) ?? 0)
        }
    }

    public func markExecutionSent(id: UUID, executionID: UUID, owner: UUID, at date: Date) throws {
        try database.pool.write { db in
            try Self.executionFence(db, executionID: executionID, owner: owner, admitting: true)
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentExecutionSpend WHERE attemptID=? AND executionID=? AND ownerGeneration=?",
                                   arguments: [id.uuidString, executionID.uuidString, owner.uuidString]) == 1 else { throw ExecutionStoreError.staleOwner }
            try db.execute(sql: "UPDATE spendAttempts SET state='sent',sentAt=? WHERE id=? AND state='reserved'", arguments: [date, id.uuidString])
            guard db.changesCount == 1 else { throw SpendAdmissionError.invalidTransition }
        }
    }
    public func executionSnapshot(_ executionID: UUID, at date: Date = .now) throws -> SpendSnapshot {
        try database.pool.read { db in
            let usage = try Self.executionUsage(db, executionID: executionID)
            return SpendSnapshot(policy: try Self.readPolicy(db), countedUSD: Self.decimalText(usage.counted),
                confirmedUSD: Self.decimalText(usage.confirmed), reservedUSD: Self.decimalText(usage.counted - usage.confirmed),
                unknownAttempts: usage.unknownCount, periodStart: nil, periodEnd: nil)
        }
    }
    private static func executionFence(_ db: Database, executionID: UUID, owner: UUID, admitting: Bool) throws {
        guard try String.fetchOne(db, sql: "SELECT generation FROM agentRuntimeOwner WHERE id=1") == owner.uuidString else { throw ExecutionStoreError.staleOwner }
        guard let data = try Data.fetchOne(db, sql: "SELECT record FROM agentExecutions WHERE id=?", arguments: [executionID.uuidString]) else { throw ExecutionStoreError.notFound }
        let record = try JSONDecoder().decode(AgentExecution.self, from: data)
        if admitting {
            guard [.running, .waitingEvent, .waitingNetwork].contains(record.state), record.boundaryPauseReason == nil else { throw ExecutionBoundaryPause() }
        }
    }
    private static func executionUsage(_ db: Database, executionID: UUID) throws -> (counted: Decimal, confirmed: Decimal, unknown: Bool, unknownCount: Int) {
        let rows = try Row.fetchAll(db, sql: "SELECT a.state,a.actualUSD,a.maximumUSD FROM spendAttempts a JOIN agentExecutionSpend e ON e.attemptID=a.id WHERE e.executionID=?",
                                   arguments: [executionID.uuidString])
        var counted: Decimal = 0; var confirmed: Decimal = 0; var unknown = false; var unknownCount = 0
        for row in rows {
            let state: String = row["state"]
            if state == "notSent" { continue }
            if let raw: String = row["actualUSD"], let value = amount(raw) { confirmed += value; counted += value }
            else {
                if let raw: String = row["maximumUSD"], let value = amount(raw) { counted += value } else { unknown = true }
                if state == "sent" || state == "unknown" { unknownCount += 1 }
            }
        }
        return (counted, confirmed, unknown, unknownCount)
    }

    public func markSent(id: UUID, at date: Date = .now) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE spendAttempts SET state = 'sent', sentAt = ? WHERE id = ? AND state = 'reserved'",
                           arguments: [date, id.uuidString])
            guard db.changesCount == 1 else { throw SpendAdmissionError.invalidTransition }
        }
    }
    public func finalizeExecutionAttempt(id: UUID, executionID: UUID, owner: UUID, state: SpendAttemptState,
                                         actualUSD: String? = nil, at date: Date = .now, completed: Bool = false) throws {
        guard [.notSent, .unknown, .confirmed].contains(state),
              state != .confirmed || actualUSD.flatMap(Self.amount) != nil else { throw SpendAdmissionError.invalidAmount }
        try database.pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT generation FROM agentRuntimeOwner WHERE id=1") == owner.uuidString,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentExecutionSpend WHERE attemptID=? AND executionID=?",
                                   arguments: [id.uuidString, executionID.uuidString]) == 1 else { throw ExecutionStoreError.staleOwner }
            let permitted = state == .notSent ? ["reserved"] : state == .unknown ? ["sent"] : ["sent", "unknown"]
            guard let current = try String.fetchOne(db, sql: "SELECT state FROM spendAttempts WHERE id=?", arguments: [id.uuidString]),
                  permitted.contains(current) else { throw SpendAdmissionError.invalidTransition }
            try db.execute(sql: "UPDATE spendAttempts SET state=?, actualUSD=?, finalizedAt=? WHERE id=?",
                arguments: [state.rawValue, actualUSD, state == .unknown && !completed ? nil : date, id.uuidString])
        }
    }

    /// Only a definitively unsent request releases its reservation.
    public func markNotSent(id: UUID, at date: Date = .now) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE spendAttempts SET state = 'notSent', finalizedAt = ? WHERE id = ? AND state = 'reserved'",
                           arguments: [date, id.uuidString])
            guard db.changesCount == 1 else { throw SpendAdmissionError.invalidTransition }
        }
    }

    public func markUnknown(id: UUID) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE spendAttempts SET state = 'unknown' WHERE id = ? AND state = 'sent'",
                           arguments: [id.uuidString])
            guard db.changesCount == 1 else { throw SpendAdmissionError.invalidTransition }
        }
    }

    public func markCompletedUnknown(id: UUID, at date: Date = .now) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE spendAttempts SET state='unknown', finalizedAt=? WHERE id=? AND state IN ('sent','unknown')",
                           arguments: [date, id.uuidString])
            guard db.changesCount == 1 else { throw SpendAdmissionError.invalidTransition }
        }
    }

    public func reconcile(id: UUID, actualUSD: String, at date: Date = .now) throws {
        guard Self.amount(actualUSD) != nil else { throw SpendAdmissionError.invalidAmount }
        try database.pool.write { db in
            try db.execute(sql: """
                UPDATE spendAttempts SET state = 'confirmed', actualUSD = ?, finalizedAt = ?
                WHERE id = ? AND state IN ('sent', 'unknown')
                """, arguments: [actualUSD, date, id.uuidString])
            guard db.changesCount == 1 else { throw SpendAdmissionError.invalidTransition }
        }
    }

    /// Apply a later verified provider receipt to an already confirmed charge.
    /// The prior amount and receipt source remain immutable audit data.
    public func correctConfirmed(id: UUID, correctedUSD: String, sourceID: String,
                                 at date: Date = .now) throws -> SpendCostCorrection {
        guard let newAmount = Self.amount(correctedUSD),
              !sourceID.isEmpty, sourceID.utf8.count <= 255,
              !sourceID.contains("\0"), !sourceID.contains("\n"), !sourceID.contains("\r") else {
            throw SpendAdmissionError.invalidAmount
        }
        return try database.pool.write { db in
            guard let attempt = try Row.fetchOne(db, sql: """
                SELECT provider, modelID, feature, actualUSD, state
                FROM spendAttempts WHERE id = ?
                """, arguments: [id.uuidString]),
                let previous: String = attempt["actualUSD"],
                let oldAmount = Self.amount(previous),
                let state: String = attempt["state"],
                state == SpendAttemptState.confirmed.rawValue,
                oldAmount != newAmount else {
                throw SpendAdmissionError.invalidTransition
            }
            guard try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM spendCostCorrections WHERE attemptID = ? AND sourceID = ?
                """, arguments: [id.uuidString, sourceID]) == 0 else {
                throw SpendAdmissionError.duplicateCorrection
            }
            let correctionID = UUID()
            try db.execute(sql: """
                INSERT INTO spendCostCorrections
                (id, attemptID, previousUSD, correctedUSD, sourceID, occurredAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [correctionID.uuidString, id.uuidString,
                                  previous, correctedUSD, sourceID, date])
            try db.execute(sql: """
                UPDATE spendAttempts SET actualUSD = ?, finalizedAt = ?
                WHERE id = ? AND state = 'confirmed' AND actualUSD = ?
                """, arguments: [correctedUSD, date, id.uuidString, previous])
            guard db.changesCount == 1 else { throw SpendAdmissionError.invalidTransition }
            return SpendCostCorrection(id: correctionID, attemptID: id,
                provider: attempt["provider"], modelID: attempt["modelID"],
                feature: attempt["feature"], previousUSD: previous,
                correctedUSD: correctedUSD, sourceID: sourceID, occurredAt: date)
        }
    }

    public func recentCorrections(limit: Int = 100) throws -> [SpendCostCorrection] {
        let boundedLimit = min(max(limit, 1), 500)
        return try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.attemptID, c.previousUSD, c.correctedUSD,
                       c.sourceID, c.occurredAt, a.provider, a.modelID, a.feature
                FROM spendCostCorrections AS c
                JOIN spendAttempts AS a ON a.id = c.attemptID
                ORDER BY c.occurredAt DESC, c.id DESC LIMIT ?
                """, arguments: [boundedLimit])
            return try rows.map { row in
                let rawID: String = row["id"]
                let rawAttemptID: String = row["attemptID"]
                guard let id = UUID(uuidString: rawID),
                      let attemptID = UUID(uuidString: rawAttemptID) else {
                    throw SpendAdmissionError.invalidTransition
                }
                return SpendCostCorrection(id: id, attemptID: attemptID,
                    provider: row["provider"], modelID: row["modelID"],
                    feature: row["feature"], previousUSD: row["previousUSD"],
                    correctedUSD: row["correctedUSD"], sourceID: row["sourceID"],
                    occurredAt: row["occurredAt"])
            }
        }
    }

    public func snapshot(at date: Date = .now) throws -> SpendSnapshot {
        try database.pool.read { db in
            let policy = try Self.readPolicy(db)
            let usage = try Self.usage(db, policy: policy, at: date)
            let interval = Self.interval(policy: policy, at: date)
            return SpendSnapshot(policy: policy, countedUSD: Self.decimalText(usage.counted),
                confirmedUSD: Self.decimalText(usage.counted - usage.reserved - usage.estimated),
                reservedUSD: Self.decimalText(usage.reserved), unknownAttempts: usage.unknownCount,
                periodStart: interval?.start, periodEnd: interval?.end, estimatedUSD: Self.decimalText(usage.estimated))
        }
    }

    /// All rows in the policy period, not just the recent-attempt preview.
    /// Grouping happens with Decimal in Swift; SQLite REAL never handles USD.
    public func breakdown(at date: Date = .now) throws -> SpendBreakdown {
        try database.pool.read { db in
            let policy = try Self.readPolicy(db)
            let interval = Self.interval(policy: policy, at: date)
            let rows: RowCursor
            if let interval {
                rows = try Row.fetchCursor(db, sql: """
                    SELECT provider, modelID, feature, maximumUSD, estimatedUSD, actualUSD, state, isException, finalizedAt
                    FROM spendAttempts
                    WHERE createdAt >= ? AND createdAt < ? AND state != 'notSent'
                    """, arguments: StatementArguments([interval.start, interval.end]))
            } else {
                rows = try Row.fetchCursor(db, sql: """
                    SELECT provider, modelID, feature, maximumUSD, estimatedUSD, actualUSD, state, isException, finalizedAt
                    FROM spendAttempts WHERE state != 'notSent'
                    """)
            }
            var groups: [SpendGroupKey: SpendGroupTotals] = [:]
            while let row = try rows.next() {
                let provider: String = row["provider"]
                let modelID: String = row["modelID"]
                let feature: String = row["feature"]
                let state: String = row["state"]
                let maximum: String? = row["maximumUSD"]
                let actual: String? = row["actualUSD"]
                let exception: Bool = row["isException"]
                for key in [SpendGroupKey.provider(provider),
                            .model(provider, modelID), .feature(feature)] {
                    var totals = groups[key] ?? SpendGroupTotals()
                    totals.attemptCount += 1
                    if exception { totals.exceptionCount += 1 }
                    let finalizedAt: Date? = row["finalizedAt"]
                    if let raw: String = row["estimatedUSD"], let value = Self.amount(raw), actual == nil {
                        if state == "reserved" || state == "sent" { totals.reserved += value }
                        else { totals.estimated += value; totals.unknownAttempts += 1 }
                    } else if state == SpendAttemptState.unknown.rawValue, finalizedAt != nil {
                        totals.unknownAttempts += 1
                    } else if state == SpendAttemptState.confirmed.rawValue,
                       let actual, let value = Self.amount(actual) {
                        totals.confirmed += value
                    } else if let maximum, let value = Self.amount(maximum) {
                        totals.reserved += value
                    } else {
                        totals.unknownAttempts += 1
                    }
                    groups[key] = totals
                }
            }
            func groupedRows(for dimension: SpendBreakdownDimension) -> [SpendBreakdownRow] {
                groups.compactMap { key, totals -> SpendBreakdownRow? in
                    guard key.dimension == dimension else { return nil }
                    return SpendBreakdownRow(id: key.stableID, estimatedUSD: Self.decimalText(totals.estimated), dimension: dimension,
                        label: key.label, confirmedUSD: Self.decimalText(totals.confirmed),
                        reservedUSD: Self.decimalText(totals.reserved),
                        unknownAttempts: totals.unknownAttempts,
                        attemptCount: totals.attemptCount,
                        exceptionCount: totals.exceptionCount)
                }.sorted { left, right in
                    let leftTotal = (Self.amount(left.confirmedUSD) ?? 0) +
                        (Self.amount(left.reservedUSD) ?? 0)
                    let rightTotal = (Self.amount(right.confirmedUSD) ?? 0) +
                        (Self.amount(right.reservedUSD) ?? 0)
                    if leftTotal != rightTotal { return leftTotal > rightTotal }
                    return left.label.localizedStandardCompare(right.label) == .orderedAscending
                }
            }
            return SpendBreakdown(providers: groupedRows(for: .provider),
                models: groupedRows(for: .model), features: groupedRows(for: .feature),
                periodStart: interval?.start, periodEnd: interval?.end)
        }
    }

    /// A diagnostic history without prompts, images, credentials or tool arguments.
    /// Scoped lookup for reconciliation of a peer request whose reply was lost.
    /// It does not admit a second attempt or bypass the current owner generation.
    public func executionAttempt(_ id: UUID, executionID: UUID, owner: UUID) throws -> SpendAttempt? {
        try database.pool.read { db in
            try Self.executionFence(db, executionID: executionID, owner: owner, admitting: false)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT s.* FROM spendAttempts s JOIN agentExecutionSpend e ON e.attemptID=s.id
                WHERE s.id=? AND e.executionID=?
                """, arguments: [id.uuidString, executionID.uuidString]),
                  let state = SpendAttemptState(rawValue: row["state"]) else { return nil }
            let conversation: String? = row["conversationID"]
            return SpendAttempt(id: id, provider: row["provider"], modelID: row["modelID"], feature: row["feature"],
                conversationID: conversation.flatMap(UUID.init(uuidString:)), maximumUSD: row["maximumUSD"],
                estimatedUSD: row["estimatedUSD"], actualUSD: row["actualUSD"], state: state, isException: row["isException"], createdAt: row["createdAt"])
        }
    }

    public func recentAttempts(limit: Int = 100) throws -> [SpendAttempt] {
        let boundedLimit = min(max(limit, 1), 500)
        return try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, provider, modelID, feature, conversationID, maximumUSD, estimatedUSD,
                       actualUSD, state, isException, createdAt
                FROM spendAttempts ORDER BY createdAt DESC, id DESC LIMIT ?
                """, arguments: [boundedLimit])
            return try rows.map { row in
                let rawID: String = row["id"]
                let rawState: String = row["state"]
                guard let id = UUID(uuidString: rawID),
                      let state = SpendAttemptState(rawValue: rawState) else {
                    throw SpendAdmissionError.invalidTransition
                }
                let rawConversationID: String? = row["conversationID"]
                return SpendAttempt(id: id, provider: row["provider"], modelID: row["modelID"],
                    feature: row["feature"], conversationID: rawConversationID.flatMap(UUID.init(uuidString:)),
                    maximumUSD: row["maximumUSD"], estimatedUSD: row["estimatedUSD"], actualUSD: row["actualUSD"], state: state,
                    isException: row["isException"], createdAt: row["createdAt"])
            }
        }
    }

    private static func readPolicy(_ db: Database) throws -> GlobalSpendPolicy {
        guard let row = try Row.fetchOne(db, sql: "SELECT enabled, limitUSD, period, timeZoneID, requiresVerifiedWebSearch FROM globalSpendPolicy WHERE id = 1") else {
            return GlobalSpendPolicy()
        }
        let periodText: String = row["period"]
        guard let period = SpendPeriod(rawValue: periodText) else { throw SpendAdmissionError.invalidPolicy }
        return GlobalSpendPolicy(enabled: row["enabled"], limitUSD: row["limitUSD"],
                                 period: period, timeZoneID: row["timeZoneID"], requiresVerifiedWebSearch: row["requiresVerifiedWebSearch"])
    }

    private static func usage(_ db: Database, policy: GlobalSpendPolicy, at date: Date) throws
        -> (counted: Decimal, reserved: Decimal, estimated: Decimal, unknown: Bool, unknownCount: Int, unsettledUnknown: Bool) {
        let rows: RowCursor
        if let interval = interval(policy: policy, at: date) {
            rows = try Row.fetchCursor(db, sql: """
                SELECT state, maximumUSD, estimatedUSD, actualUSD, finalizedAt FROM spendAttempts
                WHERE createdAt >= ? AND createdAt < ? AND state != 'notSent'
                """, arguments: StatementArguments([interval.start, interval.end]))
        } else {
            rows = try Row.fetchCursor(db, sql: "SELECT state, maximumUSD, estimatedUSD, actualUSD, finalizedAt FROM spendAttempts WHERE state != 'notSent'")
        }
        var counted = Decimal.zero
        var reserved = Decimal.zero
        var estimated = Decimal.zero
        var unknownCount = 0
        var unsettledUnknown = false
        while let row = try rows.next() {
            let state: String = row["state"]
            let maximum: String? = row["maximumUSD"]
            let actual: String? = row["actualUSD"]
            let finalizedAt: Date? = row["finalizedAt"]
            if let raw: String = row["estimatedUSD"], let value = amount(raw), actual == nil {
                counted += value
                if state == "reserved" || state == "sent" { reserved += value }
                else { estimated += value }
                unknownCount += 1
            } else if state == SpendAttemptState.unknown.rawValue, finalizedAt != nil {
                // Preserve the original maximum as admission history, not a lasting
                // reservation or an invented receipt for a completed API attempt.
                unknownCount += 1
            } else if state == SpendAttemptState.confirmed.rawValue, let actual, let value = amount(actual) {
                counted += value
            } else if let maximum, let value = amount(maximum) {
                counted += value
                reserved += value
            } else {
                unknownCount += 1
                // markUnknown closes the local attempt without inventing a
                // receipt. Reserved/sent unpriced attempts are still unsettled.
                if state != SpendAttemptState.unknown.rawValue { unsettledUnknown = true }
            }
        }
        return (counted, reserved, estimated, unknownCount > 0, unknownCount, unsettledUnknown)
    }

    private static func interval(policy: GlobalSpendPolicy, at date: Date) -> DateInterval? {
        guard policy.period != .envelope, let zone = TimeZone(identifier: policy.timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateInterval(of: policy.period == .day ? .day : .month, for: date)
    }

    private static func amount(_ raw: String) -> Decimal? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty, parts[0].count <= 10,
              parts[0].allSatisfy(\.isNumber),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= 18 && parts[1].allSatisfy(\.isNumber)),
              let number = Decimal(string: raw, locale: usdLocale), number >= 0,
              number <= 1_000_000_000 else { return nil }
        return number
    }

    private static func decimalText(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    private static func validLabel(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
    }
}

private enum SpendGroupKey: Hashable {
    case provider(String)
    case model(String, String)
    case feature(String)

    var dimension: SpendBreakdownDimension {
        switch self {
        case .provider: .provider
        case .model: .model
        case .feature: .feature
        }
    }

    var label: String {
        switch self {
        case .provider(let provider): provider
        case .model(let provider, let model): "\(provider) · \(model)"
        case .feature(let feature): feature
        }
    }

    var stableID: String {
        switch self {
        case .provider(let provider): "provider:\(provider)"
        case .model(let provider, let model): "model:\(provider.utf8.count):\(provider)\(model)"
        case .feature(let feature): "feature:\(feature)"
        }
    }
}

private struct SpendGroupTotals {
    var estimated = Decimal.zero
    var confirmed = Decimal.zero
    var reserved = Decimal.zero
    var unknownAttempts = 0
    var attemptCount = 0
    var exceptionCount = 0
}
