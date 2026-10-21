import AIMApplication
import AIMCore
import SwiftUI

/// A small colored mark that identifies one sub-agent in the conversation and in its panel.
struct SubagentAvatar: View {
    let id: UUID
    var size: CGFloat = 18
    private static let palette: [Color] = [.purple, .green, .orange, .pink, .teal, .indigo, .mint, .brown]
    var body: some View {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let color = Self.palette[bytes.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % Self.palette.count]
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.62, weight: .semibold)).foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The Sub-agents tab: active and finished children of this conversation; selecting one shows
/// what its parent asked and everything it did, with its model, effort, cost and a Stop button.
struct WorkbenchSubagentsPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var tab: WorkbenchTab
    @State private var snapshots: [SubagentSnapshot] = []
    @State private var loaded = false
    @State private var stopping: Set<UUID> = []

    private var selected: SubagentSnapshot? { tab.focusID.flatMap(UUID.init(uuidString:)).flatMap { id in snapshots.first { $0.id == id } } }

    var body: some View {
        Group {
            if let selected { detail(selected) } else { list }
        }
        .task(id: tab.conversationID ?? model.selectedConversationID) {
            guard let conversation = tab.conversationID ?? model.selectedConversationID else { loaded = true; return }
            while !Task.isCancelled {
                snapshots = await model.subagents(conversationID: conversation); loaded = true
                try? await Task.sleep(for: .milliseconds(snapshots.contains(where: \.isActive) ? 500 : 4_000))
            }
        }
        .accessibilityIdentifier("workbench-subagents")
    }

    private var list: some View {
        let attention = snapshots.filter { $0.state == .blocked || $0.state == .paused }
        let active = snapshots.filter { $0.isActive && !attention.contains($0) }, done = snapshots.filter { !$0.isActive }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if loaded && snapshots.isEmpty {
                    Text("No sub-agents in this conversation yet. When the agent delegates work, each sub-agent appears here.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(10)
                }
                if !attention.isEmpty { section("Needs attention", attention) }
                if !active.isEmpty { section("Active", active) }
                if !done.isEmpty { section("Done", done) }
            }
            .padding(14)
        }
    }

    private func section(_ title: String, _ items: [SubagentSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) · \(items.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            ForEach(items) { item in
                Button { tab.focusID = item.id.uuidString } label: {
                    HStack(alignment: .top, spacing: 10) {
                        SubagentAvatar(id: item.id, size: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                Text(elapsed(item)).font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            Text(summary(item)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(10).contentShape(Rectangle())
                }
                .buttonStyle(.aimHover(radius: 10))
                .accessibilityIdentifier("subagent-row-\(item.id.uuidString)")
            }
        }
    }

    private func detail(_ item: SubagentSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { tab.focusID = nil } label: { Image(systemName: "chevron.left").frame(width: 26, height: 26) }
                    .buttonStyle(.aimHover(radius: 7)).help("All sub-agents").accessibilityLabel("All sub-agents")
                SubagentAvatar(id: item.id)
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(modelLine(item)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if item.isActive {
                    Button {
                        stopping.insert(item.id)
                        Task { await model.cancelSubagent(executionID: item.executionID, childID: item.id); stopping.remove(item.id) }
                    } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon).font(.system(size: 12)) }
                        .buttonStyle(.bordered).controlSize(.small).disabled(stopping.contains(item.id))
                        .help("Stop this sub-agent; its parent keeps running and sees it as cancelled.")
                        .accessibilityIdentifier("subagent-stop")
                }
            }
            .padding(.horizontal, 12).frame(height: 44)
            Divider()
            ScrollView {
                let transcript = SubagentTranscript(childID: item.id, prompt: item.prompt, startedAt: item.createdAt, entries: item.entries, running: item.isActive)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(transcript.items) { entry in
                        switch entry {
                        case let .parentMessage(_, text, _):
                            HStack {
                                Spacer(minLength: 40)
                                Text(text).font(.system(size: 13)).textSelection(.enabled).padding(12)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        case let .turn(_, layout):
                            MacTurnItemsView(items: layout.all, tools: transcript.actions, live: item.isActive)
                        }
                    }
                    if !item.isActive {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(stateTitle(item.state), systemImage: item.state == .failed ? "xmark.circle" : item.state == .cancelled ? "stop.circle" : "checkmark.circle")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(item.state == .failed ? .red : .secondary)
                            if let result = item.result, !result.isEmpty {
                                Text(String(result.prefix(8_000))).font(.system(size: 13)).textSelection(.enabled)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    // Between two steps the child is waiting for its model: say so, as in the main chat.
                    if item.isActive && item.state != .blocked && item.state != .paused && item.entries.last?.kind != .toolStarted {
                        WaitingIndicator(text: item.entries.isEmpty ? "Starting…" : TurnLayoutText.header(onlyReasoning: true, duration: nil, running: true))
                    }
                }
                .padding(16)
            }
            // Follows the child as it works, like the main conversation.
            .defaultScrollAnchor(.bottom)
        }
    }

    private func modelLine(_ item: SubagentSnapshot) -> String {
        var parts: [String] = [item.modelID.map(Self.modelName) ?? "Parent's model"]
        if let effort = item.effort { parts.append(effort.capitalized) }
        if let cost = item.costUSD { parts.append(String(format: "$%.3f", cost)) }
        else if let tokens = item.tokens { parts.append("\(tokens) tokens") }
        return parts.joined(separator: " · ")
    }

    /// "anthropic/claude-sonnet-5.5" reads as "Claude Sonnet 5.5".
    static func modelName(_ id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        return base.split(separator: "-").map { word in word.prefix(1).uppercased() + word.dropFirst() }.joined(separator: " ")
    }

    private func summary(_ item: SubagentSnapshot) -> String {
        if item.state == .blocked || item.state == .paused {
            let reason = (item.result ?? "").replacingOccurrences(of: "Paused before sending by the spending limit. ", with: "")
            if item.result?.contains("spending limit") == true { return (item.state == .paused ? "Paused" : "Blocked") + " · spending limit" }
            return (item.state == .paused ? "Paused" : "Blocked") + (reason.isEmpty ? "" : " · " + reason)
        }
        if let entry = item.entries.last {
            switch entry.kind {
            case .toolStarted:
                let action = ConversationAction(id: entry.callID ?? "", conversationID: item.id, turnID: item.id, ordinal: 0, name: entry.name ?? "tool", state: .running, input: entry.text)
                return MacToolRow.title(for: action) + (MacToolRow.subject(for: action).map { " · " + $0 } ?? "")
            case .toolFinished: return "Checked a result"
            case .noteToParent: return "Sent a note to the parent"
            case .parentMessage: return "Received a message from the parent"
            case .reasoning: return "Thinking"
            case .text: return entry.text ?? ""
            }
        }
        return item.isActive ? "Waiting to start" : stateTitle(item.state)
    }

    private func stateTitle(_ state: ExecutionState) -> String {
        switch state {
        case .cancelled: "Stopped"
        case .failed: "Failed"
        case .accepted, .verified, .awaitingReview: "Finished"
        case .blocked: "Needs your review"
        case .paused: "Paused"
        default: state.rawValue.capitalized
        }
    }

    private func elapsed(_ item: SubagentSnapshot) -> String {
        let end = item.isActive ? Date.now : item.lastActivity
        return TurnLayoutText.duration(end.timeIntervalSince(item.createdAt))
    }
}

/// A turn's parts shown in order, unfolded: the view a sub-agent's work is read in.
struct MacTurnItemsView: View {
    @Environment(AppModel.self) private var model
    let items: [TurnLayoutItem<ConversationAction>]
    let tools: [ConversationAction]
    let live: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.id) { item in
                switch item {
                case let .reasoning(_, text, duration, running): MacReasoningRow(text: text, duration: duration, running: running)
                case let .text(_, text):
                    MacSourceMarkdown(text: text, sources: nil, appearance: model.settings.conversationAppearance ?? .init())
                case let .tools(_, group): MacToolGroupView(tools: group, live: live, turnTools: tools)
                case .subagents: EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Name and Name started working" in the parent's answer; opens the Sub-agents tab.
struct MacSubagentsStartedRow: View {
    @Environment(AppModel.self) private var model
    let calls: [ConversationAction]
    private var titles: [String] {
        calls.compactMap { call in
            call.input.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["title"] as? String
        }
    }
    var body: some View {
        Button { model.requestedWorkbench = .init(kind: .subagents) } label: {
            HStack(spacing: 7) {
                HStack(spacing: -4) {
                    ForEach(Array(calls.prefix(3).enumerated()), id: \.element.id) { index, call in
                        SubagentAvatar(id: AccountIdentity.stable(call.id)).zIndex(Double(3 - index))
                    }
                }
                Text(sentence).lineLimit(2).multilineTextAlignment(.leading)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12.5)).foregroundStyle(.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("subagents-started")
    }
    private var sentence: String {
        let names = titles.isEmpty ? ["\(calls.count) sub-agent\(calls.count > 1 ? "s" : "")"] : titles
        let joined = names.count > 2 ? names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more" : names.joined(separator: " and ")
        let running = calls.contains { $0.state == .running || $0.state == .waiting }
        return joined + (running ? " started working" : (names.count == 1 && titles.count == 1 ? " was delegated" : " were delegated"))
    }
}

private enum AccountIdentity {
    /// A stable UUID for a call identifier, so a sub-agent keeps one color across views.
    static func stable(_ value: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in value.utf8.enumerated() { bytes[index % 16] = bytes[index % 16] &+ byte &* UInt8(truncatingIfNeeded: index + 1) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
