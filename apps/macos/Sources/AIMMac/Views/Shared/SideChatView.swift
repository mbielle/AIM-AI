import AIMApplication
import SwiftUI

/// Owned by the tab, never inserted into the main conversation repository.
@MainActor @Observable
final class SideChatSession {
    let id = UUID()
    var messages: [ConversationMessage] = []
    var draft = ""
    var running = false
    var error: String?
    var task: Task<Void, Never>?

    func send(using model: AppModel) {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !running else { return }
        guard !model.selectedModelID.isEmpty else { model.showModelPicker = true; return }
        messages.append(.init(conversationID: id, role: .user, content: prompt, sequence: messages.count))
        draft = ""; error = nil; running = true
        let history = messages
        let answer = UUID()
        messages.append(.init(id: answer, conversationID: id, role: .assistant, content: "", sequence: messages.count))
        task = Task { @MainActor in
            defer { running = false; task = nil }
            do {
                for try await delta in try await model.sideChatStream(messages: history) {
                    try Task.checkCancellation()
                    if let index = messages.firstIndex(where: { $0.id == answer }) { messages[index].content += delta }
                }
            } catch is CancellationError {
                if let index = messages.firstIndex(where: { $0.id == answer }) { messages[index].completionStatus = .cancelled }
            } catch {
                self.error = error.localizedDescription
                if let index = messages.firstIndex(where: { $0.id == answer }) { messages[index].completionStatus = .failed }
            }
        }
    }
    func close() { task?.cancel(); task = nil; messages = []; draft = "" }
}

struct SideChatView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: SideChatSession
    @State private var height: CGFloat = 36
    var body: some View {
        VStack(spacing: 12) {
            if session.messages.isEmpty {
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.secondary)
                Text("Side chat").font(.title2)
                Text("Temporary conversation. Kept when this panel is hidden; discarded when you close this tab.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(session.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == .user ? "You" : "AIM").font(.caption).foregroundStyle(.secondary)
                                    Text(message.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.id(message.id)
                            }
                        }.padding(20)
                    }.onChange(of: session.messages.last?.content) { _, _ in
                        if let id = session.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if session.draft.isEmpty { Text("Ask a side question…").foregroundStyle(.tertiary).padding(.top, 4) }
                    ComposerTextEditor(text: $session.draft, height: $height, placeholder: "Ask a side question",
                                       sendWithCommandReturn: model.preferences.sendWithCommandReturn,
                                       smartPunctuation: model.preferences.smartPunctuation) { _ in session.send(using: model) }
                        .frame(height: height)
                }
                HStack {
                    Button(model.selectedModelID.isEmpty ? "Choose model" : model.selectedModelID) { model.showModelPicker = true }
                        .lineLimit(1).font(.caption).buttonStyle(.plain)
                    Spacer()
                    Button {
                        if session.running { session.task?.cancel() } else { session.send(using: model) }
                    } label: { Image(systemName: session.running ? "stop.fill" : "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).disabled(!session.running && session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.08))).padding(14)
        }
    }
}
