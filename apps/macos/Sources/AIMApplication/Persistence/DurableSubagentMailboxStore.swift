import Foundation
import GRDB

/// Synchronous mailbox access is safe through DatabasePool. Message consumption
/// happens only in the same transaction as the child's model checkpoint.
public struct DurableSubagentMailboxStore: Sendable {
    let database: AIMDatabase
    let childID: UUID
    let owner: UUID
    public func post(id: String, text: String, toChild: Bool) throws {
        guard !id.isEmpty, id.utf8.count <= 256, !text.isEmpty, text.utf8.count <= 16000 else {
            throw ExecutionStoreError.invalidTransition
        }
        try database.pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT generation FROM agentRuntimeOwner WHERE id=1") == owner.uuidString else {
                throw ExecutionStoreError.staleOwner
            }
            let direction = toChild ? "child" : "parent"
            if let existing = try String.fetchOne(db, sql: "SELECT content FROM agentChildMessages WHERE childID=? AND direction=? AND id=?",
                                                 arguments: [childID.uuidString, direction, id]) {
                guard existing == text else { throw ExecutionStoreError.commandConflict }; return
            }
            try db.execute(sql: "INSERT INTO agentChildMessages(id,childID,direction,content,createdAt) VALUES(?,?,?,?,?)",
                           arguments: [id, childID.uuidString, direction, text, Date.now])
            if !toChild, let parent = try String.fetchOne(db, sql: "SELECT parentExecutionID FROM agentChildExecutions WHERE id=?", arguments: [childID.uuidString]) {
                try db.execute(sql: "INSERT OR IGNORE INTO agentWakeInbox(id,dedupKey,executionID,payload,createdAt) VALUES(?,?,?,?,?)",
                    arguments: [UUID().uuidString, "child-note:\(childID):\(id)", parent, Data(text.utf8), Date.now])
            }
        }
    }
    public func messages(toChild: Bool) throws -> [DurableSubagentMessage] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id,content FROM agentChildMessages WHERE childID=? AND direction=? AND (?=0 OR consumedAt IS NULL) ORDER BY rowid",
                             arguments: [childID.uuidString, toChild ? "child" : "parent", toChild ? 1 : 0])
                .map { DurableSubagentMessage(id: $0["id"], text: $0["content"]) }
        }
    }
    public func receipt(id: String, toChild: Bool) throws -> String? {
        try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM agentChildMessages WHERE childID=? AND direction=? AND id=?",
                                arguments: [childID.uuidString, toChild ? "child" : "parent", id])
        }
    }
}
