import Foundation
import GRDB

private struct MCPServerRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mcpServers"
    var id: String
    var name: String
    var configJSON: Data
    var updatedAt: Date
}

public actor SQLiteMCPServerRepository: MCPServerRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func list() throws -> [MCPServerConfiguration] {
        try database.pool.read { db in
            try MCPServerRow.order(Column("name")).fetchAll(db).compactMap {
                try? JSONDecoder().decode(MCPServerConfiguration.self, from: $0.configJSON)
            }
        }
    }

    public func save(_ server: MCPServerConfiguration) throws {
        guard server.isValid else { throw WorkspaceHistoryError.invalidRecord }
        var updated = server
        updated.updatedAt = .now
        let row = MCPServerRow(id: server.id.uuidString, name: server.name,
            configJSON: try JSONEncoder().encode(updated), updatedAt: updated.updatedAt)
        try database.pool.write { db in
            if let other = try MCPServerRow.filter(Column("name") == server.name).fetchOne(db), other.id != row.id {
                throw WorkspaceHistoryError.invalidRecord
            }
            try row.save(db)
        }
    }

    public func delete(id: UUID) throws {
        _ = try database.pool.write { db in try MCPServerRow.deleteOne(db, key: id.uuidString) }
    }
}
