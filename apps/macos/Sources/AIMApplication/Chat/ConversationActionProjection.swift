import AIMCore
import Foundation

public enum ConversationActionProjection {
    public static func apply(_ histories: [WorkspaceRunHistory], to messages: [ConversationMessage]) -> [ConversationMessage] {
        messages.map { message in
            guard message.role == .assistant,
                  let source = messages.last(where: { $0.role == .user && $0.sequence < message.sequence }) else { return message }
            // A run belongs to one assistant turn, even when legacy histories
            // contain several assistant fragments before the next user message.
            guard messages.first(where: { $0.role == .assistant && $0.sequence > source.sequence })?.id == message.id else { return message }
            let next = messages.first { $0.role == .user && $0.sequence > source.sequence }?.createdAt
            let runs = histories.filter { $0.run.conversationID.lowercased() == message.conversationID.uuidString.lowercased() && $0.run.startedAt >= source.createdAt && (next == nil || $0.run.startedAt < next!) }.sorted { $0.run.startedAt < $1.run.startedAt }
            var actions: [ConversationAction] = []
            for run in runs {
                for call in run.calls {
                    let state: ConversationAction.State = switch call.state {
                    case .requested: run.run.state == .running ? .running : .needsReview
                    case .succeeded: .completed
                    case .failed: .failed
                    case .interrupted: .needsReview
                    }
                    let metadata = call.resultMetadataJSON.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                    let preview = metadata["aim_preview_jpeg"].flatMap { Data(base64Encoded: $0) }
                    actions.append(.init(id: run.id + ":" + call.id, conversationID: message.conversationID,
                        turnID: message.id, ordinal: actions.count, name: call.name, state: state,
                        startedAt: call.startedAt, finishedAt: call.endedAt,
                        detail: String(decoding: call.argumentsJSON, as: UTF8.self) + (call.result.map { "\n\n" + String($0.prefix(8_000)) } ?? ""), detailReference: run.id + ":" + call.id, previewJPEG: preview, input: String(decoding: call.argumentsJSON, as: UTF8.self), output: call.result))
                }
            }
            var result = message; result.actions = ConversationAction.merge(message.actions, actions.isEmpty ? nil : actions); return result
        }
    }
}
