import AIMCore
import Foundation
import GRDB

private struct MessageMetricsRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messageMetrics"
    var messageID: String
    var conversationID: String
    var createdAt: Date
    var provider: String
    var modelID: String
    var isLocal: Bool
    var totalTokens: Int
    var metricsJSON: Data
}

private struct ConversationStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversationState"
    var conversationID: String
    var titleSource: String?
    var lastReadAt: Date?
    var contextUsageJSON: Data?
}

/// Existing local read state uses an answer's immutable identity/date, never a conversation edit date.
public struct LegacyConversationReadState: Equatable, Sendable {
    public var response: ConversationResponseVersion
    public var lastReadAt: Date
    /// Preserve the former one-second completion/read tolerance.
    public var wasRead: Bool { response.completedAt <= lastReadAt.addingTimeInterval(1) }
}

/// How a conversation got its title: the first words of the request, the model, or the user.
public enum ConversationTitleSource: String, Codable, Sendable {
    case initial, generated, user
}

/// Per-answer measurements (tokens, timings) and per-conversation state kept beside the
/// conversation tables, so older records stay untouched.
public actor SQLiteMessageMetricsRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func save(_ metrics: TurnMetrics, messageID: UUID, conversationID: UUID) throws {
        let row = MessageMetricsRow(messageID: messageID.uuidString, conversationID: conversationID.uuidString,
            createdAt: metrics.startedAt, provider: metrics.provider, modelID: metrics.modelID, isLocal: metrics.isLocal,
            totalTokens: metrics.totalTokens, metricsJSON: try JSONEncoder().encode(metrics))
        try database.pool.write { db in try row.save(db) }
    }

    public func metrics(conversationID: UUID) throws -> [UUID: TurnMetrics] {
        try database.pool.read { db in
            var result: [UUID: TurnMetrics] = [:]
            for row in try MessageMetricsRow.filter(Column("conversationID") == conversationID.uuidString).fetchAll(db) {
                if let id = UUID(uuidString: row.messageID), let metrics = try? JSONDecoder().decode(TurnMetrics.self, from: row.metricsJSON) {
                    result[id] = metrics
                }
            }
            return result
        }
    }

    /// Every measurement since a date, oldest first (the profile's statistics).
    public func all(since: Date = .distantPast) throws -> [TurnMetrics] {
        try database.pool.read { db in
            try MessageMetricsRow.filter(Column("createdAt") >= since).order(Column("createdAt")).fetchAll(db)
                .compactMap { try? JSONDecoder().decode(TurnMetrics.self, from: $0.metricsJSON) }
        }
    }

    /// When the user wrote, every message since the start (activity days and streaks).
    public func userMessageDates() throws -> [Date] {
        try database.pool.read { db in
            try Date.fetchAll(db, sql: "SELECT createdAt FROM messages WHERE role = 'user' ORDER BY createdAt")
        }
    }

    /// The tools the Agent used most (workspace and connector tools).
    public func toolCallCounts(limit: Int = 8) throws -> [(name: String, count: Int)] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT name, COUNT(*) AS uses FROM workspaceCalls GROUP BY name ORDER BY uses DESC LIMIT ?",
                             arguments: [limit]).map { (name: $0["name"], count: $0["uses"]) }
        }
    }

    /// Provider charges AIM recorded (OpenRouter receipts and estimates), in US dollars.
    public func recordedSpendUSD() throws -> Double {
        try database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT actualUSD FROM spendAttempts WHERE actualUSD IS NOT NULL")
                .compactMap(Double.init).reduce(0, +)
        }
    }

    public func titleSource(conversationID: UUID) throws -> ConversationTitleSource? {
        try database.pool.read { db in
            try ConversationStateRow.fetchOne(db, key: conversationID.uuidString)?.titleSource.flatMap(ConversationTitleSource.init(rawValue:))
        }
    }

    public func setTitleSource(_ source: ConversationTitleSource, conversationID: UUID) throws {
        try database.pool.write { db in
            var row = try ConversationStateRow.fetchOne(db, key: conversationID.uuidString)
                ?? ConversationStateRow(conversationID: conversationID.uuidString)
            row.titleSource = source.rawValue
            try row.save(db)
        }
    }

    /// Conversations whose latest message is an answer that failed.
    public func failedConversationIDs() throws -> Set<UUID> {
        try database.pool.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT m.conversationID FROM messages m
                WHERE m.completionStatus = 'failed'
                  AND m.sequence = (SELECT MAX(sequence) FROM messages WHERE conversationID = m.conversationID)
                """)
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    public func contextUsage(conversationID: UUID) throws -> ContextUsage? {
        try database.pool.read { db in
            try ConversationStateRow.fetchOne(db, key: conversationID.uuidString)?.contextUsageJSON
                .flatMap { try? JSONDecoder().decode(ContextUsage.self, from: $0) }
        }
    }

    public func saveContextUsage(_ usage: ContextUsage, conversationID: UUID) throws {
        let data = try JSONEncoder().encode(usage)
        try database.pool.write { db in
            var row = try ConversationStateRow.fetchOne(db, key: conversationID.uuidString)
                ?? ConversationStateRow(conversationID: conversationID.uuidString)
            row.contextUsageJSON = data
            try row.save(db)
        }
    }

    /// Provider charges recorded for one conversation (receipts, else AIM's admitted estimates).
    public func conversationSpend(_ conversationID: UUID) throws -> (usd: Double, estimated: Bool) {
        try database.pool.read { db in
            Self.total(try Row.fetchAll(db, sql: "SELECT actualUSD, maximumUSD, estimatedUSD, state FROM spendAttempts WHERE conversationID = ?",
                                        arguments: [conversationID.uuidString]))
        }
    }

    /// Recorded spend since a date (all conversations and features).
    public func spend(since: Date) throws -> (usd: Double, estimated: Bool) {
        try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT actualUSD, maximumUSD, estimatedUSD, state FROM spendAttempts WHERE createdAt >= ?",
                                        arguments: [since])
            return Self.total(rows)
        }
    }

    /// Receipts when known, else the amount AIM admitted for the request (marked estimated).
    private static func total(_ rows: [Row]) -> (usd: Double, estimated: Bool) {
        var total = 0.0, estimated = false
        for row in rows {
            if let actual = (row["actualUSD"] as String?).flatMap(Double.init) { total += actual }
            else if (row["state"] as String?) != "notSent", let value = (row["estimatedUSD"] as String?).flatMap(Double.init) {
                total += value; estimated = true
            }
            else if (row["state"] as String?) != "notSent", let maximum = (row["maximumUSD"] as String?).flatMap(Double.init), maximum > 0 {
                total += maximum; estimated = true
            }
        }
        return (total, estimated)
    }

    public func lastRead() throws -> [UUID: Date] {
        try database.pool.read { db in
            var result: [UUID: Date] = [:]
            for row in try ConversationStateRow.fetchAll(db) {
                if let id = UUID(uuidString: row.conversationID), let date = row.lastReadAt { result[id] = date }
            }
            return result
        }
    }

    /// Read metadata only. Unknown histories are deliberately excluded, as are failed/cancelled answers.
    public func knownLegacyReadState() throws -> [UUID: LegacyConversationReadState] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id, m.conversationID, m.createdAt, s.lastReadAt
                FROM messages m JOIN conversationState s ON s.conversationID = m.conversationID
                WHERE s.lastReadAt IS NOT NULL AND m.role = 'assistant' AND m.completionStatus IS NULL
                  AND length(trim(m.content)) > 0
                  AND m.sequence = (SELECT MAX(a.sequence) FROM messages a
                    WHERE a.conversationID = m.conversationID AND a.role = 'assistant'
                      AND a.completionStatus IS NULL AND length(trim(a.content)) > 0)
                """)
            var result: [UUID: LegacyConversationReadState] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["conversationID"]) else { continue }
                result[id] = .init(response: .init(id: row["id"], completedAt: row["createdAt"]), lastReadAt: row["lastReadAt"])
            }
            return result
        }
    }

    public func markRead(conversationID: UUID, at date: Date = .now) throws {
        try database.pool.write { db in
            var row = try ConversationStateRow.fetchOne(db, key: conversationID.uuidString)
                ?? ConversationStateRow(conversationID: conversationID.uuidString)
            row.lastReadAt = date
            try row.save(db)
        }
    }
}
