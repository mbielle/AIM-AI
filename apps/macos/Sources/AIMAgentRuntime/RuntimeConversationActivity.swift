import AIMCore
import AIMApplication
import AIMAgentKit
import Foundation

/// Reconstruct public connection state from the existing durable engine journal.
/// No private reasoning or provider request bodies are exposed.
public enum RuntimeConversationActivity {
    public static func apply(repository: SQLiteAgentExecutionRepository, to messages: [ConversationMessage]) async throws -> [ConversationMessage] {
        guard let conversationID = messages.first?.conversationID, messages.allSatisfy({ $0.conversationID == conversationID }) else { return messages }
        var result = messages
        for root in try await repository.list(conversationID: conversationID) {
            let request = try? JSONDecoder().decode(AgentRequest.self, from: root.request)
            let user = messages.last { $0.role == .user && $0.createdAt <= root.createdAt }
            let source = request?.sourceMessageID.flatMap { id in messages.first { $0.id == id && $0.role == .user } } ?? user
            guard let source, let index = result.firstIndex(where: { $0.role == .assistant && $0.sequence > source.sequence }) else { continue }
            var cursor: Int64 = 0, began: Date?, ended: Date?, waiting = false, attempts = 0
            while true {
                let page = try await repository.events(root.id, after: cursor, limit: 1000)
                for entry in page where entry.kind == "engine" {
                    guard let event = try? JSONDecoder().decode(EngineEvent.self, from: entry.payload),
                          case let .runStage(id, stage) = event, id == conversationID else { continue }
                    if stage == .waitingForNetwork {
                        if !waiting { attempts += 1 }; waiting = true; ended = nil
                        if began == nil { began = entry.createdAt }
                    } else if waiting { waiting = false; ended = entry.createdAt }
                }
                guard let last = page.last else { break }; cursor = last.sequence
                if page.count < 1000 { break }
            }
            guard let began else { continue }
            let state: ConversationAction.State
            if waiting && root.state == .cancelled { state = .cancelled; ended = root.updatedAt }
            else if waiting && (root.state.isTerminal || root.state == .awaitingReview || root.state == .blocked) { state = .needsReview; ended = root.updatedAt }
            else { state = waiting ? .waiting : .completed }
            let action = ConversationAction(id: root.id.uuidString + ":network", conversationID: conversationID,
                turnID: result[index].id, ordinal: -1, name: "network", state: state,
                startedAt: began, finishedAt: ended, detail: "Network waits before submission: \(attempts). Target and model retained. Submitted operations are reconciled before any new request.")
            result[index].actions = ConversationAction.merge(result[index].actions, [action])
        }
        return result
    }
}
