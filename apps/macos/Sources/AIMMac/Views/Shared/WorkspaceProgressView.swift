import AIMCore
import AIMAgentKit
import SwiftUI

/// A transcript-native activity trail. Only actions the host actually started
/// are shown; model reasoning and invented progress are never synthesized here.
struct WorkspaceProgressView: View {
    @Environment(AppModel.self) private var model
    /// Under an answer whose timeline already lists the actions: only say what AIM waits for.
    var statusOnly = false

    var body: some View {
        if statusOnly { statusLine } else { fullBody }
    }

    @ViewBuilder private var statusLine: some View {
        if !model.pendingToolApprovals.isEmpty || !model.pendingAgentQuestions.isEmpty
            || (model.toolProgress.stage != .waitingForModel && model.toolProgress.items.allSatisfy { $0.state != .running }) {
            activity
        }
    }

    /// The live state at reading size: animated dots while the model thinks, else its icon and text.
    @ViewBuilder private var activity: some View {
        if model.pendingToolApprovals.isEmpty && model.pendingAgentQuestions.isEmpty && model.toolProgress.stage == .waitingForModel
            && model.toolProgress.items.allSatisfy({ $0.state != .running }) {
            WaitingIndicator(text: activeDescription)
        } else {
            Label(activeDescription, systemImage: activeIcon).font(.system(size: 13.5)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var fullBody: some View {
        let conversation = model.toolRunConversationID ?? model.selectedConversationID ?? UUID()
        let turn = model.messages.last(where: { $0.role == .user })?.id ?? conversation
        let actions: [ConversationAction] = model.toolProgress.items.enumerated().map { index, item in
            .init(id: item.id, conversationID: conversation, turnID: turn, ordinal: index, name: item.name,
                state: item.state == .running ? .running : item.state == .failed ? .failed : item.state == .interrupted ? .needsReview : .completed,
                startedAt: item.startedAt, finishedAt: item.finishedAt, input: item.detail)
        }
        VStack(alignment: .leading, spacing: 10) {
            if !actions.isEmpty { MacConversationActions(actions: actions) }
            if model.toolProgress.items.allSatisfy({ $0.state != .running }), model.isSending, model.messages.last(where: { $0.role == .assistant })?.content.isEmpty != false {
                activity
            }
            if model.toolProgress.omittedCount > 0 {
                Button("Open full action history") { model.showWorkspaceHistory = true }.buttonStyle(.plain).foregroundStyle(.primary)
            }
        }.frame(maxWidth: 760, alignment: .leading)
    }

    private func activityLine(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 16)
            Text(title).lineLimit(2)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var activeIcon: String {
        if !model.pendingToolApprovals.isEmpty { return "hand.raised" }
        if !model.pendingAgentQuestions.isEmpty { return "questionmark.bubble" }
        if let item = model.toolProgress.items.last(where: { $0.state == .running }) { return Self.icon(for: item.name) }
        switch model.toolProgress.stage {
        case .preparingContext: return "text.book.closed"
        case .optimizingContext: return "text.badge.checkmark"
        case .waitingForNetwork: return "wifi.slash"
        case .waitingForModel: return "sparkles"
        }
    }

    private var activeDescription: String {
        if !model.pendingToolApprovals.isEmpty { return "Waiting for your approval" }
        if !model.pendingAgentQuestions.isEmpty { return "Waiting for your answer" }
        if let item = model.toolProgress.items.last(where: { $0.state == .running }) {
            return "\(Self.runningTitle(for: item.name))\(item.detail.map { " · \($0)" } ?? "")"
        }
        switch model.toolProgress.stage {
        case .preparingContext: return "Preparing conversation context"
        case .optimizingContext: return "Optimizing the conversation · this can take a few minutes"
        case .waitingForNetwork: return "Waiting for network · cancel to stop waiting"
        case .waitingForModel: return Locale.current.language.languageCode?.identifier == "fr" ? "Réflexion…" : "Thinking…"
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }

    static func title(for tool: String) -> String { ToolDisplayName.title(tool) }

    static func runningTitle(for tool: String) -> String { ToolDisplayName.title(tool, running: true) }

    static func icon(for tool: String) -> String {
        if tool == "context_compaction" { return "rectangle.compress.vertical" }
        if tool.hasPrefix("browser_") || tool == "web_fetch" { return "globe" }
        if tool.hasPrefix("desktop_") { return "desktopcomputer" }
        if tool.hasPrefix("git_") { return "arrow.triangle.branch" }
        if tool.contains("search") || tool.contains("find") { return "magnifyingglass" }
        if tool.contains("file") || tool.contains("dir") { return "folder" }
        if tool == "run_command" { return "terminal" }
        if tool == "ask_user" { return "questionmark.bubble" }
        if tool == "delegate_task" || tool == "await_subagents" { return "person.2" }
        return "sparkles"
    }
}
