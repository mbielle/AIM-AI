import Foundation
import GRDB

/// Authenticated local decisions are committed before any continuation resumes.
/// Provider text and external events never write an interaction response.
public struct AgentInteractionStore: Sendable {
    let database: AIMDatabase
    let owner: UUID
    public init(database: AIMDatabase, owner: UUID) { self.database = database; self.owner = owner }
    public func register(id: String, kind: String, sessionID: UUID, payload: Data) throws -> Data? {
        guard payload.count <= 2 * 1024 * 1024 else { throw ExecutionStoreError.invalidTransition }
        return try database.pool.write { db in
            try fence(db)
            if let row = try Row.fetchOne(db, sql: "SELECT kind,sessionID,payload,response FROM agentInteractions WHERE id=?", arguments: [id]) {
                guard row["kind"] as String == kind, row["sessionID"] as String == sessionID.uuidString,
                      row["payload"] as Data == payload else { throw ExecutionStoreError.commandConflict }
                return row["response"]
            }
            try db.execute(sql: "INSERT INTO agentInteractions(id,kind,sessionID,payload,createdAt) VALUES(?,?,?,?,?)",
                           arguments: [id, kind, sessionID.uuidString, payload, Date.now])
            return nil
        }
    }
    public func answer(id: String, sessionID: UUID, response: Data) throws {
        try database.pool.write { db in
            try fence(db)
            guard let row = try Row.fetchOne(db, sql: "SELECT sessionID,response FROM agentInteractions WHERE id=?", arguments: [id]),
                  row["sessionID"] as String == sessionID.uuidString else { throw ExecutionStoreError.notFound }
            if let existing: Data = row["response"] {
                guard existing == response else { throw ExecutionStoreError.commandConflict }; return
            }
            try db.execute(sql: "UPDATE agentInteractions SET response=?, answeredAt=? WHERE id=?", arguments: [response, Date.now, id])
        }
    }
    private func fence(_ db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT generation FROM agentRuntimeOwner WHERE id=1") == owner.uuidString else {
            throw ExecutionStoreError.staleOwner
        }
    }
    public func matchesResponse(id: String, kind: String, sessionID: UUID, response: Data) throws -> Bool {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT kind,sessionID,response FROM agentInteractions WHERE id=?", arguments: [id]) else { return false }
            return row["kind"] as String == kind && row["sessionID"] as String == sessionID.uuidString
                && row["response"] as Data? == response
        }
    }
}
