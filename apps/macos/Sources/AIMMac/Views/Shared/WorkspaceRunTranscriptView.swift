import AIMAgentKit
import AIMCore
import AIMApplication
import SwiftUI

/// Durable host activity shown beside the turn that started it. The repository
/// remains the source of truth; unrecorded actions are never inferred.
struct WorkspaceRunTranscriptView: View {
    @Environment(AppModel.self) private var model
    let history: WorkspaceRunHistory
    /// The assistant message answering this run; nil before it is saved.
    var turnID: UUID?
    /// The answer shows these actions in its own timeline: keep only the answered questions here.
    var questionsOnly = false
    @State private var selectedCall: WorkspaceCall?
    @State private var detailCharacters = 16_384

    private var actions: [ConversationAction] {
        let conversation = UUID(uuidString: history.run.conversationID) ?? UUID()
        let turn = turnID ?? UUID(uuidString: history.id) ?? conversation
        return history.calls.enumerated().map { index, call in
            .init(id: history.id + ":" + call.id, conversationID: conversation, turnID: turn, ordinal: index,
                name: call.name, state: call.state == .succeeded ? .completed : call.state == .failed ? .failed : call.state == .requested ? .running : .needsReview,
                startedAt: call.startedAt, finishedAt: call.endedAt, detailReference: history.id + ":" + call.id,
                input: String(decoding: call.argumentsJSON, as: UTF8.self), output: call.result)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Older runs read like the timeline: one summarizing line that unfolds to each action.
            if !questionsOnly {
                MacToolGroupView(tools: actions, live: false, turnTools: actions)
                    .accessibilityIdentifier("workspace-run-activity-\(history.id)")
            }

            ForEach(history.calls.filter { $0.name == "ask_user" && $0.state == .succeeded && $0.result != nil }) { call in
                VStack(alignment: .leading, spacing: 7) {
                    Text(questionSummary(for: call))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(2)
                    Text(call.result ?? "")
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .sheet(item: $selectedCall) { call in
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(WorkspaceProgressView.title(for: call.name)).font(.headline); Spacer(); Button("Close") { selectedCall = nil } }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let metadata = call.resultMetadataJSON.flatMap({ try? JSONDecoder().decode([String: String].self, from: $0) }),
                           let bytes = metadata["aim_preview_jpeg"].flatMap({ Data(base64Encoded: $0) }),
                           let preview = InputMediaPreview.jpeg(bytes), let image = NSImage(data: preview) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                        }
                        Text(ConversationAction.redact(String(decoding: call.argumentsJSON, as: UTF8.self))).font(.system(.caption, design: .monospaced))
                        let safe = ConversationAction.redact(call.result ?? "Details unavailable", limit: 1_000_000)
                        Text(String(safe.prefix(detailCharacters))).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        if detailCharacters < safe.count {
                            Button("Load more output") { detailCharacters = min(safe.count, detailCharacters + 16_384) }
                        }
                        if (call.result?.count ?? 0) > 1_000_000 {
                            Text("This view is limited to one million characters. The complete tool result remains in the local action history.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24).frame(minWidth: 480, idealWidth: 640, minHeight: 300, idealHeight: 480)
        }
    }

    private func arguments(for call: WorkspaceCall) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: call.argumentsJSON)) ?? [:]
    }

    private func questionSummary(for call: WorkspaceCall) -> String {
        let args = arguments(for: call)
        if let text = args["question"] { return text }
        if let raw = args["questions"], let data = raw.data(using: .utf8),
           let items = try? JSONDecoder().decode([AgentQuestionItem].self, from: data) {
            return items.count == 1 ? items[0].question : "Answered \(items.count) questions"
        }
        return "Answered the agent's question"
    }
}
