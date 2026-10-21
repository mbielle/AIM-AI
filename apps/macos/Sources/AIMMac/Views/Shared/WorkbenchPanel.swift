import AIMAgentKit
import AIMCore
import AIMApplication
import AIMMacPlatform
import SwiftUI
import WebKit

enum WorkbenchPanelKind: String, CaseIterable, Codable {
    case newTab, terminal, browser, context, review, sideChat, sources, actions, subagents
    var title: String {
        switch self {
        case .newTab: "New tab"
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .context: "Files"
        case .review: "Review"
        case .sideChat: "Side chat"
        case .sources: "Sources"
        case .actions: "Actions"
        case .subagents: "Sub-agents"
        }
    }
    var icon: String {
        switch self {
        case .newTab, .browser: "globe"
        case .terminal: "terminal"
        case .context: "folder"
        case .review: "arrow.triangle.branch"
        case .sideChat: "bubble.left.and.bubble.right"
        case .sources: "book"
        case .actions: "list.bullet.rectangle"
        case .subagents: "person.2"
        }
    }
    /// Terminals follow their folder; every other tab belongs to the conversation it was opened in.
    var followsFolder: Bool { self == .terminal }
}

/// A request from the conversation to show something in the right panel.
struct WorkbenchRequest: Equatable {
    let id = UUID()
    var kind: WorkbenchPanelKind
    var messageID: UUID?
    var focusID: String?
    var actions: [ConversationAction] = []
    var address: String?
}

@MainActor @Observable
final class WorkbenchTab: Identifiable {
    let id: UUID
    var kind: WorkbenchPanelKind
    var displayName: String?
    let workspacePath: String?
    /// The conversation this tab belongs to; nil for terminals and tabs saved before round 25.
    let conversationID: UUID?
    /// Sources and Actions tabs: the answer they describe, and the item to bring into view.
    var messageID: UUID?
    var focusID: String?
    var focusRevision = 0
    /// Actions tab: the calls shown (kept in memory only, never saved to disk).
    var actions: [ConversationAction] = []
    var initialAddress: String?
    var title: String { displayName ?? kind.title }
    let sideChat = SideChatSession()
    init(id: UUID = UUID(), kind: WorkbenchPanelKind, workspacePath: String? = nil, conversationID: UUID? = nil) {
        self.id = id; self.kind = kind; self.workspacePath = workspacePath; self.conversationID = kind.followsFolder ? nil : conversationID
    }
}

struct WorkbenchTabs: View {
    @Binding var tabs: [WorkbenchTab]
    @Binding var selection: UUID?
    var body: some View {
        ZStack {
            // Remain mounted while hidden: only removing a tab ends its lifetime.
            ForEach(tabs) { tab in
                WorkbenchPanel(tab: tab)
                    .opacity(selection == tab.id ? 1 : 0)
                    .allowsHitTesting(selection == tab.id)
                    .accessibilityHidden(selection != tab.id)
            }
        }
    }
}

struct WorkbenchPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var tab: WorkbenchTab
    var body: some View {
        Group {
            switch tab.kind {
            case .newTab: NewWorkbenchTab(tab: tab)
            case .terminal: TerminalPanel(workspacePath: tab.workspacePath)
            case .browser: BrowserPreviewPanel(initialAddress: tab.initialAddress)
            case .context: WorkspaceExplorer(workspacePath: tab.workspacePath)
            case .review: GitReviewPanel(workspacePath: tab.workspacePath)
            case .sideChat: SideChatView(session: tab.sideChat)
            case .sources: WorkbenchSourcesPanel(tab: tab)
            case .actions: WorkbenchActionsPanel(tab: tab)
            case .subagents: WorkbenchSubagentsPanel(tab: tab)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NewWorkbenchTab: View {
    @Bindable var tab: WorkbenchTab
    @State private var address = ""
    @State private var browsing = false
    var body: some View {
        if browsing {
            BrowserPreviewPanel(initialAddress: address)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    TextField("Search or enter a URL", text: $address)
                        .textFieldStyle(.plain).onSubmit(openAddress)
                    Button(action: openAddress) { Image(systemName: "arrow.right") }.buttonStyle(.plain)
                }.padding(14).background(.primary.opacity(0.04), in: Capsule())
                Text("Tools").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 12) {
                    ForEach([WorkbenchPanelKind.terminal, .sideChat, .context, .review, .sources, .subagents], id: \.self) { kind in
                        Button { tab.kind = kind } label: {
                            HStack {
                                Label(kind.title, systemImage: kind.icon)
                                Spacer()
                                if kind == .sideChat { Text("⌥⌘S").font(.caption).foregroundStyle(.tertiary) }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(AIMIconButtonStyle())
                    }
                }
                Spacer()
            }.padding(20)
        }
    }
    private func openAddress() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !value.contains(".") && !value.contains(":") {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: value)]
            address = components.url!.absoluteString
        } else { address = value }
        browsing = true
        tab.displayName = URL(string: address)?.host ?? "Browser"
    }
}

@MainActor @Observable
final class TerminalSession {
    static let introduction = "Interactive zsh in the selected workspace. Commands share one shell, so cd and shell variables persist. Stop closes the session and its child processes. Full-screen terminal programs are not yet supported.\n"
    var command = ""
    var output = TerminalSession.introduction
    var isRunning = false
    var isStarting = false
    var isStopping = false
    private(set) var history = TerminalCommandHistory()
    private var generation = UUID()
    private let terminal: MacPTYTerminal
    private var task: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var latestSendID = UUID()
    private var activeWorkspace: String?

    init(terminal: MacPTYTerminal = MacPTYTerminal()) { self.terminal = terminal }

    func run(workspacePath: String?, privateInput: Bool = false) {
        let input = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isStopping else { return }
        if isRunning {
            guard workspacePath == activeWorkspace else {
                output = bounded(output + "\n[workspace changed; restart the terminal before sending]\n")
                return
            }
            submit(input, privateInput: privateInput)
            return
        }
        guard !isStarting else { return }
        guard let workspacePath,
              (try? URL(fileURLWithPath: workspacePath).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            output += "\nChoose a valid workspace before running commands.\n"
            return
        }
        let runGeneration = generation
        let transcript = output + "\n[session started]\n"
        activeWorkspace = workspacePath
        isStarting = true
        task = Task {
            do {
                for try await event in terminal.stream(workspace: workspacePath) {
                    guard runGeneration == generation else { break }
                    switch event {
                    case .ready:
                        isStarting = false
                        isRunning = true
                        submit(input, privateInput: privateInput)
                    case .output(let snapshot):
                        output = bounded(transcript + sanitized(snapshot))
                    case .completed(let exitCode):
                        output = bounded(output + "\n[session exited \(exitCode)]\n")
                    }
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                if runGeneration == generation { output += "\n[stopped]\n" }
            } catch {
                if runGeneration == generation { output += "\n[error] \(error.localizedDescription)\n" }
            }
            await terminal.terminateAll()
            if runGeneration == generation {
                output = bounded(output)
                isRunning = false
                isStarting = false
                isStopping = false
                task = nil
            }
        }
    }

    private func submit(_ input: String, privateInput: Bool) {
        guard isRunning, !isStopping else { return }
        command = ""
        if !privateInput { history.record(input) }
        let runGeneration = generation
        let sendID = UUID()
        latestSendID = sendID
        let previous = sendTask
        sendTask = Task {
            await previous?.value
            guard !Task.isCancelled, runGeneration == generation else { return }
            do { try await terminal.send(input + "\n") }
            catch {
                if runGeneration == generation {
                    output = bounded(output + "\n[input error] \(error.localizedDescription)\n")
                }
            }
            if latestSendID == sendID { sendTask = nil }
        }
    }

    private func sanitized(_ text: String) -> String {
        // This is a command-output view, not a VT emulator. Keep text readable
        // when a tool emits ANSI colors or terminal control sequences.
        text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func bounded(_ text: String) -> String {
        let maximumCharacters = 128_000
        return text.count <= maximumCharacters ? text : "[Earlier terminal output omitted]\n" + String(text.suffix(maximumCharacters))
    }

    func cancel() {
        guard isRunning || isStarting else { return }
        isStopping = true
        task?.cancel()
        sendTask?.cancel()
        Task { await terminal.terminateAll() }
    }

    func resetForWorkspace() {
        cancel()
        generation = UUID()
        let resetGeneration = generation
        activeWorkspace = nil
        command = ""; output = Self.introduction; history.clear()
        Task {
            await terminal.terminateAll()
            guard generation == resetGeneration else { return }
            isRunning = false
            isStarting = false
            isStopping = false
            task = nil
            sendTask = nil
        }
    }

    func previousCommand() -> Bool {
        guard !isStarting, !isStopping, let value = history.previous(current: command) else { return false }
        command = value; return true
    }
    func nextCommand() -> Bool {
        guard !isStarting, !isStopping, let value = history.next() else { return false }
        command = value; return true
    }
    func clearHistory() { history.clear() }
    func clearOutput() { if !isRunning && !isStarting { output = Self.introduction } }
}

private struct TerminalPanel: View {
    @Environment(\.colorScheme) private var scheme
    @State private var session = TerminalSession()
    @State private var privateInput = false
    let workspacePath: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder")
                Text(workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No workspace selected")
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Clear output") { session.clearOutput() }.disabled(session.isRunning || session.isStarting)
                    Button("Forget command history") { session.clearHistory() }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Terminal options")
                if session.isRunning || session.isStarting || session.isStopping {
                    Button("Stop", systemImage: "stop.fill") { session.cancel() }
                        .help("Stop shell and child processes")
                        .disabled(session.isStopping)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(AIMTheme.secondaryText(scheme))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(15)
                    Color.clear.frame(height: 1).id("terminal-bottom")
                }
                .onChange(of: session.output) { _, _ in
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }

            HStack(spacing: 8) {
                Text("❯")
                    .font(.system(size: 15, design: .monospaced))
                if privateInput {
                    SecureField("Masked input", text: $session.command)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { submit() }
                        .accessibilityIdentifier("terminal-private-input")
                        .disabled(session.isStarting || session.isStopping)
                } else {
                    TextField("Enter command", text: $session.command)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { submit() }
                        .onKeyPress(.upArrow) { session.previousCommand() ? .handled : .ignored }
                        .onKeyPress(.downArrow) { session.nextCommand() ? .handled : .ignored }
                        .accessibilityIdentifier("terminal-command")
                        .disabled(session.isStarting || session.isStopping)
                }
                Button {
                    privateInput.toggle()
                } label: { Image(systemName: privateInput ? "lock.fill" : "lock.open") }
                    .buttonStyle(.plain)
                    .help("Mask the next input and omit it from AIM command history. The target program must disable terminal echo to keep it out of output.")
                    .accessibilityLabel(privateInput ? "Masked terminal input enabled" : "Enable masked terminal input")
                    .disabled(!session.command.isEmpty || session.isStarting || session.isStopping)
                Button("Run", systemImage: "return") { submit() }
                    .disabled(session.isStarting || session.isStopping || session.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(13)
            .background(AIMTheme.muted(scheme))
        }
        .onDisappear { session.cancel() }
        .onChange(of: workspacePath) { _, _ in session.resetForWorkspace(); privateInput = false }
        .onChange(of: session.command) { _, value in if value.isEmpty { privateInput = false } }
    }

    private func submit() {
        let wasPrivate = privateInput
        session.run(workspacePath: workspacePath, privateInput: wasPrivate)
        if session.command.isEmpty { privateInput = false }
    }
}

private struct BrowserPreviewPanel: View {
    @Environment(\.colorScheme) private var scheme
    @State private var session = BrowserPreviewSession()
    var initialAddress: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .help("Back").disabled(!session.canGoBack).accessibilityLabel("Back")
                Button { session.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .help("Forward").disabled(!session.canGoForward).accessibilityLabel("Forward")
                Button { if session.isLoading { session.stop() } else { session.loadAddress() } } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                }.help(session.isLoading ? "Stop loading" : "Reload")
                    .accessibilityLabel(session.isLoading ? "Stop loading" : "Reload")
                TextField("URL or localhost port", text: $session.address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { session.loadAddress() }
                    .accessibilityIdentifier("browser-address")
                Button("Go", systemImage: "arrow.right") { session.loadAddress() }
                    .help("Open preview")
            }
            .buttonStyle(.plain)
            .padding(10)

            if session.isLoading { ProgressView().controlSize(.small).padding(4).accessibilityLabel("Loading preview") }
            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            BrowserWebView(webView: session.webView)
                .background(AIMTheme.muted(scheme))
        }.onAppear { if let initialAddress, session.address != initialAddress { session.address = initialAddress; session.loadAddress() } }
        .onDisappear { session.stop() }
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
