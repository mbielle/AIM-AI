import Foundation
import GRDB

/// All admissions, transitions and checkpoints are committed before effects.
/// The caller must hold RuntimeLease before installing a runtime generation.
public actor SQLiteAgentExecutionRepository {
    private let database: AIMDatabase
    private let artifacts: ExecutionArtifactStore?
    public var activity: SQLiteAccountActivityRepository { SQLiteAccountActivityRepository(database: database) }

    public init(database: AIMDatabase, artifacts: ExecutionArtifactStore? = nil) {
        self.database = database; self.artifacts = artifacts
    }

    public func installOwner(_ generation: UUID) throws {
        try database.pool.write { db in
            try db.execute(sql: "INSERT INTO agentRuntimeOwner(id,generation) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET generation=excluded.generation",
                           arguments: [generation.uuidString])
        }
    }

    /// Read-only fence for relay cleanup of a terminal parent's already-owned child.
    public func requireOwner(_ generation: UUID) throws {
        try database.pool.read { db in try Self.checkOwner(db, generation) }
    }

    public func processes(executionID: UUID) throws -> [DurableProcess] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agentProcesses WHERE executionID=?", arguments: [executionID.uuidString]).map { row in
                guard let id = UUID(uuidString: row["id"]) else { throw ExecutionStoreError.incompatibleCheckpoint }
                let reference: String? = row["artifactReference"]
                let payload: Data
                if let reference {
                    guard let artifacts else { throw ExecutionStoreError.incompatibleCheckpoint }
                    payload = try artifacts.read(reference)
                } else { payload = row["payload"] }
                return DurableProcess(id: id, executionID: executionID, admissionCallID: row["admissionCallID"],
                    workspacePath: row["workspacePath"], state: row["state"], version: row["version"], payload: payload)
            }
        }
    }

    /// Completion data and parent wake are one fenced transaction. Old generations
    /// cannot report a process as finished after a runtime replacement.
    public func saveProcess(_ process: DurableProcess, owner: UUID) throws {
        let reference = try artifacts?.put(process.payload)
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            let parent = try Self.load(db, process.executionID)
            let existing = try Row.fetchOne(db, sql: "SELECT version,executionID,admissionCallID,workspacePath FROM agentProcesses WHERE id=?", arguments: [process.id.uuidString])
            // Terminal roots may still collect the stopped receipt of an already
            // owned process. They can never admit or revive a running process.
            guard !parent.state.isTerminal || (existing != nil && process.state != "running") else { throw ExecutionStoreError.invalidTransition }
            if let row = existing {
                guard row["executionID"] as String == process.executionID.uuidString,
                      row["admissionCallID"] as String == process.admissionCallID,
                      row["workspacePath"] as String == process.workspacePath else { throw ExecutionStoreError.commandConflict }
                if (row["version"] as Int) >= process.version { return }
            }
            try db.execute(sql: """
                INSERT INTO agentProcesses(id,executionID,admissionCallID,workspacePath,state,version,payload,artifactReference)
                VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,version=excluded.version,
                payload=excluded.payload,artifactReference=excluded.artifactReference
                """, arguments: [process.id.uuidString, process.executionID.uuidString, process.admissionCallID,
                    process.workspacePath, process.state, process.version, reference == nil ? process.payload : Data(), reference])
            if process.state != "running", !parent.state.isTerminal {
                try db.execute(sql: "INSERT OR IGNORE INTO agentWakeInbox(id,dedupKey,executionID,payload,createdAt) VALUES(?,?,?,?,?)",
                    arguments: [UUID().uuidString, "process:\(process.id):\(process.version)", process.executionID.uuidString,
                                Data("Process \(process.id) state \(process.state); inspect its receipt and side effects.".utf8), Date.now])
            }
        }
    }
    public func acknowledgeUncertainProcess(_ id: UUID, executionID: UUID, owner: UUID) throws {
        guard let process = try processes(executionID: executionID).first(where: { $0.id == id }), ["unknown", "interrupted"].contains(process.state) else {
            throw ExecutionStoreError.invalidTransition
        }
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var execution = try Self.load(db, executionID)
            if process.state == "interrupted" { return }
            guard [.paused, .waitingUser, .blocked].contains(execution.state) else { throw ExecutionStoreError.invalidTransition }
            guard try String.fetchOne(db, sql: "SELECT state FROM agentProcesses WHERE id=? AND executionID=?", arguments: [id.uuidString, executionID.uuidString]) == "unknown" else { throw ExecutionStoreError.staleRevision }
            try db.execute(sql: "UPDATE agentProcesses SET state='interrupted',version=version+1 WHERE id=?", arguments: [id.uuidString])
            if let data = try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentExecutions WHERE id=?", arguments: [executionID.uuidString]) {
                var checkpoint = try Self.decodeCheckpoint(data, artifacts: artifacts)
                if let index = checkpoint.effects.firstIndex(where: { $0.call.id == process.admissionCallID && $0.call.name == "start_command" && $0.policy == .reconcile }) {
                    checkpoint.effects[index].state = .returned
                    checkpoint.effects[index].output = ModelToolOutput(id: process.admissionCallID,
                        content: "The user inspected the interrupted command. Its success is unverified. Retain process handle \(id); do not replay this command automatically.", isError: false,
                        metadata: ["process_handle": id.uuidString, "process_state": "interrupted", "reconciled_by": "human_process_inspection", "action_outcome": "unverified"])
                    checkpoint.seenCallIDs.insert(process.admissionCallID)
                    checkpoint.blockedCalls.removeAll { $0.id == process.admissionCallID }
                    checkpoint.savedAt = .now
                    try db.execute(sql: "UPDATE agentExecutions SET checkpoint=? WHERE id=?", arguments: [try Self.encodeCheckpoint(checkpoint, artifacts: artifacts), executionID.uuidString])
                }
                if !checkpoint.needsReconciliation, execution.state == .blocked { execution.state = .waitingUser }
            } else if execution.state == .blocked { execution.state = .waitingUser }
            execution.revision += 1; execution.updatedAt = .now; execution.ownerGeneration = owner
            execution.reason = "Process effects inspected by user. Resume explicitly; command success remains unverified."
            try Self.write(db, execution)
            try Self.event(db, id: executionID, kind: "humanProcessReconciliation", payload: Data(id.uuidString.utf8), at: .now)
        }
    }

    /// AIM restarted while background commands ran: they are recorded as interrupted and the
    /// agent is told, so it inspects the workspace and starts them again itself. Returns their count.
    @discardableResult
    public func interruptUnknownProcesses(executionID: UUID, owner: UUID) throws -> Int {
        let unknown = try processes(executionID: executionID).filter { $0.state == "unknown" }
        guard !unknown.isEmpty else { return 0 }
        return try database.pool.write { db in
            try Self.checkOwner(db, owner)
            let execution = try Self.load(db, executionID)
            guard execution.state == .running else { throw ExecutionStoreError.invalidTransition }
            var checkpoint = try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentExecutions WHERE id=?", arguments: [executionID.uuidString])
                .map { try Self.decodeCheckpoint($0, artifacts: artifacts) }
            for process in unknown {
                try db.execute(sql: "UPDATE agentProcesses SET state='interrupted',version=version+1 WHERE id=? AND state='unknown'", arguments: [process.id.uuidString])
                if let index = checkpoint?.effects.firstIndex(where: { $0.call.id == process.admissionCallID && $0.call.name == "start_command" }) {
                    checkpoint?.effects[index].state = .returned
                    checkpoint?.effects[index].output = ModelToolOutput(id: process.admissionCallID,
                        content: "AIM restarted while this command was running, so it was stopped and its result is unknown. Inspect the workspace, then start it again if it is still needed.",
                        isError: false, metadata: ["process_handle": process.id.uuidString, "process_state": "interrupted",
                                                   "reconciled_by": "runtime_restart", "action_outcome": "unverified"])
                    checkpoint?.seenCallIDs.insert(process.admissionCallID)
                    checkpoint?.blockedCalls.removeAll { $0.id == process.admissionCallID }
                }
            }
            if var checkpoint {
                checkpoint.savedAt = .now
                try db.execute(sql: "UPDATE agentExecutions SET checkpoint=? WHERE id=?", arguments: [try Self.encodeCheckpoint(checkpoint, artifacts: artifacts), executionID.uuidString])
            }
            try Self.event(db, id: executionID, kind: "processesInterrupted", payload: Data(String(unknown.count).utf8), at: .now)
            return unknown.count
        }
    }

    public func admitChild(_ proposal: DurableSubagent, owner: UUID) throws -> DurableSubagent {
        guard !proposal.admissionCallID.isEmpty, proposal.prompt.utf8.count <= 16000,
              proposal.workspacePath.hasPrefix("/"), proposal.state == .queued else { throw ExecutionStoreError.invalidTransition }
        return try database.pool.write { db in
            try Self.checkOwner(db, owner)
            let parent = try Self.load(db, proposal.parentExecutionID)
            guard [.running, .waitingEvent, .waitingNetwork].contains(parent.state), parent.boundaryPauseReason == nil else {
                throw ExecutionStoreError.invalidTransition
            }
            let expectedDepth: Int
            if let ancestorID = proposal.parentChildID {
                let ancestor = try Self.loadChild(db, ancestorID)
                guard ancestor.parentExecutionID == parent.id,
                      [.running, .waitingEvent, .waitingNetwork].contains(ancestor.state) else { throw ExecutionStoreError.invalidTransition }
                guard proposal.workspacePath == (ancestor.worktree?.childWorkspace ?? ancestor.workspacePath),
                      proposal.worktree == nil || ancestor.worktree != nil,
                      (ancestor.depth ?? 1) < Int.max else { throw ExecutionStoreError.invalidTransition }
                expectedDepth = (ancestor.depth ?? 1) + 1
                guard proposal.admissionCallID.hasPrefix(ancestorID.uuidString + ":") else { throw ExecutionStoreError.invalidTransition }
            } else { expectedDepth = 1 }
            if let worktree = proposal.worktree {
                guard worktree.jobID == proposal.id, worktree.conversationID == parent.conversationID,
                      worktree.parentWorkspace == proposal.workspacePath, worktree.childWorkspace != proposal.workspacePath else {
                    throw ExecutionStoreError.invalidTransition
                }
            }
            guard (proposal.depth ?? 1) == expectedDepth, expectedDepth > 0,
                  (proposal.dependencyIDs?.count ?? 0) <= 8,
                  Set(proposal.dependencyIDs ?? []).count == (proposal.dependencyIDs?.count ?? 0),
                  (proposal.requiredResultKeys?.count ?? 0) <= 32,
                  (proposal.requiredResultKeys ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && !$0.contains("\0") }) else { throw ExecutionStoreError.invalidTransition }
            for id in proposal.dependencyIDs ?? [] {
                let dependency = try Self.loadChild(db, id)
                guard dependency.parentExecutionID == parent.id, dependency.parentChildID == proposal.parentChildID,
                      dependency.id != proposal.id else { throw ExecutionStoreError.invalidTransition }
            }
            if let data = try Data.fetchOne(db, sql: "SELECT record FROM agentChildExecutions WHERE parentExecutionID=? AND admissionCallID=?",
                arguments: [proposal.parentExecutionID.uuidString, proposal.admissionCallID]) {
                let existing = try JSONDecoder().decode(DurableSubagent.self, from: data)
                guard existing.title == proposal.title, existing.prompt == proposal.prompt,
                      existing.profile == proposal.profile, existing.modelID == proposal.modelID, existing.providerID == proposal.providerID,
                      existing.workspacePath == proposal.workspacePath,
                      (existing.worktree != nil) == (proposal.worktree != nil),
                      existing.parentChildID == proposal.parentChildID,
                      (existing.dependencyIDs ?? []) == (proposal.dependencyIDs ?? []),
                      (existing.requiredResultKeys ?? []) == (proposal.requiredResultKeys ?? []) else { throw ExecutionStoreError.commandConflict }
                return existing
            }
            try db.execute(sql: "INSERT INTO agentChildExecutions(id,parentExecutionID,admissionCallID,record) VALUES(?,?,?,?)",
                arguments: [proposal.id.uuidString, proposal.parentExecutionID.uuidString, proposal.admissionCallID, try JSONEncoder().encode(proposal)])
            try Self.event(db, id: parent.id, kind: "childAdmitted", payload: JSONEncoder().encode(proposal), at: .now)
            return proposal
        }
    }
    public func children(parentExecutionID: UUID) throws -> [DurableSubagent] {
        try database.pool.read { db in
            try Data.fetchAll(db, sql: "SELECT record FROM agentChildExecutions WHERE parentExecutionID=? ORDER BY rowid",
                             arguments: [parentExecutionID.uuidString]).map { try JSONDecoder().decode(DurableSubagent.self, from: $0) }
        }
    }
    public func child(_ id: UUID) throws -> DurableSubagent {
        try database.pool.read { db in try Self.loadChild(db, id) }
    }
    public func childCheckpoint(_ id: UUID) throws -> ExecutionCheckpoint? {
        try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentChildExecutions WHERE id=?", arguments: [id.uuidString])
                .map { try Self.decodeCheckpoint($0, artifacts: artifacts) }
        }
    }
    public func transitionChild(_ id: UUID, owner: UUID, expectedRevision: Int64, to state: ExecutionState,
                                result: String? = nil, retryAt: Date? = nil) throws -> DurableSubagent {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var child = try Self.loadChild(db, id)
            guard child.revision == expectedRevision else { throw ExecutionStoreError.staleRevision }
            guard !child.state.isTerminal else { throw ExecutionStoreError.invalidTransition }
            let parent = try Self.load(db, child.parentExecutionID)
            if state == .running {
                guard [.running, .waitingEvent, .waitingNetwork].contains(parent.state),
                      parent.boundaryPauseReason == nil else { throw ExecutionBoundaryPause() }
                if let ancestorID = child.parentChildID {
                    let ancestor = try Self.loadChild(db, ancestorID)
                    guard [.running, .waitingEvent, .waitingNetwork].contains(ancestor.state),
                          ancestor.parentExecutionID == parent.id else { throw ExecutionBoundaryPause() }
                }
                for id in child.dependencyIDs ?? [] {
                    guard try Self.loadChild(db, id).state == .accepted else { throw ExecutionBoundaryPause() }
                }
                child.hasStarted = true
            }
            child.state = state; child.result = result; child.retryAt = retryAt; child.revision += 1
            try Self.writeChild(db, child)
            try Self.event(db, id: parent.id, kind: "childState", payload: JSONEncoder().encode(child), at: .now)
            if state.isTerminal || state == .blocked {
                try db.execute(sql: "INSERT OR IGNORE INTO agentWakeInbox(id,dedupKey,executionID,payload,createdAt) VALUES(?,?,?,?,?)",
                    arguments: [UUID().uuidString, "child:\(child.id):\(child.revision)", parent.id.uuidString,
                                try JSONEncoder().encode(child), Date.now])
            }
            return child
        }
    }
    public func saveChildCheckpoint(_ checkpoint: ExecutionCheckpoint, childID: UUID, owner: UUID) throws {
        guard checkpoint.version == 1, checkpoint.conversation.version == 1,
              checkpoint.effects.map(\.call.id) == checkpoint.turn.calls.map(\.id),
              Set(checkpoint.turn.calls.map(\.id)).count == checkpoint.turn.calls.count,
              checkpoint.effects.allSatisfy({ $0.state == .returned ? $0.output?.id == $0.call.id : $0.output == nil }) else { throw ExecutionStoreError.incompatibleCheckpoint }
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var child = try Self.loadChild(db, childID)
            guard child.state == .running else { throw ExecutionStoreError.invalidTransition }
            child.revision += 1; try Self.writeChild(db, child)
            try db.execute(sql: "UPDATE agentChildExecutions SET checkpoint=? WHERE id=?",
                           arguments: [try Self.encodeCheckpoint(checkpoint, artifacts: artifacts), childID.uuidString])
            if let data = checkpoint.conversation.extensions?["mailbox_consumed"] {
                for id in try JSONDecoder().decode([String].self, from: data) {
                    try db.execute(sql: "UPDATE agentChildMessages SET consumedAt=? WHERE childID=? AND direction='child' AND id=?",
                                   arguments: [Date.now, childID.uuidString, id])
                }
            }
        }
    }
    public func updateChildEffect(childID: UUID, callID: String, owner: UUID,
                                  output: ModelToolOutput? = nil, toolState: [String: Data]? = nil) throws {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var child = try Self.loadChild(db, childID)
            guard child.state == .running,
                  let bytes = try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentChildExecutions WHERE id=?", arguments: [childID.uuidString]) else {
                throw ExecutionStoreError.invalidTransition
            }
            var checkpoint = try Self.decodeCheckpoint(bytes, artifacts: artifacts)
            guard let index = checkpoint.effects.firstIndex(where: { $0.call.id == callID }),
                  checkpoint.effects[index].state != .returned else { throw ExecutionStoreError.invalidTransition }
            checkpoint.effects[index].state = output == nil ? .launched : .returned
            checkpoint.effects[index].output = output
            if output == nil { checkpoint.effects[index].wasLaunched = true }
            if output != nil { checkpoint.seenCallIDs.insert(callID) }
            if let toolState { checkpoint.toolState = toolState }
            checkpoint.savedAt = .now; child.revision += 1; try Self.writeChild(db, child)
            try db.execute(sql: "UPDATE agentChildExecutions SET checkpoint=? WHERE id=?",
                           arguments: [try Self.encodeCheckpoint(checkpoint, artifacts: artifacts), childID.uuidString])
        }
    }
    public nonisolated func childMailbox(childID: UUID, owner: UUID) -> DurableSubagentMailboxStore {
        DurableSubagentMailboxStore(database: database, childID: childID, owner: owner)
    }
    private static func loadChild(_ db: Database, _ id: UUID) throws -> DurableSubagent {
        guard let data = try Data.fetchOne(db, sql: "SELECT record FROM agentChildExecutions WHERE id=?", arguments: [id.uuidString]) else {
            throw ExecutionStoreError.notFound
        }
        return try JSONDecoder().decode(DurableSubagent.self, from: data)
    }
    private static func writeChild(_ db: Database, _ child: DurableSubagent) throws {
        try db.execute(sql: "UPDATE agentChildExecutions SET record=? WHERE id=?", arguments: [try JSONEncoder().encode(child), child.id.uuidString])
    }

    public func admit(_ proposal: AgentExecution, owner: UUID, initialMessageID: UUID? = nil, initialText: String? = nil) throws -> AgentExecution {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            if let row = try Row.fetchOne(db, sql: "SELECT record FROM agentExecutions WHERE commandID=?",
                                         arguments: [proposal.commandID.uuidString]) {
                let existing = try Self.decode(row)
                guard existing.conversationID == proposal.conversationID,
                      existing.accountID == proposal.accountID, existing.request == proposal.request else {
                    throw ExecutionStoreError.commandConflict
                }
                return existing
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentExecutions WHERE conversationID=? AND state NOT IN ('verified','accepted','failed','cancelled')",
                                   arguments: [proposal.conversationID.uuidString]) == 0 else {
                throw ExecutionStoreError.duplicateConversation
            }
            var record = proposal
            record.state = .queued; record.ownerGeneration = owner; record.revision = 0
            if let initialText {
                if let initialMessageID {
                    guard let row = try Row.fetchOne(db, sql: "SELECT conversationID,role,content FROM messages WHERE id=?", arguments: [initialMessageID.uuidString]),
                          row["conversationID"] as String == record.conversationID.uuidString,
                          row["role"] as String == MessageRole.user.rawValue,
                          row["content"] as String == initialText else { throw ExecutionStoreError.commandConflict }
                } else {
                    let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM messages WHERE conversationID=?", arguments: [record.conversationID.uuidString]) ?? -1) + 1
                    try db.execute(sql: "INSERT INTO messages(id,conversationID,role,content,sequence,createdAt) VALUES(?,?,?,?,?,?)",
                        arguments: [record.commandID.uuidString, record.conversationID.uuidString, MessageRole.user.rawValue, initialText, sequence, record.createdAt])
                    try db.execute(sql: "UPDATE conversations SET updatedAt=? WHERE id=?", arguments: [record.createdAt, record.conversationID.uuidString])
                    try db.execute(sql: "UPDATE conversationSearch SET content=trim(content || ' ' || ?) WHERE conversationID=?", arguments: [initialText, record.conversationID.uuidString])
                }
            }
            let bytes = try JSONEncoder().encode(record)
            try db.execute(sql: """
                INSERT INTO agentExecutions(id,commandID,conversationID,accountID,request,state,revision,ownerGeneration,reason,createdAt,updatedAt,record)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [record.id.uuidString, record.commandID.uuidString, record.conversationID.uuidString,
                    record.accountID?.uuidString, record.request, record.state.rawValue, record.revision,
                    owner.uuidString, record.reason, record.createdAt, record.updatedAt, bytes])
            try Self.event(db, id: record.id, kind: "admitted", payload: bytes, at: record.createdAt)
            return record
        }
    }

    public func execution(_ id: UUID) throws -> AgentExecution? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT record FROM agentExecutions WHERE id=?", arguments: [id.uuidString])
                .map(Self.decode)
        }
    }
    /// Controls and corrections have durable receipts independently of the cloud ack.
    public func pendingUserInputs(executionID: UUID, owner: UUID) throws -> [ExecutionUserInput] {
        try database.pool.read { db in
            try Self.checkOwner(db, owner)
            return try Row.fetchAll(db, sql: "SELECT id,content FROM agentExecutionInputs WHERE executionID=? AND consumed=0 ORDER BY rowid", arguments: [executionID.uuidString]).map {
                guard let id = UUID(uuidString: $0["id"]) else { throw ExecutionStoreError.incompatibleCheckpoint }
                return ExecutionUserInput(id: id, content: $0["content"])
            }
        }
    }
    public func control(commandID: UUID, executionID: UUID, action: String, text: String? = nil, sourceMessageID: UUID? = nil, owner: UUID) throws -> AgentExecution {
        let payload: Data
        if let sourceMessageID { payload = try JSONEncoder().encode(["text": text ?? "", "sourceMessageID": sourceMessageID.uuidString]) }
        else { payload = try JSONEncoder().encode(text) }
        return try database.pool.write { db in
            try Self.checkOwner(db, owner)
            if let row = try Row.fetchOne(db, sql: "SELECT executionID,action,payload,result FROM agentControlReceipts WHERE id=?",
                                         arguments: [commandID.uuidString]) {
                guard row["executionID"] as String == executionID.uuidString, row["action"] as String == action,
                      row["payload"] as Data == payload else { throw ExecutionStoreError.commandConflict }
                return try JSONDecoder().decode(AgentExecution.self, from: row["result"])
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentExecutions WHERE commandID=?", arguments: [commandID.uuidString]) == 0 else {
                throw ExecutionStoreError.commandConflict
            }
            var record = try Self.load(db, executionID)
            guard !record.state.isTerminal || action == "cancel" && record.state == .cancelled else { throw ExecutionStoreError.invalidTransition }
            switch action {
            case "pause": record.state = .paused; record.reason = "Paused by user."
            case "cancel": record.state = .cancelled; record.reason = "Cancelled by user."
            case "resume":
                guard [.paused, .waitingUser].contains(record.state) else { throw ExecutionStoreError.invalidTransition }
                if let bytes = try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentExecutions WHERE id=?", arguments: [executionID.uuidString]),
                   try Self.decodeCheckpoint(bytes, artifacts: artifacts).needsReconciliation {
                    record.state = .blocked; record.reason = "Uncertain effect requires reconciliation."
                } else { record.state = .queued; record.reason = nil }
            case "accept":
                guard record.state == .awaitingReview else { throw ExecutionStoreError.invalidTransition }
                record.state = .accepted; record.reason = "Result accepted explicitly by user; no host verification implied."
            case "correct":
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 65536, !text.contains("\0") else { throw ExecutionStoreError.invalidTransition }
                if let sourceMessageID {
                    guard let row = try Row.fetchOne(db, sql: "SELECT conversationID,role,content FROM messages WHERE id=?", arguments: [sourceMessageID.uuidString]),
                          row["conversationID"] as String == record.conversationID.uuidString,
                          row["role"] as String == "user", row["content"] as String == text else { throw ExecutionStoreError.commandConflict }
                } else {
                    let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM messages WHERE conversationID=?", arguments: [record.conversationID.uuidString]) ?? -1) + 1
                    try db.execute(sql: "INSERT INTO messages(id,conversationID,role,content,sequence,createdAt) VALUES(?,?,?,?,?,?)",
                        arguments: [commandID.uuidString, record.conversationID.uuidString, "user", text, sequence, Date.now])
                    try db.execute(sql: "UPDATE conversationSearch SET content=trim(content || ' ' || ?) WHERE conversationID=?", arguments: [text, record.conversationID.uuidString])
                }
                if let missionID = try String.fetchOne(db, sql: "SELECT id FROM agentMissions WHERE conversationID=? AND state NOT IN ('verified','failed','cancelled') ORDER BY createdAt DESC,id DESC LIMIT 1", arguments: [record.conversationID.uuidString]) {
                    try db.execute(sql: "INSERT INTO agentMissionInputs(id,missionID,content,conversationMessageID,createdAt) VALUES(?,?,?,?,?)",
                        arguments: [commandID.uuidString, missionID, text, (sourceMessageID ?? commandID).uuidString, Date.now])
                }
                try db.execute(sql: "INSERT INTO agentExecutionInputs(id,executionID,content) VALUES(?,?,?)", arguments: [commandID.uuidString, executionID.uuidString, text])
                if [.awaitingReview, .waitingUser, .waitingEvent, .waitingNetwork].contains(record.state) {
                    record.state = .queued; record.reason = nil
                }
            default: throw ExecutionStoreError.invalidTransition
            }
            if action != "correct" { record.boundaryPauseReason = nil; record.transferResumeState = nil }
            record.revision += 1; record.updatedAt = .now; record.ownerGeneration = owner
            try Self.write(db, record)
            let result = try JSONEncoder().encode(record)
            try db.execute(sql: "INSERT INTO agentControlReceipts(id,executionID,action,payload,result,createdAt) VALUES(?,?,?,?,?,?)",
                arguments: [commandID.uuidString, executionID.uuidString, action, payload, result, Date.now])
            try Self.event(db, id: executionID, kind: "control:\(action)", payload: result, at: .now)
            return record
        }
    }

    /// Completion and delivery obligation commit together. A crash cannot lose the result.
    @discardableResult
    public func settle(_ id: UUID, owner: UUID, expectedRevision: Int64, state: ExecutionState,
                       reason: String?, delivery: Data?) throws -> AgentExecution {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var record = try Self.load(db, id)
            guard record.state == .running, record.revision == expectedRevision else {
                throw ExecutionStoreError.staleRevision
            }
            record.state = state; record.reason = reason; record.revision += 1
            if state != .paused {
                record.completedTurns = (record.completedTurns ?? 0) + 1
                if let bytes = try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentExecutions WHERE id=?", arguments: [id.uuidString]) {
                    let checkpoint = try Self.decodeCheckpoint(bytes, artifacts: artifacts)
                    if checkpoint.turn.calls.isEmpty { record.settledCheckpointAt = checkpoint.savedAt }
                }
            }
            record.updatedAt = .now; record.ownerGeneration = owner
            try Self.write(db, record)
            if let delivery {
                let deliveryID = UUID()
                try db.execute(sql: "INSERT INTO agentDeliveryOutbox(id,executionID,payload,createdAt) VALUES(?,?,?,?)",
                               arguments: [deliveryID.uuidString, id.uuidString, delivery, record.updatedAt])
                if let text = String(data: delivery, encoding: .utf8), !text.isEmpty {
                    let lastUser = try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM messages WHERE conversationID=? AND role='user'",
                        arguments: [record.conversationID.uuidString]) ?? -1
                    // The app already saved this turn's message (its text, actions and timeline) when the
                    // run stopped or waited: complete that message instead of adding a second one.
                    if let row = try Row.fetchOne(db, sql: "SELECT id, content FROM messages WHERE conversationID=? AND role='assistant' AND sequence>? ORDER BY sequence DESC LIMIT 1",
                                                  arguments: [record.conversationID.uuidString, lastUser]) {
                        let existing: String = row["content"]
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let content = existing.contains(trimmed) ? existing : existing + (existing.isEmpty ? "" : "\n\n") + text
                        try db.execute(sql: "UPDATE messages SET content=?, completionStatus=NULL WHERE id=?", arguments: [content, row["id"] as String])
                    } else {
                        let sequence = (try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM messages WHERE conversationID=?",
                            arguments: [record.conversationID.uuidString]) ?? -1) + 1
                        try db.execute(sql: "INSERT INTO messages(id,conversationID,role,content,sequence,createdAt) VALUES(?,?,?,?,?,?)",
                            arguments: [deliveryID.uuidString, record.conversationID.uuidString, "assistant", text, sequence, record.updatedAt])
                    }
                    try db.execute(sql: "UPDATE conversations SET updatedAt=? WHERE id=?", arguments: [record.updatedAt, record.conversationID.uuidString])
                    try db.execute(sql: "UPDATE conversationSearch SET content=trim(content || ' ' || ?) WHERE conversationID=?", arguments: [text, record.conversationID.uuidString])
                }
            }
            try Self.event(db, id: id, kind: "settled", payload: JSONEncoder().encode(record), at: record.updatedAt)
            return record
        }
    }

    public func recordEvent(_ id: UUID, owner: UUID, kind: String, payload: Data) throws {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            let record = try Self.load(db, id)
            guard !record.state.isTerminal else { throw ExecutionStoreError.invalidTransition }
            try Self.event(db, id: id, kind: kind, payload: payload, at: .now)
        }
    }

    /// A transfer requests a pause; it never cancels an effect already in flight.
    public func requestTransfer(_ id: UUID, owner: UUID) throws {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var record = try Self.load(db, id)
            guard [.queued, .running, .waitingEvent, .waitingNetwork].contains(record.state) else { return }
            record.transferResumeState = record.state == .running ? .queued : record.state
            record.boundaryPauseReason = "Runtime ownership transfer"
            if record.state != .running { record.state = .paused; record.reason = record.boundaryPauseReason }
            record.revision += 1; record.updatedAt = .now
            try Self.write(db, record)
            try Self.event(db, id: id, kind: "transferRequested", payload: Data(), at: record.updatedAt)
        }
    }

    public func resumeTransferred(owner: UUID) throws {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            let records = try Row.fetchAll(db, sql: "SELECT record FROM agentExecutions WHERE state='paused'").map(Self.decode)
            for var record in records {
                guard let state = record.transferResumeState, record.reason == "Runtime ownership transfer" else { continue }
                record.state = state; record.reason = nil; record.boundaryPauseReason = nil; record.transferResumeState = nil
                record.ownerGeneration = owner; record.revision += 1; record.updatedAt = .now
                try Self.write(db, record)
                try Self.event(db, id: record.id, kind: "transferred", payload: Data(), at: record.updatedAt)
            }
        }
    }

    public func active(conversationID: UUID) throws -> AgentExecution? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT record FROM agentExecutions WHERE conversationID=? AND state NOT IN ('verified','accepted','failed','cancelled')",
                             arguments: [conversationID.uuidString]).map(Self.decode)
        }
    }

    public func list(conversationID: UUID) throws -> [AgentExecution] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT record FROM agentExecutions WHERE conversationID=? ORDER BY createdAt,id", arguments: [conversationID.uuidString]).map(Self.decode)
        }
    }

    public func list(states: Set<ExecutionState>? = nil) throws -> [AgentExecution] {
        let records = try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT record FROM agentExecutions ORDER BY createdAt,id").map(Self.decode)
        }
        return states.map { wanted in records.filter { wanted.contains($0.state) } } ?? records
    }

    @discardableResult
    public func transition(_ id: UUID, owner: UUID, expectedRevision: Int64, to state: ExecutionState,
                           reason: String? = nil, at date: Date = .now) throws -> AgentExecution {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var record = try Self.load(db, id)
            guard record.revision == expectedRevision else { throw ExecutionStoreError.staleRevision }
            guard !record.state.isTerminal else { throw ExecutionStoreError.invalidTransition }
            record.state = state; record.reason = reason; record.ownerGeneration = owner
            record.revision += 1; record.updatedAt = date
            try Self.write(db, record)
            try Self.event(db, id: id, kind: "state", payload: JSONEncoder().encode(record), at: date)
            return record
        }
    }

    @discardableResult
    public func saveCheckpoint(_ checkpoint: ExecutionCheckpoint, executionID: UUID, owner: UUID,
                               expectedRevision: Int64) throws -> AgentExecution {
        guard checkpoint.version == 1, checkpoint.conversation.version == 1,
              checkpoint.effects.map(\.call.id) == checkpoint.turn.calls.map(\.id),
              Set(checkpoint.turn.calls.map(\.id)).count == checkpoint.turn.calls.count,
              checkpoint.effects.allSatisfy({ effect in
                  effect.state == .returned ? effect.output?.id == effect.call.id : effect.output == nil
              }) else { throw ExecutionStoreError.incompatibleCheckpoint }
        return try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var record = try Self.load(db, executionID)
            guard record.revision == expectedRevision else { throw ExecutionStoreError.staleRevision }
            guard record.state == .running else { throw ExecutionStoreError.invalidTransition }
            record.revision += 1; record.updatedAt = checkpoint.savedAt
            try Self.write(db, record)
            try db.execute(sql: "UPDATE agentExecutions SET checkpoint=? WHERE id=?",
                           arguments: [try Self.encodeCheckpoint(checkpoint, artifacts: artifacts), executionID.uuidString])
            for id in checkpoint.deliveredMissionInputIDs ?? [] {
                try db.execute(sql: "UPDATE agentExecutionInputs SET consumed=1 WHERE id=? AND executionID=?", arguments: [id.uuidString, executionID.uuidString])
            }
            try Self.event(db, id: executionID, kind: "checkpoint", payload: Data(), at: checkpoint.savedAt)
            return record
        }
    }

    public func checkpoint(_ id: UUID) throws -> ExecutionCheckpoint? {
        let bytes = try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentExecutions WHERE id=?", arguments: [id.uuidString])
        }
        guard let bytes else { return nil }
        let value = try Self.decodeCheckpoint(bytes, artifacts: artifacts)
        guard value.version == 1, value.conversation.version == 1 else { throw ExecutionStoreError.incompatibleCheckpoint }
        return value
    }

    /// Read-modify-write is one transaction, including parallel tool callbacks.
    public func updateEffect(executionID: UUID, callID: String, owner: UUID,
                             output: ModelToolOutput? = nil, toolState: [String: Data]? = nil) throws {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var record = try Self.load(db, executionID)
            guard record.state == .running,
                  let bytes = try Data.fetchOne(db, sql: "SELECT checkpoint FROM agentExecutions WHERE id=?", arguments: [executionID.uuidString]) else {
                throw ExecutionStoreError.invalidTransition
            }
            var checkpoint = try Self.decodeCheckpoint(bytes, artifacts: artifacts)
            guard checkpoint.version == 1, let index = checkpoint.effects.firstIndex(where: { $0.call.id == callID }),
                  checkpoint.effects[index].state != .returned,
                  output == nil || output?.id == callID else { throw ExecutionStoreError.invalidTransition }
            checkpoint.effects[index].state = output == nil ? .launched : .returned
            if output == nil { checkpoint.effects[index].wasLaunched = true }
            checkpoint.effects[index].output = output
            if let toolState { checkpoint.toolState = toolState }
            if output?.metadata["recovery_required"] != nil,
               !checkpoint.blockedCalls.contains(where: { $0.id == callID }) {
                checkpoint.blockedCalls.append(checkpoint.effects[index].call)
            }
            if output != nil { checkpoint.seenCallIDs.insert(callID) }
            checkpoint.savedAt = .now; record.revision += 1; record.updatedAt = checkpoint.savedAt
            try Self.write(db, record)
            try db.execute(sql: "UPDATE agentExecutions SET checkpoint=? WHERE id=?", arguments: [try Self.encodeCheckpoint(checkpoint, artifacts: artifacts), executionID.uuidString])
            try Self.event(db, id: executionID, kind: output == nil ? "effectLaunched" : "effectReturned",
                           payload: Data(callID.utf8), at: record.updatedAt)
        }
    }

    public func eventCursor(_ id: UUID) throws -> Int64 {
        try database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(sequence) FROM agentExecutionEvents WHERE executionID=?", arguments: [id.uuidString]) ?? 0
        }
    }

    public func events(_ id: UUID, after sequence: Int64 = 0, limit: Int = 100) throws -> [ExecutionEvent] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agentExecutionEvents WHERE executionID=? AND sequence>? ORDER BY sequence LIMIT ?",
                             arguments: [id.uuidString, sequence, max(1, min(limit, 1000))]).map {
                ExecutionEvent(sequence: $0["sequence"], executionID: id, kind: $0["kind"],
                               payload: $0["payload"], createdAt: $0["createdAt"])
            }
        }
    }

    public func latestEvents(_ id: UUID, kind: String, limit: Int) throws -> [ExecutionEvent] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agentExecutionEvents WHERE executionID=? AND kind=? ORDER BY sequence DESC LIMIT ?",
                             arguments: [id.uuidString, kind, max(1, min(limit, 1000))]).map {
                ExecutionEvent(sequence: $0["sequence"], executionID: id, kind: $0["kind"],
                               payload: $0["payload"], createdAt: $0["createdAt"])
            }
        }
    }

    public func wait(_ condition: WakeCondition, owner: UUID, expectedRevision: Int64) throws -> AgentExecution {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var record = try Self.load(db, condition.executionID)
            guard !record.state.isTerminal, record.revision == expectedRevision else { throw ExecutionStoreError.staleRevision }
            record.state = condition.kind == .network ? .waitingNetwork : .waitingEvent
            record.reason = "Waiting for \(condition.kind.rawValue): \(condition.key)"
            record.revision += 1; record.updatedAt = .now; record.ownerGeneration = owner
            try Self.write(db, record)
            try db.execute(sql: "DELETE FROM agentWakeConditions WHERE executionID=?", arguments: [condition.executionID.uuidString])
            try db.execute(sql: "INSERT INTO agentWakeConditions(id,executionID,kind,eventKey,dueAt,baseline) VALUES(?,?,?,?,?,?)",
                arguments: [condition.id.uuidString, condition.executionID.uuidString, condition.kind.rawValue, condition.key, condition.dueAt, condition.baseline])
            try Self.event(db, id: record.id, kind: "waiting", payload: JSONEncoder().encode(condition), at: record.updatedAt)
            return record
        }
    }

    /// Payload is untrusted event data; never modifies request or authorizations.
    @discardableResult
    public func enqueueWake(executionID: UUID, dedupKey: String, payload: Data, owner: UUID, at date: Date = .now) throws -> Bool {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            let record = try Self.load(db, executionID)
            guard !record.state.isTerminal else { return false }
            try db.execute(sql: "INSERT OR IGNORE INTO agentWakeInbox(id,dedupKey,executionID,payload,createdAt) VALUES(?,?,?,?,?)",
                           arguments: [UUID().uuidString, dedupKey, executionID.uuidString, payload, date])
            return db.changesCount == 1
        }
    }

    /// Read-only reconciliation of an already committed wake. Pending and
    /// consumed rows both prove admission; callers must still check account/grant.
    public func wakePayload(executionID: UUID, dedupKey: String) throws -> Data? {
        try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM agentWakeInbox WHERE executionID=? AND dedupKey=? LIMIT 1",
                              arguments: [executionID.uuidString, dedupKey])
        }
    }

    /// Leaves events pending during user pauses. Consumption and wakeup are atomic.
    public func consumeWake(executionID: UUID, owner: UUID, at date: Date = .now) throws -> Data? {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            var record = try Self.load(db, executionID)
            let premature = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentWakeConditions WHERE executionID=? AND kind='network' AND dueAt>?", arguments: [executionID.uuidString, date]) ?? 0
            guard premature == 0 else { return nil }
            guard [.waitingEvent, .waitingNetwork].contains(record.state) else { return nil }
            let rows = try Row.fetchAll(db, sql: "SELECT id,payload FROM agentWakeInbox WHERE executionID=? AND consumedAt IS NULL ORDER BY createdAt,id",
                                       arguments: [executionID.uuidString])
            guard !rows.isEmpty else { return nil }
            // A burst is one wake. Retain every original receipt in the inbox,
            // but do not let equivalent old events wake the next wait again.
            let payload: Data = rows.count == 1 ? rows[0]["payload"] : try JSONEncoder().encode(rows.map { row in
                let data: Data = row["payload"]
                return String(decoding: data, as: UTF8.self)
            })
            try db.execute(sql: "UPDATE agentWakeInbox SET consumedAt=? WHERE executionID=? AND consumedAt IS NULL", arguments: [date, executionID.uuidString])
            try db.execute(sql: "DELETE FROM agentWakeConditions WHERE executionID=?", arguments: [executionID.uuidString])
            record.state = .queued; record.reason = nil; record.revision += 1
            record.ownerGeneration = owner; record.updatedAt = date
            try Self.write(db, record)
            try Self.event(db, id: executionID, kind: "wake", payload: payload, at: date)
            return payload
        }
    }

    public func dueConditions(at date: Date) throws -> [WakeCondition] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT c.* FROM agentWakeConditions c JOIN agentExecutions e ON e.id=c.executionID WHERE c.dueAt<=? AND e.state IN ('waitingEvent','waitingNetwork')",
                             arguments: [date]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]), let executionID = UUID(uuidString: row["executionID"]),
                      let kind = WakeCondition.Kind(rawValue: row["kind"]) else { return nil }
                return WakeCondition(id: id, executionID: executionID, kind: kind, key: row["eventKey"], dueAt: row["dueAt"], baseline: row["baseline"])
            }
        }
    }

    public func wakeConditions() throws -> [WakeCondition] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT c.* FROM agentWakeConditions c JOIN agentExecutions e ON e.id=c.executionID WHERE e.state NOT IN ('verified','accepted','failed','cancelled')").map { row in
                guard let id = UUID(uuidString: row["id"]), let execution = UUID(uuidString: row["executionID"]),
                      let kind = WakeCondition.Kind(rawValue: row["kind"]) else { throw ExecutionStoreError.incompatibleCheckpoint }
                return WakeCondition(id: id, executionID: execution, kind: kind, key: row["eventKey"], dueAt: row["dueAt"], baseline: row["baseline"])
            }
        }
    }

    public func queueDelivery(id: UUID, executionID: UUID, payload: Data, owner: UUID) throws {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            try db.execute(sql: "INSERT OR IGNORE INTO agentDeliveryOutbox(id,executionID,payload,createdAt) VALUES(?,?,?,?)",
                           arguments: [id.uuidString, executionID.uuidString, payload, Date.now])
        }
    }

    public func archiveConversation(executionID: UUID, content: Data, owner: UUID) throws {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            // Sub-agents compact their history while the parent waits for them (waitingEvent).
            guard [.running, .waitingEvent, .waitingNetwork].contains(try Self.load(db, executionID).state) else { throw ExecutionStoreError.invalidTransition }
            let reference = try artifacts?.put(content)
            try db.execute(sql: "INSERT INTO agentConversationArchives(id,executionID,content,createdAt,artifactReference,byteCount) VALUES(?,?,?,?,?,?)",
                           arguments: [UUID().uuidString, executionID.uuidString, reference == nil ? content : Data(), Date.now, reference, content.count])
        }
    }

    public func archivedConversations(executionID: UUID) throws -> [(id: String, bytes: Int)] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id,COALESCE(byteCount,LENGTH(content)) AS bytes FROM agentConversationArchives WHERE executionID=? ORDER BY createdAt,id",
                             arguments: [executionID.uuidString]).map { ($0["id"], $0["bytes"]) }
        }
    }

    public func readArchive(id: String, executionID: UUID, offset: Int, limit: Int) throws -> Data? {
        guard offset >= 0, offset < Int.max, (1...65_536).contains(limit) else { throw ExecutionStoreError.invalidTransition }
        let row = try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT artifactReference,SUBSTR(content,?,?) AS page FROM agentConversationArchives WHERE id=? AND executionID=?",
                              arguments: [offset + 1, limit, id, executionID.uuidString])
        }
        guard let row else { return nil }
        if let reference: String = row["artifactReference"] {
            guard let artifacts else { throw ExecutionStoreError.incompatibleCheckpoint }
            let data = try artifacts.read(reference)
            return Data(data.dropFirst(min(offset, data.count)).prefix(limit))
        }
        return row["page"]
    }

    private static func encodeCheckpoint(_ checkpoint: ExecutionCheckpoint, artifacts: ExecutionArtifactStore?) throws -> Data {
        guard let artifacts else { return try JSONEncoder().encode(checkpoint) }
        var stripped = checkpoint
        let reference = try artifacts.put(stripped.conversation.transcript)
        stripped.conversation.transcript = Data()
        var images: [String: String] = [:]
        for index in stripped.effects.indices {
            guard let output = stripped.effects[index].output, let image = output.imagePNG else { continue }
            images[output.id] = try artifacts.put(image)
            stripped.effects[index].output = ModelToolOutput(id: output.id, content: output.content, isError: output.isError, metadata: output.metadata)
        }
        var toolState: [String: String] = [:]
        for (name, data) in stripped.toolState ?? [:] { toolState[name] = try artifacts.put(data) }
        let hadToolState = stripped.toolState != nil
        stripped.toolState = nil
        return try JSONEncoder().encode(StoredExecutionCheckpoint(checkpoint: stripped, transcript: reference, images: images, toolState: hadToolState ? toolState : nil))
    }
    private static func decodeCheckpoint(_ bytes: Data, artifacts: ExecutionArtifactStore?) throws -> ExecutionCheckpoint {
        guard let stored = try? JSONDecoder().decode(StoredExecutionCheckpoint.self, from: bytes) else {
            return try JSONDecoder().decode(ExecutionCheckpoint.self, from: bytes)
        }
        guard stored.storageVersion == 1, let artifacts else { throw ExecutionStoreError.incompatibleCheckpoint }
        var checkpoint = stored.checkpoint
        checkpoint.conversation.transcript = try artifacts.read(stored.transcript)
        if let tools = stored.toolState {
            var state: [String: Data] = [:]
            for (name, reference) in tools { state[name] = try artifacts.read(reference) }
            checkpoint.toolState = state
        }
        for index in checkpoint.effects.indices {
            guard let output = checkpoint.effects[index].output, let reference = stored.images[output.id] else { continue }
            checkpoint.effects[index].output = ModelToolOutput(id: output.id, content: output.content, isError: output.isError,
                imagePNG: try artifacts.read(reference), metadata: output.metadata)
        }
        return checkpoint
    }

    public func pendingDeliveries() throws -> [(id: UUID, executionID: UUID, payload: Data)] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id,executionID,payload FROM agentDeliveryOutbox WHERE deliveredAt IS NULL ORDER BY createdAt").compactMap { row in
                guard let id = UUID(uuidString: row["id"]), let executionID = UUID(uuidString: row["executionID"]) else { return nil }
                return (id, executionID, row["payload"])
            }
        }
    }

    public func latestDeliveryEnvelope(executionID: UUID) throws -> (id: UUID, payload: Data)? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id,payload FROM agentDeliveryOutbox WHERE executionID=? ORDER BY rowid DESC LIMIT 1",
                                            arguments: [executionID.uuidString]),
                  let id = UUID(uuidString: row["id"]) else { return nil }
            return (id, row["payload"])
        }
    }

    public func latestDelivery(executionID: UUID) throws -> Data? {
        try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM agentDeliveryOutbox WHERE executionID=? ORDER BY rowid DESC LIMIT 1",
                             arguments: [executionID.uuidString])
        }
    }

    public func delivered(_ id: UUID, owner: UUID) throws {
        try database.pool.write { db in
            try Self.checkOwner(db, owner)
            try db.execute(sql: "UPDATE agentDeliveryOutbox SET deliveredAt=? WHERE id=?", arguments: [Date.now, id.uuidString])
        }
    }

    private static func checkOwner(_ db: Database, _ owner: UUID) throws {
        guard try String.fetchOne(db, sql: "SELECT generation FROM agentRuntimeOwner WHERE id=1") == owner.uuidString else {
            throw ExecutionStoreError.staleOwner
        }
    }
    private static func decode(_ row: Row) throws -> AgentExecution {
        try JSONDecoder().decode(AgentExecution.self, from: row["record"])
    }
    private static func load(_ db: Database, _ id: UUID) throws -> AgentExecution {
        guard let row = try Row.fetchOne(db, sql: "SELECT record FROM agentExecutions WHERE id=?", arguments: [id.uuidString]) else {
            throw ExecutionStoreError.notFound
        }
        return try decode(row)
    }
    private static func write(_ db: Database, _ record: AgentExecution) throws {
        try db.execute(sql: "UPDATE agentExecutions SET state=?,revision=?,ownerGeneration=?,reason=?,updatedAt=?,record=? WHERE id=?",
                       arguments: [record.state.rawValue, record.revision, record.ownerGeneration?.uuidString,
                           record.reason, record.updatedAt, try JSONEncoder().encode(record), record.id.uuidString])
    }
    private static func event(_ db: Database, id: UUID, kind: String, payload: Data, at date: Date) throws {
        try db.execute(sql: "INSERT INTO agentExecutionEvents(executionID,kind,payload,createdAt) VALUES(?,?,?,?)",
                       arguments: [id.uuidString, kind, payload, date])
    }
}
