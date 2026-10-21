import Foundation
import GRDB

/// Opaque encrypted Remote receipts. A runtime generation fences every mutation.
public struct RemoteReceiptStore: Sendable {
    private let database: AIMDatabase
    private let owner: UUID
    public init(database: AIMDatabase, owner: UUID) { self.database = database; self.owner = owner }
    public func load(id: String, accountID: String, machineID: String) throws -> Data? {
        try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM agentRemoteReceipts WHERE id=? AND accountID=? AND machineID=?",
                             arguments: [id, accountID, machineID])
        }
    }
    public func pending(accountID: String, machineID: String) throws -> [Data] {
        try database.pool.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM agentRemoteReceipts WHERE accountID=? AND machineID=? AND delivered=0 ORDER BY rowid",
                             arguments: [accountID, machineID])
        }
    }
    public func save(id: String, accountID: String, machineID: String, payload: Data,
                     replacing previous: Data?, delivered: Bool) throws {
        guard payload.count <= 2 * 1024 * 1024 else { throw ExecutionStoreError.incompatibleCheckpoint }
        try database.pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT generation FROM agentRuntimeOwner WHERE id=1") == owner.uuidString else {
                throw ExecutionStoreError.staleOwner
            }
            let current = try Data.fetchOne(db, sql: "SELECT payload FROM agentRemoteReceipts WHERE id=? AND accountID=? AND machineID=?",
                                            arguments: [id, accountID, machineID])
            guard current == previous else { throw ExecutionStoreError.staleRevision }
            try db.execute(sql: "INSERT INTO agentRemoteReceipts(id,accountID,machineID,payload,delivered) VALUES(?,?,?,?,?) ON CONFLICT(id,accountID,machineID) DO UPDATE SET payload=excluded.payload, delivered=excluded.delivered",
                           arguments: [id, accountID, machineID, payload, delivered])
        }
    }
}
