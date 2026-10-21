import AIMCore
import Foundation
import GRDB

/// A change made while the account could not be reached, replayed on the latest account memory.
public enum AccountMemoryPendingChange: Codable, Equatable, Sendable {
    case upsert(AccountMemoryEntry)
    case remove(UUID)

    /// An entry changed on another device after this change was made keeps that newer version.
    static func apply(_ changes: [Self], to snapshot: AccountMemorySnapshot) -> AccountMemorySnapshot {
        var result = snapshot
        for change in changes {
            switch change {
            case let .upsert(entry):
                if let index = result.entries.firstIndex(where: { $0.id == entry.id }) {
                    guard (result.entries[index].updatedAt ?? .distantPast) <= (entry.updatedAt ?? .distantPast) else { continue }
                    result.entries[index] = entry
                } else if result.entries.count < 2000 {
                    result.entries.append(entry)
                }
            case let .remove(id):
                result.entries.removeAll { $0.id == id }
            }
        }
        return result
    }
}

public struct AccountMemoryCacheRecord: Sendable, Equatable {
    public var snapshot: AccountMemorySnapshot?
    public var pending: [AccountMemoryPendingChange]
    public var refreshedAt: Date
    public init(snapshot: AccountMemorySnapshot?, pending: [AccountMemoryPendingChange], refreshedAt: Date) {
        self.snapshot = snapshot; self.pending = pending; self.refreshedAt = refreshedAt
    }
    /// What this Mac sees: the last account memory with its unsent changes.
    public var effective: AccountMemorySnapshot? { snapshot.map { AccountMemoryPendingChange.apply(pending, to: $0) } }
}

public protocol AccountMemoryCaching: Sendable {
    func record(accountID: UUID) async throws -> AccountMemoryCacheRecord?
    func store(_ record: AccountMemoryCacheRecord, accountID: UUID) async throws
    func remove(accountID: UUID) async throws
}

public struct SQLiteAccountMemoryCache: AccountMemoryCaching {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }
    public func record(accountID: UUID) async throws -> AccountMemoryCacheRecord? {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT snapshot, pending, refreshedAt FROM accountMemoryCache WHERE accountID = ?",
                                             arguments: [accountID.uuidString]) else { return nil }
            let decoder = JSONDecoder()
            let snapshot: AccountMemorySnapshot? = (row["snapshot"] as Data?).flatMap { try? decoder.decode(AccountMemorySnapshot.self, from: $0) }
            let pending = ((row["pending"] as Data?).flatMap { try? decoder.decode([AccountMemoryPendingChange].self, from: $0) }) ?? []
            return AccountMemoryCacheRecord(snapshot: snapshot, pending: pending, refreshedAt: row["refreshedAt"])
        }
    }
    public func store(_ record: AccountMemoryCacheRecord, accountID: UUID) async throws {
        let encoder = JSONEncoder()
        let snapshot = try record.snapshot.map { try encoder.encode($0) }, pending = try encoder.encode(record.pending)
        try await database.pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO accountMemoryCache(accountID, snapshot, pending, refreshedAt) VALUES (?, ?, ?, ?)",
                           arguments: [accountID.uuidString, snapshot, pending, record.refreshedAt])
        }
    }
    public func remove(accountID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM accountMemoryCache WHERE accountID = ?", arguments: [accountID.uuidString])
        }
    }
}

/// The account service while signed in without a connection: every call is "unreachable", so
/// memory falls back to this Mac's copy and keeps changes for later.
public struct UnreachableAccountContent: AccountContentSyncing {
    public init() {}
    public func documents(accountID: UUID) async throws -> [AccountDocument] { throw AccountServiceError.unavailable }
    public func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument { throw AccountServiceError.unavailable }
}
