import AIMCore
import SwiftUI

/// This row follows one real invocation's metadata; it never rotates through citations.
struct AIMWebActivityLine: View {
    let action: ConversationAction
    var body: some View {
        if let activity = WebActivityPresentation(action: action) {
            HStack(spacing: 7) {
                if let domain = activity.domain {
                    AIMSourceIcon(domain: domain, size: 18, sourceURL: activity.url?.absoluteString)
                } else { Image(systemName: "globe").frame(width: 18) }
                Text(activity.title).contentTransition(.opacity)
                if let subject = activity.subject { Text(subject).lineLimit(1).truncationMode(.middle).contentTransition(.opacity) }
                if activity.isRunning { ProgressView().controlSize(.mini) }
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("web-activity-" + action.id)
        }
    }
}

struct AIMConversationActions: View {
    let actions: [ConversationAction]
    var attachments: [NativeChatAttachment] = []
    @State private var showing = false
    @State private var selection: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { selection = nil; showing = true } label: {
                HStack { Text("Actions · \(actions.count)"); Spacer(); Image(systemName: "chevron.right") }.font(.footnote).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("chat-actions")
            ForEach(actions.filter { [.running, .waiting, .failed, .needsReview].contains($0.state) }) { action in
                Button { selection = action.id; showing = true } label: {
                    Label(action.name.replacingOccurrences(of: "_", with: " "), systemImage: action.state == .failed ? "exclamationmark.circle" : "gearshape")
                        .font(.footnote).foregroundStyle([.failed, .needsReview].contains(action.state) ? Color.red : .secondary)
                }.buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showing) { AIMActionsPanel(actions: actions, attachments: attachments, selection: selection) }
    }
}

struct AIMActionsPanel: View {
    let actions: [ConversationAction]
    var attachments: [NativeChatAttachment] = []
    @State var selection: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(actions) { action in
                    DisclosureGroup(isExpanded: Binding(get: { selection == action.id }, set: { selection = $0 ? action.id : nil })) {
                        if let bytes = image(action), let image = UIImage(data: bytes) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320) }
                        LabeledContent("State", value: action.state.rawValue)
                        if let duration = action.duration { LabeledContent("Duration", value: String(format: "%.1f s", duration)) }
                        Text("Input").font(.headline)
                        Text(action.input.map { ConversationAction.redact($0) } ?? "Not provided by the service").textSelection(.enabled)
                        Text("Output").font(.headline)
                        Text((action.output ?? (action.detail?.hasPrefix("NativeWebSearchActivity(") == true ? nil : action.detail)).map { ConversationAction.redact($0) } ?? "Not provided by the service").textSelection(.enabled)
                        if action.detailReference != nil { Text("Full details remain on the execution Mac.").foregroundStyle(.secondary) }
                    } label: {
                        Label(action.name.replacingOccurrences(of: "_", with: " ") + (action.timestamp.map { String(format: " · %.2f s", $0) } ?? ""), systemImage: action.mediaID == nil ? "terminal" : "photo")
                    }.tint(.primary)
                }
            }
            .navigationTitle("Actions").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }.aimUniversalPanelSurface().presentationDetents([.medium, .large]).accessibilityIdentifier("tool-activity-panel")
    }
    private func image(_ action: ConversationAction) -> Data? {
        if let preview = action.previewJPEG { return InputMediaPreview.validatedJPEG(preview) }
        guard let id = action.mediaID else { return nil }
        for attachment in attachments {
            if attachment.id == id { return attachment.data }
            if let frame = attachment.video?.frames.first(where: { $0.id == id }) { return frame.jpeg }
        }
        return nil
    }
}

/// A cited site's icon, with a neutral globe while unavailable.
struct AIMSourceIcon: View {
    let domain: String
    var size: CGFloat = 36
    var sourceURL: String? = nil
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.primary.opacity(0.06))
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit().frame(width: size * 0.58, height: size * 0.58)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.48, weight: .regular)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: sourceURL ?? domain) {
            image = nil
            let data: Data?
            if let url = sourceURL.flatMap(URL.init(string:)) { data = await SourceFaviconStore.shared.icon(url: url) }
            else { data = await SourceFaviconStore.shared.icon(domain: domain) }
            if !Task.isCancelled, let data, let icon = UIImage(data: data) { image = icon }
        }
        .accessibilityHidden(true)
    }
}

struct AIMSourcesPanel: View {
    let sources: [ConversationSource]
    var focusedID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                List(sources) { source in
                    Button { if let url = URL(string: source.url) { openURL(url) } } label: {
                        HStack(alignment: .top, spacing: 12) {
                            AIMSourceIcon(domain: source.domain, sourceURL: source.url)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(source.displayDomain).foregroundStyle(.secondary)
                                    if let references = source.references, !references.isEmpty {
                                        Text(references.map { "[\($0)]" }.joined(separator: " ")).foregroundStyle(.tertiary)
                                    }
                                }.font(.caption)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(source.id == focusedID ? Color.primary.opacity(0.06) : Color.clear)
                    .contextMenu {
                        Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.string = source.url }
                    }
                    .id(source.id)
                    .accessibilityIdentifier("source-row-\(source.domain)")
                }
                .listStyle(.plain)
                .onAppear { if let focusedID { scroll.scrollTo(focusedID, anchor: .top) } }
            }
            .navigationTitle("Sources").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }.aimUniversalPanelSurface().presentationDetents([.medium, .large])
    }
}

struct AIMSourceMarkdown: View {
    let text: String
    var sources: [ConversationSource]?
    @State private var selected: ConversationSource?
    var body: some View {
        let projection = ConversationSourceProjection(text: text, sources: sources)
        AIMMarkdownView(source: projection.citedText)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == SourceCitationLink.scheme else { return .systemAction }
                guard let source = SourceCitationLink.sources(url, in: projection.sources).first else { return .discarded }
                selected = source; return .handled
            })
            .sheet(item: $selected) { source in AIMSourcesPanel(sources: projection.sources, focusedID: source.id) }
    }
}

struct AIMAttentionBadge: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let center = AIMNotificationCenter.shared
        content.overlay(alignment: .topTrailing) {
            if center.attention.count > 0 {
                HStack(spacing: 3) {
                    Circle().fill(color(center.attention.priority)).frame(width: 6, height: 6)
                    Text(center.attention.count.formatted()).font(.system(size: 10, weight: .semibold))
                }.padding(4).background(.regularMaterial, in: Capsule()).offset(x: 6, y: -4)
                    .allowsHitTesting(false)
                    .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                    .accessibilityLabel("\(center.attention.count) conversations need attention")
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: center.arrivalRevision)
    }
    private func color(_ kind: ConversationAttention.Kind?) -> Color { kind == .failure ? .red : kind == .approval ? .green : .blue }
}

/// An assistant turn as it happened: reasoning, actions and text in order while it runs,
/// then everything before the final answer folded into one "Worked for …" row.
struct AIMTurnTimelineView: View {
    let layout: TurnLayout<ConversationAction>
    let sources: [ConversationSource]?
    var attachments: [NativeChatAttachment] = []
    var citationPresentation: ProjectSourceCitationPresentation?
    let live: Bool
    /// Remote answers load tool details from the Mac; local ones use the actions panel.
    var openTools: (([ConversationAction]) -> Void)?
    @State private var expanded = false

    init(text: String, timeline: TurnTimeline?, actions: [ConversationAction], sources: [ConversationSource]?,
         attachments: [NativeChatAttachment] = [], live: Bool, citationPresentation: ProjectSourceCitationPresentation? = nil) {
        self.citationPresentation = citationPresentation
        layout = TurnLayout.make(content: text, timeline: timeline, tools: actions, key: \.id, running: live)
        self.sources = sources; self.attachments = attachments; self.live = live
    }

    init(layout: TurnLayout<ConversationAction>, sources: [ConversationSource]?, live: Bool, openTools: @escaping ([ConversationAction]) -> Void) {
        self.layout = layout; self.sources = sources; self.live = live; self.openTools = openTools
    }

    var body: some View {
        let presentation = TurnWorkPresentation(layout: layout, sources: sources, live: live)
        VStack(alignment: .leading, spacing: 10) {
            if layout.hasWork {
                Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(presentation.header)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        if presentation.hasFailedActions || presentation.hasInterruptedActions {
                            Image(systemName: "exclamationmark.circle")
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("turn-work")
                if live, let action = presentation.activeWebAction { AIMWebActivityLine(action: action) }
                else if live, let label = presentation.activeLabel {
                    Text(label).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("turn-active-stage")
                }
                if let summary = presentation.sourceSummary {
                    Label(summary, systemImage: "globe").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("turn-source-summary")
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(layout.work, id: \.id) { item($0, live: false) }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
                    .transition(.opacity)
                }
            }
            ForEach(layout.answer, id: \.id) { item($0, live: live) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func item(_ item: TurnLayoutItem<ConversationAction>, live: Bool) -> some View {
        switch item {
        case let .reasoning(_, text, duration, running): AIMReasoningRow(text: text, duration: duration, running: running)
        case let .text(_, text): AIMStreamingSourceMarkdown(text: citationPresentation?.displayed(text) ?? text, sources: sources, live: live)
        case let .tools(_, group):
            let delegated = group.filter { $0.name == "delegate_task" }
            if !delegated.isEmpty { AIMSubagentsStartedRow(calls: delegated) }
            let others = group.filter { $0.name != "delegate_task" }
            if !others.isEmpty { AIMToolGroupView(tools: others, attachments: attachments, live: live, openTools: openTools) }
        case let .subagents(_, ids):
            Label(ids.count == 1 ? "1 sub-agent started" : "\(ids.count) sub-agents started", systemImage: "person.2")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct AIMReasoningRow: View {
    let text: String
    let duration: TimeInterval?
    let running: Bool
    @State private var open: Bool?
    var body: some View {
        let isOpen = open ?? false
        VStack(alignment: .leading, spacing: 4) {
            Button { open = !isOpen } label: {
                HStack(spacing: 6) {
                    Text(TurnWorkPresentation.providerReasoningTitle())
                    if !text.isEmpty { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0)) }
                }
                .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(text.isEmpty).accessibilityIdentifier("turn-reasoning")
            if isOpen, !text.isEmpty {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Consecutive actions under one title; more than five rows scroll inside the group.
struct AIMToolGroupView: View {
    let tools: [ConversationAction]
    var attachments: [NativeChatAttachment] = []
    let live: Bool
    var openTools: (([ConversationAction]) -> Void)?
    @State private var open: Bool?
    /// The touched action; the panel opens with it unfolded.
    @State private var selected: Selection?
    private struct Selection: Identifiable { let id: String }
    private var running: Bool { tools.contains { $0.state == .running || $0.state == .waiting } }

    var body: some View {
        let isOpen = open ?? (live && running)
        VStack(alignment: .leading, spacing: 0) {
            if live, let action = tools.last(where: { WebActivityPresentation(action: $0)?.isRunning == true }) {
                // One changing line for the active invocation. All recorded
                // calls remain available in the details, without rotating citations.
                Button { selected = Selection(id: action.id) } label: { AIMWebActivityLine(action: action) }
                    .buttonStyle(.plain).frame(minHeight: 44)
                    .animation(.easeOut(duration: 0.16), value: action.id)
            } else if tools.count == 1, let tool = tools.first {
                row(tool)
            } else {
                Button { withAnimation(.easeOut(duration: 0.18)) { open = !isOpen } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: ToolActivityCategory.classify(tools.last?.name ?? "").symbol).frame(width: 18)
                        Text(TurnLayoutText.group(names: tools.map(\.name), running: running)).lineLimit(2)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0))
                        if tools.contains(where: { $0.state == .failed || $0.state == .needsReview }) { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                    .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("turn-tool-group")
                if isOpen {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { ForEach(tools) { row($0) } }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: tools.count > 5 ? 5 * 44 : nil)
                    .scrollIndicators(tools.count > 5 ? .visible : .hidden)
                    .padding(.leading, 10)
                }
            }
        }
        .sheet(item: $selected) { AIMActionsPanel(actions: tools, attachments: attachments, selection: $0.id) }
    }

    private func row(_ action: ConversationAction) -> some View {
        Button { if let openTools { openTools(tools) } else { selected = .init(id: action.id) } } label: {
            HStack(spacing: 8) {
                if let web = WebActivityPresentation(action: action), let domain = web.domain {
                    AIMSourceIcon(domain: domain, size: 18, sourceURL: web.url?.absoluteString)
                } else { Image(systemName: ToolActivityCategory.classify(action.name).symbol).frame(width: 18) }
                Text(Self.title(action)).lineLimit(1)
                if let subject = Self.subject(action) { Text(subject).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary) }
                if action.state == .running || action.state == .waiting { ProgressView().controlSize(.mini) }
                if action.state == .failed { Image(systemName: "xmark.circle").foregroundStyle(.red) }
                if action.state == .needsReview { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            }
            .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("turn-tool-\(action.id)")
    }

    static func title(_ action: ConversationAction) -> String {
        if let web = WebActivityPresentation(action: action) { return web.title }
        let fr = TurnLayoutText.french(), running = action.state == .running || action.state == .waiting
        switch ToolActivityCategory.classify(action.name) {
        case .search: return running ? (fr ? "Recherche" : "Searching") : (fr ? "Recherche" : "Searched")
        case .find: return fr ? "Fichiers recherchés" : "Searched files"
        case .note: return fr ? "Note envoyée" : "Sent a note"
        case .browse: return fr ? "Page lue" : "Read page"
        case .read: return fr ? "Lu" : "Read"
        case .edit: return fr ? "Modifié" : "Edited"
        case .command: return fr ? "Commande" : "Ran"
        case .image: return fr ? "Image analysée" : "Viewed image"
        case .network: return running ? (fr ? "Attente du réseau" : "Waiting for network") : (fr ? "Réseau rétabli" : "Network restored")
        case .route, .subagent, .other: return action.name.hasPrefix("Provider · ") ? action.name : action.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func subject(_ action: ConversationAction) -> String? {
        if let web = WebActivityPresentation(action: action) { return web.subject }
        guard let input = action.input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else { return action.name == "view_image" ? action.detail : nil }
        if let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] {
            for key in ["query", "path", "command", "url", "title", "pattern"] { if let value = object[key] as? String, !value.isEmpty { return String(value.prefix(120)) } }
            return nil
        }
        return String(input.prefix(120))
    }
}

/// "Name and Name started working" in an answer; opens the delegated tasks with their model,
/// effort and state. The sub-agents' own steps are followed on the Mac that runs them.
struct AIMSubagentsStartedRow: View {
    let calls: [ConversationAction]
    @State private var showing = false
    private func field(_ call: ConversationAction, _ key: String) -> String? {
        (call.input.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })?[key] as? String
    }
    private var sentence: String {
        let fr = TurnLayoutText.french()
        let names = calls.compactMap { field($0, "title") }
        let label = names.isEmpty ? "\(calls.count) " + (fr ? "sous-agent(s)" : "sub-agent(s)") : names.prefix(2).joined(separator: fr ? " et " : " and ") + (names.count > 2 ? (fr ? " et \(names.count - 2) autres" : " and \(names.count - 2) more") : "")
        let running = calls.contains { $0.state == .running || $0.state == .waiting }
        return label + (running ? (fr ? " travaille(nt)" : " started working") : (fr ? " délégué(s)" : " delegated"))
    }
    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2").frame(width: 18)
                Text(sentence).lineLimit(2).multilineTextAlignment(.leading)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .font(.footnote).foregroundStyle(.secondary).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("subagents-started")
        .sheet(isPresented: $showing) {
            NavigationStack {
                List(calls) { call in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(field(call, "title") ?? "Sub-agent").font(.subheadline.weight(.semibold))
                            Spacer()
                            if call.state == .running || call.state == .waiting { ProgressView().controlSize(.mini) }
                            else if call.state == .failed { Image(systemName: "xmark.circle").foregroundStyle(.red) }
                        }
                        let route = [field(call, "provider"), field(call, "model"), field(call, "effort")?.capitalized].compactMap { $0 }
                        if !route.isEmpty { Text(route.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        if let prompt = field(call, "prompt") { Text(prompt).font(.footnote).lineLimit(6) }
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.plain)
                .navigationTitle(TurnLayoutText.french() ? "Sous-agents" : "Sub-agents").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showing = false } } }
            }
            .aimUniversalPanelSurface().presentationDetents([.medium, .large])
        }
    }
}
