import AIMCore
import Foundation
import GRDB

/// New, explicitly attributed executions only. Remote mirrors never produce rows here.
public actor SQLiteAccountActivityRepository {
    private let database: AIMDatabase
    private let importOwnersStore: (any SecureStoring)?
    public nonisolated let deviceID: String
    public init(database: AIMDatabase, importOwnersStore: (any SecureStoring)? = nil) {
        self.database = database; self.importOwnersStore = importOwnersStore
        let key = "aim.activity.installation"
        if let existing = UserDefaults.standard.string(forKey: key) { deviceID = existing }
        else { let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: key); deviceID = value }
    }
    public func ownConversation(_ id: UUID, accountID: UUID, since: Date = .now) throws {
        try database.pool.write { db in
            if let owner = try String.fetchOne(db, sql: "SELECT accountID FROM activityConversationOwners WHERE conversationID=?", arguments: [id.uuidString]), owner != accountID.uuidString { throw AccountServiceError.conflict }
            try db.execute(sql: "INSERT OR IGNORE INTO activityConversationOwners VALUES(?,?,?)", arguments: [id.uuidString, accountID.uuidString, since])
        }
    }
    public func record(_ value: AccountActivityRecord) throws {
        guard value.valid else { throw AccountServiceError.unavailable }
        try database.pool.write { db in
            let old = try Data.fetchOne(db, sql: "SELECT payload FROM accountActivity WHERE id=?", arguments: [value.id.uuidString]).map { try JSONDecoder().decode(AccountActivityRecord.self, from: $0) }
            if let old, old.accountID != value.accountID { throw AccountServiceError.conflict }
            let merged = AccountActivityRecord.merge((old.map { [$0] } ?? []) + [value], accountID: value.accountID)
            guard let saved = merged.first else { return }
            try db.execute(sql: "INSERT INTO accountActivity(id,accountID,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [value.id.uuidString, value.accountID.uuidString, try JSONEncoder().encode(saved)])
        }
    }
    public func existing(_ id: UUID) throws -> AccountActivityRecord? {
        try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM accountActivity WHERE id=?", arguments: [id.uuidString])
                .map { try JSONDecoder().decode(AccountActivityRecord.self, from: $0) }
        }
    }
    public func records(accountID: UUID) throws -> [AccountActivityRecord] {
        try database.pool.read { db in
            var rows = try Data.fetchAll(db, sql: "SELECT payload FROM accountActivity WHERE accountID=?", arguments: [accountID.uuidString]).map { try JSONDecoder().decode(AccountActivityRecord.self, from: $0) }
            let costRows = try Row.fetchAll(db, sql: """
                SELECT s.*, (SELECT MAX(occurredAt) FROM spendCostCorrections c WHERE c.attemptID=s.id) AS correctedAt
                FROM spendAttempts s JOIN activityConversationOwners o ON o.conversationID=s.conversationID
                WHERE o.accountID=? AND (s.createdAt>=o.since OR EXISTS(SELECT 1 FROM accountActivity a WHERE a.id=s.id AND a.accountID=o.accountID)) AND s.state!='notSent'
                """, arguments: [accountID.uuidString])
            for row in costRows {
                guard let id = UUID(uuidString: row["id"] as String) else { continue }
                let actual: String? = row["actualUSD"], maximum: String? = row["maximumUSD"], state: String = row["state"]
                let estimate: String? = row["estimatedUSD"]
                let at: Date = row["createdAt"], final: Date? = row["finalizedAt"], corrected: Date? = row["correctedAt"]
                rows.append(.init(id: id, accountID: accountID, deviceID: deviceID, deviceName: Host.current().localizedName ?? "Mac", conversationID: (row["conversationID"] as String?).flatMap(UUID.init(uuidString:)), kind: .cost,
                    provider: row["provider"], modelID: row["modelID"], mode: row["feature"], startedAt: at, completedAt: final,
                    costUSD: actual.flatMap(Double.init) ?? estimate.flatMap(Double.init) ?? (state == "reserved" || state == "sent" ? maximum.flatMap(Double.init) : nil),
                    costState: actual != nil ? .confirmed : estimate != nil ? .estimated : ((state == "reserved" || state == "sent") && maximum != nil ? .reserved : .unknown), updatedAt: corrected ?? final ?? at))
            }
            return AccountActivityRecord.merge(rows, accountID: accountID)
        }
    }
    /// Only unclaimed historical executions are offered; source tables are never rewritten.
    public func legacyPreview(accountID: UUID) throws -> [AccountActivityImportItem] {
        try database.pool.read { db in try self.legacyPreview(db: db, accountID: accountID) }
    }
    public func importLegacy(_ preview: [AccountActivityImportItem], selectedIDs: Set<UUID>, accountID: UUID) throws -> Int {
        try database.pool.write { db in
            let current = try self.legacyPreview(db: db, accountID: accountID)
            let selected = try AccountActivityImportItem.selected(selectedIDs, from: preview, current: current, accountID: accountID)
            for record in selected {
                // Selection and insert share one transaction: another import/account cannot steal an ID.
                try db.execute(sql: "INSERT INTO accountActivity(id,accountID,payload) VALUES(?,?,?)", arguments: [record.id.uuidString, accountID.uuidString, try JSONEncoder().encode(record)])
                if let id = record.conversationID {
                    try db.execute(sql: "INSERT OR IGNORE INTO activityConversationOwners VALUES(?,?,?)", arguments: [id.uuidString, accountID.uuidString, Date()])
                }
            }
            return selected.count
        }
    }
    private nonisolated func legacyPreview(db: Database, accountID: UUID) throws -> [AccountActivityImportItem] {
        let owner = accountID.uuidString
        let owners: [UUID: UUID]
        if let data = try importOwnersStore?.readData(forKey: "account-chat-owners.v1") {
            owners = try JSONDecoder().decode([UUID: UUID].self, from: data)
        } else { owners = [:] }
        func visible(_ conversation: UUID) -> Bool { owners[conversation] == nil || owners[conversation] == accountID }
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.messageID,m.conversationID,m.metricsJSON,COALESCE(c.title,'Earlier conversation') AS title,
                   EXISTS(SELECT 1 FROM spendAttempts s WHERE s.conversationID=m.conversationID AND s.state!='notSent') AS hasLedger
            FROM messageMetrics m LEFT JOIN conversations c ON c.id=m.conversationID
            LEFT JOIN activityConversationOwners o ON o.conversationID=m.conversationID
            WHERE (o.accountID IS NULL OR o.accountID=?)
              AND (o.since IS NULL OR m.createdAt<o.since)
              AND NOT EXISTS(SELECT 1 FROM accountActivity a WHERE a.id=m.messageID)
            ORDER BY m.createdAt DESC
            """, arguments: [owner])
        var result: [AccountActivityImportItem] = []
        for row in rows {
            guard let id = UUID(uuidString: row["messageID"] as String), let conversation = UUID(uuidString: row["conversationID"] as String),
                  let metric = try? JSONDecoder().decode(TurnMetrics.self, from: row["metricsJSON"] as Data) else { continue }
            guard visible(conversation) else { continue }
            let tokens = metric.usage.inputTokens.flatMap { input in metric.usage.outputTokens.map { input + $0 } }
            var record = AccountActivityRecord(id: id, accountID: accountID, deviceID: AccountActivityRecord.unattributedDeviceID, deviceName: "Unknown execution device", conversationID: conversation,
                provider: metric.totalSeconds > 0 ? metric.provider : "unknown", modelID: metric.totalSeconds > 0 ? metric.modelID : "Earlier answer", mode: metric.mode, startedAt: metric.startedAt,
                totalTokens: tokens, costUSD: metric.costUSD, costState: metric.costUSD == nil ? .unknown : .estimated, updatedAt: metric.startedAt)
            // A legacy answer's stream duration is not the duration of its Agent task.
            record.costTrackedSeparately = row["hasLedger"] as Bool
            if record.valid { result.append(try .init(title: row["title"], record: record)) }
        }
        let costs = try Row.fetchAll(db, sql: """
            SELECT s.*,COALESCE(c.title,'Earlier conversation') AS title,
                   (SELECT MAX(occurredAt) FROM spendCostCorrections x WHERE x.attemptID=s.id) AS correctedAt
            FROM spendAttempts s LEFT JOIN conversations c ON c.id=s.conversationID
            LEFT JOIN activityConversationOwners o ON o.conversationID=s.conversationID
            WHERE (o.accountID IS NULL OR o.accountID=?) AND (o.since IS NULL OR s.createdAt<o.since)
              AND s.conversationID IS NOT NULL AND s.state!='notSent'
              AND NOT EXISTS(SELECT 1 FROM accountActivity a WHERE a.id=s.id)
            ORDER BY s.createdAt DESC
            """, arguments: [owner])
        for row in costs {
            guard let id = UUID(uuidString: row["id"] as String), let conversation = UUID(uuidString: row["conversationID"] as String) else { continue }
            guard visible(conversation) else { continue }
            let actual: String? = row["actualUSD"], at: Date = row["createdAt"], final: Date? = row["finalizedAt"], corrected: Date? = row["correctedAt"]
            let record = AccountActivityRecord(id: id, accountID: accountID, deviceID: deviceID, deviceName: Host.current().localizedName ?? "Mac", conversationID: conversation,
                kind: .cost, provider: row["provider"], modelID: row["modelID"], mode: row["feature"], startedAt: at, completedAt: final,
                costUSD: actual.flatMap(Double.init), costState: actual == nil ? .unknown : .confirmed, updatedAt: corrected ?? final ?? at)
            if record.valid { result.append(try .init(title: row["title"], record: record)) }
        }
        return result.sorted { $0.record.startedAt > $1.record.startedAt }
    }
    public func synchronize(accountID: UUID, service: any AccountContentSyncing) async throws -> [AccountActivityRecord] {
        // This Mac's activity goes up as one document per month (Round 37), not one per record.
        let synced = try await AccountActivityService(accountID: accountID, service: service).synchronize(records(accountID: accountID), deviceID: deviceID)
        for row in synced { try record(row) }
        return try records(accountID: accountID)
    }
}
