import Foundation
import GRDB
import Darwin

public enum DatabaseOpenMode: Sendable { case migrate, existingSchemaOnly }
public enum DatabaseOpenError: Error { case migrationLock, missingSchema }

public final class AIMDatabase: @unchecked Sendable {
    public let pool: DatabasePool

    public init(path: String, mode: DatabaseOpenMode = .migrate) throws {
        let fd = Darwin.open(path + ".migration-lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DatabaseOpenError.migrationLock }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, flock(fd, LOCK_EX) == 0 else { throw DatabaseOpenError.migrationLock }
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        pool = try DatabasePool(path: path, configuration: configuration)
        if mode == .migrate { try Self.migrator.migrate(pool) }
        else {
            guard try pool.read({ db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='v47-memory-semantic-index'")
            }) == 1 else { throw DatabaseOpenError.missingSchema }
        }
    }

    public init(inMemory: Bool) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let name = inMemory ? "aim-tests-\(UUID().uuidString).sqlite" : "aim-tests.sqlite"
        pool = try DatabasePool(path: FileManager.default.temporaryDirectory.appending(path: name).path, configuration: configuration)
        try Self.migrator.migrate(pool)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-native-foundation") { db in
            // Create referenced tables before their dependants. SQLite accepts
            // an unresolved foreign key in some configurations, but validating
            // the schema with foreign_keys enabled requires this stable order.
            try db.create(table: "projects") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("instructions", .text).notNull().defaults(to: "")
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull().indexed()
            }

            try db.create(table: "projectSources") { table in
                table.column("id", .text).primaryKey()
                table.column("projectID", .text).notNull().indexed().references("projects", onDelete: .cascade)
                table.column("canonicalPath", .text).notNull()
                table.column("displayName", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("lastScannedAt", .datetime)
                table.uniqueKey(["projectID", "canonicalPath"])
            }

            try db.create(table: "conversations") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("mode", .text).notNull()
                table.column("projectID", .text).references("projects", onDelete: .setNull)
                table.column("engineID", .text)
                table.column("isArchived", .boolean).notNull().defaults(to: false)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull().indexed()
            }

            try db.create(table: "messages") { table in
                table.column("id", .text).primaryKey()
                table.column("conversationID", .text).notNull().indexed().references("conversations", onDelete: .cascade)
                table.column("role", .text).notNull()
                table.column("content", .text).notNull()
                table.column("sequence", .integer).notNull()
                table.column("createdAt", .datetime).notNull()
                table.uniqueKey(["conversationID", "sequence"])
            }

            try db.create(table: "memoryItemsV2") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull()
                table.column("scope", .text).notNull()
                table.column("scopeKey", .text).notNull().indexed()
                table.column("subjectKey", .text).notNull().indexed()
                table.column("content", .text).notNull()
                table.column("status", .text).notNull().indexed()
                table.column("confidence", .double).notNull()
                table.column("isPinned", .boolean).notNull().defaults(to: false)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull().indexed()
            }

            try db.create(table: "scheduledTasks") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("prompt", .text).notNull()
                table.column("recurrenceRule", .text)
                table.column("nextRunAt", .datetime).indexed()
                table.column("state", .text).notNull().indexed()
                table.column("consecutiveFailures", .integer).notNull().defaults(to: 0)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "scheduledExecutions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("taskID", .text).notNull().indexed().references("scheduledTasks", onDelete: .cascade)
                table.column("startedAt", .datetime).notNull()
                table.column("endedAt", .datetime)
                table.column("result", .text)
                table.column("error", .text)
            }

            try db.create(table: "activity") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("application", .text).notNull().indexed()
                table.column("title", .text).notNull()
                table.column("url", .text)
                table.column("startedAt", .datetime).notNull().indexed()
                table.column("endedAt", .datetime).notNull()
            }

            try db.create(table: "agentTaskNodes") { table in
                table.column("id", .text).primaryKey()
                table.column("sessionID", .text).notNull().indexed()
                table.column("parentID", .text).references("agentTaskNodes", onDelete: .cascade)
                table.column("type", .text).notNull()
                table.column("title", .text).notNull()
                table.column("status", .text).notNull().indexed()
                table.column("payloadJSON", .blob).notNull()
                table.column("resultJSON", .blob)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "agentTaskArtifacts") { table in
                table.column("id", .text).primaryKey()
                table.column("taskID", .text).notNull().indexed().references("agentTaskNodes", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("reference", .text).notNull()
                table.column("metadataJSON", .blob).notNull()
                table.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "sessionCompactions") { table in
                table.column("sessionID", .text).primaryKey()
                table.column("payloadJSON", .blob).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("version", .integer).notNull()
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE conversationSearch USING fts5(
                    conversationID UNINDEXED,
                    title,
                    content,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE VIRTUAL TABLE memorySearch USING fts5(
                    memoryID UNINDEXED,
                    content,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                """)
        }
        migrator.registerMigration("v2-conversation-routing") { db in
            try db.alter(table: "conversations") { table in
                table.add(column: "provider", .text)
                table.add(column: "modelID", .text)
                table.add(column: "workspacePath", .text)
            }
        }
        migrator.registerMigration("v3-workspace-run-history") { db in
            try db.create(table: "workspaceRuns") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationID", .text).notNull().indexed().references("conversations", onDelete: .cascade)
                t.column("provider", .text).notNull()
                t.column("modelID", .text).notNull()
                t.column("workspacePath", .text).notNull()
                t.column("state", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
            }
            try db.create(table: "workspaceCalls") { t in
                t.column("id", .text).notNull()
                t.column("runID", .text).notNull().indexed().references("workspaceRuns", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("argumentsJSON", .blob).notNull()
                t.column("state", .text).notNull()
                t.column("result", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.primaryKey(["runID", "id"])
                t.uniqueKey(["runID", "ordinal"])
            }
        }
        migrator.registerMigration("v4-project-document-snapshots") { db in
            try db.create(table: "projectDocuments") { t in
                t.column("id", .text).primaryKey()
                t.column("projectID", .text).notNull().indexed().references("projects", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("content", .text).notNull()
                t.column("importedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v5-message-text-attachments") { db in
            try db.alter(table: "messages") { $0.add(column: "attachmentsJSON", .blob) }
        }
        migrator.registerMigration("v6-composer-drafts") { db in
            try db.create(table: "composerDrafts") { table in
                table.column("scope", .text).primaryKey()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("v7-message-images") { db in
            try db.alter(table: "messages") { $0.add(column: "imagesJSON", .blob) }
        }
        migrator.registerMigration("v8-assistant-completion") { db in
            try db.alter(table: "messages") { $0.add(column: "completionStatus", .text) }
        }
        migrator.registerMigration("v9-memory-provenance") { db in
            try db.alter(table: "memoryItemsV2") { table in
                table.add(column: "evidenceQuote", .text)
                table.add(column: "sourceMessageID", .text)
            }
        }
        migrator.registerMigration("v10-project-source-index") { db in
            try db.create(table: "projectSourceChunks") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("sourceID", .text).notNull().indexed().references("projectSources", onDelete: .cascade)
                table.column("projectID", .text).notNull().indexed().references("projects", onDelete: .cascade)
                table.column("relativePath", .text).notNull()
                table.column("startLine", .integer).notNull()
                table.column("content", .text).notNull()
                table.uniqueKey(["sourceID", "relativePath", "startLine"])
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE projectSourceSearch USING fts5(
                    relativePath, content,
                    content = 'projectSourceChunks', content_rowid = 'id',
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER projectSourceChunks_insert AFTER INSERT ON projectSourceChunks BEGIN
                    INSERT INTO projectSourceSearch(rowid, relativePath, content)
                    VALUES (new.id, new.relativePath, new.content);
                END;
                CREATE TRIGGER projectSourceChunks_delete AFTER DELETE ON projectSourceChunks BEGIN
                    INSERT INTO projectSourceSearch(projectSourceSearch, rowid, relativePath, content)
                    VALUES ('delete', old.id, old.relativePath, old.content);
                END;
                """)
        }
        migrator.registerMigration("v11-project-memory-policy") { db in
            try db.alter(table: "projects") { $0.add(column: "usesGlobalMemory", .boolean) }
        }
        migrator.registerMigration("v12-conversation-pins") { db in
            try db.alter(table: "conversations") { $0.add(column: "pinnedAt", .datetime) }
        }
        migrator.registerMigration("v13-project-source-write-consent") { db in
            try db.alter(table: "projectSources") {
                $0.add(column: "writeAccessGranted", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v14-agent-plans") { db in
            try db.create(table: "agentPlans") { table in
                table.column("conversationID", .text).primaryKey().references("conversations", onDelete: .cascade)
                table.column("stepsJSON", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v15-tool-execution-evidence") { db in
            try db.alter(table: "workspaceCalls") {
                $0.add(column: "launchedAt", .datetime)
                $0.add(column: "executionEvidenceVersion", .integer)
                $0.add(column: "resultMetadataJSON", .blob)
            }
            try db.create(table: "toolResultArtifacts") {
                $0.column("id", .text).primaryKey()
                $0.column("runID", .text).notNull().indexed().references("workspaceRuns", onDelete: .cascade)
                $0.column("content", .blob).notNull()
            }
        }
        migrator.registerMigration("v16-agent-missions") { db in
            try db.create(table: "agentMissions") { table in
                table.column("id", .text).primaryKey()
                table.column("conversationID", .text).notNull().indexed().references("conversations", onDelete: .cascade)
                table.column("objective", .text).notNull()
                table.column("criteriaJSON", .blob).notNull()
                table.column("state", .text).notNull().indexed()
                table.column("stateReason", .text)
                table.column("activeRunID", .text)
                table.column("revision", .integer).notNull()
                table.column("createdAt", .datetime).notNull().indexed()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "agentMissionInputs") { table in
                table.column("id", .text).primaryKey()
                table.column("missionID", .text).notNull().indexed().references("agentMissions", onDelete: .cascade)
                table.column("content", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("consumedAt", .datetime)
            }
            try db.create(table: "agentMissionEvents") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("missionID", .text).notNull().indexed().references("agentMissions", onDelete: .cascade)
                table.column("revision", .integer).notNull()
                table.column("oldState", .text)
                table.column("newState", .text).notNull()
                table.column("reason", .text)
                table.column("occurredAt", .datetime).notNull()
                table.uniqueKey(["missionID", "revision"])
            }
        }
        migrator.registerMigration("v17-global-spend-ledger") { db in
            try db.create(table: "globalSpendPolicy") { table in
                table.column("id", .integer).primaryKey()
                table.column("enabled", .boolean).notNull()
                table.column("limitUSD", .text)
                table.column("period", .text).notNull()
                table.column("timeZoneID", .text).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "spendAttempts") { table in
                table.column("id", .text).primaryKey()
                table.column("provider", .text).notNull()
                table.column("modelID", .text).notNull()
                table.column("feature", .text).notNull()
                // No foreign key: deleting a conversation must not reset the
                // installation-wide accounting record.
                table.column("conversationID", .text)
                table.column("maximumUSD", .text)
                table.column("actualUSD", .text)
                table.column("state", .text).notNull().indexed()
                table.column("isException", .boolean).notNull()
                table.column("createdAt", .datetime).notNull().indexed()
                table.column("sentAt", .datetime)
                table.column("finalizedAt", .datetime)
            }
        }
        migrator.registerMigration("v18-mission-correction-link") { db in
            try db.alter(table: "agentMissionInputs") {
                $0.add(column: "conversationMessageID", .text)
            }
        }
        migrator.registerMigration("v19-agent-action-reconciliation") { db in
            try db.create(table: "agentActionReconciliations") { table in
                table.column("missionID", .text).notNull().indexed().references("agentMissions", onDelete: .cascade)
                table.column("runID", .text).notNull().references("workspaceRuns", onDelete: .cascade)
                table.column("callID", .text).notNull()
                table.column("assessment", .text).notNull()
                table.column("note", .text).notNull()
                table.column("reviewedAt", .datetime).notNull()
                table.primaryKey(["runID", "callID"])
            }
        }
        migrator.registerMigration("v20-mission-authorizations") { db in
            try db.create(table: "agentMissionAuthorizations") { table in
                table.column("missionID", .text).primaryKey().references("agentMissions", onDelete: .cascade)
                table.column("revision", .integer).notNull()
                table.column("rulesJSON", .blob).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("revokedAt", .datetime)
            }
            try db.create(table: "agentMissionAuthorizationEvents") { table in
                table.column("missionID", .text).notNull().references("agentMissions", onDelete: .cascade)
                table.column("revision", .integer).notNull()
                table.column("rulesJSON", .blob).notNull()
                table.column("revokedAt", .datetime)
                table.column("occurredAt", .datetime).notNull()
                table.primaryKey(["missionID", "revision"])
            }
        }
        migrator.registerMigration("v21-mission-file-evidence") { db in
            try db.create(table: "agentMissionFileEvidence") { table in
                table.column("id", .text).primaryKey()
                table.column("missionID", .text).notNull().indexed().references("agentMissions", onDelete: .cascade)
                table.column("criterionID", .text).notNull().indexed()
                table.column("workspacePath", .text).notNull()
                table.column("relativePath", .text).notNull()
                table.column("sha256", .text).notNull()
                table.column("byteCount", .integer).notNull()
                table.column("observedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v22-memory-subject-index") { db in
            // The original index contained only content. Rebuild it so a
            // remembered subject can be found without scanning all memories.
            try db.execute(sql: "DELETE FROM memorySearch")
            try db.execute(sql: """
                INSERT INTO memorySearch(memoryID, content)
                SELECT id, subjectKey || ' ' || content FROM memoryItemsV2
                """)
        }
        migrator.registerMigration("v23-subagent-jobs") { db in
            try db.create(table: "subagentJobs") { table in
                table.column("id", .text).primaryKey()
                table.column("conversationID", .text).notNull().indexed()
                    .references("conversations", onDelete: .cascade)
                table.column("workspacePath", .text).notNull()
                table.column("title", .text).notNull()
                table.column("prompt", .text).notNull()
                table.column("state", .text).notNull().indexed()
                table.column("result", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "subagentJobsScope", on: "subagentJobs",
                          columns: ["conversationID", "workspacePath", "createdAt"])
        }
        migrator.registerMigration("v24-subagent-retries") { db in
            try db.alter(table: "subagentJobs") {
                $0.add(column: "retryOf", .text)
            }
            // One approved retry per interrupted attempt. A retry can itself
            // be retried after another interruption, creating a clear chain.
            try db.create(index: "subagentJobsRetryOf", on: "subagentJobs",
                          columns: ["retryOf"], unique: true)
        }
        migrator.registerMigration("v25-spend-corrections") { db in
            try db.create(table: "spendCostCorrections") { table in
                table.column("id", .text).primaryKey()
                table.column("attemptID", .text).notNull().indexed()
                    .references("spendAttempts", onDelete: .cascade)
                table.column("previousUSD", .text).notNull()
                table.column("correctedUSD", .text).notNull()
                table.column("sourceID", .text).notNull()
                table.column("occurredAt", .datetime).notNull().indexed()
                table.uniqueKey(["attemptID", "sourceID"])
            }
        }
        migrator.registerMigration("v26-cua-qualifications") { db in
            try db.create(table: "cuaQualifications") { table in
                table.column("id", .text).primaryKey()
                table.column("keyDigest", .text).notNull().indexed()
                table.column("driverVersion", .text).notNull()
                table.column("driverSHA256", .text).notNull()
                table.column("osBuild", .text).notNull()
                table.column("adapterContract", .text).notNull()
                table.column("capability", .text).notNull()
                table.column("schemaDigest", .text).notNull()
                table.column("qualifiedAt", .datetime).notNull()
                table.column("evidence", .text).notNull()
                table.column("disqualifiedAt", .datetime)
                table.column("disqualificationReason", .text)
            }
        }
        migrator.registerMigration("v27-mission-check-evidence") { db in
            try db.create(table: "agentMissionCheckEvidence") { table in
                table.column("id", .text).primaryKey()
                table.column("missionID", .text).notNull().indexed().references("agentMissions", onDelete: .cascade)
                table.column("criterionID", .text).notNull().indexed()
                table.column("kind", .text).notNull()
                table.column("digest", .text).notNull()
                table.column("summary", .text).notNull()
                table.column("observedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v28-mcp-servers") { db in
            try db.create(table: "mcpServers") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull().unique()
                table.column("configJSON", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v29-scheduled-task-runtime") { db in
            try db.alter(table: "scheduledTasks") { table in
                table.add(column: "specJSON", .blob)
                table.add(column: "runningSince", .datetime)
                table.add(column: "lastRunAt", .datetime)
                table.add(column: "lastStatus", .text)
                table.add(column: "pausedReason", .text)
            }
            try db.alter(table: "scheduledExecutions") { table in
                table.add(column: "conversationID", .text)
                table.add(column: "status", .text)
            }
        }
        migrator.registerMigration("v30-subagent-workspaces") { db in
            try db.create(table: "subagentWorkspaces") { table in
                table.column("jobID", .text).primaryKey()
                table.column("state", .text).notNull()
                table.column("recordJSON", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v31-message-metrics-and-conversation-state") { db in
            try db.create(table: "messageMetrics") { table in
                table.column("messageID", .text).primaryKey()
                table.column("conversationID", .text).notNull().indexed().references("conversations", onDelete: .cascade)
                table.column("createdAt", .datetime).notNull().indexed()
                table.column("provider", .text).notNull()
                table.column("modelID", .text).notNull()
                table.column("isLocal", .boolean).notNull()
                table.column("totalTokens", .integer).notNull()
                table.column("metricsJSON", .blob).notNull()
            }
            try db.create(table: "conversationState") { table in
                table.column("conversationID", .text).primaryKey().references("conversations", onDelete: .cascade)
                table.column("titleSource", .text)
                table.column("lastReadAt", .datetime)
            }
        }
        migrator.registerMigration("v32-conversation-context-usage") { db in
            try db.alter(table: "conversationState") { table in
                table.add(column: "contextUsageJSON", .blob)
            }
        }
        migrator.registerMigration("v33-message-videos") { db in
            try db.alter(table: "messages") { $0.add(column: "videosJSON", .blob) }
        }
        migrator.registerMigration("v34-agent-continuity") { db in
            try db.execute(sql: """
                CREATE TABLE agentRuntimeOwner (id INTEGER PRIMARY KEY CHECK(id = 1), generation TEXT NOT NULL);
                CREATE TABLE agentExecutions (
                    id TEXT PRIMARY KEY, commandID TEXT NOT NULL UNIQUE,
                    conversationID TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    accountID TEXT, request BLOB NOT NULL, state TEXT NOT NULL,
                    revision INTEGER NOT NULL, ownerGeneration TEXT, reason TEXT,
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
                    record BLOB NOT NULL, checkpoint BLOB
                );
                CREATE UNIQUE INDEX agentActiveConversation ON agentExecutions(conversationID)
                    WHERE state NOT IN ('verified','accepted','failed','cancelled');
                CREATE TABLE agentExecutionEvents (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    executionID TEXT NOT NULL REFERENCES agentExecutions(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, payload BLOB NOT NULL, createdAt DATETIME NOT NULL
                );
                CREATE TABLE agentWakeConditions (
                    id TEXT PRIMARY KEY,
                    executionID TEXT NOT NULL REFERENCES agentExecutions(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, eventKey TEXT NOT NULL, dueAt DATETIME,
                    UNIQUE(executionID, kind, eventKey)
                );
                CREATE TABLE agentWakeInbox (
                    id TEXT PRIMARY KEY, dedupKey TEXT NOT NULL UNIQUE,
                    executionID TEXT NOT NULL REFERENCES agentExecutions(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL, createdAt DATETIME NOT NULL, consumedAt DATETIME
                );
                CREATE TABLE agentDeliveryOutbox (
                    id TEXT PRIMARY KEY,
                    executionID TEXT NOT NULL REFERENCES agentExecutions(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL, createdAt DATETIME NOT NULL, deliveredAt DATETIME
                );
                """)
        }
        migrator.registerMigration("v35-agent-conversation-archives") { db in
            try db.execute(sql: """
                CREATE TABLE agentConversationArchives (
                    id TEXT PRIMARY KEY,
                    executionID TEXT NOT NULL REFERENCES agentExecutions(id) ON DELETE CASCADE,
                    content BLOB NOT NULL, createdAt DATETIME NOT NULL
                );
                """)
        }
        migrator.registerMigration("v36-execution-archive-references") { db in
            try db.alter(table: "agentConversationArchives") { table in
                table.add(column: "artifactReference", .text)
                table.add(column: "byteCount", .integer)
            }
        }
        migrator.registerMigration("v37-durable-subagents") { db in
            try db.execute(sql: """
                CREATE TABLE agentChildExecutions (
                    id TEXT PRIMARY KEY,
                    parentExecutionID TEXT NOT NULL REFERENCES agentExecutions(id) ON DELETE CASCADE,
                    admissionCallID TEXT NOT NULL,
                    record BLOB NOT NULL, checkpoint BLOB,
                    UNIQUE(parentExecutionID, admissionCallID)
                );
                CREATE TABLE agentChildMessages (
                    id TEXT NOT NULL,
                    childID TEXT NOT NULL REFERENCES agentChildExecutions(id) ON DELETE CASCADE,
                    direction TEXT NOT NULL, content TEXT NOT NULL,
                    createdAt DATETIME NOT NULL, consumedAt DATETIME,
                    PRIMARY KEY(childID, direction, id)
                );
                """)
        }
        migrator.registerMigration("v38-agent-interactions") { db in
            try db.execute(sql: """
                CREATE TABLE agentInteractions (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, sessionID TEXT NOT NULL,
                    payload BLOB NOT NULL, response BLOB, createdAt DATETIME NOT NULL, answeredAt DATETIME
                );
                """)
        }
        migrator.registerMigration("v39-agent-control-receipts") { db in
            try db.execute(sql: """
                CREATE TABLE agentControlReceipts (
                    id TEXT PRIMARY KEY,
                    executionID TEXT NOT NULL REFERENCES agentExecutions(id) ON DELETE CASCADE,
                    action TEXT NOT NULL, payload BLOB NOT NULL, result BLOB NOT NULL, createdAt DATETIME NOT NULL
                );
                """)
        }
        migrator.registerMigration("v40-execution-spend") { db in
            try db.execute(sql: """
                CREATE TABLE agentExecutionSpend (
                    attemptID TEXT PRIMARY KEY REFERENCES spendAttempts(id),
                    executionID TEXT NOT NULL REFERENCES agentExecutions(id),
                    ownerGeneration TEXT NOT NULL
                );
                CREATE INDEX agentExecutionSpendByExecution ON agentExecutionSpend(executionID);
                """)
        }
        migrator.registerMigration("v41-remote-continuity-receipts") { db in
            try db.execute(sql: """
                CREATE TABLE agentRemoteReceipts (
                    id TEXT NOT NULL, accountID TEXT NOT NULL, machineID TEXT NOT NULL,
                    payload BLOB NOT NULL, delivered BOOLEAN NOT NULL DEFAULT 0,
                    PRIMARY KEY(id, accountID, machineID)
                );
                """)
        }
        migrator.registerMigration("v42-durable-schedule-admissions") { db in
            try db.execute(sql: """
                CREATE TABLE agentScheduleAdmissions (
                    commandID TEXT PRIMARY KEY, taskID TEXT NOT NULL,
                    conversationID TEXT NOT NULL, claimID INTEGER NOT NULL UNIQUE REFERENCES scheduledExecutions(id),
                    payload BLOB NOT NULL, completed BOOLEAN NOT NULL DEFAULT 0
                );
                CREATE TABLE agentScheduleEvents (
                    id TEXT PRIMARY KEY, taskID TEXT NOT NULL, dedupKey TEXT NOT NULL UNIQUE,
                    reason TEXT NOT NULL, payload TEXT, createdAt DATETIME NOT NULL, consumedAt DATETIME
                );
                """)
        }
        migrator.registerMigration("v43-wake-baselines") { db in
            try db.alter(table: "agentWakeConditions") { $0.add(column: "baseline", .text) }
        }
        migrator.registerMigration("v44-trigger-observations") { db in
            try db.execute(sql: "CREATE TABLE agentTriggerBaselines(taskID TEXT PRIMARY KEY, sourceSignature TEXT NOT NULL, output TEXT NOT NULL)")
        }
        migrator.registerMigration("v45-durable-processes") { db in
            try db.execute(sql: """
                CREATE TABLE agentProcesses (
                    id TEXT PRIMARY KEY, executionID TEXT NOT NULL REFERENCES agentExecutions(id),
                    admissionCallID TEXT NOT NULL, workspacePath TEXT NOT NULL, state TEXT NOT NULL,
                    version INTEGER NOT NULL, payload BLOB NOT NULL, artifactReference TEXT,
                    UNIQUE(executionID,admissionCallID)
                );
                """)
        }
        migrator.registerMigration("v46-execution-inputs") { db in
            try db.execute(sql: "CREATE TABLE agentExecutionInputs(id TEXT PRIMARY KEY, executionID TEXT NOT NULL REFERENCES agentExecutions(id), content TEXT NOT NULL, consumed BOOLEAN NOT NULL DEFAULT 0)")
        }
        migrator.registerMigration("v47-memory-semantic-index") { db in
            try db.execute(sql: """
                CREATE TABLE memorySemanticIndex (
                    memoryID TEXT PRIMARY KEY NOT NULL REFERENCES memoryItemsV2(id) ON DELETE CASCADE,
                    contentHash TEXT NOT NULL, vector BLOB, updatedAt DATETIME NOT NULL
                )
                """)
        }
        migrator.registerMigration("v48-account-activity") { db in
            try db.execute(sql: """
                CREATE TABLE accountActivity(id TEXT PRIMARY KEY, accountID TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX accountActivityByAccount ON accountActivity(accountID);
                CREATE TABLE activityConversationOwners(conversationID TEXT PRIMARY KEY, accountID TEXT NOT NULL, since DATETIME NOT NULL);
                """)
        }
        migrator.registerMigration("v49-conversation-actions") { db in
            try db.alter(table: "messages") { $0.add(column: "actionsJSON", .blob); $0.add(column: "visualReportJSON", .blob) }
        }
        // Round 37: the account's memory kept on this Mac (read without network) and the
        // changes waiting to reach the account when it was unreachable.
        migrator.registerMigration("v50-account-memory-cache") { db in
            try db.execute(sql: """
                CREATE TABLE accountMemoryCache(accountID TEXT PRIMARY KEY, snapshot BLOB, pending BLOB NOT NULL,
                    refreshedAt DATETIME NOT NULL);
                """)
        }
        migrator.registerMigration("v51-project-sync-pin") { db in
            try db.alter(table: "projects") { $0.add(column: "isPinned", .boolean) }
        }
        migrator.registerMigration("v52-estimated-web-budget") { db in
            try db.alter(table: "globalSpendPolicy") { $0.add(column: "requiresVerifiedWebSearch", .boolean).notNull().defaults(to: false) }
        }
        migrator.registerMigration("v53-spend-estimates") { db in
            try db.alter(table: "spendAttempts") { $0.add(column: "estimatedUSD", .text) }
        }
        return migrator
    }
}
