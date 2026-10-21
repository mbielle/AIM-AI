import AIMApplication
import AIMCore
import SwiftUI

/// An assistant turn as it happened: reasoning, actions and text in order while it runs,
/// then everything before the final answer folded into one "Worked for …" line.
struct MacTurnTimelineView: View {
    @Environment(AppModel.self) private var model
    let message: ConversationMessage
    let tools: [ConversationAction]
    let live: Bool
    var searchQuery = ""
    @State private var expanded = false

    private var sources: [ConversationSource]? { message.sources ?? model.messageMetrics[message.id]?.sources }

    var body: some View {
        let layout = TurnLayout.make(content: message.content, timeline: message.timeline, tools: tools, key: \.id, running: live)
        let presentation = TurnWorkPresentation(layout: layout, sources: sources, live: live)
        VStack(alignment: .leading, spacing: 12) {
            if layout.hasWork {
                Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(presentation.header)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded || model.galleryExpandsTurns ? 90 : 0))
                        if presentation.hasFailedActions || presentation.hasInterruptedActions {
                            Image(systemName: "exclamationmark.circle")
                        }
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("turn-work-\(message.id.uuidString)")
                if live, let action = presentation.activeWebAction {
                    MacToolRow(action: action, turnTools: tools)
                } else if live, let label = presentation.activeLabel {
                    Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("turn-active-stage")
                }
                if let summary = presentation.sourceSummary {
                    Label(summary, systemImage: "globe").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("turn-source-summary")
                }
                if expanded || model.galleryExpandsTurns {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(layout.work, id: \.id) { item(item: $0, live: false) }
                    }.padding(.leading, 12).transition(.opacity)
                }
            }
            ForEach(layout.answer, id: \.id) { item(item: $0, live: live) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func item(item: TurnLayoutItem<ConversationAction>, live: Bool) -> some View {
        switch item {
        case let .reasoning(_, text, duration, running):
            MacReasoningRow(text: text, duration: duration, running: running)
        case let .text(_, text):
            MacStreamingSourceMarkdown(text: text, sources: sources, appearance: model.settings.conversationAppearance ?? .init(), searchQuery: searchQuery, messageID: message.id, live: live)
                .foregroundStyle(.primary)
        case let .tools(_, group):
            // Delegations read as "… started working" and open the Sub-agents tab.
            let delegated = group.filter { $0.name == "delegate_task" }
            if !delegated.isEmpty { MacSubagentsStartedRow(calls: delegated) }
            let others = group.filter { $0.name != "delegate_task" }
            if !others.isEmpty { MacToolGroupView(tools: others, live: live, turnTools: tools) }
        case let .subagents(_, ids):
            Label(ids.count == 1 ? "1 sub-agent started" : "\(ids.count) sub-agents started", systemImage: "person.2")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }
}

/// Provider-supplied reasoning stays in a separately opened detail, without another duration.
struct MacReasoningRow: View {
    @Environment(AppModel.self) private var model
    let text: String
    let duration: TimeInterval?
    let running: Bool
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? model.galleryExpandsTurns
        VStack(alignment: .leading, spacing: 6) {
            Button { open = !isOpen } label: {
                HStack(spacing: 6) {
                    Text(TurnWorkPresentation.providerReasoningTitle())
                    if !text.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(text.isEmpty)
            if isOpen, !text.isEmpty {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Consecutive actions under one title ("Searched the web, read 3 files"). More than five
/// rows scroll inside the group so the conversation keeps its place.
struct MacToolGroupView: View {
    @Environment(AppModel.self) private var model
    let tools: [ConversationAction]
    let live: Bool
    /// Every action of the turn, listed in the Actions tab when one is opened.
    var turnTools: [ConversationAction] = []
    @State private var open: Bool?

    private var running: Bool { tools.contains { $0.state == .running || $0.state == .waiting } }

    var body: some View {
        if live, let action = tools.last(where: { WebActivityPresentation(action: $0)?.isRunning == true }) {
            MacToolRow(action: action, turnTools: turnTools.isEmpty ? tools : turnTools)
        } else if tools.count == 1, let tool = tools.first {
            MacToolRow(action: tool, turnTools: turnTools)
        } else {
            let isOpen = open ?? ((live && running) || model.galleryExpandsTurns)
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.easeOut(duration: 0.16)) { open = !isOpen } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: ToolActivityCategory.classify(tools.last?.name ?? "").symbol).frame(width: 15)
                        Text(TurnLayoutText.group(names: tools.map(\.name), running: running))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0))
                        if tools.contains(where: { $0.state == .failed || $0.state == .needsReview }) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isOpen {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) { ForEach(tools) { MacToolRow(action: $0, turnTools: turnTools) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: tools.count > 8 ? 8 * 28 : nil)
                    .scrollIndicators(tools.count > 8 ? .visible : .hidden)
                    .padding(.leading, 8)
                }
            }
        }
    }
}

/// One action: what it did, its subject, its state; a click shows its input and output here,
/// and the complete details on demand.
struct MacToolRow: View {
    @Environment(AppModel.self) private var model
    let action: ConversationAction
    var turnTools: [ConversationAction] = []
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.14)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    if let web = WebActivityPresentation(action: action), let domain = web.domain {
                        MacSourceIcon(domain: domain, size: 18, sourceURL: web.url?.absoluteString)
                    } else { Image(systemName: Self.symbol(for: action)).frame(width: 15) }
                    Text(title).lineLimit(1)
                    if let subject { Text(subject).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary) }
                    if action.state == .running || action.state == .waiting { ProgressView().controlSize(.mini) }
                    if action.state == .failed { Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("Failed") }
                    if action.state == .needsReview { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary) }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(minHeight: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(action.state == .needsReview ? "Effect unknown · inspect before retrying" : title)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if let data = action.previewJPEG, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    preview("Input", action.input)
                    preview("Output", action.output ?? (action.detail?.hasPrefix("NativeWebSearchActivity(") == true ? nil : action.detail))
                    Button("Open in panel") {
                        model.requestedWorkbench = .init(kind: .actions, focusID: action.id, actions: turnTools.isEmpty ? [action] : turnTools)
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.primary)
                }
                .padding(10)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder private func preview(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value.map { String(ConversationAction.redact($0).prefix(1_200)) } ?? "Not provided by the service")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(value == nil ? .tertiary : .secondary)
                .lineLimit(10).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String { Self.title(for: action) }
    private var subject: String? { Self.subject(for: action) }

    static func symbol(for action: ConversationAction) -> String {
        let icon = WorkspaceProgressView.icon(for: action.name)
        return icon == "sparkles" ? ToolActivityCategory.classify(action.name).symbol : icon
    }

    static func title(for action: ConversationAction, locale: Locale = .current) -> String {
        if let web = WebActivityPresentation(action: action, locale: locale) { return web.title }
        // A finished action may have failed or have an unknown effect. Only a
        // completed action can use the successful, past-tense tool label.
        let french = locale.language.languageCode?.identifier == "fr"
        let status: String?
        switch action.state {
        case .failed: status = french ? "Échec" : "Failed"
        case .cancelled: status = french ? "Annulé" : "Cancelled"
        case .needsReview: status = french ? "Effet inconnu" : "Effect unknown"
        default: status = nil
        }
        if let status {
            return "\(status) · \(ToolDisplayName.title(action.name, running: true, locale: locale))"
        }
        let running = action.state == .running || action.state == .waiting
        switch action.name {
        case "web_search": return running ? "Searching the web" : "Searched the web"
        case "view_image": return "Viewed image"
        case "visual_analysis": return "Analysed images"
        case "network": return running ? "Waiting for the network" : "Network available"
        default:
            if action.name.hasPrefix("Provider · ") { return action.name }
            return ToolDisplayName.title(action.name, running: running, locale: locale)
        }
    }

    /// The query, path, command or address the action worked on, when it is known.
    static func subject(for action: ConversationAction) -> String? {
        if let web = WebActivityPresentation(action: action) { return web.subject }
        guard let input = action.input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            return action.name == "view_image" ? action.detail : nil
        }
        if let data = input.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = action.name == "open_app" ? ["app", "bundle_id"] : ["query", "path", "command", "url", "title", "pattern", "source", "question"]
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty {
                    return key == "path" || key == "source" ? URL(fileURLWithPath: value).lastPathComponent : String(value.prefix(120))
                }
            }
            return nil
        }
        return String(input.prefix(120))
    }
}

private extension AppModel {
    /// Gallery expansion is available only in Debug qualification builds.
    var galleryExpandsTurns: Bool {
        #if DEBUG
        debugExpandTurns
        #else
        false
        #endif
    }
}
