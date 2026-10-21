import AIMCore
import AVKit
import AIMMacPlatform
import AIMApplication
import AIMAgentRuntime
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var searchVisible = false
    @State private var searchQuery = ""
    @State private var searchResults: [TranscriptSearchResult.Match] = []
    @State private var searchTruncated = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedSearchID: UUID?
    @FocusState private var searchFocused: Bool
    @State private var greetingIndex = Int.random(in: 0..<3)
    /// A conversation being opened stays invisible until it is laid out at its end, then fades in.
    @State private var revealed = true
    @State private var previewTurn: UUID?
    @State private var showEarlier = false
    @State private var cardHovered = false
    @State private var previewClose: Task<Void, Never>?
    @State private var selectedMissionEvidence: MissionFileEvidence?

    private var greeting: String {
        switch model.mode {
        case .chat: ["Welcome back.", "What’s on your mind?", "Let’s explore an idea."][greetingIndex]
        case .code: ["Let’s build.", "What will we create?", "Bring your idea to life."][greetingIndex]
        case .agent: ["Your AI assistant.", "What can I do for you?", "Let’s get things done."][greetingIndex]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedConversationID == nil, model.mode != .code {
                AIMSegmentedControl(selection: Binding(get: { model.mode }, set: { model.selectNewConversationMode($0) }),
                                    options: [(AIMMode.chat, "Chat"), (.agent, "Agent")], identifierPrefix: "new-mode-")
                .padding(.top, 14)
            }
            if let response = model.unsavedResponse {
                VStack(alignment: .leading, spacing: 8) {
                    Label("A response could not be saved", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("It is still held in memory. Save it before sending again or quitting; a crash or force quit could lose it.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Retry save") { Task { await model.retryResponseSave() } }
                            .disabled(model.isRetryingResponseSave || model.isSending)
                        Button("Copy response") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(response.content, forType: .string)
                        }
                        if model.selectedConversationID != response.conversationID {
                            Button("Open conversation") { Task { await model.selectConversation(response.conversationID) } }
                        }
                    }
                    if let error = model.responseSaveError { Text(error).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(14).frame(maxWidth: model.preferences.fullWidthConversations ? .infinity : 760, alignment: .leading)
                    .background(AIMTheme.muted(scheme), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 26).padding(.top, 12)
            }
            // The welcome screen only for a new conversation: while an existing one loads, its
            // layout stays (no flash of "Welcome back").
            if model.selectedConversationID == nil && model.messages.isEmpty {
                    Spacer()
                    ZStack {
                        Text(greeting).id(greeting).transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    .font(AIMTypography.title(44, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.bottom, 26)
                    .animation(.easeInOut(duration: 0.28), value: greeting)
                    composer
                    Spacer()
                    Spacer().frame(maxHeight: 85)
            } else {
                searchBar
                transcript
                VStack(spacing: 9) {
                    if model.isSending || model.selectedContinuityExecution?.state.isTerminal == false,
                       let approval = model.selectedToolApproval {
                        WorkspaceApprovalView(approval: approval)
                            .frame(maxWidth: model.preferences.fullWidthConversations ? .infinity : 760)
                            .padding(.horizontal, 26)
                    } else if let question = model.pendingAgentQuestions.first(where: { $0.conversationID == model.selectedConversationID }) {
                        AgentQuestionView(question: question)
                            .padding(.horizontal, 26)
                    } else if let execution = model.selectedContinuityExecution, let decision = ContinuityDecision.make(execution),
                              model.dismissedContinuityDecision != "\(execution.id.uuidString)-\(execution.revision)" {
                        ContinuityDecisionCard(execution: execution, decision: decision)
                            .frame(maxWidth: model.preferences.fullWidthConversations ? .infinity : 760)
                            .padding(.horizontal, 26)
                    }
                    if let voice = model.voiceSession {
                        VoiceConversationView(session: voice) { Task { await model.toggleVoiceConversation() } }
                    }
                    ComputerUsePreviewView()
                    composer
                }
                .padding(.top, 9).padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AIMTheme.background(scheme))
        .sheet(isPresented: Binding(get: { model.showMissionAuthorization }, set: { model.showMissionAuthorization = $0 })) { MissionAuthorizationView() }
        .sheet(item: $selectedMissionEvidence) { receipt in
            VStack(alignment: .leading, spacing: 12) {
                Text("File verification receipt").font(.title3.weight(.semibold))
                Text("AIM read this file at the recorded time. The receipt does not claim the file remains unchanged later.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Workspace", value: receipt.workspacePath)
                LabeledContent("File", value: receipt.relativePath)
                LabeledContent("Observed", value: receipt.observedAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Bytes", value: receipt.byteCount.formatted())
                LabeledContent("SHA-256", value: receipt.sha256)
                    .textSelection(.enabled)
                Button("Close") { selectedMissionEvidence = nil }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24)
            .frame(minWidth: 480)
        }
        .onChange(of: searchQuery) { _, _ in refreshSearch() }
        .onChange(of: model.messages.count) { _, _ in refreshSearch() }
        .onChange(of: model.isSending) { _, sending in
            if !sending {
                refreshSearch()
                Task { await model.loadWorkspaceHistory() }
            }
        }
        .onChange(of: model.selectedConversationID) { _, _ in
            showEarlier = false
            greetingIndex = (greetingIndex + 1) % 3
            searchTask?.cancel(); searchResults = []; selectedSearchID = nil
            searchQuery = ""; searchVisible = false
        }
        .onChange(of: model.searchTargetMessageID) { _, id in
            if id != nil { closeSearch() }
        }
        .onChange(of: model.transcriptSearchRequest) { _, _ in
            searchVisible = true; searchFocused = true; refreshSearch()
        }
        .onDisappear { searchTask?.cancel() }
        .task(id: model.selectedConversationID) { await model.loadWorkspaceHistory() }
    }

    private var composer: some View {
        AIMComposer(placeholder: model.mode == .chat ? "Ask anything" : "Describe what you have in mind…")
            .padding(.horizontal, 26)
    }

    /// Which card (approval, question or task decision) currently sits above the chat bar.
    private var decisionCardKey: String? {
        if let approval = model.selectedToolApproval { return "approval:" + approval.id.uuidString }
        if let question = model.pendingAgentQuestions.first(where: { $0.conversationID == model.selectedConversationID }) { return "question:" + question.id }
        if let execution = model.selectedContinuityExecution, ContinuityDecision.make(execution) != nil {
            return "decision:\(execution.id.uuidString)-\(execution.revision)"
        }
        return nil
    }

    /// The latest turns of a long conversation (at least 24 messages, starting at a question);
    /// everything while searching or once the person opened the earlier messages.
    private var shownMessages: [ConversationMessage] {
        let all = model.messages
        guard !showEarlier, !searchVisible, all.count > 40 else { return all }
        var start = all.count - 24
        while start > 0, all[start].role != .user { start -= 1 }
        return Array(all[start...])
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let through = model.compactedThroughSequence {
                        Label("Earlier context summarized through message \(through + 1); original messages remain below.", systemImage: "text.alignleft")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("AIM uses a separate request billed by your own provider key when a conversation grows long. The summary is used only for later model context; it does not change or delete the transcript.")
                    }
                    let shown = shownMessages
                    if shown.count < model.messages.count {
                        // Long conversations open on their latest turns, as in Codex.
                        VStack(alignment: .leading, spacing: 10) {
                            Button { showEarlier = true } label: {
                                HStack(spacing: 6) {
                                    Text("\(model.messages.count - shown.count) previous messages")
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 13)).foregroundStyle(.secondary).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("previous-messages")
                            Divider().opacity(0.6)
                        }
                    }
                    ForEach(shown) { message in
                        MessageRow(message: message, searchQuery: searchVisible ? searchQuery : "", runActions: runActions(for: message))
                            .padding(6)
                            .background(model.searchTargetMessageID == message.id
                                ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .id(message.id)
                        if message.role == .user {
                            let answer = firstAnswer(after: message)
                            ForEach(history(after: message).filter { !$0.calls.isEmpty }) { run in
                                // Answers with a timeline show their actions in place; older ones keep this summary.
                                WorkspaceRunTranscriptView(history: run, turnID: answer?.id, questionsOnly: answer?.timeline != nil)
                            }
                            let liveTimeline = model.messages.last.map { $0.role == .assistant && $0.timeline?.entries.isEmpty == false } ?? false
                            if model.isSending, model.selectedConversationID == model.toolRunConversationID,
                               model.messages.last(where: { $0.role == .user })?.id == message.id,
                               model.toolRunProvider != nil {
                                if !liveTimeline { WorkspaceProgressView() }
                            } else if model.isSending, model.messages.last?.id == message.id {
                                // Nothing has arrived yet: say what is happening instead of a silent wait.
                                WaitingIndicator(text: waitingText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                            }
                        }
                    }
                    // The run's state belongs at the end of the conversation, never above it.
                    if let execution = model.selectedContinuityExecution, !model.isSending { ContinuityWaitingLine(execution: execution) }
                    if model.mode == .agent, let mission = model.agentMission,
                       mission.conversationID == model.selectedConversationID,
                       !model.isSending,
                       // A durable task's own decision card already speaks for a blocked mission.
                       !mission.criteria.isEmpty || mission.isVerified || (mission.state == .blocked && model.selectedContinuityExecution == nil) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: mission.state == .blocked ? "exclamationmark.circle" :
                                    mission.isVerified ? "checkmark.seal" : "circle.dotted")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mission.isVerified ? "Mission verified" :
                                     mission.state == .blocked ? "Some actions need a check" :
                                     mission.state == .suspendedFinancial ? "Mission paused by spending limit" :
                                     mission.state == .cancelled ? "Mission stopped" : "Mission not yet verified")
                                    .font(.subheadline.weight(.semibold))
                                if let reason = mission.stateReason { Text(reason).font(.caption) }
                                if !mission.criteria.isEmpty {
                                    Text("\(mission.criteria.filter { $0.verifiedAt != nil }.count)/\(mission.criteria.count) criteria with file receipts")
                                        .font(.caption.weight(.medium))
                                    ForEach(mission.criteria) { criterion in
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: criterion.verifiedAt == nil ? "circle" : "checkmark.circle.fill")
                                            Text(criterion.description)
                                            if criterion.evidenceReference != nil {
                                                Button("Receipt") {
                                                    Task {
                                                        selectedMissionEvidence = await model.missionFileEvidence(
                                                            criterionID: criterion.id)
                                                    }
                                                }
                                                .buttonStyle(.link)
                                            }
                                        }
                                        .font(.caption)
                                        .accessibilityIdentifier("mission-criterion-\(criterion.id.uuidString)")
                                    }
                                }
                                if mission.state == .blocked, mission.activeRunID != nil {
                                    Button("Review action history") { model.showWorkspaceHistory = true }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                }
                                if mission.state == .partial,
                                   mission.stateReason?.hasPrefix("The user reviewed the interrupted run.") == true {
                                    Button("Continue mission") { Task { await model.continueReviewedMission() } }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("agent-mission-status")
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
                .padding(.horizontal, 26).padding(.vertical, 24)
                .frame(maxWidth: 800).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .opacity(revealed ? 1 : 0)
            .task(id: model.selectedConversationID) {
                guard model.isLoadingConversation else { revealed = true; return }
                revealed = false
                while model.isLoadingConversation, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(16)) }
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
                // Two frames for the rows to settle, then a short fade.
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
                withAnimation(.easeOut(duration: 0.22)) { revealed = true }
            }
            .overlay(alignment: .leading) {
                // One mark per question. Hovering shows the start of the question and of its answer
                // beside the mark; the card stays while the pointer moves onto it; a click jumps there.
                GeometryReader { geometry in
                    let turns = model.messages.filter { $0.role == .user }
                    let mark = max(4, min(15, (geometry.size.height - 30) / CGFloat(max(1, turns.count)) - 2))
                    let top = (geometry.size.height - CGFloat(turns.count) * (mark + 2)) / 2
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 2) {
                            ForEach(turns) { turn in
                                Capsule().fill(previewTurn == turn.id ? Color.primary : Color.secondary.opacity(0.3))
                                    .frame(width: previewTurn == turn.id ? 18 : 8, height: 3)
                                    .frame(width: 22, height: mark)
                                    .contentShape(Rectangle())
                                    .onHover { hovering in hoverMark(turn.id, hovering) }
                                    .onTapGesture { jump(to: turn, proxy: proxy) }
                                    .accessibilityElement()
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel("Jump to: \(turn.content.prefix(100))")
                                    .accessibilityAction { jump(to: turn, proxy: proxy) }
                            }
                        }
                        .frame(width: 22, height: geometry.size.height, alignment: .center)
                        if let id = previewTurn, let index = turns.firstIndex(where: { $0.id == id }) {
                            let turn = turns[index]
                            Button { jump(to: turn, proxy: proxy) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(turn.content).lineLimit(2).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                                    if let answer = firstAnswer(after: turn), !answer.content.isEmpty {
                                        Text(answer.content).lineLimit(2).font(.system(size: 12.5)).foregroundStyle(.secondary)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .frame(width: 300, alignment: .leading)
                                .background(AIMTheme.menuSurface(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
                                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.08), radius: 10, y: 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in cardHovered = hovering; if !hovering { closePreviewSoon() } }
                            .offset(x: 26, y: min(max(8, top + CGFloat(index) * (mark + 2) - 18), max(8, geometry.size.height - 90)))
                            .transition(.opacity)
                            .accessibilityIdentifier("minimap-preview")
                        }
                    }
                }.frame(width: 22)
            }
            .onChange(of: model.messages.count) { _, _ in
                if !searchVisible && model.searchTargetMessageID == nil {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            // A card above the chat bar takes room: keep the latest words in view.
            .onChange(of: decisionCardKey) { _, key in
                guard key != nil, !searchVisible else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                }
            }
            .onChange(of: selectedSearchID) { _, id in
                if let match = searchResults.first(where: { $0.id == id }) { proxy.scrollTo(match.messageID, anchor: .top) }
            }
            .onChange(of: model.searchTargetMessageID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
            .task(id: model.searchTargetMessageID) {
                if let id = model.searchTargetMessageID {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    private func hoverMark(_ id: UUID, _ hovering: Bool) {
        if hovering { previewClose?.cancel(); previewTurn = id } else { closePreviewSoon() }
    }

    /// A short grace period lets the pointer travel from the mark to its card.
    private func closePreviewSoon() {
        previewClose?.cancel()
        previewClose = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, !cardHovered else { return }
            previewTurn = nil
        }
    }

    private func jump(to turn: ConversationMessage, proxy: ScrollViewProxy) {
        if !shownMessages.contains(where: { $0.id == turn.id }) { showEarlier = true }
        previewTurn = nil; cardHovered = false
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(turn.id, anchor: .top) }
        }
    }

    private func firstAnswer(after user: ConversationMessage) -> ConversationMessage? {
        guard let next = model.messages.first(where: { $0.sequence > user.sequence && $0.role == .assistant }),
              !model.messages.contains(where: { $0.role == .user && $0.sequence > user.sequence && $0.sequence < next.sequence }) else { return nil }
        return next
    }

    /// The calls of the workspace runs a turn's first answer replies to, as actions.
    private func runActions(for message: ConversationMessage) -> [ConversationAction] {
        guard message.role == .assistant,
              let user = model.messages.last(where: { $0.role == .user && $0.sequence < message.sequence }),
              firstAnswer(after: user)?.id == message.id else { return [] }
        return history(after: user).flatMap { run in
            run.calls.map { call in
                ConversationAction(id: run.id + ":" + call.id, conversationID: message.conversationID, turnID: message.id, ordinal: 0, name: call.name,
                    state: call.state == .succeeded ? .completed : call.state == .failed ? .failed : call.state == .requested && run.run.state == .running ? .running : .needsReview,
                    startedAt: call.startedAt, finishedAt: call.endedAt, detailReference: run.id + ":" + call.id,
                    input: String(decoding: call.argumentsJSON, as: UTF8.self), output: call.result)
            }
        }
    }

    private func history(after message: ConversationMessage) -> [WorkspaceRunHistory] {
        let nextUser = model.messages.first { $0.role == .user && $0.sequence > message.sequence }?.createdAt
        return model.workspaceHistory.filter { run in
            run.run.conversationID == message.conversationID.uuidString &&
                run.run.startedAt >= message.createdAt && (nextUser.map { run.run.startedAt < $0 } ?? true) &&
                !(model.isSending && run.run.conversationID == model.toolRunConversationID?.uuidString && run.run.state == .running)
        }
        .sorted { $0.run.startedAt < $1.run.startedAt }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if searchVisible {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in this conversation", text: $searchQuery)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { stepSearch(1) }
                        .onExitCommand { closeSearch() }
                    Text(searchPosition).font(.caption).foregroundStyle(.secondary)
                    Button { stepSearch(-1) } label: { Image(systemName: "chevron.up") }
                        .help("Previous matching message").disabled(searchResults.isEmpty)
                    Button { stepSearch(1) } label: { Image(systemName: "chevron.down") }
                        .help("Next matching message").disabled(searchResults.isEmpty)
                    Button(action: closeSearch) { Image(systemName: "xmark") }.help("Close search")
                } else {
                    EmptyView()
                }
            }.buttonStyle(.plain)
            if searchVisible {
                Text(searchQuery.count > 256 ? "Use a query of up to 256 characters." : searchTruncated ? "Partial results: search limits reached. Attachments are not searched." : "Message text only · attachments are not searched")
                    .font(.caption2).foregroundStyle(.secondary)
                if let selected = searchResults.first(where: { $0.id == selectedSearchID }) {
                    Text(selected.excerpt).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 32).padding(.vertical, 6)
    }

    private var searchPosition: String {
        guard let index = searchResults.firstIndex(where: { $0.id == selectedSearchID }) else { return "0 matches" }
        return "\(index + 1) / \(searchResults.count) matches"
    }

    private var waitingText: String {
        if model.selectedProvider == .local, case .loading(let name) = model.localEngineState {
            return "Loading \(name) into memory…"
        }
        return Locale.current.language.languageCode?.identifier == "fr" ? "Réflexion…" : "Thinking…"
    }

    private func closeSearch() {
        searchTask?.cancel(); searchVisible = false; selectedSearchID = nil
        searchResults = []; searchFocused = false
    }

    private func stepSearch(_ direction: Int) {
        guard !searchResults.isEmpty else { return }
        let index = searchResults.firstIndex(where: { $0.id == selectedSearchID }) ?? 0
        selectedSearchID = searchResults[(index + direction + searchResults.count) % searchResults.count].id
    }

    private func refreshSearch() {
        searchTask?.cancel()
        guard searchVisible else { return }
        let query = searchQuery
        let messages = model.messages
        let conversation = model.selectedConversationID
        searchResults = []; selectedSearchID = nil; searchTruncated = false
        searchTask = Task {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let worker = Task.detached { TranscriptSearch.find(query, in: messages) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, model.selectedConversationID == conversation else { return }
            searchResults = result.matches; searchTruncated = result.isTruncated
            selectedSearchID = result.matches.first?.id
        }
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let message: ConversationMessage
    var searchQuery = ""
    /// Actions of the workspace runs answered by this message (Code/Agent).
    var runActions: [ConversationAction] = []
    @State private var attachmentPreview: TextAttachment?
    @State private var imagePreview: ImageAttachment?
    @State private var confirmingBranch = false
    @State private var confirmingRegeneration = false
    @State private var editBranch = false
    @State private var hovered = false
    @State private var copied = false

    /// The latest answer keeps its actions visible; older messages show them on hover.
    private var isLatest: Bool { model.messages.last?.id == message.id }

    /// The answer being written right now.
    private var isLive: Bool {
        message.role == .assistant && model.isSending && isLatest && message.completionStatus == nil
            && model.activeTurnConversationID == message.conversationID
    }

    /// Stored actions, the workspace runs of this turn and, while it runs, the host's live
    /// progress; one entry per call even when the same call appears under several IDs.
    /// What Copy puts on the pasteboard: the final answer, without the agent's working notes.
    private var copiedText: String {
        guard message.role == .assistant, message.timeline != nil else { return message.content }
        let layout = TurnLayout.make(content: message.content, timeline: message.timeline, tools: turnTools, key: \.id)
        let text = layout.answer.compactMap { item -> String? in if case let .text(_, text) = item { return text }; return nil }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? message.content : text
    }
    private var turnTools: [ConversationAction] {
        var result = message.actions ?? []
        func known(_ id: String) -> Bool { result.contains { $0.id == id || $0.id.hasSuffix(":" + id) } }
        for action in runActions where !known(action.id) { result.append(action) }
        if isLive {
            for (index, item) in model.toolProgress.items.enumerated() where !known(item.id) {
                result.append(.init(id: item.id, conversationID: message.conversationID, turnID: message.id, ordinal: result.count + index, name: item.name,
                    state: item.state == .running ? .running : item.state == .failed ? .failed : item.state == .interrupted ? .needsReview : .completed,
                    startedAt: item.startedAt, finishedAt: item.finishedAt, input: item.detail))
            }
        }
        return result
    }

    @ViewBuilder private func inputAttachmentLabel(_ attachment: TextAttachment) -> some View {
        if let frame = attachment.video?.frames.first, let image = NSImage(data: frame.jpeg) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 112, height: 112).clipped()
                .overlay { Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 3) }
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            Label(attachment.name, systemImage: "doc.text").lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(AIMTheme.menuSurface(scheme), in: Capsule())
                .overlay(Capsule().strokeBorder(AIMTheme.cardBorder(scheme)))
        }
    }
    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            ForEach(message.attachments ?? []) { attachment in
                Button { attachmentPreview = attachment } label: {
                    inputAttachmentLabel(attachment)
                }
                .buttonStyle(.aimHover(radius: 16)).font(.system(size: 12))
            }
            ForEach(message.images ?? []) { image in
                Button { imagePreview = image } label: {
                    if let bitmap = NSImage(data: image.data) {
                        Image(nsImage: bitmap).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Label(image.name, systemImage: "photo")
                    }
                }
                .buttonStyle(.plain).help(image.name)
            }
            ForEach(message.videos ?? []) { video in GeneratedVideoView(url: model.videoURL(video), title: video.title) }
            if message.role == .assistant {
                let tools = turnTools
                if !message.content.isEmpty || !tools.isEmpty || message.timeline?.entries.isEmpty == false {
                    MacTurnTimelineView(message: message, tools: tools, live: isLive, searchQuery: searchQuery)
                        .foregroundStyle(AIMTheme.foreground(scheme))
                }
                if isLive { WorkspaceProgressView(statusOnly: true) }
            } else if !message.content.isEmpty {
                HStack(alignment: .top) {
                    Spacer(minLength: 55)
                    Text(SearchHighlight.apply(to: AttributedString(message.content), query: searchQuery))
                        .font(AIMTypography.conversation(model.settings.conversationAppearance ?? .init()))
                        .lineSpacing(4).textSelection(.enabled)
                        .padding(16)
                        .background(AIMTheme.muted(scheme), in: RoundedRectangle(cornerRadius: 22))
                        .foregroundStyle(AIMTheme.foreground(scheme))
                }
            }
            if message.role == .assistant, let completion = message.completionStatus {
                Label(completion == .failed
                      ? "Response failed · any text above is incomplete and will not be used as model context"
                      : "Response stopped · any text above is incomplete and will not be used as model context",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(completion == .failed ? "Incomplete response: failed" : "Incomplete response: stopped")
            }
            if message.role == .assistant, model.workspacePath != nil, let changed = ChangedFilesSummary.count(turnTools) {
                // A finished task never asks for acceptance; the changes stay one click away.
                Button { model.requestedWorkbench = .init(kind: .review) } label: {
                    Label(changed == 1 ? "1 file changed · View changes" : "\(changed) files changed · View changes",
                          systemImage: "arrow.triangle.branch")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).accessibilityIdentifier("message-changed-files")
            }
            if message.role == .assistant, isLatest, let notice = model.memoryNotices[message.conversationID],
               model.messages.last(where: { $0.role == .user })?.id == notice.after {
                // What this exchange added to memory; Settings › Personalization lists and edits it.
                Label(notice.saved ? "Memorized: \(notice.text)" : "Memory: \(notice.text)", systemImage: "brain")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .help("Saved to memory. Review or delete it in Settings › Personalization.")
                    .accessibilityIdentifier("message-memory-notice")
            }
            HStack(spacing: 0) {
                if message.role == .assistant, !ConversationSourceProjection(text: message.content, sources: message.sources ?? model.messageMetrics[message.id]?.sources).sources.isEmpty {
                    let cited = ConversationSourceProjection(text: message.content, sources: message.sources ?? model.messageMetrics[message.id]?.sources).sources
                    Button { model.requestedWorkbench = .init(kind: .sources, messageID: message.id) } label: {
                        HStack(spacing: 6) {
                            HStack(spacing: -5) {
                                ForEach(Array(cited.prefix(3).enumerated()), id: \.element.id) { index, source in
                                    MacSourceIcon(domain: source.domain, size: 17, sourceURL: source.url).zIndex(Double(3 - index))
                                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(AIMTheme.background(scheme), lineWidth: 1.5))
                                }
                            }
                            Text("Sources").font(.caption)
                        }
                        .padding(.horizontal, 6).frame(height: 26)
                    }
                    .buttonStyle(.aimHover(radius: 7)).accessibilityIdentifier("message-sources")
                }
                if !message.content.isEmpty {
                    action(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copiedText, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                }
                if message.role == .assistant && !message.content.isEmpty {
                    action("speaker.wave.2", "Read aloud") { Task { await model.readAloud(message.content) } }
                }
                if message.role == .assistant && model.mode == .chat {
                    action("arrow.clockwise", "Regenerate in a new branch") { confirmingRegeneration = true }
                        .disabled(!model.canRegenerateChatResponse(after: message))
                }
                if message.role == .user {
                    action("pencil", "Edit in a new branch") { editBranch = true; confirmingBranch = true }
                        .disabled(!model.canBranchConversation)
                }
                action("arrow.triangle.branch", "Continue in a new branch") { editBranch = false; confirmingBranch = true }
                    .disabled(!model.canBranchConversation)
                if message.role == .assistant, let metrics = model.messageMetrics[message.id] {
                    AnswerMetricsBadge(metrics: metrics, forced: model.debugShowsMetrics && isLatest).padding(.leading, 4)
                }
            }
            .foregroundStyle(.secondary)
            .opacity(hovered || isLatest || copied ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .sheet(item: $attachmentPreview) { attachment in
            if let video = attachment.video { MacPreparedVideoPreview(attachment: attachment, video: video) }
            else { TextAttachmentPreview(attachment: attachment) }
        }
        .sheet(item: $imagePreview) { ImageAttachmentPreview(attachment: $0) }
        .confirmationDialog(editBranch ? "Edit in a new branch?" : "Branch from this message?", isPresented: $confirmingBranch) {
            Button(editBranch ? "Create branch and edit" : "Create branch") {
                Task { await model.branchConversation(at: message, edit: editBranch) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original conversation stays unchanged. Later messages are not copied. Files and commands are neither replayed nor undone; the workspace and project settings remain at their current state. Nothing is sent until you press Send.")
        }
        .confirmationDialog("Regenerate this response?", isPresented: $confirmingRegeneration) {
            Button("Regenerate in new branch") { Task { await model.regenerateChatResponse(after: message) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new provider request will be made using the selected model and your API key. The original conversation stays unchanged; later messages are not copied.")
        }
    }

    private func action(_ icon: String, _ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon).font(.system(size: 12.5)).frame(width: 28, height: 26)
        }
        .buttonStyle(.aimHover(radius: 7))
        .aimTooltip(title)
        .accessibilityLabel(title)
    }
}

/// Compact response information next to the answer actions; provider charges remain estimates unless reported.
struct AnswerMetricsBadge: View {
    let metrics: TurnMetrics
    var forced = false
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12.5)).frame(width: 28, height: 26)
        }
        .buttonStyle(.aimHover(radius: 7))
        .aimTooltip("Response information")
        .accessibilityLabel("Response information")
        .accessibilityIdentifier("chat-response-information")
        .popover(isPresented: $showing) { AnswerMetricsDetail(metrics: metrics, usesSystemColors: true).padding(18).foregroundStyle(.primary) }
        .aimRichTooltip(forced: forced) { AnswerMetricsDetail(metrics: metrics) }
    }

    private var summary: String {
        if let speed = metrics.outputTokensPerSecond { return Self.number(speed, digits: 1) + " tok/s" }
        return Self.tokens(metrics.totalTokens) + " tokens"
    }

    static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func seconds(_ value: Double) -> String {
        value < 10 ? number(value, digits: 2) + " s" : value < 120 ? number(value, digits: 1) + " s"
            : "\(Int(value) / 60) min \(Int(value) % 60) s"
    }

    static func tokens(_ value: Int) -> String {
        value >= 1_000_000_000 ? number(Double(value) / 1_000_000_000, digits: 1) + "bn"
            : value >= 1_000_000 ? number(Double(value) / 1_000_000, digits: 1) + "M"
            : value >= 100_000 ? number(Double(value) / 1_000, digits: 0) + "k"
            : value >= 10_000 ? number(Double(value) / 1_000, digits: 1) + "k" : value.formatted()
    }
}

/// The tooltip's lines: prompt processing, generation and times (what the provider reports).
struct AnswerMetricsDetail: View {
    let metrics: TurnMetrics
    var usesSystemColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                if let first = metrics.firstTokenSeconds { row("First words", AnswerMetricsBadge.seconds(first)) }
                if metrics.isLocal, metrics.usage.promptSeconds != nil {
                    row("Prompt processing", [tokens(metrics.usage.processedPromptTokens ?? metrics.usage.inputTokens),
                                              metrics.promptTokensPerSecond.map { AnswerMetricsBadge.number($0, digits: 1) + " tok/s" },
                                              metrics.usage.promptSeconds.map(AnswerMetricsBadge.seconds)])
                } else if let input = metrics.usage.inputTokens {
                    row("Input", [tokens(input), metrics.usage.cachedInputTokens.flatMap { $0 > 0 ? AnswerMetricsBadge.tokens($0) + " cached" : nil }])
                }
                row("Generation", [tokens(metrics.outputTokens, estimated: metrics.outputIsEstimated),
                                   metrics.outputTokensPerSecond.map { AnswerMetricsBadge.number($0, digits: 1) + " tok/s" },
                                   (metrics.usage.generationSeconds ?? metrics.streamSeconds).map(AnswerMetricsBadge.seconds)])
                if let reasoning = metrics.usage.reasoningTokens, reasoning > 0 { row("Reasoning", AnswerMetricsBadge.tokens(reasoning) + " tokens") }
                if metrics.isLocal, let cached = metrics.usage.cachedInputTokens, cached > 0 { row("Reused from cache", AnswerMetricsBadge.tokens(cached) + " tokens") }
                row("Total time", AnswerMetricsBadge.seconds(metrics.totalSeconds))
                if let searches = metrics.webSearchUsage?.requests { row("Web searches", String(searches)) }
                if let activities = metrics.webSearchActivities, !activities.isEmpty {
                    let completed = activities.filter { $0.status == .completed }.count
                    let failed = activities.filter { $0.status == .failed }.count
                    row("Observed search calls", [completed > 0 ? "\(completed) completed" : nil, failed > 0 ? "\(failed) failed" : nil,
                        activities.contains(where: { $0.status == .running }) ? "unfinished call" : nil])
                }
                if let cost = metrics.costUSD, cost > 0 { row("Cost", cost < 0.01 ? "$" + AnswerMetricsBadge.number(cost, digits: 4) : "$" + AnswerMetricsBadge.number(cost, digits: 2)) }
            }
            if metrics.webSearchUsage?.providerTotalCostUSD == nil, metrics.webSearchUsage != nil {
                Text("Estimated cost; unreported web-search fees are excluded.")
                    .font(.system(size: 10.5)).foregroundStyle(usesSystemColors ? Color.secondary : .white.opacity(0.5))
            }
            if metrics.outputIsEstimated {
                Text("≈ estimated from the text: this provider did not report token counts.")
                    .font(.system(size: 10.5)).foregroundStyle(usesSystemColors ? Color.secondary : .white.opacity(0.5))
            }
        }
    }

    private var title: String {
        if metrics.isLocal {
            switch metrics.usage.engine {
            case "mlx": return "On this Mac · MLX"
            case "llama.cpp": return "On this Mac · llama.cpp"
            default: return "On this Mac"
            }
        }
        return "Via " + (ChatProvider(rawValue: metrics.provider)?.name ?? metrics.provider)
    }

    private func tokens(_ value: Int?, estimated: Bool = false) -> String? {
        value.map { (estimated ? "≈ " : "") + AnswerMetricsBadge.tokens($0) + " tokens" }
    }

    @ViewBuilder private func row(_ label: String, _ parts: [String?]) -> some View {
        row(label, parts.compactMap { $0 }.joined(separator: " · "))
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(usesSystemColors ? Color.secondary : .white.opacity(0.6))
            Text(value).monospacedDigit()
        }
    }
}

/// "Thinking" with three breathing dots, shown until the first words arrive.
struct WaitingIndicator: View {
    let text: String
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle().frame(width: 6, height: 6)
                        .opacity(phase == index ? 1 : 0.3)
                        .scaleEffect(phase == index ? 1.1 : 0.85)
                }
            }
            .foregroundStyle(.secondary)
            Text(text).font(.system(size: 13.5)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.35), value: phase)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(380))
                phase = (phase + 1) % 3
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A generated video, played in place; the file stays in AIM's media folder.
private struct GeneratedVideoView: View {
    let url: URL
    let title: String
    @Environment(AppModel.self) private var model
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if FileManager.default.fileExists(atPath: url.path) {
                MacVideoPlayer(player: player)
                    .frame(width: 420, height: 236)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear { if player == nil { player = AVPlayer(url: url) } }
                    .onDisappear { player?.pause() }
                HStack(spacing: 10) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button { FileOpenDestination.open(url, with: model.preferences.fileOpenApp) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                }
                .buttonStyle(.aimHover(radius: 8)).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Label("\(title) · the video file is no longer on this Mac", systemImage: "film").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}


/// How many files a turn changed, from its completed file actions.
enum ChangedFilesSummary {
    static let mutatingTools: Set<String> = ["apply_edit", "undo_edit", "create_dir", "copy_file", "move_file", "trash_file",
                                             "restore_checkpoint", "merge_subagent_changes"]
    static func count(_ actions: [ConversationAction]) -> Int? {
        var paths: Set<String> = []
        var unnamed = 0
        for action in actions where action.state == .completed && mutatingTools.contains(action.name) {
            let object = action.input.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            let named = ["path", "destination", "source"].compactMap { object?[$0] as? String }
            if named.isEmpty { unnamed += 1 } else { paths.formUnion(named.prefix(1)) }
        }
        let total = paths.count + unnamed
        return total > 0 ? total : nil
    }
}
