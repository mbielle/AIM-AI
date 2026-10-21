import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, notifications, importData = "import", profile, appearance, voice, configuration, personalization
    case shortcuts = "keyboard shortcuts", usage = "usage & costs", account
    case providers, localModels = "local models"
    case connectors, skills, computerUse = "computer use", browser, remote, automations
    case hooks, git, worktrees
    case permissions, privacy, updates, about
    case archived = "archived chats"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .importData: "Import"
        case .usage: "Usage & costs"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    enum Group: String, CaseIterable {
        case personal = "Personal", models = "Models", integrations = "Integrations", coding = "Coding"
        case system = "System", archived = "Archived"
    }

    var group: Group {
        switch self {
        case .general, .notifications, .importData, .profile, .appearance, .voice, .configuration, .personalization,
             .shortcuts, .usage, .account: .personal
        case .providers, .localModels: .models
        case .connectors, .skills, .computerUse, .browser, .remote, .automations: .integrations
        case .hooks, .git, .worktrees: .coding
        case .permissions, .privacy, .updates, .about: .system
        case .archived: .archived
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .importData: "square.and.arrow.down"
        case .profile: "person.crop.circle"
        case .appearance: "sun.max"
        case .voice: "mic"
        case .configuration: "slider.horizontal.below.square.filled.and.square"
        case .personalization: "brain.head.profile"
        case .shortcuts: "command.square"
        case .usage: "gauge.with.dots.needle.33percent"
        case .account: "person.badge.key"
        case .providers: "key"
        case .localModels: "desktopcomputer"
        case .connectors: "puzzlepiece.extension"
        case .skills: "book.pages"
        case .computerUse: "cursorarrow.rays"
        case .browser: "safari"
        case .remote: "iphone.radiowaves.left.and.right"
        case .automations: "clock.arrow.circlepath"
        case .hooks: "point.3.connected.trianglepath.dotted"
        case .git: "arrow.triangle.branch"
        case .worktrees: "square.stack.3d.down.right"
        case .permissions: "hand.raised"
        case .privacy: "lock.shield"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        case .archived: "archivebox"
        }
    }

    /// Extra words the sidebar search matches, so “OpenAI” finds Providers.
    var keywords: String {
        switch self {
        case .general: "launch login language menu bar sleep close window folder default permissions full access licenses open source composer send enter steer queue follow-up context punctuation quick chat hotkey"
        case .notifications: "alert sound banner completion approval question automation remote limit"
        case .importData: "claude code codex cursor chatgpt export conversations mcp skills instructions"
        case .profile: "name statistics"
        case .appearance: "theme dark light mode font text size accent color code reduce motion sidebar translucent width cursor"
        case .voice: "speech realtime tts read aloud elevenlabs dictation whisper parakeet language"
        case .configuration: "default model reasoning effort approval web search mode agent code chat backup fallback"
        case .personalization: "instructions preferences custom memory remember facts agents.md"
        case .shortcuts: "keyboard hotkey shortcut command"
        case .usage: "billing spend cost budget limit credits chatgpt plan openrouter"
        case .account: "sign in sign out email password google"
        case .providers: "api key openrouter openai anthropic gemini deepseek xai grok perplexity chatgpt mistral groq"
        case .localModels: "ollama lm studio mlx hugging face offline"
        case .connectors: "mcp server oauth tools plugins"
        case .skills: "learned procedures github plugins"
        case .computerUse: "apps control accessibility allowed apps"
        case .browser: "playwright chrome sites permissions downloads browsing data"
        case .remote: "iphone phone pairing qr code devices"
        case .automations: "scheduled tasks cron webhook trigger"
        case .hooks: "lifecycle hooks commands pre post tool"
        case .git: "branch prefix commit message template"
        case .worktrees: "worktree subagent delete"
        case .permissions: "accessibility screen recording microphone camera always allow approvals sub-agent command"
        case .privacy: "activity journal diagnostics history"
        case .updates: "version upgrade"
        case .about: "version"
        case .archived: "archive restore conversations chats"
        }
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query) || keywords.localizedCaseInsensitiveContains(query)
    }
}

struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.settingsSection = nil } label: {
                Label("Back to \(model.mode == .code ? "Code" : "Chat")", systemImage: "chevron.left")
                    .font(.system(size: 13))
                    .padding(.horizontal, 6).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(TextLinkStyle()).padding(.top, 10)
            Text("Settings").font(.system(size: 22, weight: .semibold)).padding(.top, 14).padding(.horizontal, 6)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
                TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 14)).focusEffectDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.Group.allCases, id: \.self) { group in
                        let sections = SettingsSection.allCases.filter { $0.group == group && $0.matches(query) }
                        if !sections.isEmpty {
                            Text(group.rawValue).font(.system(size: 13)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 6)
                            ForEach(sections) { section in row(section) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            UserProfileMenu()
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func row(_ section: SettingsSection) -> some View {
        let selected = model.settingsSection == section
        return Button { model.settingsSection = section } label: {
            HStack(spacing: 11) {
                Image(systemName: section.icon).font(.system(size: 14)).frame(width: 18)
                Text(section.title).font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(selected ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsDetailView: View {
    let section: SettingsSection
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            switch section {
            case .general: GeneralSettingsView()
            case .notifications: NotificationSettingsView()
            case .importData: ImportSettingsView()
            case .profile: ProfileView()
            case .appearance: AppearanceSettingsView()
            case .voice: VoiceSettingsView()
            case .configuration: ConfigurationSettingsView()
            case .personalization: PersonalizationSettingsView()
            case .shortcuts: ShortcutSettingsView()
            case .usage: ConsumptionSettingsView()
            case .account: AccountSettingsView()
            case .providers: ProvidersSettingsView()
            case .localModels: LocalModelsSettingsView()
            case .connectors: ConnectorsSettingsView()
            case .skills: SkillsSettingsView()
            case .computerUse: ComputerUseSettingsView()
            case .browser: BrowserSettingsView()
            case .remote: RemoteSettingsView()
            case .automations: AutomationsSettingsView()
            case .hooks: HooksSettingsView()
            case .git: GitSettingsView()
            case .worktrees: WorktreeSettingsView()
            case .permissions: PermissionSettingsView()
            case .privacy: PrivacySettingsView()
            case .updates: UpdateSettingsView()
            case .about: AboutSettingsView()
            case .archived: ArchivedChatsSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(section)
        .task { await model.refreshPermissions() }
    }
}

struct UserProfileMenu: View {
    @Environment(AppModel.self) private var model
    @State private var showingMenu = false
    private var user: AuthenticatedUserSummary { AuthenticatedUserSummary(model.account.accessUser) }
    var body: some View {
        Button { showingMenu.toggle() } label: {
            HStack(spacing: 10) {
                AccountAvatar(initial: user.initial, size: 30)
                Text(user.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.aimHover(radius: 10, active: showingMenu))
        .accessibilityLabel("User profile and settings").accessibilityIdentifier("user-profile-menu")
        #if DEBUG
        .onChange(of: model.debugOpenMenu) { _, menu in showingMenu = menu == "profile" }
        #endif
        .aimMenu(isPresented: $showingMenu) {
            if let email = model.account.accessUser?.email { AIMMenuSection(email) }
            AIMMenuItem("My profile", icon: "person.crop.circle") { model.settingsSection = .profile }
            AIMMenuItem("Settings", icon: "gearshape", shortcut: "⌘,") { model.settingsSection = .general }
            AIMMenuItem("AI providers", icon: "key") { model.settingsSection = .providers }
            AIMMenuItem("Archived conversations", icon: "archivebox") { model.settingsSection = .archived }
            AIMMenuDivider()
            if model.account.accessUser != nil {
                AIMMenuItem("Sign out", icon: "rectangle.portrait.and.arrow.right") { Task { await model.account.signOut() } }
                    .disabled(model.account.isBusy)
            } else {
                AIMMenuItem("Account…", icon: "person.crop.circle") { model.settingsSection = .account }
            }
        }
    }
}

/// Display values for the signed-in account (falls back to the Mac user's name).
struct AuthenticatedUserSummary {
    let name: String
    let email: String?
    /// Debug gallery: a fictitious profile, so no real person's name appears in its captures.
    @MainActor static var galleryProfile: String?

    @MainActor init(_ user: AuthenticatedUser?) {
        if let gallery = Self.galleryProfile { name = gallery; email = nil; return }
        let fullName = user?.fullName?.trimmingCharacters(in: .whitespaces)
        email = user?.email
        if let fullName, !fullName.isEmpty { name = fullName }
        else if let email = user?.email { name = String(email.split(separator: "@").first ?? Substring(email)) }
        else { name = NSFullUserName() }
    }

    var initial: String { String(name.prefix(1)).uppercased() }
}

struct AccountAvatar: View {
    let initial: String
    var size: CGFloat = 32

    var body: some View {
        Text(initial).font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.36, green: 0.40, blue: 0.48), Color(red: 0.22, green: 0.25, blue: 0.31)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Light, dark or following the system, applied to every AIM window.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    static let storageKey = "aim.appearance.mode"

    static var current: AppearanceMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    @MainActor
    static func apply(_ mode: AppearanceMode = current) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppearanceMode.storageKey) private var mode = AppearanceMode.system.rawValue
    private var appearance: ConversationAppearance { model.settings.conversationAppearance ?? .init() }

    private func pref<Value: Equatable>(_ path: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] }, set: { value in model.updatePreferences { $0[keyPath: path] = value } })
    }

    var body: some View {
        SettingsPage("Appearance") {
            SettingsGroup("Visual style") {
                SettingsRow("Mode", description: "Follow macOS, or keep AIM light or dark.") {
                    HStack(spacing: 10) {
                        ForEach(AppearanceMode.allCases, id: \.self) { item in
                            AppearanceTile(mode: item, selected: mode == item.rawValue) {
                                mode = item.rawValue
                                AppearanceMode.apply(item)
                            }
                        }
                    }
                }
            }
            SettingsGroup("Conversation text", footer: "Applies to messages in Chat, Code and Agent, including headings, code and tables. Menus and the composer keep their compact sizing.") {
                SettingsMenuRow("Font", selection: Binding(
                    get: { appearance.typeface },
                    set: { model.setConversationAppearance(.init(typeface: $0, textSize: appearance.textSize)) }
                ), options: [(.lora, "Lora · AIM identity"), (.system, "System · Sans serif")])
                SettingsMenuRow("Text size", selection: Binding(
                    get: { appearance.textSize },
                    set: { model.setConversationAppearance(.init(typeface: appearance.typeface, textSize: $0)) }
                ), options: (12...24).map { ($0, "\($0) pt") })
                SettingsBlock {
                    Text("Preview").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    NativeMarkdownView(source: "### A comfortable reading space\nYour conversations, at the size you prefer.\n\n```swift\nlet message = \"Hello, AIM\"\n```", appearance: appearance)
                }
                SettingsRow("Reset text appearance", description: "Back to Lora at 15 pt.") {
                    Button("Reset") { model.setConversationAppearance(.init()) }.buttonStyle(.settings)
                        .disabled(appearance == .init())
                }
            }
            SettingsGroup("Code") {
                SettingsMenuRow("Code font", selection: pref(\.codeFont),
                                options: [(.system, "SF Mono · System"), (.menlo, "Menlo"), (.monaco, "Monaco"), (.courier, "Courier New")])
                SettingsMenuRow("Code size", description: "In code blocks of answers.",
                                selection: Binding(get: { model.preferences.codeSize ?? 0 }, set: { value in model.updatePreferences { $0.codeSize = value == 0 ? nil : value } }),
                                options: [(0, "Match text (\(appearance.codeSize) pt)")] + (10...20).map { ($0, "\($0) pt") })
            }
            SettingsGroup("Interface") {
                SettingsRow("Accent", description: "Switches, selections and highlights.") {
                    HStack(spacing: 8) {
                        ForEach(AppPreferences.Accent.allCases, id: \.self) { accent in
                            Button { model.updatePreferences { $0.accent = accent } } label: {
                                Circle().fill(AppearancePreferences.color(accent)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(model.preferences.accent == accent ? 0.6 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain).aimTooltip(accent.rawValue.capitalized)
                            .accessibilityLabel(accent.rawValue.capitalized).accessibilityAddTraits(model.preferences.accent == accent ? .isSelected : [])
                        }
                    }
                }
                SettingsRow("Reduce motion", description: "Turn off AIM's animations, or follow macOS.") {
                    AIMSegmentedControl(selection: pref(\.reduceMotion), options: [(.system, "System"), (.on, "On"), (.off, "Off")], compact: true)
                }
                SettingsToggleRow("Translucent sidebar", description: "Let the desktop show through the sidebar, like Finder.", isOn: pref(\.translucentSidebar))
                SettingsToggleRow("Full-width conversations", description: "Use the whole width of the window for messages.", isOn: pref(\.fullWidthConversations))
                SettingsToggleRow("Pointer cursors", description: "Show a pointing hand over buttons and links.", isOn: pref(\.pointerCursors))
            }
        }
    }
}

private struct AppearanceTile: View {
    let mode: AppearanceMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                thumbnail.frame(width: 96, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? AIMTheme.toggleOn : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                Text(mode.rawValue.capitalized).font(.system(size: 12)).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.rawValue.capitalized) mode").accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var thumbnail: some View {
        switch mode {
        case .light: page(dark: false)
        case .dark: page(dark: true)
        case .system: HStack(spacing: 0) { page(dark: false); page(dark: true) }
        }
    }

    private func page(dark: Bool) -> some View {
        let background = dark ? Color(white: 0.11) : Color(white: 0.98)
        let line = dark ? Color.white.opacity(0.28) : Color.black.opacity(0.16)
        return ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 5) {
                Circle().fill(line).frame(width: 6, height: 6)
                Capsule().fill(line).frame(width: 34, height: 3)
                Capsule().fill(AIMTheme.toggleOn.opacity(0.8)).frame(width: 24, height: 3)
                Capsule().fill(line).frame(width: 28, height: 3)
            }.padding(8)
        }
    }
}

private struct PermissionSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var alwaysAllowed = AlwaysAllowedActions.all()

    var body: some View {
        SettingsPage("Permissions", subtitle: "macOS asks for each permission only when a feature needs it.") {
            SettingsGroup("Agent") {
                SettingsRow("Computer Use", description: "Review Accessibility, selected-window screenshots and the current browser-connection status.") {
                    Button("Set up…") { openWindow(id: "computer-use") }.buttonStyle(.settings)
                }
            }
            SettingsGroup("Always allowed", footer: "Actions you chose “Always allow” for run without asking in every conversation. Actions that need a review each time (deletions, private data, risky commands) are still asked. The spending limit always applies.") {
                if alwaysAllowed.isEmpty {
                    SettingsRow("None yet", description: "Choose “Always allow” on a permission card to add an action type here.") { EmptyView() }
                }
                ForEach(alwaysAllowed, id: \.key) { category in
                    SettingsRow(category.title, description: "Always allow " + category.scope + ".") {
                        Button("Revoke") {
                            AlwaysAllowedActions.remove(key: category.key)
                            alwaysAllowed = AlwaysAllowedActions.all()
                        }
                        .buttonStyle(.settings)
                        .accessibilityIdentifier("revoke-always-\(category.key)")
                    }
                }
            }
            SettingsGroup("macOS permissions") {
                ForEach(MacPermissionKind.allCases) { kind in
                    SettingsRow(title(kind), description: reason(kind)) {
                        let granted = model.permissionStates[kind] == .granted
                        SettingsStatus(text: model.permissionStates[kind]?.rawValue.capitalized ?? "Unknown", color: granted ? .green : .orange)
                        if !granted {
                            Button("Request") { Task { await model.requestPermission(kind) } }.buttonStyle(.settings)
                        }
                    }
                }
            }
        }
    }

    private func title(_ kind: MacPermissionKind) -> String {
        switch kind { case .accessibility: "Accessibility"; case .screenRecording: "Screen Recording"; case .microphone: "Microphone"; case .speechRecognition: "Speech Recognition"; case .camera: "Camera" }
    }
    private func reason(_ kind: MacPermissionKind) -> String {
        switch kind {
        case .accessibility: "Read and control approved app interfaces."
        case .screenRecording: "Capture a selected window for visual tools."
        case .microphone: "Record voice prompts and transcription."
        case .speechRecognition: "Transcribe voice prompts on this Mac."
        case .camera: "Attach a photo from the Mac camera."
        }
    }
}

private struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showClearConfirmation = false
    @State private var excludedApps = ""
    @State private var excludedDomains = ""
    @AppStorage("AIMLocalActivitySuggestionsEnabled", store: AIMInstallationContext.sharedPreferences) private var suggestionsEnabled = false
    @AppStorage(RuntimePrivacyPolicy.defaultsKey, store: AIMInstallationContext.sharedPreferences) private var privateMode = false

    var body: some View {
        SettingsPage("Privacy") {
            SettingsGroup("Activity journal", footer: "This local journal records the foreground application and, when Accessibility is already allowed, the focused window title and document reference. Browser sessions remain excluded while private-mode detection is unverified.") {
                SettingsToggleRow("Enable local activity journal", description: "Lets AIM answer questions about what you worked on.", isOn: Binding(
                    get: { model.settings.activity.isEnabled },
                    set: { enabled in
                        var updated = model.settings.activity
                        updated.isEnabled = enabled
                        model.setActivitySettings(updated)
                    }
                ))
                SettingsMenuRow("Keep history for", selection: Binding(
                    get: { model.settings.activity.retentionDays },
                    set: { days in
                        var updated = model.settings.activity
                        updated.retentionDays = days
                        model.setActivitySettings(updated)
                    }
                ), options: Array(Set([1, 3, 7, 14, 30, model.settings.activity.retentionDays])).sorted()
                    .map { ($0, $0 == 1 ? "1 day" : "\($0) days") })
            }
            SettingsGroup("Activity exclusions", footer: "New exclusions apply to future recording and to reads of existing history. Use Clear to remove saved history.") {
                SettingsRow("Applications", description: "Names or name fragments, comma separated") { TextField("Excluded applications", text: $excludedApps).frame(width: 260) }
                SettingsRow("Domains", description: "Exact domains and their subdomains, comma separated") { TextField("Excluded domains", text: $excludedDomains).frame(width: 260) }
                SettingsRow("Save exclusions") {
                    Button("Apply") {
                        var updated = model.settings.activity
                        updated.excludedApplications = values(excludedApps)
                        updated.excludedDomains = values(excludedDomains)
                        model.setActivitySettings(updated)
                    }.buttonStyle(.settings)
                }
            }
            SettingsGroup("Local activity suggestions", footer: "Proposals use saved history, require your review, and make no model request. Preparing a draft does not start an agent.") {
                SettingsToggleRow("Show suggestions", isOn: $suggestionsEnabled)
                if suggestionsEnabled && !privateMode {
                    ForEach(ActivitySuggestion.proposals(entries: model.activityEntries, settings: model.settings.activity)) { suggestion in
                        SettingsRow(suggestion.title.isEmpty ? suggestion.application : suggestion.title,
                            description: "Sources: " + suggestion.sourceIDs.map(String.init).joined(separator: ", ") + " · " + suggestion.endedAt.formatted(date: .abbreviated, time: .shortened)) {
                            Button("Prepare draft") { model.prepareActivitySuggestion(suggestion) }.buttonStyle(.settings)
                        }
                    }
                }
            }
            SettingsGroup("Recent activity") {
                if let error = model.activityError { SettingsBlock { SettingsNotice(error, tone: .error) } }
                if model.activityEntries.isEmpty {
                    SettingsRow("No saved activity", description: "Nothing in the last 200 entries.")
                } else {
                    ForEach(model.activityEntries.prefix(12)) { entry in
                        SettingsRow(entry.application, description: entry.title.isEmpty ? entry.url : entry.title) {
                            Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsRow("Manage history", description: model.activityEntries.isEmpty ? nil : "\(model.activityEntries.count) saved entries.") {
                    Button("Refresh") { Task { await model.loadActivityEntries() } }.buttonStyle(.settings)
                    Button("Clear…") { showClearConfirmation = true }.buttonStyle(.settingsDestructive)
                        .disabled(model.activityEntries.isEmpty)
                }
            }
            SettingsGroup("Diagnostics") {
                SettingsRow("Logs stay on this Mac", description: "AIM keeps its diagnostic logs locally.")
                SettingsRow("Reports need your confirmation", description: "A report is sent only after you preview and confirm it.")
            }
        }
        .task {
            excludedApps = model.settings.activity.excludedApplications.joined(separator: ", ")
            excludedDomains = model.settings.activity.excludedDomains.joined(separator: ", ")
            await model.loadActivityEntries()
        }
        .confirmationDialog("Delete all local activity history?", isPresented: $showClearConfirmation) {
            Button("Delete history", role: .destructive) { Task { await model.clearActivityEntries() } }
        } message: {
            Text("This cannot be undone. Future app activity will still be recorded if the journal stays enabled.")
        }
    }
    private func values(_ text: String) -> [String] {
        Array(Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }
}

private struct UpdateSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsPage("Updates") {
            SettingsGroup {
                SettingsRow("Automatic updates", description: "Signed updates download in the background. AIM asks before restarting and never interrupts an active task.") {
                    Button("Check for Updates…") { model.checkForUpdates() }.buttonStyle(.settings)
                        .disabled(!model.updateController.canCheckForUpdates)
                }
                SettingsRow("Installed version") {
                    Text(AboutSettingsView.version).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
}

private struct AboutSettingsView: View {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        SettingsPage("About") {
            SettingsGroup {
                SettingsRow(title: "AIM AI", description: "Your AI workspace for Mac: chat, code and an agent that works in your apps.",
                            leading: { AIMLogoView(size: 44) }) { EmptyView() }
                SettingsRow("Version") {
                    Text(Self.version).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                SettingsRow("Requirements") {
                    Text("Apple Silicon · macOS 14 or later").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
