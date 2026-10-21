import AIMApplication
import AIMCore
import AppKit
import SwiftUI

/// A cited site's icon, with a neutral globe while unavailable.
struct MacSourceIcon: View {
    let domain: String
    var size: CGFloat = 30
    var sourceURL: String? = nil
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(.primary.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: size * 0.58, height: size * 0.58)
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
            if !Task.isCancelled, let data, let icon = NSImage(data: data) { image = icon }
        }
        .accessibilityHidden(true)
    }
}

/// The Sources tab: every source of one answer (or of the whole conversation), with the
/// cited one brought into view. A click opens the page in a browser tab beside the chat.
struct WorkbenchSourcesPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var tab: WorkbenchTab

    private var sources: [ConversationSource] {
        let messages = tab.messageID.map { id in model.messages.filter { $0.id == id } } ?? model.messages.filter { $0.role == .assistant }
        return messages.reduce(into: [ConversationSource]()) { result, message in
            let projected = ConversationSourceProjection(text: message.content, sources: message.sources ?? model.messageMetrics[message.id]?.sources).sources
            result = ConversationSource.merge(result, projected) ?? result
        }
    }

    var body: some View {
        let sources = sources
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Sources").font(.system(size: 15, weight: .semibold))
                        Text("\(sources.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    if sources.isEmpty {
                        Text(model.messages.contains(where: { $0.id == tab.messageID }) || tab.messageID == nil
                             ? "This answer has no sources." : "Open the conversation of this answer to see its sources.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 10)
                    }
                    ForEach(sources) { source in row(source).id(source.id) }
                }
                .padding(14)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: tab.focusRevision) { _, _ in scroll(proxy) }
        }
        .accessibilityIdentifier("workbench-sources")
    }

    private func row(_ source: ConversationSource) -> some View {
        let focused = source.id == tab.focusID
        return Button { model.requestedWorkbench = .init(kind: .browser, address: source.url) } label: {
            HStack(alignment: .top, spacing: 12) {
                MacSourceIcon(domain: source.domain, sourceURL: source.url)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(source.displayDomain).foregroundStyle(.secondary)
                        if let references = source.references, !references.isEmpty {
                            Text(references.map { "[\($0)]" }.joined(separator: " ")).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 12))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.aimHover(radius: 10))
        .help(source.url)
        .contextMenu {
            Button("Open in Browser") { if let url = URL(string: source.url) { NSWorkspace.shared.open(url) } }
            Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.url, forType: .string) }
        }
        .accessibilityIdentifier("workbench-source-\(source.domain)")
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let focus = tab.focusID else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(focus, anchor: .top) }
    }
}

/// The Actions tab: each action's subject, state, input and complete output, the touched one
/// unfolded. Outputs are read after secrets are masked and shown in pages.
struct WorkbenchActionsPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var tab: WorkbenchTab
    @State private var unfolded: Set<String> = []
    @State private var limits: [String: Int] = [:]

    private var actions: [ConversationAction] {
        if !tab.actions.isEmpty { return tab.actions }
        return tab.messageID.flatMap { id in model.messages.first { $0.id == id }?.actions } ?? []
    }

    var body: some View {
        let actions = actions
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Actions").font(.system(size: 15, weight: .semibold))
                        Text("\(actions.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                    if actions.isEmpty {
                        Text("Open the conversation of these actions to see them.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 6)
                    }
                    ForEach(actions) { card($0).id($0.id) }
                }
                .padding(14)
            }
            .onAppear { focus(proxy) }
            .onChange(of: tab.focusRevision) { _, _ in focus(proxy) }
        }
        .accessibilityIdentifier("workbench-actions")
    }

    private func card(_ action: ConversationAction) -> some View {
        let open = unfolded.contains(action.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button { if open { unfolded.remove(action.id) } else { unfolded.insert(action.id) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: MacToolRow.symbol(for: action)).frame(width: 16)
                    Text(MacToolRow.title(for: action)).foregroundStyle(.primary)
                    if let subject = MacToolRow.subject(for: action) { Text(subject).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    if action.state == .running || action.state == .waiting { ProgressView().controlSize(.mini) }
                    if let duration = action.duration { Text(TurnLayoutText.duration(duration)).foregroundStyle(.tertiary).monospacedDigit() }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 12.5)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                if action.state == .failed { Label("Failed", systemImage: "xmark.circle").font(.caption).foregroundStyle(.red) }
                if action.state == .needsReview { Label("Effect unknown · inspect before retrying", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                if let data = action.previewJPEG, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                block("Input", action.input.map { ConversationAction.redact($0) })
                let output = fullOutput(action)
                let limit = limits[action.id] ?? 16_384
                block("Output", output.map { String($0.prefix(limit)) })
                if let output, output.count > limit {
                    Button("Load more output") { limits[action.id] = min(output.count, limit + 16_384) }.buttonStyle(.plain).font(.caption).foregroundStyle(.primary)
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(open ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func block(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let value {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy \(title.lowercased())")
                }
            }
            Text(value ?? "Not provided by the service")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(9).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The local run's complete result when this Mac recorded it, else the stored output.
    private func fullOutput(_ action: ConversationAction) -> String? {
        if let reference = action.detailReference, let split = reference.firstIndex(of: ":") {
            let run = String(reference[..<split]), call = String(reference[reference.index(after: split)...])
            if let value = model.workspaceHistory.first(where: { $0.id == run })?.calls.first(where: { $0.id == call })?.result {
                return ConversationAction.redact(value, limit: 1_000_000)
            }
        }
        return (action.output ?? (action.detail?.hasPrefix("NativeWebSearchActivity(") == true ? nil : action.detail)).map { ConversationAction.redact($0, limit: 1_000_000) }
    }

    private func focus(_ proxy: ScrollViewProxy) {
        guard let id = tab.focusID else { return }
        unfolded.insert(id)
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
    }
}
