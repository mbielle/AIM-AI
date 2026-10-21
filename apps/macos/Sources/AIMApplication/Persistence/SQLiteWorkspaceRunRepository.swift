import Foundation
import AIMCore
import GRDB

extension WorkspaceRun: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "workspaceRuns" }
}
extension WorkspaceCall: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "workspaceCalls" }
}

public actor SQLiteWorkspaceRunRepository: WorkspaceRunRepository, ToolArtifactRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func begin(_ run: WorkspaceRun) throws {
        guard run.state == .running, run.endedAt == nil, UUID(uuidString: run.id) != nil,
              UUID(uuidString: run.conversationID) != nil, (run.workspacePath.isEmpty || run.workspacePath.hasPrefix("/")),
              run.workspacePath.utf8.count <= 16_384, run.modelID.utf8.count <= 255 else { throw WorkspaceHistoryError.invalidRecord }
        try database.pool.write { db in try run.insert(db) }
    }

    public func saveToolArtifact(id: String, runID: String, content: Data) throws {
        guard UUID(uuidString: id) != nil, content.count <= 32 * 1_024 * 1_024 else { throw WorkspaceHistoryError.invalidRecord }
        try database.pool.write { db in
            guard try WorkspaceRun.fetchOne(db, key: runID)?.state == .running else { throw WorkspaceHistoryError.invalidTransition }
            try db.execute(sql: "INSERT INTO toolResultArtifacts (id, runID, content) VALUES (?, ?, ?)", arguments: [id, runID, content])
        }
    }

    public func readToolArtifact(id: String, runID: String, offset: Int, limit: Int) throws -> ToolArtifactPage {
        guard offset >= 0, offset < Int.max, (1...65_536).contains(limit) else {
            throw WorkspaceHistoryError.invalidRecord
        }
        return try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT LENGTH(content) AS byteCount,
                       SUBSTR(content, ?, ?) AS pageBytes
                FROM toolResultArtifacts WHERE id = ? AND runID = ?
                """, arguments: [offset + 1, limit + 4, id, runID]) else {
                throw WorkspaceHistoryError.invalidRecord
            }
            return try ToolArtifactPage(id: id, window: row["pageBytes"],
                                        totalBytes: row["byteCount"], offset: offset, limit: limit)
        }
    }

    public func readToolArtifact(id: String, conversationID: UUID, workspacePath: String,
                                 offset: Int, limit: Int) throws -> ToolArtifactPage {
        guard UUID(uuidString: id) != nil, workspacePath.hasPrefix("/"), offset >= 0,
              offset < Int.max, (1...65_536).contains(limit) else {
            throw WorkspaceHistoryError.invalidRecord
        }
        return try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT LENGTH(a.content) AS byteCount,
                       SUBSTR(a.content, ?, ?) AS pageBytes
                FROM toolResultArtifacts AS a
                JOIN workspaceRuns AS r ON r.id = a.runID
                WHERE a.id = ? AND r.conversationID = ? AND r.workspacePath = ?
                """, arguments: [offset + 1, limit + 4, id,
                                 conversationID.uuidString, workspacePath]) else {
                throw WorkspaceHistoryError.invalidRecord
            }
            return try ToolArtifactPage(id: id, window: row["pageBytes"],
                                        totalBytes: row["byteCount"], offset: offset, limit: limit)
        }
    }

    public func listToolArtifacts(conversationID: UUID, workspacePath: String,
                                  offset: Int, limit: Int) throws -> ToolArtifactListing {
        guard workspacePath.hasPrefix("/"), offset >= 0,
              (1...100).contains(limit), offset <= Int.max - limit else {
            throw WorkspaceHistoryError.invalidRecord
        }
        return try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.runID, LENGTH(a.content) AS byteCount,
                       r.startedAt AS runStartedAt
                FROM toolResultArtifacts AS a
                JOIN workspaceRuns AS r ON r.id = a.runID
                WHERE r.conversationID = ? AND r.workspacePath = ?
                ORDER BY r.startedAt DESC, a.id DESC
                LIMIT ? OFFSET ?
                """, arguments: [conversationID.uuidString, workspacePath, limit + 1, offset])
            let summaries = rows.prefix(limit).map { row in
                ToolArtifactSummary(id: row["id"], runID: row["runID"],
                                    byteCount: row["byteCount"], runStartedAt: row["runStartedAt"])
            }
            return ToolArtifactListing(artifacts: summaries,
                                       nextOffset: rows.count > limit ? offset + limit : nil)
        }
    }

    public func requested(_ call: WorkspaceCall) throws {
        guard !call.id.isEmpty, call.id.utf8.count <= 256, call.name.utf8.count <= 128,
              call.argumentsJSON.count <= ToolPayloadLimits.argumentsJSONBytes, call.state == .requested, call.result == nil, call.endedAt == nil,
              call.ordinal >= 0,
              (try? ToolJSONValue.decodeObject(call.argumentsJSON)) != nil else { throw WorkspaceHistoryError.invalidRecord }
        try database.pool.write { db in
            guard let run = try WorkspaceRun.fetchOne(db, key: call.runID), run.state == .running,
                  try WorkspaceCall.filter(Column("runID") == call.runID).fetchCount(db) == call.ordinal else { throw WorkspaceHistoryError.invalidTransition }
            try call.insert(db)
            try db.execute(sql: "UPDATE workspaceCalls SET executionEvidenceVersion = 1 WHERE runID = ? AND id = ?",
                           arguments: [call.runID, call.id])
        }
    }

    public func launched(runID: String, callID: String) throws {
        try database.pool.write { db in
            guard try WorkspaceRun.fetchOne(db, key: runID)?.state == .running else {
                throw WorkspaceHistoryError.invalidTransition
            }
            try db.execute(sql: """
                UPDATE workspaceCalls SET launchedAt = ?
                WHERE runID = ? AND id = ? AND state = 'requested' AND launchedAt IS NULL
                """, arguments: [Date.now, runID, callID])
            guard db.changesCount == 1 else { throw WorkspaceHistoryError.invalidTransition }
        }
    }

    public func returned(runID: String, output: ModelToolOutput) throws {
        guard output.content.utf8.count <= ToolPayloadLimits.resultEnvelopeBytes else { throw WorkspaceHistoryError.invalidRecord }
        var metadata = output.metadata
        if let image = output.imagePNG, let preview = InputMediaPreview.jpeg(image) { metadata["aim_preview_jpeg"] = preview.base64EncodedString() }
        let savedMetadata = try JSONEncoder().encode(metadata)
        try database.pool.write { db in
            guard let run = try WorkspaceRun.fetchOne(db, key: runID), run.state == .running,
                  var call = try WorkspaceCall.fetchOne(db, key: ["runID": runID, "id": output.id]), call.state == .requested else { throw WorkspaceHistoryError.invalidTransition }
            call.state = output.isError ? .failed : .succeeded
            call.result = output.content; call.endedAt = .now
            try call.update(db)
            try db.execute(sql: "UPDATE workspaceCalls SET resultMetadataJSON = ? WHERE runID = ? AND id = ?",
                           arguments: [savedMetadata, runID, output.id])
        }
    }

    public func finish(runID: String, state: WorkspaceRunState) throws {
        guard state != .running else { throw WorkspaceHistoryError.invalidTransition }
        try database.pool.write { db in
            guard var run = try WorkspaceRun.fetchOne(db, key: runID), run.state == .running else { throw WorkspaceHistoryError.invalidTransition }
            let pending = try WorkspaceCall.filter(Column("runID") == runID && Column("state") == WorkspaceCallState.requested.rawValue).fetchAll(db)
            guard (state != .completed && state != .unverified) || pending.isEmpty else { throw WorkspaceHistoryError.invalidTransition }
            for var call in pending {
                call.state = .interrupted; call.endedAt = .now
                try call.update(db)
            }
            run.state = state; run.endedAt = .now
            try run.update(db)
        }
    }

    public func history(conversationID: UUID, limit: Int = 50) throws -> [WorkspaceRunHistory] {
        try database.pool.read { db in
            let runs = try WorkspaceRun.filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("startedAt").desc, Column("id")).limit(max(1, min(limit, 100))).fetchAll(db)
            return try runs.map { run in
                let calls = try WorkspaceCall.filter(Column("runID") == run.id).order(Column("ordinal")).fetchAll(db)
                return WorkspaceRunHistory(run: run, calls: calls)
            }
        }
    }

    public func run(id: String) async throws -> WorkspaceRunHistory? {
        try await database.pool.read { db in
            guard let run = try WorkspaceRun.fetchOne(db, key: id) else { return nil }
            let calls = try WorkspaceCall.filter(Column("runID") == id).order(Column("ordinal")).fetchAll(db)
            return WorkspaceRunHistory(run: run, calls: calls)
        }
    }
}
