import Foundation
import GRDB

private struct MissionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentMissions"
    var id: String
    var conversationID: String
    var objective: String
    var criteriaJSON: Data
    var state: String
    var stateReason: String?
    var activeRunID: String?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    init(_ mission: AgentMission) throws {
        id = mission.id.uuidString
        conversationID = mission.conversationID.uuidString
        objective = mission.objective
        criteriaJSON = try JSONEncoder().encode(mission.criteria)
        state = mission.state.rawValue
        stateReason = mission.stateReason
        activeRunID = mission.activeRunID
        revision = mission.revision
        createdAt = mission.createdAt
        updatedAt = mission.updatedAt
    }

    func mission() throws -> AgentMission {
        guard let missionID = UUID(uuidString: id), let conversation = UUID(uuidString: conversationID),
              let state = AgentMissionState(rawValue: state),
              let criteria = try? JSONDecoder().decode([AgentMissionCriterion].self, from: criteriaJSON) else {
            throw AgentMissionError.invalidInput
        }
        var mission = AgentMission(id: missionID, conversationID: conversation, objective: objective,
                                   criteria: criteria, createdAt: createdAt)
        mission.state = state
        mission.stateReason = stateReason
        mission.activeRunID = activeRunID
        mission.updatedAt = updatedAt
        mission.revision = revision
        return mission
    }
}

private struct MissionInputRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentMissionInputs"
    var id: String
    var missionID: String
    var content: String
    var conversationMessageID: String?
    var createdAt: Date
    var consumedAt: Date?

    init(_ input: AgentMissionInput) {
        id = input.id.uuidString
        missionID = input.missionID.uuidString
        content = input.content
        conversationMessageID = input.conversationMessageID?.uuidString
        createdAt = input.createdAt
        consumedAt = input.consumedAt
    }

    func input() throws -> AgentMissionInput {
        guard let id = UUID(uuidString: id), let missionID = UUID(uuidString: missionID) else {
            throw AgentMissionError.invalidInput
        }
        var input = AgentMissionInput(id: id, missionID: missionID, content: content,
                                      conversationMessageID: conversationMessageID.flatMap(UUID.init(uuidString:)), createdAt: createdAt)
        input.consumedAt = consumedAt
        return input
    }
}

private struct MissionCheckEvidenceRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentMissionCheckEvidence"
    var id: String
    var missionID: String
    var criterionID: String
    var kind: String
    var digest: String
    var summary: String
    var observedAt: Date

    func evidence() throws -> MissionCheckEvidence {
        guard let id = UUID(uuidString: id), let missionID = UUID(uuidString: missionID),
              let criterionID = UUID(uuidString: criterionID),
              let kind = MissionHostCheck.Kind(rawValue: kind) else { throw AgentMissionError.invalidInput }
        return MissionCheckEvidence(id: id, missionID: missionID, criterionID: criterionID, kind: kind,
            digest: digest, summary: summary, observedAt: observedAt)
    }
}

private struct MissionFileEvidenceRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentMissionFileEvidence"
    var id: String
    var missionID: String
    var criterionID: String
    var workspacePath: String
    var relativePath: String
    var sha256: String
    var byteCount: Int64
    var observedAt: Date

    init(_ evidence: MissionFileEvidence) {
        id = evidence.id.uuidString
        missionID = evidence.missionID.uuidString
        criterionID = evidence.criterionID.uuidString
        workspacePath = evidence.workspacePath
        relativePath = evidence.relativePath
        sha256 = evidence.sha256
        byteCount = evidence.byteCount
        observedAt = evidence.observedAt
    }

    func evidence() throws -> MissionFileEvidence {
        guard let id = UUID(uuidString: id), let missionID = UUID(uuidString: missionID),
              let criterionID = UUID(uuidString: criterionID) else { throw AgentMissionError.invalidInput }
        return MissionFileEvidence(id: id, missionID: missionID, criterionID: criterionID,
            workspacePath: workspacePath, relativePath: relativePath,
            sha256: sha256, byteCount: byteCount, observedAt: observedAt)
    }
}

private struct ReconciliationRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentActionReconciliations"
    var missionID: String
    var runID: String
    var callID: String
    var assessment: String
    var note: String
    var reviewedAt: Date

    init(_ value: ActionReconciliation) {
        missionID = value.missionID.uuidString
        runID = value.runID
        callID = value.callID
        assessment = value.assessment.rawValue
        note = value.note
        reviewedAt = value.reviewedAt
    }

    func value() throws -> ActionReconciliation {
        guard let missionID = UUID(uuidString: missionID),
              let assessment = ActionEffectAssessment(rawValue: assessment) else {
            throw AgentMissionError.invalidInput
        }
        return ActionReconciliation(missionID: missionID, runID: runID, callID: callID,
                                    assessment: assessment, note: note, reviewedAt: reviewedAt)
    }
}

private struct MissionAuthorizationRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentMissionAuthorizations"
    var missionID: String
    var revision: Int
    var rulesJSON: Data
    var createdAt: Date
    var updatedAt: Date
    var revokedAt: Date?

    init(_ value: MissionAuthorization) throws {
        missionID = value.missionID.uuidString
        revision = value.revision
        rulesJSON = try JSONEncoder().encode(value.rules)
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        revokedAt = value.revokedAt
    }

    func authorization() throws -> MissionAuthorization {
        guard let id = UUID(uuidString: missionID), revision >= 0,
              let stored = try? JSONDecoder().decode([MissionAuthorizationRule].self, from: rulesJSON),
              stored.count <= 128 else { throw MissionAuthorizationError.invalidScope }
        let rules = try stored.map {
            let resource = try MissionResource(kind: $0.resource.kind, identifier: $0.resource.identifier)
            guard resource == $0.resource else { throw MissionAuthorizationError.invalidScope }
            return try MissionAuthorizationRule(resource: resource, operations: $0.operations)
        }
        return MissionAuthorization(missionID: id, revision: revision, rules: rules,
            createdAt: createdAt, updatedAt: updatedAt, revokedAt: revokedAt)
    }
}

/// All transitions and input enqueue operations are database transactions.
/// A revision rejects stale in-memory decisions after a restart or another turn.
public actor SQLiteAgentMissionRepository: AgentMissionRepository, CheckpointMissionResuming {
    private let database: AIMDatabase

    public init(database: AIMDatabase) { self.database = database }

    public func restoreExecution(_ checkpoint: ExecutionCheckpoint, executionID: UUID,
                                 owner: UUID, conversationID: UUID) throws -> AgentMission {
        guard checkpoint.version == 1, !checkpoint.needsReconciliation,
              let missionID = checkpoint.missionID, let runID = checkpoint.workspaceRunID else {
            throw ExecutionStoreError.incompatibleCheckpoint
        }
        return try database.pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT generation FROM agentRuntimeOwner WHERE id=1") == owner.uuidString,
                  let executionData = try Data.fetchOne(db, sql: "SELECT record FROM agentExecutions WHERE id=?",
                                                       arguments: [executionID.uuidString]) else { throw ExecutionStoreError.staleOwner }
            let execution = try JSONDecoder().decode(AgentExecution.self, from: executionData)
            let resumedExplicitly = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentControlReceipts WHERE executionID=? AND action IN ('resume','correct') AND createdAt>=?",
                                                    arguments: [executionID.uuidString, checkpoint.savedAt]) ?? 0
            guard execution.conversationID == conversationID, execution.state == .running,
                  var mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  mission.conversationID == conversationID,
                  ([.preparing, .executing, .partial, .blocked].contains(mission.state)
                    || resumedExplicitly > 0 && [.awaitingUser, .suspendedHuman, .suspendedFinancial].contains(mission.state)),
                  mission.activeRunID == nil || mission.activeRunID == runID,
                  let run = try WorkspaceRun.fetchOne(db, key: runID),
                  run.conversationID == conversationID.uuidString, run.state != .cancelled else {
                throw ExecutionStoreError.invalidTransition
            }
            let calls = try WorkspaceCall.filter(Column("runID") == runID).fetchAll(db)
            for call in calls where call.requiresReconciliation {
                guard let effect = checkpoint.effects.first(where: { $0.call.id == call.id }),
                      effect.call.name == call.name,
                      effect.call.jsonArguments == (try ToolJSONValue.decodeObject(call.argumentsJSON)) else {
                    throw ExecutionStoreError.invalidTransition
                }
                if effect.state == .returned, let output = effect.output {
                    try db.execute(sql: "UPDATE workspaceCalls SET state=?, result=?, resultMetadataJSON=?, endedAt=? WHERE runID=? AND id=?",
                        arguments: [output.isError ? "failed" : "succeeded", output.content,
                                    try JSONEncoder().encode(output.metadata), Date.now, runID, call.id])
                } else {
                    guard effect.policy == .readOnly || effect.state == .requested && call.launchedAt == nil else {
                        throw ExecutionStoreError.invalidTransition
                    }
                    try db.execute(sql: "UPDATE workspaceCalls SET state='interrupted', endedAt=? WHERE runID=? AND id=?",
                                   arguments: [Date.now, runID, call.id])
                }
            }
            try db.execute(sql: "UPDATE workspaceRuns SET state='failed', endedAt=? WHERE id=? AND state='running'",
                           arguments: [Date.now, runID])
            let previous = mission.state
            mission.state = .preparing; mission.activeRunID = nil
            mission.stateReason = "Restored from a versioned runtime checkpoint; uncertain effects reconciled by the host."
            mission.revision += 1; mission.updatedAt = .now
            try MissionRow(mission).update(db); try event(db, mission: mission, oldState: previous)
            return mission
        }
    }

    public func beginOrSteer(conversationID: UUID, message: String) throws -> AgentMission {
        let objective = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty, objective.utf8.count <= 64 * 1_024, !objective.contains("\0") else {
            throw AgentMissionError.invalidInput
        }
        return try database.pool.write { db in
            let latest = try MissionRow.filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("createdAt").desc, Column("id").desc).fetchOne(db)
            let mission: AgentMission
            if var latest = try latest?.mission(), !latest.state.isTerminal {
                // Corrections arriving during execution are queued for a safe
                // model boundary; they must not silently replace the objective.
                if latest.state != .executing && latest.state != .preparing && latest.state != .blocked {
                    let previous = latest.state
                    latest.state = .preparing
                    latest.stateReason = nil
                    latest.activeRunID = nil
                    latest.updatedAt = .now
                    latest.revision += 1
                    try MissionRow(latest).update(db)
                    try event(db, mission: latest, oldState: previous)
                }
                mission = latest
            } else {
                mission = AgentMission(conversationID: conversationID, objective: objective)
                try MissionRow(mission).insert(db)
                try event(db, mission: mission, oldState: nil)
            }
            try MissionInputRow(AgentMissionInput(missionID: mission.id, content: objective)).insert(db)
            return mission
        }
    }

    public func enqueueCorrection(conversationID: UUID, message: String) throws -> ConversationMessage {
        let content = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.utf8.count <= 64 * 1_024, !content.contains("\0") else {
            throw AgentMissionError.invalidInput
        }
        return try database.pool.write { db in
            guard let row = try MissionRow.filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("createdAt").desc, Column("id").desc).fetchOne(db),
                  let mode = try String.fetchOne(db, sql: "SELECT mode FROM conversations WHERE id = ?",
                                                 arguments: [conversationID.uuidString]), mode == AIMMode.agent.rawValue else {
                throw AgentMissionError.invalidTransition
            }
            let mission = try row.mission()
            guard mission.state == .executing, mission.activeRunID != nil else { throw AgentMissionError.invalidTransition }
            guard let runID = mission.activeRunID,
                  let runState = try String.fetchOne(db, sql: "SELECT state FROM workspaceRuns WHERE id = ? AND conversationID = ?",
                                                         arguments: [runID, conversationID.uuidString]),
                  runState == WorkspaceRunState.running.rawValue else { throw AgentMissionError.invalidTransition }
            let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM messages WHERE conversationID = ?",
                                             arguments: [conversationID.uuidString]) ?? -1) + 1
            let saved = ConversationMessage(conversationID: conversationID, role: .user,
                                            content: content, sequence: sequence)
            try db.execute(sql: "INSERT INTO messages (id, conversationID, role, content, sequence, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [saved.id.uuidString, conversationID.uuidString, MessageRole.user.rawValue,
                                       content, sequence, saved.createdAt])
            try MissionInputRow(AgentMissionInput(missionID: mission.id, content: content,
                                                  conversationMessageID: saved.id)).insert(db)
            try db.execute(sql: "UPDATE conversationSearch SET content = trim(content || ' ' || ?) WHERE conversationID = ?",
                           arguments: [content, conversationID.uuidString])
            try db.execute(sql: "UPDATE conversations SET updatedAt = ? WHERE id = ?",
                           arguments: [saved.createdAt, conversationID.uuidString])
            return saved
        }
    }

    public func load(id: UUID) throws -> AgentMission? {
        try database.pool.read { db in try MissionRow.fetchOne(db, key: id.uuidString)?.mission() }
    }

    public func authorization(missionID: UUID) throws -> MissionAuthorization? {
        try database.pool.read { db in
            try MissionAuthorizationRow.fetchOne(db, key: missionID.uuidString)?.authorization()
        }
    }

    public func replaceAuthorization(missionID: UUID, expectedRevision: Int?,
                                     rules: [MissionAuthorizationRule]) throws -> MissionAuthorization {
        guard rules.count <= 128 else { throw MissionAuthorizationError.invalidScope }
        let validated = try rules.map {
            let resource = try MissionResource(kind: $0.resource.kind, identifier: $0.resource.identifier)
            guard resource == $0.resource else { throw MissionAuthorizationError.invalidScope }
            return try MissionAuthorizationRule(resource: resource, operations: $0.operations)
        }
        let encoded = try JSONEncoder().encode(validated)
        guard encoded.count <= 64 * 1_024 else { throw MissionAuthorizationError.invalidScope }
        return try database.pool.write { db in
            guard let mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  !mission.state.isTerminal else { throw MissionAuthorizationError.unavailable }
            let previous = try MissionAuthorizationRow.fetchOne(db, key: missionID.uuidString)?.authorization()
            guard previous?.revision == expectedRevision else { throw MissionAuthorizationError.conflict }
            let now = Date.now
            let updated = MissionAuthorization(missionID: missionID, revision: (previous?.revision ?? -1) + 1,
                rules: validated, createdAt: previous?.createdAt ?? now, updatedAt: now, revokedAt: nil)
            try MissionAuthorizationRow(updated).save(db)
            try db.execute(sql: "INSERT INTO agentMissionAuthorizationEvents (missionID, revision, rulesJSON, revokedAt, occurredAt) VALUES (?, ?, ?, NULL, ?)",
                           arguments: [missionID.uuidString, updated.revision, encoded, now])
            return updated
        }
    }

    public func revokeAuthorization(missionID: UUID, expectedRevision: Int) throws -> MissionAuthorization {
        try database.pool.write { db in
            guard let previous = try MissionAuthorizationRow.fetchOne(db, key: missionID.uuidString)?.authorization(),
                  previous.revision == expectedRevision else { throw MissionAuthorizationError.conflict }
            let now = Date.now
            let updated = MissionAuthorization(missionID: missionID, revision: previous.revision + 1,
                rules: previous.rules, createdAt: previous.createdAt, updatedAt: now, revokedAt: now)
            let row = try MissionAuthorizationRow(updated)
            try row.save(db)
            try db.execute(sql: "INSERT INTO agentMissionAuthorizationEvents (missionID, revision, rulesJSON, revokedAt, occurredAt) VALUES (?, ?, ?, ?, ?)",
                           arguments: [missionID.uuidString, updated.revision, row.rulesJSON, now, now])
            return updated
        }
    }

    public func latest(conversationID: UUID) throws -> AgentMission? {
        try database.pool.read { db in
            try MissionRow.filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("createdAt").desc, Column("id").desc).fetchOne(db)?.mission()
        }
    }

    public func pendingInputs(missionID: UUID) throws -> [AgentMissionInput] {
        try database.pool.read { db in
            try MissionInputRow.filter(Column("missionID") == missionID.uuidString && Column("consumedAt") == nil)
                .order(Column("createdAt"), Column("id")).fetchAll(db).map { try $0.input() }
        }
    }

    public func consumeInput(id: UUID, missionID: UUID) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE agentMissionInputs SET consumedAt = ? WHERE id = ? AND missionID = ? AND consumedAt IS NULL",
                           arguments: [Date.now, id.uuidString, missionID.uuidString])
            guard db.changesCount == 1 else { throw AgentMissionError.conflict }
        }
    }

    public func reconciliations(missionID: UUID) throws -> [ActionReconciliation] {
        try database.pool.read { db in
            try ReconciliationRow.filter(Column("missionID") == missionID.uuidString)
                .order(Column("reviewedAt"), Column("callID")).fetchAll(db).map { try $0.value() }
        }
    }

    public func recordReconciliation(missionID: UUID, expectedRevision: Int, callID: String,
                                     assessment: ActionEffectAssessment, note: String) throws -> AgentMission {
        let detail = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty, callID.utf8.count <= 256, !callID.contains("\0"),
              !detail.isEmpty, detail.utf8.count <= 2_000, !detail.contains("\0") else {
            throw AgentMissionError.invalidInput
        }
        return try database.pool.write { db in
            guard var mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  mission.revision == expectedRevision, mission.state == .blocked,
                  let runID = mission.activeRunID,
                  let run = try WorkspaceRun.fetchOne(db, key: runID), run.state != .running,
                  run.conversationID == mission.conversationID.uuidString,
                  let call = try WorkspaceCall.fetchOne(db, key: ["runID": runID, "id": callID]),
                  call.requiresReconciliation else { throw AgentMissionError.conflict }
            guard try ReconciliationRow.fetchOne(db, key: ["runID": runID, "callID": callID]) == nil else {
                throw AgentMissionError.conflict
            }
            let record = ActionReconciliation(missionID: missionID, runID: runID, callID: callID,
                                              assessment: assessment, note: detail, reviewedAt: .now)
            try ReconciliationRow(record).insert(db)
            mission.revision += 1
            mission.updatedAt = .now
            mission.stateReason = "Review recorded for \(call.name). Review every uncertain action before continuing."
            try MissionRow(mission).update(db)
            try event(db, mission: mission, oldState: .blocked)
            return mission
        }
    }

    /// Explicitly unlock only after every launched-or-legacy-uncertain action
    /// has a user observation. The original call remains interrupted in the audit.
    public func completeReview(missionID: UUID, expectedRevision: Int, note: String) throws -> AgentMission {
        let instruction = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, instruction.utf8.count <= 2_000,
              !instruction.contains("\0") else { throw AgentMissionError.invalidInput }
        return try database.pool.write { db in
            guard var mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  mission.revision == expectedRevision, mission.state == .blocked,
                  let runID = mission.activeRunID,
                  let run = try WorkspaceRun.fetchOne(db, key: runID), run.state != .running,
                  run.conversationID == mission.conversationID.uuidString else { throw AgentMissionError.conflict }
            let calls = try WorkspaceCall.filter(Column("runID") == runID)
                .order(Column("ordinal")).fetchAll(db).filter(\.requiresReconciliation)
            let records = try ReconciliationRow.filter(Column("missionID") == missionID.uuidString &&
                Column("runID") == runID).fetchAll(db)
            guard Set(calls.map(\.id)) == Set(records.map(\.callID)) else { throw AgentMissionError.missingEvidence }
            let byCall = Dictionary(uniqueKeysWithValues: records.map { ($0.callID, $0) })
            let observations: String = calls.map { call -> String in
                let record = byCall[call.id]!
                let label: String = record.assessment == ActionEffectAssessment.observed.rawValue
                    ? "I observed an effect" : "I did not observe an effect"
                return "- \(call.name) [\(call.id)]: \(label). My observation: \(record.note)"
            }.joined(separator: "\n")
            let summary: String = "I reviewed the interrupted AIM run. These are my observations, not verified tool results.\n" +
                (observations.isEmpty ? "No action with an uncertain effect was recorded.\n" : observations + "\n") +
                "My continuation instruction: \(instruction)\nBefore any repeat action, inspect the current target state again."
            guard summary.utf8.count <= 64 * 1_024 else { throw AgentMissionError.invalidInput }
            let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM messages WHERE conversationID = ?",
                                             arguments: [mission.conversationID.uuidString]) ?? -1) + 1
            let message = ConversationMessage(conversationID: mission.conversationID, role: .user,
                                              content: summary, sequence: sequence)
            try db.execute(sql: "INSERT INTO messages (id, conversationID, role, content, sequence, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [message.id.uuidString, message.conversationID.uuidString,
                                       MessageRole.user.rawValue, summary, sequence, message.createdAt])
            try db.execute(sql: "UPDATE conversationSearch SET content = trim(content || ' ' || ?) WHERE conversationID = ?",
                           arguments: [summary, mission.conversationID.uuidString])
            try db.execute(sql: "UPDATE conversations SET updatedAt = ? WHERE id = ?",
                           arguments: [message.createdAt, mission.conversationID.uuidString])
            mission.state = .partial
            mission.stateReason = "The user reviewed the interrupted run. The mission may continue after a fresh observation; no action was automatically replayed."
            mission.activeRunID = nil
            mission.revision += 1
            mission.updatedAt = .now
            try MissionRow(mission).update(db)
            try event(db, mission: mission, oldState: .blocked)
            return mission
        }
    }

    public func wasUncertainAction(missionID: UUID, name: String,
                                   arguments: [String: ToolJSONValue]) throws -> Bool {
        try database.pool.read { db in
            let prior = try Data.fetchAll(db, sql: """
                SELECT c.argumentsJSON FROM agentActionReconciliations AS r
                JOIN workspaceCalls AS c ON c.runID = r.runID AND c.id = r.callID
                WHERE r.missionID = ? AND c.name = ?
                """, arguments: [missionID.uuidString, name])
            if try prior.contains(where: { data in
                let recorded = try ToolJSONValue.decodeObject(data)
                    .filter { $0.value != .null }
                return recorded == arguments
            }) { return true }
            guard let mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission() else {
                throw AgentMissionError.conflict
            }
            // A result can be durably returned while its external effect is
            // still uncertain (for example, Mail accepted a send without a
            // delivery receipt). Such calls do not enter crash reconciliation.
            // Include them when a later run tries the same exact operation.
            let completed = try Row.fetchAll(db, sql: """
                SELECT c.argumentsJSON, c.resultMetadataJSON
                FROM workspaceCalls AS c
                JOIN workspaceRuns AS r ON r.id = c.runID
                WHERE r.conversationID = ? AND r.startedAt >= ?
                  AND c.name = ? AND c.resultMetadataJSON IS NOT NULL
                """, arguments: [mission.conversationID.uuidString, mission.createdAt, name])
            return try completed.contains { row in
                let metadata = try JSONDecoder().decode([String: String].self,
                    from: row["resultMetadataJSON"] as Data)
                guard let outcome = metadata["action_outcome"],
                      ["unknown", "unverified", "partial"].contains(outcome) else { return false }
                let recorded = try ToolJSONValue.decodeObject(row["argumentsJSON"] as Data)
                    .filter { $0.value != .null }
                return recorded == arguments
            }
        }
    }

    public func setCriteria(missionID: UUID, expectedRevision: Int,
                            criteria: [AgentMissionCriterion]) throws -> AgentMission {
        guard (1...20).contains(criteria.count), Set(criteria.map(\.id)).count == criteria.count,
              criteria.allSatisfy({ !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.description.utf8.count <= 300 && $0.verifiedAt == nil && $0.evidenceReference == nil &&
                  ($0.fileCheck?.isValid ?? true) && ($0.hostCheck?.isValid ?? true) &&
                  !($0.fileCheck != nil && $0.hostCheck != nil) }) else {
            throw AgentMissionError.invalidInput
        }
        return try mutate(missionID: missionID, expectedRevision: expectedRevision) { mission in
            guard mission.state != .verified else { throw AgentMissionError.invalidTransition }
            mission.criteria = criteria
        }
    }

    public func appendFileCriterion(missionID: UUID, expectedRevision: Int,
                                    description: String, check: MissionFileCheck) throws -> AgentMission {
        let label = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 300, !label.contains("\0"), check.isValid else {
            throw AgentMissionError.invalidInput
        }
        return try mutate(missionID: missionID, expectedRevision: expectedRevision) { mission in
            guard [.preparing, .executing, .partial].contains(mission.state),
                  mission.criteria.count < 20 else { throw AgentMissionError.invalidTransition }
            mission.criteria.append(AgentMissionCriterion(description: label, fileCheck: check))
        }
    }

    public func appendHostCriterion(missionID: UUID, expectedRevision: Int,
                                    description: String, check: MissionHostCheck) throws -> AgentMission {
        let label = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 300, !label.contains("\0"), check.isValid else {
            throw AgentMissionError.invalidInput
        }
        return try mutate(missionID: missionID, expectedRevision: expectedRevision) { mission in
            guard [.preparing, .executing, .partial].contains(mission.state),
                  mission.criteria.count < 20 else { throw AgentMissionError.invalidTransition }
            mission.criteria.append(AgentMissionCriterion(description: label, hostCheck: check))
        }
    }

    public func recordHostCheck(missionID: UUID, expectedRevision: Int, criterionID: UUID,
                                observation: MissionCheckObservation, expectedRunID: String?) throws -> AgentMission {
        guard observation.satisfied else { throw AgentMissionError.criterionNotMet }
        guard !observation.digest.isEmpty, observation.digest.utf8.count <= 128,
              observation.summary.utf8.count <= 2_000 else { throw AgentMissionError.invalidInput }
        return try database.pool.write { db in
            guard var current = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  current.revision == expectedRevision,
                  [.executing, .partial].contains(current.state),
                  expectedRunID == nil || (current.state == .executing && current.activeRunID == expectedRunID),
                  let index = current.criteria.firstIndex(where: { $0.id == criterionID }),
                  let check = current.criteria[index].hostCheck else { throw AgentMissionError.conflict }
            let row = MissionCheckEvidenceRow(id: UUID().uuidString, missionID: missionID.uuidString,
                criterionID: criterionID.uuidString, kind: check.kind.rawValue, digest: observation.digest,
                summary: observation.summary, observedAt: observation.observedAt)
            try row.insert(db)
            current.criteria[index].verifiedAt = observation.observedAt
            current.criteria[index].evidenceReference = row.id
            current.revision += 1
            current.updatedAt = .now
            try MissionRow(current).update(db)
            try event(db, mission: current, oldState: current.state)
            return current
        }
    }

    public func hostEvidence(missionID: UUID, criterionID: UUID) throws -> MissionCheckEvidence? {
        try database.pool.read { db in
            guard let mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  let reference = mission.criteria.first(where: { $0.id == criterionID })?.evidenceReference,
                  let row = try MissionCheckEvidenceRow.fetchOne(db, key: reference),
                  row.missionID == missionID.uuidString,
                  row.criterionID == criterionID.uuidString else { return nil }
            return try row.evidence()
        }
    }

    public func transition(missionID: UUID, expectedRevision: Int, to state: AgentMissionState,
                           reason: String? = nil, activeRunID: String? = nil) async throws -> AgentMission {
        guard reason?.utf8.count ?? 0 <= 2_000, reason?.contains("\0") != true,
              activeRunID == nil || UUID(uuidString: activeRunID!) != nil else { throw AgentMissionError.invalidInput }
        if state == .verified {
            guard try await evidenceComplete(missionID: missionID, expectedRevision: expectedRevision) else {
                throw AgentMissionError.missingEvidence
            }
            try Task.checkCancellation()
            return try finishVerified(missionID: missionID, expectedRevision: expectedRevision, reason: reason)
        }
        return try mutate(missionID: missionID, expectedRevision: expectedRevision) { mission in
            guard Self.allowed(from: mission.state, to: state) else { throw AgentMissionError.invalidTransition }
            mission.state = state
            mission.stateReason = reason
            mission.activeRunID = state == .executing ? activeRunID : nil
        }
    }

    public func verifyFileCriterion(missionID: UUID, expectedRevision: Int, criterionID: UUID,
                                    workspacePath: String, expectedRunID: String? = nil) async throws -> AgentMission {
        guard let mission = try load(id: missionID), mission.revision == expectedRevision,
              [.executing, .partial].contains(mission.state),
              expectedRunID == nil || (mission.state == .executing && mission.activeRunID == expectedRunID),
              let check = mission.criteria.first(where: { $0.id == criterionID })?.fileCheck,
              check.isValid else { throw AgentMissionError.conflict }
        let inspection = try await Self.inspectFile(workspacePath: workspacePath, check: check)
        try Task.checkCancellation()
        return try storeFileInspection(inspection, missionID: missionID,
                                       expectedRevision: expectedRevision, criterionID: criterionID,
                                       workspacePath: workspacePath, check: check,
                                       expectedRunID: expectedRunID)
    }

    private func storeFileInspection(_ inspection: MissionFileInspection, missionID: UUID,
                                     expectedRevision: Int, criterionID: UUID,
                                     workspacePath: String, check: MissionFileCheck,
                                     expectedRunID: String?) throws -> AgentMission {
        try database.pool.write { db in
            guard var current = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  current.revision == expectedRevision,
                  [.executing, .partial].contains(current.state),
                  expectedRunID == nil || (current.state == .executing && current.activeRunID == expectedRunID),
                  let index = current.criteria.firstIndex(where: { $0.id == criterionID }),
                  current.criteria[index].fileCheck == check else { throw AgentMissionError.conflict }
            let evidence = MissionFileEvidence(missionID: missionID, criterionID: criterionID,
                workspacePath: workspacePath, relativePath: check.relativePath, sha256: inspection.sha256,
                byteCount: inspection.byteCount, observedAt: inspection.observedAt)
            try MissionFileEvidenceRow(evidence).insert(db)
            current.criteria[index].verifiedAt = evidence.observedAt
            current.criteria[index].evidenceReference = evidence.id.uuidString
            current.revision += 1
            current.updatedAt = .now
            try MissionRow(current).update(db)
            try event(db, mission: current, oldState: current.state)
            return current
        }
    }

    private func evidenceComplete(missionID: UUID, expectedRevision: Int) async throws -> Bool {
        let items: [(MissionFileCheck, MissionFileEvidence)]? = try await database.pool.read { db in
            guard let mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  mission.revision == expectedRevision, !mission.criteria.isEmpty else { return nil }
            var items: [(MissionFileCheck, MissionFileEvidence)] = []
            for criterion in mission.criteria {
                if let hostCheck = criterion.hostCheck {
                    // Host checks are re-observed by the platform right before completion;
                    // here the current receipt must exist and match the criterion.
                    guard let reference = criterion.evidenceReference, criterion.verifiedAt != nil,
                          let row = try MissionCheckEvidenceRow.fetchOne(db, key: reference),
                          row.missionID == missionID.uuidString, row.criterionID == criterion.id.uuidString,
                          row.kind == hostCheck.kind.rawValue else { return nil }
                    continue
                }
                guard let check = criterion.fileCheck, let reference = criterion.evidenceReference,
                      let evidence = try MissionFileEvidenceRow.fetchOne(db, key: reference),
                      evidence.missionID == missionID.uuidString,
                      evidence.criterionID == criterion.id.uuidString,
                      evidence.relativePath == check.relativePath,
                      criterion.verifiedAt != nil else { return nil }
                items.append((check, try evidence.evidence()))
            }
            return items
        }
        guard let items else { return false }
        for (check, receipt) in items {
            let current: MissionFileInspection
            do {
                current = try await Self.inspectFile(workspacePath: receipt.workspacePath, check: check)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return false
            }
            guard current.sha256 == receipt.sha256,
                  current.byteCount == receipt.byteCount else { return false }
        }
        return true
    }

    private nonisolated static func inspectFile(workspacePath: String,
                                                check: MissionFileCheck) async throws -> MissionFileInspection {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try MissionFileInspector.inspect(workspacePath: workspacePath, check: check)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    private func finishVerified(missionID: UUID, expectedRevision: Int, reason: String?) throws -> AgentMission {
        try database.pool.write { db in
            guard var mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  mission.revision == expectedRevision,
                  Self.allowed(from: mission.state, to: .verified),
                  !mission.criteria.isEmpty else { throw AgentMissionError.conflict }
            if mission.state == .executing {
                guard let runID = mission.activeRunID,
                      let run = try WorkspaceRun.fetchOne(db, key: runID),
                      run.conversationID == mission.conversationID.uuidString,
                      run.state == .unverified else { throw AgentMissionError.missingEvidence }
            }
            let lastLaunch: Date? = if let runID = mission.activeRunID {
                try Date.fetchOne(db, sql: "SELECT MAX(launchedAt) FROM workspaceCalls WHERE runID = ?", arguments: [runID])
            } else { nil }
            if let runID = mission.activeRunID {
                let pending = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM workspaceCalls WHERE runID = ? AND state IN ('requested', 'interrupted')
                      AND (executionEvidenceVersion IS NULL OR launchedAt IS NOT NULL)
                    """, arguments: [runID]) ?? 0
                guard pending == 0 else { throw AgentMissionError.missingEvidence }
            }
            let corrections = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM agentMissionInputs WHERE missionID = ? AND consumedAt IS NULL
                """, arguments: [missionID.uuidString]) ?? 0
            guard corrections == 0 else { throw AgentMissionError.missingEvidence }
            for criterion in mission.criteria {
                if let hostCheck = criterion.hostCheck {
                    guard let reference = criterion.evidenceReference, criterion.verifiedAt != nil,
                          let row = try MissionCheckEvidenceRow.fetchOne(db, key: reference),
                          row.missionID == missionID.uuidString, row.criterionID == criterion.id.uuidString,
                          row.kind == hostCheck.kind.rawValue,
                          lastLaunch == nil || row.observedAt >= lastLaunch! else {
                        throw AgentMissionError.missingEvidence
                    }
                    continue
                }
                guard let check = criterion.fileCheck, let reference = criterion.evidenceReference,
                      let row = try MissionFileEvidenceRow.fetchOne(db, key: reference),
                      row.missionID == missionID.uuidString,
                      row.criterionID == criterion.id.uuidString,
                      row.relativePath == check.relativePath,
                      criterion.verifiedAt != nil,
                      lastLaunch == nil || row.observedAt >= lastLaunch! else {
                    throw AgentMissionError.missingEvidence
                }
            }
            let prior = mission.state
            mission.state = .verified
            mission.stateReason = reason ?? "Every mission criterion has a current host receipt."
            mission.activeRunID = nil
            mission.revision += 1
            mission.updatedAt = .now
            try MissionRow(mission).update(db)
            try event(db, mission: mission, oldState: prior)
            return mission
        }
    }

    public func fileEvidence(missionID: UUID, criterionID: UUID) throws -> MissionFileEvidence? {
        try database.pool.read { db in
            guard let mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  let reference = mission.criteria.first(where: { $0.id == criterionID })?.evidenceReference,
                  let row = try MissionFileEvidenceRow.fetchOne(db, key: reference),
                  row.missionID == missionID.uuidString,
                  row.criterionID == criterionID.uuidString else { return nil }
            return try row.evidence()
        }
    }

    /// Reads the audit record in the same transaction as the mission state.
    /// A model's final answer never promotes the mission to verified.
    public func finalizeRun(missionID: UUID, expectedRevision: Int, runID: String) throws -> AgentMission {
        try database.pool.write { db in
            guard var mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission(),
                  mission.revision == expectedRevision, mission.state == .executing,
                  mission.activeRunID == runID,
                  let run = try WorkspaceRun.fetchOne(db, key: runID),
                  run.conversationID == mission.conversationID.uuidString else {
                throw AgentMissionError.conflict
            }
            let unknown = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM workspaceCalls
                WHERE runID = ? AND state IN ('requested', 'interrupted')
                  AND (executionEvidenceVersion IS NULL OR launchedAt IS NOT NULL)
                """, arguments: [runID]) ?? 0
            if run.state == .running || unknown > 0 {
                mission.state = .blocked
                mission.stateReason = "An action may have taken effect without a reliable result. Inspect the target before resuming."
            } else if run.state == .cancelled {
                mission.state = .cancelled
                mission.stateReason = "The user stopped this run."
            } else {
                mission.state = .partial
                let pendingCorrections = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentMissionInputs WHERE missionID = ? AND consumedAt IS NULL AND conversationMessageID IS NOT NULL",
                                                          arguments: [missionID.uuidString]) ?? 0
                mission.stateReason = pendingCorrections > 0
                    ? "A user correction arrived as this run ended. It remains queued; resume the mission to process it."
                    : run.state == .unverified
                    ? "The model ended its turn, but the mission criteria were not independently verified."
                    : "The run failed before the mission criteria were independently verified."
            }
            if mission.state != .blocked { mission.activeRunID = nil }
            mission.revision += 1
            mission.updatedAt = .now
            try MissionRow(mission).update(db)
            try event(db, mission: mission, oldState: .executing)
            return mission
        }
    }

    public func recoverInterrupted() throws -> [AgentMission] {
        try database.pool.write { db in
            let rows = try MissionRow.filter(Column("state") == AgentMissionState.preparing.rawValue ||
                                             Column("state") == AgentMissionState.executing.rawValue).fetchAll(db)
            let durableConversations = Set(try String.fetchAll(db, sql: "SELECT conversationID FROM agentExecutions WHERE state NOT IN ('verified','accepted','failed','cancelled')"))
            return try rows.filter { !durableConversations.contains($0.conversationID) }.map { row in
                var mission = try row.mission()
                let prior = mission.state
                var uncertain = false
                var launchedActions = false
                var runExists = false
                if let runID = mission.activeRunID {
                    runExists = try WorkspaceRun.fetchOne(db, key: runID) != nil
                    let count = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM workspaceCalls
                        WHERE runID = ? AND state IN ('requested', 'interrupted')
                          AND (executionEvidenceVersion IS NULL OR launchedAt IS NOT NULL)
                        """, arguments: [runID]) ?? 0
                    uncertain = count > 0
                    let launchedCount = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM workspaceCalls WHERE runID = ? AND launchedAt IS NOT NULL
                        """, arguments: [runID]) ?? 0
                    launchedActions = launchedCount > 0
                    try db.execute(sql: "UPDATE workspaceCalls SET state = 'interrupted', endedAt = ? WHERE runID = ? AND state = 'requested'",
                                   arguments: [Date.now, runID])
                    try db.execute(sql: "UPDATE workspaceRuns SET state = 'failed', endedAt = ? WHERE id = ? AND state = 'running'",
                                   arguments: [Date.now, runID])
                }
                if !runExists || (!uncertain && !launchedActions) {
                    // An action cannot launch before the run journal exists.
                    // A versioned, prepared-only call never crossed the durable
                    // launch boundary either. It needs no effect reconciliation.
                    mission.state = .partial
                    mission.stateReason = runExists
                        ? "AIM stopped before any tool action launched. Continue with a fresh observation."
                        : "AIM stopped before any tool run started. Continue with a fresh turn."
                    mission.activeRunID = nil
                } else {
                    mission.state = .blocked
                    mission.stateReason = uncertain
                        ? "A previously launched action has no recorded result. Inspect its effect before resuming; it will not be replayed."
                        : "AIM stopped after a tool action returned. Review its recorded result and the current target before continuing to avoid repeating an effect."
                }
                // Retain the exact run so the unresolved action can be
                // inspected later. The host must never infer "not executed".
                mission.revision += 1
                mission.updatedAt = .now
                try MissionRow(mission).update(db)
                try event(db, mission: mission, oldState: prior)
                return mission
            }
        }
    }

    private func mutate(missionID: UUID, expectedRevision: Int,
                        change: (inout AgentMission) throws -> Void) throws -> AgentMission {
        try database.pool.write { db in
            guard var mission = try MissionRow.fetchOne(db, key: missionID.uuidString)?.mission() else {
                throw AgentMissionError.conflict
            }
            guard mission.revision == expectedRevision else { throw AgentMissionError.conflict }
            let prior = mission.state
            try change(&mission)
            mission.revision += 1
            mission.updatedAt = .now
            try MissionRow(mission).update(db)
            try event(db, mission: mission, oldState: prior)
            return mission
        }
    }

    private static func allowed(from old: AgentMissionState, to new: AgentMissionState) -> Bool {
        guard !old.isTerminal else { return false }
        if old == .blocked { return false }
        if new == .preparing { return old != .executing }
        if new == .executing { return old == .preparing || old == .awaitingUser || old == .partial }
        if new == .verified { return old == .executing || old == .partial }
        return new != old
    }

    private func event(_ db: Database, mission: AgentMission, oldState: AgentMissionState?) throws {
        try db.execute(sql: """
            INSERT INTO agentMissionEvents (missionID, revision, oldState, newState, reason, occurredAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [mission.id.uuidString, mission.revision, oldState?.rawValue,
                               mission.state.rawValue, mission.stateReason, mission.updatedAt])
    }
}
