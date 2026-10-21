import Foundation
import GRDB

/// The v1 schema reserved this table. It deliberately has no foreign key so
/// deletion is coordinated with the conversation transaction below.
public actor SQLiteSessionCompactionRepository: SessionCompactionRepository {
    private let database: AIMDatabase

    public init(database: AIMDatabase) { self.database = database }

    public func load(conversationID: UUID) throws -> SessionCompaction? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT payloadJSON, version FROM sessionCompactions WHERE sessionID = ?",
                arguments: [conversationID.uuidString]) else { return nil }
            let version: Int = row["version"]
            guard version == 1 else { throw SessionCompactionError.staleCheckpoint }
            let payload: Data = row["payloadJSON"]
            let decoded = try JSONDecoder().decode(SessionCompaction.self, from: payload)
            guard decoded.conversationID == conversationID else { throw SessionCompactionError.staleCheckpoint }
            return try SessionCompaction(conversationID: decoded.conversationID,
                throughMessageID: decoded.throughMessageID, throughSequence: decoded.throughSequence,
                summary: decoded.summary, updatedAt: decoded.updatedAt)
        }
    }

    public func save(_ checkpoint: SessionCompaction) throws {
        let payload = try JSONEncoder().encode(checkpoint)
        try database.pool.write { db in
            guard try Row.fetchOne(db, sql: "SELECT 1 FROM conversations WHERE id = ?",
                                   arguments: [checkpoint.conversationID.uuidString]) != nil else {
                throw SessionCompactionError.staleCheckpoint
            }
            guard try Row.fetchOne(db, sql: """
                SELECT 1 FROM messages WHERE id = ? AND conversationID = ? AND sequence = ?
                    AND (role != 'assistant' OR completionStatus IS NULL)
                """, arguments: [checkpoint.throughMessageID.uuidString,
                                 checkpoint.conversationID.uuidString, checkpoint.throughSequence]) != nil else {
                throw SessionCompactionError.staleCheckpoint
            }
            if let existing = try Row.fetchOne(db,
                sql: "SELECT payloadJSON FROM sessionCompactions WHERE sessionID = ?",
                arguments: [checkpoint.conversationID.uuidString]) {
                let data: Data = existing["payloadJSON"]
                let prior = try JSONDecoder().decode(SessionCompaction.self, from: data)
                guard checkpoint.throughSequence > prior.throughSequence else { throw SessionCompactionError.staleCheckpoint }
            }
            try db.execute(sql: """
                INSERT INTO sessionCompactions(sessionID, payloadJSON, createdAt, updatedAt, version)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(sessionID) DO UPDATE SET payloadJSON = excluded.payloadJSON,
                    updatedAt = excluded.updatedAt, version = excluded.version
                """, arguments: [checkpoint.conversationID.uuidString, payload, checkpoint.updatedAt, checkpoint.updatedAt])
        }
    }

    public func delete(conversationID: UUID) throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM sessionCompactions WHERE sessionID = ?", arguments: [conversationID.uuidString])
        }
    }
}
