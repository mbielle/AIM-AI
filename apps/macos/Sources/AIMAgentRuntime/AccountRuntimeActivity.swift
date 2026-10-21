import AIMApplication
import AIMAgentKit
import AIMCore
import CryptoKit
import Foundation

/// Measures only roots attributed at admission. Old execution journals remain local until selected for import.
package enum AccountRuntimeActivity {
    package static func stableID(_ scope: UUID, _ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((scope.uuidString + ":" + value).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    package static func begin(_ root: AgentExecution, request: AgentRequest, repository: SQLiteAgentExecutionRepository) async throws {
        guard let account = root.accountID else { return }
        let activity = await repository.activity
        try await activity.ownConversation(root.conversationID, accountID: account, since: root.createdAt)
        if try await activity.existing(root.id) == nil {
            try await activity.record(.init(id: root.id, accountID: account, deviceID: activity.deviceID,
                deviceName: Host.current().localizedName ?? "Mac", conversationID: root.conversationID, kind: .task,
                provider: (request.provider ?? .openRouter).rawValue, modelID: request.modelID, mode: request.mode.rawValue, startedAt: root.createdAt))
        }
    }
    /// The parent journal makes child metrics recoverable, without persisting another copy of its text.
    package struct ChildMetric: Codable { package var childID: UUID; package var metrics: TurnMetrics }
    package static func child(_ event: EngineEvent, childID: UUID, context: RuntimeExecutionContext) async throws {
        if case let .turnMetrics(_, metrics) = event {
            try await context.repository.recordEvent(context.executionID, owner: context.owner,
                kind: "childMetrics", payload: JSONEncoder().encode(ChildMetric(childID: childID, metrics: metrics)))
        }
    }
    package static func refresh(_ root: AgentExecution, repository: SQLiteAgentExecutionRepository, now: Date = .now) async throws {
        let activity = await repository.activity
        guard var task = try await activity.existing(root.id), task.kind == .task, task.accountID == root.accountID else { return }
        var cursor: Int64 = 0
        var journal: [ExecutionEvent] = []
        while true {
            let batch = try await repository.events(root.id, after: cursor, limit: 1000)
            journal += batch
            guard let last = batch.last else { break }
            cursor = last.sequence
            if batch.count < 1000 { break }
        }
        let children = try await repository.children(parentExecutionID: root.id)
        var transitions: [AccountTaskTransition] = [.init(nodeID: root.id, at: root.createdAt, state: .running)]
        for entry in journal {
            if ["state", "settled"].contains(entry.kind), let state = try? JSONDecoder().decode(AgentExecution.self, from: entry.payload) {
                transitions.append(.init(nodeID: root.id, at: entry.createdAt, state: status(state.state)))
            } else if entry.kind == "waiting" { transitions.append(.init(nodeID: root.id, at: entry.createdAt, state: .waiting)) }
            else if entry.kind == "wake" { transitions.append(.init(nodeID: root.id, at: entry.createdAt, state: .running)) }
            else if ["childAdmitted", "childState"].contains(entry.kind), let child = try? JSONDecoder().decode(DurableSubagent.self, from: entry.payload) {
                transitions.append(.init(nodeID: child.id, at: entry.createdAt, state: status(child.state)))
            } else if entry.kind == "engine", let event = try? JSONDecoder().decode(EngineEvent.self, from: entry.payload) {
                switch event {
                case let .turnMetrics(_, metrics): try await response(metrics, nodeID: root.id, task: task, activity: activity)
                case .approvalRequested: transitions.append(.init(nodeID: root.id, at: entry.createdAt, state: .waiting))
                case .textDelta, .toolStarted, .toolStartedDetailed: transitions.append(.init(nodeID: root.id, at: entry.createdAt, state: .running))
                default: break
                }
                if case let .toolStarted(_, id, name) = event {
                    let rowID = stableID(root.id, "tool:" + id)
                    if try await activity.existing(rowID) == nil {
                        try await activity.record(.init(id: rowID, accountID: task.accountID, deviceID: task.deviceID, deviceName: task.deviceName,
                            conversationID: task.conversationID, parentTaskID: root.id, kind: .tool, provider: task.provider,
                            modelID: task.modelID, mode: task.mode, startedAt: entry.createdAt, toolName: name, updatedAt: entry.createdAt))
                    }
                }
            } else if entry.kind == "childMetrics", let row = try? JSONDecoder().decode(ChildMetric.self, from: entry.payload) {
                try await response(row.metrics, nodeID: row.childID, task: task, activity: activity)
            }
        }
        // Completeness is derived from durable terminal transitions, including every descendant.
        let timing = AccountTaskTimeline(rootID: root.id, startedAt: root.createdAt,
            nodeIDs: Set(children.map(\.id) + [root.id]), transitions: transitions, now: now)
        // Unchanged statistics are not written again (each write is uploaded to the account).
        // Waiting time is kept to the minute while a task runs; the final value is written when it ends.
        guard task.completedAt != timing.completedAt || task.waitingSeconds.map({ Int($0) / 60 }) != Int(timing.waitingSeconds) / 60 else { return }
        task.completedAt = timing.completedAt; task.waitingSeconds = timing.waitingSeconds; task.updatedAt = now
        try await activity.record(task)
    }
    private static func status(_ state: ExecutionState) -> AccountTaskTransition.State {
        if state.isTerminal { return .finished }
        return [.queued, .running].contains(state) ? .running : .waiting
    }
    private static func response(_ metrics: TurnMetrics, nodeID: UUID, task: AccountActivityRecord,
                                 activity: SQLiteAccountActivityRepository) async throws {
        let id = stableID(nodeID, "response:\(metrics.startedAt.timeIntervalSince1970):\(metrics.provider):\(metrics.modelID)")
        var row = AccountActivityRecord(id: id, accountID: task.accountID, deviceID: task.deviceID, deviceName: task.deviceName,
            conversationID: task.conversationID, parentTaskID: task.id, provider: metrics.provider, modelID: metrics.modelID,
            mode: metrics.mode, startedAt: metrics.startedAt, completedAt: metrics.startedAt.addingTimeInterval(metrics.totalSeconds),
            totalTokens: metrics.usage.inputTokens.flatMap { input in metrics.usage.outputTokens.map { input + $0 } }, updatedAt: metrics.startedAt.addingTimeInterval(metrics.totalSeconds))
        row.costTrackedSeparately = true
        try await activity.record(row)
    }
}
