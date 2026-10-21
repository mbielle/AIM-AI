import Foundation
import GRDB

private struct SubagentWorkspaceRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "subagentWorkspaces"
    var jobID: String
    var state: String
    var recordJSON: Data
    var updatedAt: Date
}

public actor SQLiteSubagentWorkspaceRepository: SubagentWorkspaceRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func save(_ record: SubagentWorkspaceRecord) throws {
        guard record.repositoryRoot.hasPrefix("/"), record.worktreePath.hasPrefix("/"),
              !record.relativeWorkspace.hasPrefix("/"), record.branch.hasPrefix("aim/subagent-") else {
            throw WorkspaceHistoryError.invalidRecord
        }
        let row = SubagentWorkspaceRow(jobID: record.jobID.uuidString, state: record.state.rawValue,
                                       recordJSON: try JSONEncoder().encode(record), updatedAt: record.updatedAt)
        try database.pool.write { db in try row.save(db) }
    }

    public func load(jobID: UUID) throws -> SubagentWorkspaceRecord? {
        try database.pool.read { db in
            try SubagentWorkspaceRow.fetchOne(db, key: jobID.uuidString)
        }.flatMap { try? JSONDecoder().decode(SubagentWorkspaceRecord.self, from: $0.recordJSON) }
    }

    public func list(states: Set<SubagentWorkspaceRecord.State>) throws -> [SubagentWorkspaceRecord] {
        try database.pool.read { db in
            try SubagentWorkspaceRow.filter(states.map(\.rawValue).contains(Column("state")))
                .order(Column("updatedAt").desc).fetchAll(db)
        }.compactMap { try? JSONDecoder().decode(SubagentWorkspaceRecord.self, from: $0.recordJSON) }
    }
}
