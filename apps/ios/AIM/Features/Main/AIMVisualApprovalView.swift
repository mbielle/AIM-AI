import AIMCore
import SwiftUI

struct AIMVisualApprovalView: View {
    let chat: NativeChatStore
    let pending: NativeVisualApproval
    @State private var provider: ChatProvider = .openRouter
    @State private var modelID = ""
    @State private var models: [ChatModel] = []
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The main model stays \(pending.primaryModel). Choose a visual analyst for these attachments.")
                    Picker("Provider", selection: $provider) { ForEach(ChatProvider.allCases.filter { chat.connectedProviders.contains($0) }, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Visual model", selection: $modelID) {
                        Text("Choose model").tag("")
                        ForEach(models.filter { $0.supportsImageInput == true }) { Text($0.name).tag($0.id) }
                    }
                    Text("Analysis uses this iPhone’s credentials. Cost is not known in advance; provider charges apply. Every batch is admitted separately. A strict budget requires a verified cost bound.").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = chat.errorMessage { Text(error).foregroundStyle(.red) }
                if chat.preparingVisualAnalysis { ProgressView("Analysing media…") }
                Button("Authorize once") { run(false) }.disabled(modelID.isEmpty || chat.preparingVisualAnalysis)
                Button("Always authorize this visual model on this iPhone") { run(true) }.disabled(modelID.isEmpty || chat.preparingVisualAnalysis)
                Button("Refuse", role: .cancel) { task?.cancel(); chat.pendingVisualApproval = nil }
            }.navigationTitle("Visual analysis")
                .interactiveDismissDisabled(chat.preparingVisualAnalysis)
                .task(id: provider) { do { models = try await chat.catalog(for: provider) } catch { chat.errorMessage = error.localizedDescription } }
                .onAppear { if !chat.connectedProviders.contains(provider), let first = ChatProvider.allCases.first(where: { chat.connectedProviders.contains($0) }) { provider = first } }
                .onDisappear { task?.cancel() }
        }
    }
    private func run(_ remember: Bool) {
        task = Task { _ = await chat.runVisualApproval(pending, choice: .init(provider: provider, modelID: modelID), remember: remember) }
    }
}
