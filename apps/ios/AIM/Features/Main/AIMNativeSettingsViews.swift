import AIMCore
import AuthenticationServices
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct AIMSettingsPageHeader: View {
    let title: String
    let back: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).aimGlassCircle()
            }.buttonStyle(.plain).accessibilityLabel("Back").accessibilityIdentifier("settings-page-back")
            Spacer(minLength: 8)
            Text(title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.7).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)

                .accessibilityIdentifier("settings-page-title")
            Spacer(minLength: 8)
            Color.clear.frame(width: 44, height: 44)
        }.padding(12).aimSettingsHeader().foregroundStyle(.primary).font(.system(.body))
    }
}

struct AIMAppSecuritySettingsView: View {
    let lock: AppLockService
    let remote: MainExperienceStore
    @State private var migrationError: String?
    @State private var migrating = false
    let sessions: (any AccountSessionServicing)?
    let signOut: () -> Void
    let back: () -> Void
    let openSessions: () -> Void
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Security & login", back: back)
            AIMSettingsForm {
                Section {
                    Toggle("Require Face ID", isOn: Binding(get: { lock.isRequired }, set: { value in Task { await lock.setRequired(value) } }))
                        .tint(.green).disabled(lock.isAuthenticating).accessibilityIdentifier("settings-require-face-id")
                } footer: { Text("Face ID or iPhone passcode. Locks after one minute outside AIM.") }
                if let error = lock.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                Section("Sessions") {
                    Button { openSessions() } label: { HStack { Text("Active sessions"); Spacer(); Image(systemName: "chevron.right") } }
                }
                if remote.deviceAuthorizationState?.version != 2 {
                    Section("Remote authorization") {
                        Text(remote.remoteSecurityError ?? "Checking this iPhone’s authorization. Pairing, keys and history are kept.").font(.footnote).foregroundStyle(.secondary)
                        if remote.remoteSecurityDiagnosticCode == "fresh_sign_in_required" {
                            Button("Sign in again", action: signOut)
                        } else {
                            Button("Retry authorization") { Task { await remote.loadRemoteSecurity() } }
                                .disabled(remote.isLoadingRemoteSecurity)
                        }
                        if let migrationError { Text(migrationError).foregroundStyle(.red).font(.footnote) }
                    }
                }
                if lock.isRequired { Button("Lock now") { lock.lock() } }
            }.scrollContentBackground(.hidden)
        }

    }
}

struct AIMAccountSessionsView: View {
    let service: (any AccountSessionServicing)?
    let signOut: () -> Void
    let back: () -> Void
    @State private var sessions: [AccountSession] = []
    @State private var loading = false
    @State private var error: String?
    @State private var revocation: Revocation?
    private struct Revocation: Identifiable { let id = UUID(); let scope: SessionRevocationScope }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Active sessions", back: back)
            AIMSettingsForm {
                Text("Devices and account sessions. Activity is reported by the account service; location and trust are not inferred.").font(.footnote).foregroundStyle(.secondary)
                if loading { ProgressView() }
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.device).font(.headline)
                        Text(session.platform).font(.subheadline).foregroundStyle(.secondary)
                        if let date = session.lastActiveAt { Text(date, style: .relative).font(.caption) }
                        if session.isCurrent { Text("Current session").font(.caption).foregroundStyle(.secondary) }
                        if session.revokedAt != nil {
                            Text(session.stopState == "confirmed" ? "Tasks stopped" : "Stop requested").font(.caption).foregroundStyle(.orange)
                        } else {
                            Button("Disconnect", role: .destructive) { revocation = .init(scope: .session(session.id)) }.disabled(loading)
                        }
                    }.padding(.vertical, 5)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Section {
                    Button("Disconnect other sessions", role: .destructive) { revocation = .init(scope: .others) }
                    Button("Disconnect all sessions", role: .destructive) { revocation = .init(scope: .all) }
                }.disabled(loading || sessions.isEmpty)
            }
                .refreshable { await load() }
        }.task { await load() }
        .alert("Disconnect sessions?", isPresented: Binding(get: { revocation != nil }, set: { if !$0 { revocation = nil } })) {
            Button("Cancel", role: .cancel) { revocation = nil }
            Button("Disconnect", role: .destructive) {
                guard let scope = revocation?.scope else { return }; revocation = nil
                Task { await revoke(scope) }
            }
        } message: { Text("New account access is blocked immediately. Running tasks show Stop requested until their Mac confirms they have stopped.") }
    }
    private func load() async {
        guard let service else { error = AccountServiceError.updateRequired.localizedDescription; return }
        loading = true; defer { loading = false }
        do { sessions = try await service.sessions(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func revoke(_ scope: SessionRevocationScope) async {
        guard let service else { return }; loading = true
        do {
            let receipt = try await service.revoke(scope)
            if receipt.currentRevoked { back(); signOut() } else { await load() }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct AIMProvidersSettingsView: View {
    let chat: NativeChatStore
    var openBFL: () -> Void = {}
    let openProvider: (ChatProvider) -> Void
    let back: () -> Void
    @State private var connecting = false
    @State private var web = ASWebAuthenticationSessionClient()
    @State private var oauthError: String?
    @State private var oauthStatus: String?
    private var providers: [ChatProvider] { ChatProvider.allCases.filter { $0 != .local && $0 != .chatgpt } }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Providers", back: back)
            AIMSettingsForm {
                Section {
                    Button { Task { await connectOpenRouter() } } label: {
                        HStack(spacing: 12) {
                            AIMModelLogo(modelID: "", provider: "openrouter", displayName: "OpenRouter", size: 32)
                            Text("Sign in with OpenRouter"); Spacer()
                            if connecting { ProgressView() } else { Image(systemName: "chevron.right") }
                        }.foregroundStyle(.primary).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(connecting)
                        .accessibilityIdentifier("provider-openrouter-sign-in")
                    if let oauthStatus {
                        Text(oauthStatus).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("provider-openrouter-status")
                    }
                    if let oauthError {
                        Text(oauthError).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("provider-openrouter-error")
                    }
                    HStack(spacing: 12) {
                        AIMModelLogo(modelID: "", provider: "openai", displayName: "ChatGPT", size: 32)
                        Text("ChatGPT"); Spacer(); Text("Not available yet").font(.footnote).foregroundStyle(.secondary)
                    }.frame(minHeight: 40)
                } header: { Text("Accounts") } footer: { Text("ChatGPT plan access requires OpenAI approval.") }
                if !chat.connectedProviders.isEmpty {
                    Section("Connected providers") {
                        ForEach(providers.filter { chat.connectedProviders.contains($0) }) { provider in providerRow(provider) }
                    }
                }
                Section {
                    ForEach(providers.filter { !chat.connectedProviders.contains($0) }) { provider in providerRow(provider) }
                    Button(action: openBFL) {
                        HStack(spacing: 12) {
                            AIMBrandLogo(identity: "black-forest-labs", size: 32)
                            Text("Black Forest Labs")
                            Spacer()
                            if chat.bflConnected { Text("Connected").font(.footnote).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.foregroundStyle(.primary).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("provider-blackForestLabs-row")
                } header: { Text("API keys") } footer: { Text("Keys stay in this iPhone’s Keychain.") }
            }
        }.webAuthenticationPresentationAnchor(web)
    }
    private func providerRow(_ provider: ChatProvider) -> some View {
        Button { openProvider(provider) } label: {
            HStack(spacing: 12) {
                AIMModelLogo(modelID: "", provider: provider.rawValue, displayName: provider.name, size: 32)
                Text(provider.name); Spacer(); Image(systemName: "chevron.right")
            }.foregroundStyle(.primary).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("provider-\(provider.rawValue)-row")
    }
    private func connectOpenRouter() async {
        guard !connecting else { return }
        connecting = true; oauthError = nil; oauthStatus = "Opening OpenRouter sign-in…"
        defer { connecting = false }
        do {
            // Requires this installation's Associated Domains entitlement and the published AASA route.
            guard #available(iOS 17.4, *) else { throw AccountServiceError.updateRequired }
            let flow = try OpenRouterPKCE(callbackURL: URL(string: "https://aim-ai.tech/auth/openrouter/ios")!)
            let callback = try await web.authenticateHTTPS(at: flow.authorizationURL, host: "aim-ai.tech", path: "/auth/openrouter/ios")
            let request: URLRequest
            do { request = try flow.exchangeRequest(callback: callback) }
            catch { throw WebAuthenticationError.missingCallback }
            oauthStatus = "Completing OpenRouter sign-in…"
            let (data, response) = try await NativeChatTransport.secretSession().data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = root["key"] as? String, !key.isEmpty else {
                oauthStatus = nil
                oauthError = "OpenRouter could not complete sign-in. Please try connecting again."
                return
            }
            oauthStatus = "Checking this iPhone’s OpenRouter connection…"
            if await chat.saveKey(key, provider: .openRouter) {
                oauthStatus = "OpenRouter connected on this iPhone."
            } else {
                oauthStatus = nil
                oauthError = chat.errorMessage ?? "OpenRouter sign-in finished, but this iPhone could not save and validate the connection. Please try again."
            }
        } catch WebAuthenticationError.cancelled {
            oauthStatus = "Sign-in cancelled. You can try again."
        } catch {
            oauthStatus = nil
            oauthError = error is URLError
                ? "The connection to OpenRouter was interrupted. Please start sign-in again."
                : error.localizedDescription
        }
    }
}

private struct AIMProfileArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ChatServiceError.invalidResponse }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct AIMImportSettingsView: View {
    let chat: NativeChatStore
    let identity: AppIdentity
    let back: () -> Void
    @State private var choosing = false
    @State private var preview: AIMProfileArchive?
    @State private var conversationIDs: Set<UUID> = []
    @State private var projectIDs: Set<UUID> = []
    @State private var exportConversationIDs: Set<UUID> = []
    @State private var exportProjectIDs: Set<UUID> = []
    @State private var exportDocument: AIMProfileArchiveDocument?
    @State private var exporting = false
    @State private var confirming = false
    @State private var error: String?
    @State private var result: String?
    private var selected: AIMProfileArchive? { try? preview?.selecting(conversationIDs: conversationIDs, projectIDs: projectIDs) }
    private var destination: String { identity.isLocal ? "this local profile" : (identity.accountEmail ?? "this signed-in account") }
    private var hasExportSelection: Bool { !exportConversationIDs.isEmpty || !exportProjectIDs.isEmpty }
    private var exportMessages: [NativeChatMessage] { chat.conversations.filter { exportConversationIDs.contains($0.id) }.flatMap(\.messages) }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Copy profile data", back: back)
            AIMSettingsForm {
                Section {
                    Text("Destination: \(destination)")
                    Text("Export selected data from the local profile, then sign in and choose that file here. Review and confirm the copy before any imported data can sync. Originals and existing destination conversations stay intact.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Export from this profile") {
                    DisclosureGroup("Choose conversations · \(exportConversationIDs.count) selected") {
                        ForEach(chat.conversations) { item in selection(item.title, id: item.id, values: $exportConversationIDs) }
                    }
                    DisclosureGroup("Choose projects · \(exportProjectIDs.count) selected") {
                        ForEach(chat.projects) { item in selection(item.name, id: item.id, values: $exportProjectIDs) }
                    }
                    Text("\(exportConversationIDs.count) conversations · \(exportProjectIDs.count) projects · \(exportMessages.count) messages · \(exportMessages.reduce(0) { $0 + ($1.attachments?.count ?? 0) }) retained attachments").font(.footnote)
                    Button("Save selected copy to Files") { prepareExport() }.disabled(!hasExportSelection)
                        .accessibilityIdentifier("profile-copy-export")
                    Text("Copies include message text, inline images, document text and prepared video frames/transcripts. Original video files, generated media, tool actions, activity, memories, preferences and provider credentials are excluded. Select related projects to retain conversation grouping.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Import a reviewed copy") {
                    Button("Choose file") { choosing = true }
                        .accessibilityIdentifier("profile-copy-choose-file")
                    Text("AIM profile-copy JSON, or text exports from AIM, ChatGPT and Claude. Maximum 32 MB.").font(.footnote).foregroundStyle(.secondary)
                }
                if let preview {
                    Section("Document preview") {
                        Text("\(preview.conversations.count) conversations · \(preview.projects.count) projects · \(preview.messageCount) messages · \(preview.attachmentCount) retained attachments")
                        if preview.omittedMediaReferences > 0 || preview.omittedActions > 0 {
                            Text("Excluded from the source export: \(preview.omittedMediaReferences) generated media references and \(preview.omittedActions) tool actions.").font(.footnote)
                        }
                        Button("Select all content in this document") {
                            conversationIDs = Set(preview.conversations.map(\.id)); projectIDs = Set(preview.projects.map(\.id))
                        }
                        ForEach(preview.projects) { item in selection("Project: " + item.name, id: item.id, values: $projectIDs) }
                        ForEach(preview.conversations) { item in selection(item.title + " · \(item.messages.count) messages", id: item.id, values: $conversationIDs) }
                    }
                    if let selected {
                        Section("Selected copy") {
                            Text("\(selected.conversations.count) conversations · \(selected.projects.count) projects · \(selected.messageCount) messages · \(selected.attachmentCount) attachments")
                            Text("Each copy gets new IDs. Existing destination data is never merged or overwritten. Conversations whose projects are not selected become ungrouped. No task is resumed and no model is called.").font(.footnote).foregroundStyle(.secondary)
                            Button(identity.isLocal ? "Review local copy" : "Review copy to account") { confirming = true }
                                .disabled(selected.conversations.isEmpty && selected.projects.isEmpty)
                                .accessibilityIdentifier("profile-copy-review-import")
                            Button("Cancel import", role: .cancel) { clearPreview() }
                        }
                    }
                }
                if let result { Text(result).accessibilityIdentifier("profile-copy-result") }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("profile-copy-error") }
            }.scrollContentBackground(.hidden)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.json]) { outcome in
            do {
                let url = try outcome.get(); let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= AIMProfileArchive.maximumBytes else { throw NativeDocumentError.limit }
                preview = try AIMProfileArchive.decode(Data(contentsOf: url)); conversationIDs = []; projectIDs = []
                error = nil; result = nil
            } catch { self.error = error.localizedDescription; clearPreview() }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "AIM-profile-copy") { outcome in
            switch outcome {
            case .success: result = "Copy saved. Sign in to the destination account and import this file after reviewing it. Source data is unchanged."
            case let .failure(error): self.error = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert("Copy selected data?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button(identity.isLocal ? "Copy to local profile" : "Copy and allow account sync") {
                do {
                    guard let selected else { return }
                    try chat.importProfileArchive(selected)
                    result = "Copied \(selected.conversations.count) conversations and \(selected.projects.count) projects. Existing data and originals were preserved."
                    if !identity.isLocal { result! += " Account synchronization may continue in the background; see any synchronization error below." }
                    error = nil; clearPreview()
                } catch { self.error = "Copy could not be saved. Existing data and the source file are preserved. " + error.localizedDescription }
            }
        } message: {
            Text("Destination: \(destination). Copy \(selected?.conversations.count ?? 0) conversations and \(selected?.projects.count ?? 0) projects, including retained attachments. " + (identity.isLocal ? "The copy stays local." : "After confirmation this copy may upload to your configured account server through normal synchronization."))
        }
        .safeAreaInset(edge: .bottom) { if let message = chat.syncMessage { Text(message).font(.footnote).padding().background(.regularMaterial) } }
    }
    private func selection(_ title: String, id: UUID, values: Binding<Set<UUID>>) -> some View {
        Toggle(title, isOn: Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        }))
    }
    private func clearPreview() { preview = nil; conversationIDs = []; projectIDs = [] }
    private func prepareExport() {
        do {
            let archive = try AIMProfileArchive.make(conversations: chat.conversations.filter { exportConversationIDs.contains($0.id) }, projects: chat.projects.filter { exportProjectIDs.contains($0.id) })
            exportDocument = AIMProfileArchiveDocument(data: try JSONEncoder().encode(archive))
            error = nil; result = nil; exporting = true
        } catch { self.error = error.localizedDescription }
    }
}

struct AIMActivityGrid: View {
    let chat: NativeChatStore
    private let days = (0..<91).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: Date())) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(.headline)
            Text("\(chat.totalTurns) completed answers · \(chat.conversations.count) conversations").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 13), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    let count = chat.activity[day] ?? 0
                    RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(count == 0 ? 0.07 : min(1, 0.2 + Double(count) * 0.12))).aspectRatio(1, contentMode: .fit)
                        .accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)): \(count) completed answers")
                }
            }
            if let message = chat.syncMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct AIMDevicePreferencesView: View {
    @Environment(\.scenePhase) private var scenePhase
    let page: AIMSettingsPage
    let chat: NativeChatStore
    let back: () -> Void
    @AppStorage("aim.appearance") private var appearance = AIMAppearancePreference.system.rawValue
    @AppStorage("aim.interface-language") private var language = AIMInterfaceLanguage.english.rawValue
    @AppStorage("aim.typography") private var typography = AIMTypographyPreference.lora.rawValue
    @AppStorage("aim.notifications.enabled") private var notifications = false
    @AppStorage("aim.voice.identifier") private var voice = ""
    @AppStorage("aim.voice.rate") private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("aim.start-screen") private var startScreen = "chat"
    @AppStorage("aim.autocorrect") private var autocorrect = true
    @AppStorage("aim.haptics") private var haptics = true
    @State private var notice: String?
    private var title: String { switch page { case .general: "General"; case .notifications: "Notifications"; case .appearance: "Appearance"; case .voice: "Voice"; default: "Configuration" } }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: title, back: back)
            AIMSettingsForm {
                switch page {
                case .general:
                    Picker("Language", selection: $language) { Text("English").tag(AIMInterfaceLanguage.english.rawValue); Text("Français").tag(AIMInterfaceLanguage.french.rawValue) }
                    Section { Picker("Start screen", selection: $startScreen) { Text("Chat").tag("chat"); Text("Code").tag("code"); Text("Agent").tag("agent") }; Toggle("Auto-correct spelling", isOn: $autocorrect).tint(.green); Toggle("Haptic feedback", isOn: $haptics).tint(.green) }
                case .appearance:
                    Section {
                        Picker("Appearance", selection: $appearance) { ForEach(AIMAppearancePreference.allCases, id: \.rawValue) { Text(String(describing: $0).capitalized).tag($0.rawValue) } }
                        Picker("Typography", selection: $typography) { ForEach(AIMTypographyPreference.allCases, id: \.rawValue) { Text(String(describing: $0).capitalized).tag($0.rawValue) } }
                    }
                    Section {
                        AIMAppearancePreview(appearance: AIMAppearancePreference(rawValue: appearance) ?? .system, typography: AIMTypographyPreference(rawValue: typography) ?? .lora)
                    } header: { Text("Preview") } footer: { Text("Typography applies to Chat. Settings always use the system font.") }
                case .notifications:
                    Section {
                        Toggle("Allow notifications", isOn: Binding(get: { notifications }, set: { value in Task { await AIMNotificationCenter.shared.requestEnabled(value) } })).tint(.green)
                        if AIMNotificationCenter.shared.authorizationStatus == .denied { Link("Open iOS settings", destination: URL(string: UIApplication.openSettingsURLString)!).foregroundStyle(.primary) }
                        Text(AIMNotificationCenter.shared.status).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(AIMNotificationCategory.allCases, id: \.self) { category in
                            Toggle(category.title, isOn: Binding(get: { UserDefaults.standard.object(forKey: "aim.notifications." + category.rawValue) as? Bool ?? true }, set: { value in
                                UserDefaults.standard.set(value, forKey: "aim.notifications." + category.rawValue)
                                Task { await AIMNotificationCenter.shared.updateRegistration() }
                            })).tint(.green)
                        }
                    } header: { Text("Updates from AIM") } footer: { Text("Generic alerts. Responses you are following stay inside AIM. Notifications never approve actions.") }
                case .voice:
                    Picker("Voice", selection: $voice) {
                        Text("System default").tag("")
                        ForEach(AVSpeechSynthesisVoice.speechVoices(), id: \.identifier) { Text("\($0.name) · \($0.language)").tag($0.identifier) }
                    }
                    Slider(value: $rate, in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)) { Text("Speech rate") }
                    Text("Uses voices available on this iPhone. Local Mac speech engines remain on the selected Mac.").font(.footnote).foregroundStyle(.secondary)
                default: EmptyView()
                }
                if let notice { Text(notice).foregroundStyle(.red) }
            }.scrollContentBackground(.hidden)
        }.task {
            if page == .notifications { await AIMNotificationCenter.shared.refreshAuthorization() }
        }.onChange(of: scenePhase) { _, phase in
            if page == .notifications, phase == .active { Task { await AIMNotificationCenter.shared.refreshAuthorization() } }
        }
    }
}

private struct AIMAppearancePreview: View {
    let appearance: AIMAppearancePreference
    let typography: AIMTypographyPreference
    @Environment(\.colorScheme) private var systemScheme
    private var chatFont: Font { typography == .lora ? .custom("Lora", size: 17, relativeTo: .body) : .system(.body) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AIM").font(typography == .lora ? .custom("Lora", size: 25, relativeTo: .title2) : .system(.title2, weight: .semibold))
                Spacer()
                Image(systemName: "ellipsis").font(.system(.body))
            }
            HStack {
                Spacer(minLength: 24)
                Text("Help me plan my day.").font(chatFont).padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            }
            Text("Let’s start with what matters to you.").font(chatFont)
            HStack(spacing: 10) {
                Text("Ask AIM…").font(chatFont).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).accessibilityHidden(true)
            }.padding(12).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.14), lineWidth: 1))
        }
        .padding(16).foregroundStyle(.primary)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
        .environment(\.colorScheme, appearance.colorScheme ?? systemScheme)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chat preview. Help me plan my day. Let’s start with what matters to you.")
    }
}

struct AIMChatConfigurationSettingsView: View {
    let chat: NativeChatStore
    var personalization = false
    let back: () -> Void
    @State private var draft = AccountChatPreferences()
    @State private var baseline = AccountChatPreferences()
    @State private var loaded = false
    @State private var revision = 0
    @State private var leaving = false
    @State private var saving = false
    @State private var notice: String?
    @State private var outputAutomatic = true
    @State private var outputLimitText = ""
    @State private var baselineOutput: Int?
    @State private var researchKeyInput = ""
    @State private var researchKeyNotice: String?
    private var outputDirty: Bool {
        !personalization && ((!outputAutomatic && (Int(outputLimitText).map { $0 <= 0 } ?? true))
            || (outputAutomatic ? nil : Int(outputLimitText)) != baselineOutput)
    }
    private var dirty: Bool { draft != baseline || outputDirty }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: personalization ? "Personalization" : "Configuration", back: leave)
            AIMSettingsForm {
                Section {
                    Picker("Response style", selection: $draft.responseStyle) { ForEach(AccountChatPreferences.ResponseStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Response language", selection: $draft.responseLanguage) { Text("Automatic").tag(""); Text("English").tag("English"); Text("Français").tag("French") }
                }
                if personalization {
                    Section {
                        preference("Warmth", field: \.warmth)
                        preference("Enthusiasm", field: \.enthusiasm)
                        preference("Headers and lists", field: \.formatting)
                        preference("Emoji", field: \.emoji)
                    }
                } else {
                    Section {
                        Picker("Output length", selection: $outputAutomatic) {
                            Text("Automatic").tag(true); Text("Custom limit").tag(false)
                        }
                        if !outputAutomatic {
                            TextField("Maximum output tokens", text: $outputLimitText).keyboardType(.numberPad)
                            if Int(outputLimitText).map({ $0 > 0 }) != true { Text("Enter a positive token count.").font(.footnote).foregroundStyle(.secondary) }
                        }
                    } footer: { Text("Automatic uses the provider’s model capacity. A custom maximum applies on this iPhone.") }
                    Section {
                        Toggle("Automatic web search", isOn: Binding(get: { draft.automaticWebSearch ?? true }, set: { draft.automaticWebSearch = $0 }))
                            .tint(.green)
                            .disabled(!draft.resolvedResearchMode.isOrchestrated && !NativeWebSearchRules.supports(provider: chat.provider, modelID: chat.modelID) && !(draft.automaticWebSearch ?? true))
                        Picker("Research mode", selection: Binding(get: { draft.resolvedResearchMode }, set: { draft.researchMode = $0; researchKeyInput = ""; researchKeyNotice = nil })) {
                            ForEach(AIMResearchMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        if draft.resolvedResearchMode.isOrchestrated {
                            SecureField("Search API key for this profile", text: $researchKeyInput)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Save search API key") {
                                do { try chat.saveResearchKey(researchKeyInput, mode: draft.resolvedResearchMode); researchKeyInput = ""; researchKeyNotice = "Search key saved for this profile. No request was sent." }
                                catch { researchKeyNotice = error.localizedDescription }
                            }.disabled(researchKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Remove this search API key", role: .destructive) {
                                do { try chat.removeResearchKey(mode: draft.resolvedResearchMode); researchKeyInput = ""; researchKeyNotice = "Search key removed from this profile." }
                                catch { researchKeyNotice = error.localizedDescription }
                            }
                            if let researchKeyNotice { Text(researchKeyNotice).font(.footnote).foregroundStyle(.secondary) }
                            Text("AIM chooses search and page-read tools with your model. Your separate search API account is charged. No alternate paid provider is used. Strict verified-only budgets cannot admit this mode.").font(.footnote).foregroundStyle(.secondary)
                        }
                        LabeledContent("Provider", value: chat.provider.name)
                        if !chat.modelID.isEmpty { LabeledContent("Model", value: chat.models.first { $0.id == chat.modelID }?.name ?? chat.modelID) }
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if draft.resolvedResearchMode.isOrchestrated {
                                Text("Model usage and search API charges are recorded separately. Search prices may be estimates; an absent provider receipt remains unknown.")
                            } else {
                                Text(NativeWebSearchRules.costDescription(provider: chat.provider, modelID: chat.modelID))
                            }
                            if !draft.resolvedResearchMode.isOrchestrated && NativeWebSearchRules.supports(provider: chat.provider, modelID: chat.modelID) {
                                Text("budget.web_search_behavior")
                            }
                        }
                    }
                }
                Section { AIMSettingsEditor(title: "Custom instructions", text: Binding(get: { draft.customInstructions ?? "" }, set: { draft.customInstructions = $0 })) }
                Section {
                    Button(saving ? "Saving…" : "Save changes") { Task { _ = await save() } }.disabled(!dirty || saving)
                    Text(dirty ? "Unsaved changes" : "Preferences saved").font(.footnote).foregroundStyle(.secondary)
                } footer: { Text("Shared with your AIM account. Configuration and Personalization use the same instructions.") }
                if let notice { AIMSettingsMessage(text: notice) }
            }
        }.onAppear { if !loaded {
            baseline = chat.preferences; draft = baseline; revision = chat.preferencesRevision
            baselineOutput = chat.customOutputTokenLimit; outputAutomatic = baselineOutput == nil
            outputLimitText = baselineOutput.map(String.init) ?? ""; loaded = true
        } }
        .interactiveDismissDisabled(dirty || saving).settingsDraftNavigationProtection(dirty || saving, onBackAttempt: leave)
        .alert("Save changes?", isPresented: $leaving) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { back() }
            Button("Save") { Task { if await save() { back() } } }
        }
    }
    private func preference(_ title: String, field: WritableKeyPath<AccountChatPreferences, String?>) -> some View {
        Picker(title, selection: Binding(get: { draft[keyPath: field] ?? "default" }, set: { draft[keyPath: field] = $0 })) {
            Text("Default").tag("default"); Text("Less").tag("less"); Text("More").tag("more")
        }
    }
    private func leave() { guard !saving else { return }; if dirty { leaving = true } else { back() } }
    private func save() async -> Bool {
        guard !saving else { return false }; saving = true; defer { saving = false }
        guard chat.preferences == baseline else { notice = "Preferences changed on another device. Reopen this page to review them; your draft is kept here."; return false }
        let outputLimit = outputAutomatic ? nil : Int(outputLimitText)
        if !personalization {
            guard outputAutomatic || outputLimit.map({ $0 > 0 }) == true else { notice = "Enter a positive maximum output token count."; return false }
            guard chat.customOutputTokenLimit == baselineOutput else { notice = "The output setting changed while this page was open. Your draft is kept."; return false }
        }
        if draft != baseline {
            guard await chat.savePreferences(draft, baseline: baseline, revision: revision) else { notice = chat.syncMessage; return false }
        }
        if !personalization { chat.customOutputTokenLimit = outputLimit; baselineOutput = outputLimit }
        baseline = draft; revision = chat.preferencesRevision; notice = nil; return true
    }
}

struct AIMSelectedMacSettingsView: View {
    let store: MainExperienceStore
    let back: () -> Void
    let openConnection: () -> Void
    let openSecurity: () -> Void
    @State private var settings: RemoteMacSettings?
    @State private var loadedMachineID: String?
    @State private var loading = false
    @State private var failure: RemoteMacSettingsError?
    @State private var requestID = UUID()
    private var availability: RemoteMacSettingsAvailability { store.macSettingsAvailability }
    private var context: String { (store.selectedMachine?.id ?? "") + ":" + availability.rawValue }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Selected Mac", back: back)
            AIMSettingsForm {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.selectedMachine?.name ?? "Choose a Mac").font(.headline)
                            Text(statusTitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "desktopcomputer").font(.title2) }
                    if !store.overview.machines.isEmpty {
                        Picker("Computer", selection: Binding(get: { store.selectedMachineID ?? "" }, set: { id in
                            settings = nil; loadedMachineID = nil; failure = nil; requestID = UUID()
                            Task { await store.selectMachine(id: id) }
                        })) {
                            Text("Choose a Mac").tag("")
                            ForEach(store.overview.machines) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                if availability == .ready, let value = settings, loadedMachineID == store.selectedMachine?.id {
                    Section {
                        Picker("Appearance", selection: Binding(get: { value.appearance }, set: { newValue in
                            var next = value; next.appearance = newValue; Task { await save(next, machineID: loadedMachineID) }
                        })) { ForEach(RemoteMacSettings.Appearance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        Toggle("Remote notifications", isOn: binding(\.notifyRemote)).tint(.green)
                        Toggle("Approval notifications", isOn: binding(\.notifyApprovals)).tint(.green)
                        Toggle("Question notifications", isOn: binding(\.notifyQuestions)).tint(.green)
                    } header: { Text("Mac preferences") } footer: { Text("Saved on this Mac. Provider keys stay on each device.") }
                    .disabled(loading)
                }
                if availability != .ready || failure != nil {
                    Section {
                        AIMSettingsMessage(text: explanation)
                        if availability == .pairingRequired || availability == .selectComputer {
                            AIMSettingsAction(title: "Computer connection", icon: "link", action: openConnection)
                        } else if availability == .authorizationRequired || failure == .authorizationRequired {
                            AIMSettingsAction(title: "Security & login", icon: "lock.shield", action: openSecurity)
                        }
                    }
                }
                Section {
                    Button { Task { await store.load(); await load() } } label: {
                        HStack { Text(loading ? "Checking connection…" : "Refresh"); Spacer(); if loading { ProgressView() } }
                    }.disabled(loading)
                }
            }
        }.task(id: context) { await load() }
        .onDisappear { requestID = UUID() }
    }
    private var statusTitle: String {
        switch availability {
        case .ready: loading ? "Checking connection…" : "Online"
        case .selectComputer: "No Mac selected"
        case .pairingRequired: "Pairing required"
        case .offline: "Offline"
        case .authorizationRequired: "Authorization required"
        case .synchronizing: "Waiting for Mac capabilities"
        case .updateRequired: "Update required"
        case .keyUnavailable: "Secure connection unavailable"
        }
    }
    private var explanation: String {
        switch failure ?? .unavailable(availability) {
        case .bridgeUnresponsive: "The Mac is online, but AIM did not answer. Open AIM on the Mac, then refresh."
        case .updateRequired, .unavailable(.updateRequired): "Update AIM on the selected Mac to change its settings here."
        case .authorizationRequired, .unavailable(.authorizationRequired): "Authorize this iPhone in Security & login, then retry."
        case .invalidResponse: "The Mac returned an incompatible settings response. Update both AIM apps, then refresh."
        case .connectionFailed: "The connection could not be checked. Check your network, then refresh."
        case .unavailable(.pairingRequired): "Pair this iPhone with your Mac in Computer connection."
        case .unavailable(.selectComputer): "Select a paired Mac to view its preferences."
        case .unavailable(.offline): "Open AIM on this Mac and check its network connection."
        case .unavailable(.synchronizing): "AIM is waiting for this Mac to announce its capabilities. Open AIM on the Mac, then refresh."
        case .unavailable(.keyUnavailable): "The secure connection cannot be read yet. Check Computer connection without resetting your pairing."
        case .unavailable(.ready): "Changes apply to the selected Mac."
        }
    }
    private func binding(_ key: WritableKeyPath<RemoteMacSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings?[keyPath: key] ?? false }, set: { newValue in
            guard var next = settings else { return }; next[keyPath: key] = newValue
            let machineID = loadedMachineID
            Task { await save(next, machineID: machineID) }
        })
    }
    private func load() async {
        let request = UUID(); requestID = request
        settings = nil; loadedMachineID = nil; failure = nil; loading = false
        guard availability == .ready, let machineID = store.selectedMachine?.id else { return }
        loading = true
        defer { if requestID == request { loading = false } }
        do {
            let value = try await store.macSettings(machineID: machineID)
            guard requestID == request, store.selectedMachine?.id == machineID, !Task.isCancelled else { return }
            settings = value; loadedMachineID = machineID
        } catch is CancellationError { }
        catch { if requestID == request { failure = .classify(error) } }
    }
    private func save(_ value: RemoteMacSettings, machineID: String?) async {
        guard !loading, let machineID, loadedMachineID == machineID, store.selectedMachine?.id == machineID else { return }
        let request = UUID(); requestID = request; loading = true; failure = nil
        defer { if requestID == request { loading = false } }
        do {
            let saved = try await store.macSettings(value, machineID: machineID)
            guard requestID == request, loadedMachineID == machineID, store.selectedMachine?.id == machineID else { return }
            settings = saved
        } catch is CancellationError { }
        catch { if requestID == request { failure = .classify(error) } }
    }
}

struct AIMDelegationView: View {
    let service: RemoteDelegationService
    let remote: MainExperienceStore
    let initialText: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var machineID = ""
    @State private var modelID = ""
    @State private var workspace = ""
    @State private var budget = ""
    @State private var maximumTurns = ""
    @State private var useMacLimits = true
    @State private var notice: String?
    var body: some View {
        NavigationStack {
            AIMSettingsForm {
                Section("Request") {
                    TextEditor(text: $text).frame(minHeight: 110)
                    Picker("Mac", selection: $machineID) { Text("Choose Mac").tag(""); ForEach(remote.overview.machines) { Text($0.name).tag($0.id) } }
                    Picker("Model", selection: $modelID) {
                        Text("Choose model").tag("")
                        ForEach(remote.overview.machines.first(where: { $0.id == machineID })?.capabilities?.models ?? [], id: \.id) { Text($0.name).tag($0.id) }
                    }
                    TextField("Absolute Mac workspace path", text: $workspace).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Permissions & budget") {
                    Text("Actions always ask for approval. This uses the selected Mac’s provider and billing; your iPhone provider is not used.").font(.footnote).foregroundStyle(.secondary)
                    Toggle("Use the Mac’s existing spending limits", isOn: $useMacLimits)
                    if !useMacLimits { TextField("Maximum API spend in USD", text: $budget).keyboardType(.decimalPad) }
                    TextField("Maximum turns (optional)", text: $maximumTurns).keyboardType(.numberPad)
                    Button("Save waiting request") {
                        do {
                            let turns = maximumTurns.isEmpty ? nil : Int(maximumTurns)
                            if !maximumTurns.isEmpty && turns == nil { throw RemoteSecurityServiceError.invalidResponse }
                            if !useMacLimits && budget.isEmpty { throw RemoteSecurityServiceError.invalidResponse }
                            try service.enqueue(.init(machineID: machineID, modelID: modelID, text: text, workspace: workspace,
                                maximumSpendUSD: useMacLimits ? nil : budget.replacingOccurrences(of: ",", with: "."), maximumTurns: turns))
                            text = ""; notice = nil
                        } catch { notice = "Choose a Mac, model, workspace and valid budget before saving." }
                    }
                    Text("Saving and reconnecting do not start execution. Press Start for the saved request when its assigned Mac is ready.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Saved requests") {
                    ForEach(service.requests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.text).lineLimit(3)
                            Text("\(request.state.rawValue.capitalized) · \(request.modelID)").font(.caption).foregroundStyle(.secondary)
                            Text(request.maximumSpendUSD.map { "Maximum $" + $0 } ?? "Mac spending limits").font(.caption)
                            if [.waiting, .uncertain].contains(request.state) {
                                Button(request.state == .uncertain ? "Reconcile saved request" : "Start on assigned Mac") {
                                    guard let machine = remote.overview.machines.first(where: { $0.id == request.machineID }) else { return }
                                    Task { await service.start(request.id, machine: machine) }
                                }
                            }
                            if request.state == .waiting { Button("Cancel request", role: .destructive) { do { try service.cancel(request.id) } catch { notice = error.localizedDescription } } }
                            if let id = request.conversationID { Text("Conversation: \(id)").font(.caption).textSelection(.enabled) }
                        }
                    }
                }
                if let message = notice ?? service.errorMessage { Text(message).font(.footnote).foregroundStyle(.red) }
            }.navigationTitle("Delegate to Mac")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.large])
            .onAppear { text = initialText }
            .onChange(of: machineID) { _, _ in modelID = "" }
    }
}


struct AIMWebConnectorsView: View {
    let accountID: UUID
    let cloud: any CloudContentServicing
    let back: () -> Void
    @State private var connectors: AIMWebConnectorStore
    @State private var accountConnectors = false
    @State private var adding = false
    @State private var name = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var selectedTool: MCPWebTool?
    @State private var arguments = "{}"
    @State private var confirming = false
    @State private var connectingOAuth = false
    @State private var web = ASWebAuthenticationSessionClient()
    init(accountID: UUID, cloud: any CloudContentServicing, back: @escaping () -> Void) {
        self.accountID = accountID; self.cloud = cloud; self.back = back
        _connectors = State(initialValue: AIMWebConnectorStore(accountID: accountID))
    }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Connectors", back: back)
            VStack(spacing: 0) {
            Picker("Connections", selection: $accountConnectors) { Text("This iPhone").tag(false); Text("Account").tag(true) }.pickerStyle(.segmented).padding(.horizontal, 16)
            if accountConnectors { AIMWebAccountConnectorsView(service: cloud, safeTop: 0, openMenu: back) }
            else {
                AIMSettingsForm {
                    Section("Web connectors") {
                        Button("Add HTTPS MCP connector", systemImage: "plus") { adding = true }
                        ForEach(connectors.servers) { server in
                            HStack {
                                Button { Task { await connectors.loadTools(server) } } label: { Label(server.name, systemImage: "globe").foregroundStyle(.primary) }
                                Spacer(); Button(role: .destructive) { Task { await connectors.disconnect(server) } } label: { Image(systemName: "trash") }
                            }
                        }
                    }
                    Section("Connector catalog") {
                        ForEach(ConnectorCatalog.connectors) { connector in
                            Button {
                                if connector.auth == .oauth { Task { await signIn(connector) } }
                                else { name = connector.id; endpoint = connector.url ?? ""; token = ""; adding = true }
                            } label: {
                                HStack(spacing: 12) {
                                    AIMConnectorCatalogLogo(connector: connector)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(connector.name).foregroundStyle(.primary)
                                        Text(connector.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(connector.soon || connector.url == nil ? "Coming soon" : connector.url?.hasSuffix("/sse") == true ? "Requires Mac" : connector.auth == .oauth ? "Sign in on this iPhone" : "Connect on this iPhone")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }.disabled(connectingOAuth || connector.soon || connector.url == nil || connector.url?.hasSuffix("/sse") == true)
                        }
                    }
                    Text("Use each connector’s own token on this iPhone. Local processes and legacy SSE connectors run on the Mac. Tool calls always ask for confirmation.").font(.footnote).foregroundStyle(.secondary)
                    Section("Available tools") {
                        ForEach(connectors.tools) { tool in
                            Button { selectedTool = tool; arguments = "{}" } label: {
                                VStack(alignment: .leading) { Text(tool.name).foregroundStyle(.primary); Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            }
                        }
                    }
                    if let result = connectors.resultText { Section("Result") { Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                    if let error = connectors.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
                    if connectors.busy || connectingOAuth { ProgressView() }
                }.listStyle(.insetGrouped)
            }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                AIMSettingsForm { TextField("Name", text: $name).textInputAutocapitalization(.never); TextField("HTTPS MCP URL", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled(); SecureField("Bearer token (if needed)", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    .navigationTitle("New connector").toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { token = ""; adding = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Save") { do { try connectors.add(name: name, url: endpoint, token: token); token = ""; name = ""; endpoint = ""; adding = false } catch { connectors.errorMessage = error.localizedDescription } }.disabled(name.isEmpty || endpoint.isEmpty) }
                    }
            }.presentationDetents([.large])
        }
        .sheet(item: $selectedTool) { tool in
            NavigationStack {
                AIMSettingsForm {
                    Text(tool.description)
                    TextEditor(text: $arguments).font(.system(.body, design: .monospaced)).frame(minHeight: 150)
                    Text("Arguments must match the connector’s JSON schema.").font(.footnote)
                    if let data = try? JSONEncoder().encode(tool.schema) { Text(String(decoding: data, as: UTF8.self)).font(.caption).textSelection(.enabled) }
                    Button("Review action") { confirming = true }
                }.navigationTitle(tool.name)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selectedTool = nil } } }
                    .alert("Run this connector action?", isPresented: $confirming) {
                        Button("Run") { Task { await connectors.execute(tool, serverID: connectors.loadedServerID ?? UUID(), arguments: arguments, confirmed: true); selectedTool = nil } }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("The connector may read or modify external data.\n\n" + tool.name + "\n" + arguments) }
            }.presentationDetents([.large])
        }
        .onDisappear { Task { await connectors.close() } }
    }
    private func signIn(_ connector: PortableConnector) async {
        guard !connectingOAuth, let raw = connector.url, let url = URL(string: raw) else { return }
        connectingOAuth = true; defer { connectingOAuth = false }
        do {
            guard #available(iOS 17.4, *) else { throw AccountServiceError.updateRequired }
            let flow = try await MCPAuthorizationFlow.prepare(resource: url, callback: URL(string: "https://aim-ai.tech/auth/mcp/ios")!)
            let callback = try await web.authenticateHTTPS(at: flow.authorizationURL, host: "aim-ai.tech", path: "/auth/mcp/ios")
            let tokens = try await flow.exchange(callback: callback)
            try connectors.saveOAuth(name: connector.id, url: url, tokens: tokens)
            connectors.errorMessage = nil
        } catch { connectors.errorMessage = error.localizedDescription }
    }
}

struct AIMConnectorCatalogLogo: View {
    let connector: PortableConnector
    var body: some View { AIMBrandLogo(identity: connector.id, fallbackURL: connector.logo.flatMap(URL.init(string:)), size: 32) }
}


struct AIMSubagentSettingsView: View {
    let chat: NativeChatStore
    let remote: MainExperienceStore
    let back: () -> Void
    @State private var target = ""
    @State private var nativeModels: [ChatProvider: [ChatModel]] = [:]
    private var scope: String { target.isEmpty ? chat.subagentTargetID : target }
    private var preferences: SubagentPreferences { chat.subagentPreferences(target: scope) }
    private var choices: [(String, SubagentModelChoice, Bool)] {
        if scope == chat.subagentTargetID {
            return ChatProvider.allCases.flatMap { provider in (nativeModels[provider] ?? []).filter { $0.isChatModel }.map { ($0.name + " · " + provider.rawValue, SubagentModelChoice(provider: provider, modelID: $0.id), $0.supportsImageInput == true) } }
        }
        let id = String(scope.dropFirst(4))
        return (remote.overview.machines.first { $0.id == id }?.capabilities?.models ?? []).filter { $0.isAvailable != false }.compactMap { model in
            guard let provider = ChatProvider(rawValue: model.provider) else { return nil }
            return (model.name + " · " + model.provider, .init(provider: provider, modelID: model.id), model.detail?.supportsImageInput == true || model.capabilities.contains("vision"))
        }
    }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Sub-agents", back: back)
            AIMSettingsForm {
                Section {
                    Picker("Execution device", selection: $target) {
                        Text("This iPhone").tag(chat.subagentTargetID)
                        ForEach(remote.overview.machines) { Text($0.name).tag("mac:" + $0.id) }
                    }
                    modelPicker("General model", visual: false)
                    modelPicker("Visual model", visual: true)
                    Text("A task’s explicit model takes priority. An unavailable model is never replaced automatically. Visual permission is separate from this default.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Visual permissions") {
                    if preferences.permanentVisualConsents.isEmpty { Text("No permanent authorization").foregroundStyle(.secondary) }
                    ForEach(preferences.permanentVisualConsents.sorted { $0.modelID < $1.modelID }, id: \.self) { choice in
                        Button("Revoke · " + choice.provider.rawValue + " / " + choice.modelID, role: .destructive) {
                            var value = preferences; value.permanentVisualConsents.remove(choice); chat.setSubagentPreferences(value, target: scope)
                        }
                    }
                }
            }
        }
        .task {
            if target.isEmpty { target = chat.subagentTargetID }
            for provider in ChatProvider.allCases where chat.connectedProviders.contains(provider) {
                do { nativeModels[provider] = try await chat.catalog(for: provider) } catch { chat.errorMessage = error.localizedDescription }
            }
        }
    }
    private func modelPicker(_ title: String, visual: Bool) -> some View {
        let selected = visual ? preferences.visual : preferences.general
        return Picker(title, selection: Binding<SubagentModelChoice?>(get: { visual ? preferences.visual : preferences.general }, set: { choice in
            var value = preferences; if visual { value.visual = choice } else { value.general = choice }; chat.setSubagentPreferences(value, target: scope)
        })) {
            Text(visual ? "Ask on first use" : "Follow main model").tag(Optional<SubagentModelChoice>.none)
            if let selected, !choices.contains(where: { $0.1 == selected }) { Text(selected.modelID + " · unavailable").tag(Optional(selected)) }
            ForEach(choices.filter { !visual || $0.2 }, id: \.1) { item in Text(item.0).tag(Optional(item.1)) }
        }
    }
}
