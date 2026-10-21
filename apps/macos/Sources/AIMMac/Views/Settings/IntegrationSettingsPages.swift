import AIMCore
import AIMApplication
import AIMMacPlatform
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Import

struct ImportSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sources: [AIImportSource] = []
    @State private var scanned = false
    @State private var reviewing: AIImportSource?
    @State private var chats: [ChatExportReader.Conversation]?
    @State private var chatsFile: String?
    @State private var status: String?
    @State private var working = false

    var body: some View {
        SettingsPage("Import", subtitle: "Bring instructions, skills, MCP servers and conversations from other AI apps into AIM.") {
            SettingsGroup("Import from another AI app", description: "Detected on this Mac. Nothing is changed in the other app.") {
                if !scanned {
                    SettingsBlock { ProgressView().controlSize(.small) }
                } else if sources.isEmpty {
                    SettingsRow("Nothing found", description: "Claude Code, Claude Desktop, Codex and Cursor setups appear here when they exist.")
                }
                ForEach(sources) { source in
                    SettingsRow(title: source.name, description: Self.contents(source), leading: { ImportSourceIcon(kind: source.kind) }) {
                        Button("Import…") { reviewing = source }.buttonStyle(.settings).disabled(working)
                    }
                }
            }
            SettingsGroup("Conversations", description: "From a ChatGPT or Claude data export (the .zip or its conversations.json). Text only.") {
                SettingsRow("Import an export file", description: chats.map { "\($0.count) conversation\($0.count == 1 ? "" : "s") in \(chatsFile ?? "the file") · \($0.reduce(0) { $0 + $1.messages.count }) messages" }) {
                    if let chats, !chats.isEmpty {
                        Button("Import \(chats.count)") { Task { await importChats(chats) } }.buttonStyle(.settingsPrimary).disabled(working)
                    }
                    Button("Choose file…") { chooseExport() }.buttonStyle(.settings).disabled(working)
                }
            }
            if let status { SettingsBlock { SettingsNotice(status, tone: .success) } }
        }
        .task { await scan() }
        .sheet(item: $reviewing) { source in
            ImportReviewSheet(source: source) { instructions, skills, servers in
                Task {
                    working = true
                    defer { working = false }
                    do { status = try await model.importSetup(source, instructions: instructions, skills: skills, servers: servers).text }
                    catch { status = error.localizedDescription }
                }
            }
        }
    }

    static func contents(_ source: AIImportSource) -> String {
        var parts: [String] = []
        if source.instructions != nil { parts.append("instructions") }
        if !source.skillDirectories.isEmpty { parts.append("\(source.skillDirectories.count) skill\(source.skillDirectories.count == 1 ? "" : "s")") }
        if !source.servers.isEmpty { parts.append("\(source.servers.count) MCP server\(source.servers.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func scan() async {
        sources = await Task.detached { AIImportScanner.scan() }.value
        scanned = true
    }

    private func chooseExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .json]
        panel.prompt = "Read"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            chats = try ChatExportReader.read(url)
            chatsFile = url.lastPathComponent
            status = nil
        } catch {
            chats = nil
            status = error.localizedDescription
        }
    }

    private func importChats(_ value: [ChatExportReader.Conversation]) async {
        working = true
        defer { working = false }
        do {
            let count = try await model.importChats(value)
            status = "Imported \(count) conversation\(count == 1 ? "" : "s"). They are in your Recents."
            chats = nil
        } catch { status = error.localizedDescription }
    }
}

private struct ImportSourceIcon: View {
    let kind: AIImportSource.Kind
    var body: some View {
        Group {
            switch kind {
            case .claudeCode, .claudeDesktop: ModelCreatorLogo(creator: "anthropic", size: 22)
            case .codex: ModelCreatorLogo(creator: "openai", size: 22)
            case .cursor: Image(systemName: "cursorarrow.rays").font(.system(size: 16))
            }
        }
        .frame(width: 28)
    }
}

/// Shows exactly what will be added before anything is imported.
private struct ImportReviewSheet: View {
    let source: AIImportSource
    let onImport: (Bool, Bool, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var instructions = true
    @State private var skills = true
    @State private var servers = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from \(source.name)").font(.system(size: 20, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let found = source.instructions {
                        Toggle(isOn: $instructions) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Instructions").font(.system(size: 13, weight: .medium))
                                Text("Added to your AGENTS.md (Settings › Personalization), used by Agent and Code tasks. From \(GeneralSettingsView.abbreviated(found.path)).")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Text(found.text.prefix(400) + (found.text.count > 400 ? "…" : ""))
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                    .padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }.toggleStyle(.checkbox)
                    }
                    if !source.skillDirectories.isEmpty {
                        Toggle(isOn: $skills) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Skills").font(.system(size: 13, weight: .medium))
                                Text(source.skillDirectories.map(\.lastPathComponent).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                    if !source.servers.isEmpty {
                        Toggle(isOn: $servers) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MCP servers").font(.system(size: 13, weight: .medium))
                                ForEach(source.servers, id: \.name) { server in
                                    Text("\(server.name) · \(server.url ?? ([server.command ?? ""] + server.arguments).joined(separator: " "))")
                                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text("Imported as untrusted: every tool call asks first. Environment values go to the Keychain.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.settings).keyboardShortcut(.cancelAction)
                Button("Import") { onImport(instructions, skills, servers); dismiss() }.buttonStyle(.settingsPrimary)
                    .disabled(!(instructions && source.instructions != nil) && !(skills && !source.skillDirectories.isEmpty) && !(servers && !source.servers.isEmpty))
            }
        }
        .padding(24).frame(width: 580, height: 520)
    }
}

// MARK: Computer use

struct ComputerUseSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var enabled = IntegrationPreferences.computerUseEnabled

    var body: some View {
        SettingsPage("Computer use", subtitle: "How AIM's Agent uses other apps on this Mac.") {
            SettingsGroup("Control") {
                SettingsToggleRow("Control apps", description: "Let the Agent click, type and switch windows in your apps, with your approval. When off, it can still read windows.",
                                  isOn: Binding(get: { enabled }, set: { enabled = $0; IntegrationPreferences.computerUseEnabled = $0 }))
                SettingsRow("Set up computer use", description: "Accessibility, window screenshots and the browser connection, checked step by step.") {
                    Button("Open…") { openWindow(id: "computer-use") }.buttonStyle(.settings)
                }
            }
            SettingsGroup("macOS permissions") {
                ForEach([MacPermissionKind.accessibility, .screenRecording], id: \.self) { kind in
                    let granted = model.permissionStates[kind] == .granted
                    SettingsRow(kind == .accessibility ? "Accessibility" : "Screen Recording",
                                description: kind == .accessibility ? "Needed to read and control app interfaces." : "Needed to see a selected window.") {
                        SettingsStatus(text: granted ? "Allowed" : "Not allowed", color: granted ? .green : .orange)
                        if !granted { Button("Request") { Task { await model.requestPermission(kind) } }.buttonStyle(.settings) }
                    }
                }
            }
        }
        .task { await model.refreshPermissions() }
    }
}

// MARK: Browser

struct BrowserSettingsView: View {
    @State private var enabled = IntegrationPreferences.browserEnabled
    @State private var mode = AgentBrowserPreferences.mode
    /// Read off the main thread: the Keychain may wait for macOS's authorization.
    @State private var hasToken = false
    @State private var token = ""
    @State private var blocked = IntegrationPreferences.blockedSites
    @State private var newSite = ""
    @State private var cleared = false

    private var sessionsFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/BrowserSessions", isDirectory: true)
    }

    var body: some View {
        SettingsPage("Browser", subtitle: "How AIM's Agent browses the web.") {
            SettingsGroup {
                SettingsToggleRow("Browser for the Agent", description: "Let the Agent open and use web pages (each action asks for your approval).",
                                  isOn: Binding(get: { enabled }, set: { enabled = $0; IntegrationPreferences.browserEnabled = $0 }))
            }
            SettingsGroup("Which browser") {
                SettingsRow("Browser", description: mode == .extensionConnected
                            ? "Your Chrome, through the official Playwright extension: the Agent uses the tabs you share, already signed in."
                            : "A separate Chrome with a fresh profile for each task: nothing from your usual browser.") {
                    AIMSegmentedControl(selection: Binding(get: { mode }, set: { mode = $0; AgentBrowserPreferences.mode = $0 }),
                                        options: [(.extensionConnected, "Your Chrome"), (.isolated, "Isolated")], compact: true)
                }
                if mode == .extensionConnected {
                    SettingsRow("Extension token", description: hasToken ? "Saved in the Keychain." : "Paste the token shown by the Playwright MCP Bridge extension.") {
                        if hasToken {
                            SettingsStatus(text: "Connected")
                            Button("Remove") { try? AgentBrowserPreferences.removeExtensionToken(); hasToken = false }.buttonStyle(.settings)
                        } else {
                            SecureField("Token", text: $token).textFieldStyle(.settings).frame(width: 200)
                            Button("Save") {
                                if (try? AgentBrowserPreferences.saveExtensionToken(token)) != nil { hasToken = true; token = "" }
                            }.buttonStyle(.settings).disabled(token.isEmpty)
                        }
                    }
                }
            }
            SettingsGroup("Blocked sites", description: "The Agent never opens these sites (a domain also blocks its subdomains).") {
                ForEach(blocked, id: \.self) { site in
                    SettingsRow(site) {
                        SettingsIconButton(systemImage: "trash", destructive: true, help: "Unblock \(site)") {
                            blocked.removeAll { $0 == site }
                            IntegrationPreferences.blockedSites = blocked
                        }
                    }
                }
                SettingsRow("Block a site", description: blocked.isEmpty ? "No site is blocked." : nil) {
                    TextField("example.com", text: $newSite).textFieldStyle(.settings).frame(width: 200).onSubmit(addSite)
                    Button("Add") { addSite() }.buttonStyle(.settings).disabled(IntegrationPreferences.normalizedSite(newSite) == nil)
                }
            }
            SettingsGroup("Browsing records", description: "Isolated sessions keep a private record (pages, console) for your review; the ten most recent are kept.") {
                SettingsRow("Session records", description: cleared ? "Cleared." : nil) {
                    if let sessionsFolder {
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([sessionsFolder])
                        }.buttonStyle(.settings)
                        Button("Clear") {
                            try? FileManager.default.removeItem(at: sessionsFolder)
                            cleared = true
                        }.buttonStyle(.settingsDestructive)
                    }
                }
            }
        }
        .task { if mode == .extensionConnected { await loadToken() } }
    }

    private func loadToken() async {
        hasToken = await Task.detached(priority: .userInitiated) { AgentBrowserPreferences.hasExtensionToken }.value
    }

    private func addSite() {
        guard let site = IntegrationPreferences.normalizedSite(newSite) else { return }
        blocked = Array(Set(blocked + [site])).sorted()
        IntegrationPreferences.blockedSites = blocked
        newSite = ""
    }
}

// MARK: Hooks

struct HooksSettingsView: View {
    @State private var configuration = AgentHookRunner.readConfiguration()
    @State private var editing: HookDraft?
    @State private var error: String?

    struct HookDraft: Identifiable {
        let id = UUID()
        var index: Int?
        var event = "PreToolUse"
        var matcher = ""
        var command = ""
        var timeout = 30
    }

    var body: some View {
        SettingsPage("Hooks", subtitle: "Your commands, run at moments of an Agent task. Like Claude Code's: PreToolUse can block a call (exit code 2), PostToolUse adds its output to the result, SessionStart adds context, Stop runs when a turn ends.") {
            SettingsGroup("Your hooks", description: "Each receives a JSON description on standard input.") {
                if (configuration.hooks ?? []).isEmpty {
                    SettingsRow("No hooks", description: "Hooks you add appear here.")
                }
                ForEach(Array((configuration.hooks ?? []).enumerated()), id: \.offset) { index, hook in
                    SettingsRow(hook.event + (hook.matcher.map { " · \($0)" } ?? ""), description: hook.command) {
                        Button("Edit") {
                            editing = HookDraft(index: index, event: hook.event, matcher: hook.matcher ?? "", command: hook.command, timeout: hook.timeout ?? 30)
                        }.buttonStyle(.settings)
                        SettingsIconButton(systemImage: "trash", destructive: true, help: "Delete this hook") {
                            configuration.hooks?.remove(at: index)
                            save()
                        }
                    }
                }
                SettingsRow("Add a hook") {
                    Button("Add…") { editing = HookDraft() }.buttonStyle(.settings)
                    Button("Reload") { configuration = AgentHookRunner.readConfiguration() }.buttonStyle(.settings)
                }
            }
            SettingsGroup("Trusted projects", description: "A project's own .aim/hooks.json runs only if its folder is listed here, so a cloned repository cannot run commands silently.") {
                ForEach(configuration.trusted_projects ?? [], id: \.self) { path in
                    SettingsRow(GeneralSettingsView.abbreviated(path)) {
                        SettingsIconButton(systemImage: "trash", destructive: true, help: "Stop trusting this project") {
                            configuration.trusted_projects?.removeAll { $0 == path }
                            save()
                        }
                    }
                }
                SettingsRow("Trust a project folder") {
                    Button("Choose…") { trustProject() }.buttonStyle(.settings)
                }
            }
            if let error { SettingsBlock { SettingsNotice(error, tone: .error) } }
        }
        .sheet(item: $editing) { draft in
            HookEditor(draft: draft) { value in
                let hook = AgentHookRunner.Hook(event: value.event, matcher: value.matcher.isEmpty ? nil : value.matcher,
                                                command: value.command, timeout: value.timeout)
                var hooks = configuration.hooks ?? []
                if let index = value.index, hooks.indices.contains(index) { hooks[index] = hook } else { hooks.append(hook) }
                configuration.hooks = hooks
                save()
            }
        }
    }

    private func save() {
        do { try AgentHookRunner.writeConfiguration(configuration); error = nil }
        catch { self.error = "Could not save hooks.json: \(error.localizedDescription)" }
    }

    private func trustProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        configuration.trusted_projects = Array(Set((configuration.trusted_projects ?? []) + [path])).sorted()
        save()
    }
}

private struct HookEditor: View {
    @State var draft: HooksSettingsView.HookDraft
    let onSave: (HooksSettingsView.HookDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.index == nil ? "Add a hook" : "Edit hook").font(.system(size: 20, weight: .semibold))
            Picker("When", selection: $draft.event) {
                ForEach(AgentHookRunner.events, id: \.self) { Text($0).tag($0) }
            }
            if draft.event == "PreToolUse" || draft.event == "PostToolUse" {
                TextField("Tool name (optional, * wildcards, e.g. run_command or browser_*)", text: $draft.matcher).textFieldStyle(.settings)
            }
            TextField("Command (run with /bin/zsh)", text: $draft.command, axis: .vertical).textFieldStyle(.settings).lineLimit(2...5)
            Stepper("Timeout: \(draft.timeout) s", value: $draft.timeout, in: 1...600)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.settings).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft); dismiss() }.buttonStyle(.settingsPrimary)
                    .disabled(draft.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 520)
    }
}

// MARK: Git

struct GitSettingsView: View {
    @State private var prefix = IntegrationPreferences.branchPrefix
    @State private var template = IntegrationPreferences.commitTemplate

    var body: some View {
        SettingsPage("Git", subtitle: "How AIM names branches and prepares commits. AIM asks before every commit and push, and never force-pushes.") {
            SettingsGroup {
                SettingsRow("Branch prefix", description: IntegrationPreferences.validBranchPrefix(prefix)
                            ? "Used for new worktree branches and sub-agent branches (\(prefix)subagent-…)." : "Letters, digits, / - _ . only, without “..”.") {
                    TextField("aim/", text: $prefix).textFieldStyle(.settings).frame(width: 200)
                        .onChange(of: prefix) { _, value in if IntegrationPreferences.validBranchPrefix(value) { IntegrationPreferences.branchPrefix = value } }
                }
            }
            SettingsGroup("Commit message template", description: "Placed in the message field when you commit from AIM.") {
                SettingsBlock {
                    TextEditor(text: $template)
                        .font(.system(size: 13, design: .monospaced)).frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        .onChange(of: template) { _, value in IntegrationPreferences.commitTemplate = value }
                }
            }
        }
    }
}

// MARK: Worktrees

struct WorktreeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var root = IntegrationPreferences.worktreeRoot
    @State private var records: [SubagentWorkspaceRecord] = []
    @State private var error: String?
    @State private var jevKey = ""
    @State private var hasJevKey = false

    var body: some View {
        SettingsPage("Worktrees", subtitle: "Sub-agents that edit code work in their own Git worktree, merged back only after your review. AIM removes a worktree once its work is merged or discarded.") {
            SettingsGroup {
                SettingsRow("Worktree folder", description: "Where new sub-agent worktrees are created.") {
                    Text(GeneralSettingsView.abbreviated(root ?? SubagentWorkspaceService.builtInRoot.path))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .trailing)
                    if root != nil {
                        SettingsIconButton(systemImage: "arrow.uturn.backward", help: "Use AIM's folder") {
                            root = nil; IntegrationPreferences.worktreeRoot = nil
                        }
                    }
                    Button("Change") { chooseRoot() }.buttonStyle(.settings)
                }
            }
            SettingsGroup("Sub-agent model advisor") {
                SettingsRow("Jev ranking", description: hasJevKey
                    ? "Saved. When the agent asks which model a sub-agent should use, Jev (TypeSafe) ranks the connected candidates: about $0.04 per million input tokens, a fraction of a cent per request, billed to your TypeSafe account."
                    : "Without a key, candidates are chosen by price and task size on this Mac, with no model call. With a TypeSafe key, Jev ranks them; only the task and the candidate list are sent.") {
                    if hasJevKey {
                        Button("Remove") { do { try model.removeJevKey(); hasJevKey = false } catch { self.error = error.localizedDescription } }.buttonStyle(.settingsDestructive)
                    } else {
                        SecureField("TypeSafe API key", text: $jevKey).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                        Button("Save") {
                            do { try model.saveJevKey(jevKey); jevKey = ""; hasJevKey = true; error = nil } catch { self.error = "Enter a valid TypeSafe key." }
                        }.buttonStyle(.settings).disabled(jevKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            SettingsGroup("Worktrees") {
                if records.isEmpty { SettingsRow("No worktrees", description: "Worktrees created by AIM's sub-agents appear here.") }
                ForEach(records, id: \.jobID) { record in
                    let exists = FileManager.default.fileExists(atPath: record.worktreePath)
                    SettingsRow(record.title, description: "\(record.branch) · \(record.state.rawValue)\(exists ? "" : " · folder removed")") {
                        if exists {
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.worktreePath)]) }.buttonStyle(.settings)
                            if record.state != .active {
                                Button("Remove") { Task { await remove(record) } }.buttonStyle(.settingsDestructive)
                            }
                        }
                    }
                }
            }
            if let error { SettingsBlock { SettingsNotice(error, tone: .error) } }
        }
        .task { records = await model.subagentWorktrees(); hasJevKey = model.hasJevKey }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        root = path
        IntegrationPreferences.worktreeRoot = path
    }

    private func remove(_ record: SubagentWorkspaceRecord) async {
        do { try await model.removeSubagentWorktree(record); error = nil }
        catch { self.error = error.localizedDescription }
        records = await model.subagentWorktrees()
    }
}

// MARK: Archived chats

struct ArchivedChatsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportTarget: Conversation?
    @State private var deleting: Conversation?

    var body: some View {
        SettingsPage("Archived chats") {
            SettingsGroup {
                if model.archivedConversations.isEmpty {
                    SettingsRow("No archived conversations", description: "Conversations you archive appear here.")
                }
                ForEach(model.archivedConversations) { conversation in
                    SettingsRow(conversation.title, description: conversation.updatedAt.formatted(date: .abbreviated, time: .omitted)) {
                        Button("Export…") { exportTarget = conversation }.buttonStyle(.settings)
                            .disabled(model.isSending || model.responseSaveError != nil)
                        Button("Restore") { Task { await model.setArchived(conversation.id, false) } }.buttonStyle(.settings)
                        SettingsIconButton(systemImage: "trash", destructive: true, help: "Delete permanently") { deleting = conversation }
                    }
                }
            }
        }
        .task { await model.loadArchives() }
        .sheet(item: $exportTarget) { ConversationExportView(conversation: $0) }
        .confirmationDialog("Delete this conversation permanently?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { Task { await model.deleteConversation(deleting.id); await model.loadArchives() } }
            }
        } message: { Text("This cannot be undone.") }
    }
}
