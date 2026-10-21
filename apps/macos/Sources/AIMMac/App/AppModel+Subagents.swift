import AIMAgentKit
import AIMAgentRuntime
import AIMApplication
import AIMCore
import Foundation

/// A sub-agent as the Sub-agents panel shows it, read from the durable execution store.
struct SubagentSnapshot: Identifiable, Equatable {
    let id: UUID
    let executionID: UUID
    let title: String
    let prompt: String
    let provider: String?
    let modelID: String?
    let effort: String?
    let state: ExecutionState
    let result: String?
    let createdAt: Date
    let entries: [SubagentJournalEntry]
    let costUSD: Double?
    let tokens: Int?

    var isActive: Bool { !state.isTerminal }
    var lastActivity: Date { entries.last?.at ?? createdAt }
}

extension AppModel {
    /// Every sub-agent started in this conversation, oldest first, with its journal.
    func subagents(conversationID: UUID) async -> [SubagentSnapshot] {
        #if DEBUG
        if let debugSubagents { return debugSubagents }
        #endif
        let repository = SQLiteAgentExecutionRepository(database: database)
        guard let executions = try? await repository.list(conversationID: conversationID) else { return [] }
        var result: [SubagentSnapshot] = []
        for execution in executions {
            guard let children = try? await repository.children(parentExecutionID: execution.id), !children.isEmpty else { continue }
            // A child without its own route runs on the parent's model: show that model, not a placeholder.
            let parentModel = (try? JSONDecoder().decode(AgentRequest.self, from: execution.request))?.modelID
            var entries: [SubagentJournalEntry] = []
            var metrics: [UUID: [TurnMetrics]] = [:]
            var cursor: Int64 = 0
            while let batch = try? await repository.events(execution.id, after: cursor, limit: 500), let last = batch.last {
                for event in batch {
                    if event.kind == SubagentJournalEntry.eventKind, let entry = try? JSONDecoder().decode(SubagentJournalEntry.self, from: event.payload) {
                        entries.append(entry)
                    } else if event.kind == "childMetrics", let row = try? JSONDecoder().decode(AccountRuntimeActivity.ChildMetric.self, from: event.payload) {
                        metrics[row.childID, default: []].append(row.metrics)
                    }
                }
                cursor = last.sequence
                if batch.count < 500 { break }
            }
            for child in children {
                let turns = metrics[child.id] ?? []
                let costs = turns.compactMap(\.costUSD)
                let tokens = turns.compactMap { turn in turn.usage.inputTokens.map { $0 + turn.outputTokens } }
                result.append(SubagentSnapshot(id: child.id, executionID: execution.id, title: child.title, prompt: child.prompt,
                    provider: child.providerID, modelID: child.modelID ?? parentModel, effort: child.effort, state: child.state, result: child.result,
                    createdAt: child.createdAt, entries: entries.filter { $0.childID == child.id },
                    costUSD: costs.isEmpty || costs.count < turns.count ? nil : costs.reduce(0, +),
                    tokens: tokens.isEmpty ? nil : tokens.reduce(0, +)))
            }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }
}
