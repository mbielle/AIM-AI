import Foundation
import GRDB

private struct SubagentJobRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "subagentJobs"
    var id: String
    var conversationID: String
    var workspacePath: String
    var title: String
    var prompt: String
    var retryOf: String?
    var state: String
    var result: String?
    var createdAt: Date
    var updatedAt: Date

    init(_ job: SubagentJobRecord) {
        id = job.id.uuidString; conversationID = job.conversationID.uuidString
        workspacePath = job.workspacePath; title = job.title; prompt = job.prompt
        retryOf = job.retryOf?.uuidString
        state = job.state.rawValue; result = job.result
        createdAt = job.createdAt; updatedAt = job.updatedAt
    }

    var job: SubagentJobRecord? {
        guard let id = UUID(uuidString: id), let conversationID = UUID(uuidString: conversationID),
              let state = SubagentJobState(rawValue: state) else { return nil }
        return SubagentJobRecord(id: id, conversationID: conversationID,
            workspacePath: workspacePath, title: title, prompt: prompt,
            retryOf: retryOf.flatMap(UUID.init(uuidString:)),
            state: state, result: result, createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// The journal survives AIM restarts. Unfinished children are marked uncertain
/// on startup rather than silently rerun (which could duplicate provider cost).
public actor SQLiteSubagentJobRepository: SubagentJobRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func enqueue(_ job: SubagentJobRecord) throws {
        guard job.state == .queued, job.result == nil,
              job.workspacePath.hasPrefix("/"), !job.workspacePath.contains("\0"),
              job.workspacePath.utf8.count <= 16_384,
              !job.title.isEmpty, job.title.utf8.count <= 400,
              !job.prompt.isEmpty, job.prompt.utf8.count <= 16_000,
              job.retryOf != job.id else {
            throw WorkspaceHistoryError.invalidRecord
        }
        try database.pool.write { db in
            if let retryOf = job.retryOf {
                guard let original = try SubagentJobRow.fetchOne(db, key: retryOf.uuidString),
                      original.conversationID == job.conversationID.uuidString,
                      original.workspacePath == job.workspacePath,
                      original.state == SubagentJobState.interrupted.rawValue else {
                    throw WorkspaceHistoryError.invalidTransition
                }
            }
            try SubagentJobRow(job).insert(db)
        }
    }

    public func markRunning(id: UUID) throws {
        try database.pool.write { db in
            try db.execute(sql: """
                UPDATE subagentJobs SET state = 'running', updatedAt = ?
                WHERE id = ? AND state = 'queued'
                """, arguments: [Date.now, id.uuidString])
            guard db.changesCount == 1 else { throw WorkspaceHistoryError.invalidTransition }
        }
    }

    public func finish(id: UUID, state: SubagentJobState, result: String?) throws {
        guard [.done, .error, .cancelled].contains(state),
              (result?.utf8.count ?? 0) <= 160_000 else { throw WorkspaceHistoryError.invalidRecord }
        try database.pool.write { db in
            try db.execute(sql: """
                UPDATE subagentJobs SET state = ?, result = ?, updatedAt = ?
                WHERE id = ? AND state = 'running'
                """, arguments: [state.rawValue, result, Date.now, id.uuidString])
            if db.changesCount == 0 {
                // A prior cancellation wins over a late model response.
                guard state == .cancelled,
                      try String.fetchOne(db, sql: "SELECT state FROM subagentJobs WHERE id = ?",
                                          arguments: [id.uuidString]) == SubagentJobState.cancelled.rawValue else {
                    throw WorkspaceHistoryError.invalidTransition
                }
            }
        }
    }

    public func cancel(id: UUID) throws {
        try database.pool.write { db in
            try db.execute(sql: """
                UPDATE subagentJobs SET state = 'cancelled',
                    result = 'Cancelled before its result could be accepted.', updatedAt = ?
                WHERE id = ? AND state IN ('queued', 'running')
                """, arguments: [Date.now, id.uuidString])
            if db.changesCount == 0 {
                guard try SubagentJobRow.fetchOne(db, key: id.uuidString) != nil else {
                    throw WorkspaceHistoryError.invalidRecord
                }
            }
        }
    }

    public func load(id: UUID, conversationID: UUID,
                     workspacePath: String) throws -> SubagentJobRecord? {
        try database.pool.read { db in
            guard let row = try SubagentJobRow.fetchOne(db, key: id.uuidString),
                  row.conversationID == conversationID.uuidString,
                  row.workspacePath == workspacePath else { return nil }
            return row.job
        }
    }

    public func list(conversationID: UUID, workspacePath: String,
                     offset: Int, limit: Int) throws -> SubagentJobPage {
        guard workspacePath.hasPrefix("/"), offset >= 0,
              (1...20).contains(limit), offset <= Int.max - limit else {
            throw WorkspaceHistoryError.invalidRecord
        }
        return try database.pool.read { db in
            let total = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM subagentJobs WHERE conversationID = ? AND workspacePath = ?
                """, arguments: [conversationID.uuidString, workspacePath]) ?? 0
            let active = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM subagentJobs
                WHERE conversationID = ? AND workspacePath = ? AND state IN ('queued', 'running')
                """, arguments: [conversationID.uuidString, workspacePath]) ?? 0
            let rows = try SubagentJobRow.fetchAll(db, sql: """
                SELECT * FROM subagentJobs WHERE conversationID = ? AND workspacePath = ?
                ORDER BY createdAt ASC, id ASC LIMIT ? OFFSET ?
                """, arguments: [conversationID.uuidString, workspacePath, limit, offset])
            let jobs = rows.compactMap(\.job)
            return SubagentJobPage(jobs: jobs,
                nextOffset: offset + jobs.count < total ? offset + jobs.count : nil,
                totalJobs: total, activeJobs: active)
        }
    }

    public func recoverInterrupted() throws -> Int {
        try database.pool.write { db in
            try db.execute(sql: """
                UPDATE subagentJobs SET state = 'interrupted',
                    result = 'AIM stopped before this child returned a verified result. Review before retrying.',
                    updatedAt = ?
                WHERE state IN ('queued', 'running')
                """, arguments: [Date.now])
            return db.changesCount
        }
    }
}
