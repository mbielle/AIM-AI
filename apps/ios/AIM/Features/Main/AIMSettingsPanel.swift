import AIMCore
import LocalAuthentication
import SwiftUI
import UIKit

enum AIMSettingsPage: Hashable {
    case root
    case general, notifications, importData, appearance, voice, configuration, providers, selectedMac
    case profile
    case usage
    case personalization
    case memory
    case plugins
    case connection
    case security, subagents
    case privacy
    case data
    case about
}

enum AIMSettingsPresentationOrigin {
    case settings, connectionShortcut
}

struct AIMSettingsPresentation: Identifiable {
    let id = UUID()
    let initialPage: AIMSettingsPage
    var origin: AIMSettingsPresentationOrigin = .settings
}

struct AIMSettingsPanel: View {
    let identity: AppIdentity
    let directConnection: AIMDirectConnectionStore?
    let store: MainExperienceStore
    let cloudContentService: any CloudContentServicing
    let appLock: AppLockService
    let nativeChat: NativeChatStore
    let accountSessions: (any AccountSessionServicing)?
    let initialPage: AIMSettingsPage
    let origin: AIMSettingsPresentationOrigin
    let signOut: () -> Void
    let connectAccount: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @AppStorage("aim.appearance") private var appearance = AIMAppearancePreference.system.rawValue
    @AppStorage("aim.interface-language") private var interfaceLanguage = AIMInterfaceLanguage.english.rawValue
    @AppStorage("aim.typography") private var typography = AIMTypographyPreference.lora.rawValue
    @State private var path: [SettingsDestination]
    @State private var connectors: AIMWebConnectorStore
    private var page: AIMSettingsPage {
        if case let .page(value) = path.last { return value }; return .root
    }
    private func back() { if !path.isEmpty { path.removeLast() } }
    @State private var selectedDetent: PresentationDetent
    @State private var pairingIsEditing = false
    @State private var appearanceExpanded = false
    @State private var typographyExpanded = false
    @State private var languageExpanded = false

    private static let compactDetent = PresentationDetent.fraction(0.54)

    init(
        directConnection: AIMDirectConnectionStore? = nil,
        identity: AppIdentity,
        store: MainExperienceStore,
        cloudContentService: any CloudContentServicing,
        appLock: AppLockService,
        nativeChat: NativeChatStore,
        accountSessions: (any AccountSessionServicing)?,
        initialPage: AIMSettingsPage,
        origin: AIMSettingsPresentationOrigin = .settings,
        connectAccount: (() -> Void)? = nil,
        signOut: @escaping () -> Void
    ) {
        self.appLock = appLock; self.nativeChat = nativeChat; self.accountSessions = accountSessions
        self.identity = identity
        self.directConnection = directConnection
        self.store = store
        self.cloudContentService = cloudContentService
        self.initialPage = initialPage
        self.origin = origin
        self.signOut = signOut
        self.connectAccount = connectAccount
        _connectors = State(initialValue: nativeChat.connectors)
        _path = State(initialValue: nativeChat.pendingSettingsDestination.map { [.page(.plugins), $0] } ?? (initialPage == .root ? [] : [.page(initialPage)]))
        nativeChat.pendingSettingsDestination = nil
        _selectedDetent = State(initialValue: origin == .connectionShortcut && initialPage == .connection ? Self.compactDetent : .large)
    }

    var body: some View {
        NavigationStack(path: $path) {
            settingsRoot
                .navigationDestination(for: SettingsDestination.self) { destination in
                Group {
                switch destination {
                case .page(.root):
                    settingsRoot
                case .page(.connection) where directConnection != nil, .pairComputer where directConnection != nil:
                    if let directConnection { AIMDirectConnectionView(direct: directConnection, remote: store, back: back) }
                case .page(.connection) where identity.isLocal, .pairComputer where identity.isLocal, .page(.selectedMac) where identity.isLocal && directConnection == nil, .deleteAccount where identity.isLocal, .sessions where identity.isLocal, .webAccountConnectors where identity.isLocal, .webAccount where identity.isLocal:
                    localCloudNotice
                case .page(.connection):
                    AIMConnectionSettingsView(
                        store: store,
                        onBack: { back() },
                        addConnection: { selectedDetent = .large; path.append(.pairComputer) }
                    )
                case .pairComputer:
                    AIMPairComputerView(store: store, back: back, paired: { back() })
                case .page(.security):
                    AIMAppSecuritySettingsView(lock: appLock, remote: store, sessions: accountSessions, signOut: signOut, back: { back() }, openSessions: { path.append(.sessions) })
                case .page(.subagents):
                    AIMSubagentSettingsView(chat: nativeChat, remote: store, back: back)
                case .page(.providers):
                    AIMProvidersSettingsView(chat: nativeChat, openBFL: { path.append(.bflProvider) }, openProvider: { path.append(.provider($0)) }, back: { back() })
                case .page(.importData):
                    AIMImportSettingsView(chat: nativeChat, identity: identity, back: { back() })
                case .page(.general), .page(.notifications), .page(.appearance):
                    AIMDevicePreferencesView(page: page, chat: nativeChat, back: { back() })
                case .page(.voice):
                    AIMVoiceSettingsView(chat: nativeChat, openHistory: { path.append(.dictationHistory) }, back: back)
                case .dictationHistory:
                    AIMDictationHistoryView(chat: nativeChat, back: back, openConversation: { id in
                        AIMNotificationCenter.shared.pendingConversation = id; dismiss()
                    })
                case .page(.configuration):
                    AIMChatConfigurationSettingsView(chat: nativeChat, back: { back() })
                case .page(.selectedMac):
                    AIMSelectedMacSettingsView(store: store, back: { back() }, openConnection: { path.append(.page(.connection)) }, openSecurity: { path.append(.page(.security)) })
                case .page(.profile):
                    AIMAccountProfileView(
                        identity: identity,
                        openAccount: { path.append(.account) },
                        nativeChat: nativeChat,
                        onBack: { back() },
                        openActivity: { path.append(.profileActivity($0, $1, $2)) },
                        openImport: { path.append(.activityImport) }
                    )
                case .page(.usage):
                    AIMAccountUsageView(chat: nativeChat, back: { back() })
                case .page(.personalization):
                    AIMChatConfigurationSettingsView(chat: nativeChat, personalization: true, back: { back() })
                case .page(.memory):
                    AIMAccountMemoryView(chat: nativeChat, legacyService: cloudContentService, summary: false, openSummary: { path.append(.memorySummary) }, back: { back() })
                case .page(.plugins):
                    AIMConnectorListView(connectors: connectors, cloud: cloudContentService, remote: store.macConnectors.map { .init($0, available: store.macSettingsAvailability == .ready) }, open: { path.append($0) }, back: back, openWebAccounts: { id in path.append(id.map(SettingsDestination.webAccount) ?? .webAccountConnectors) })
                case .page(.privacy):
                    AIMPrivacySettingsView(onBack: { back() })
                case .page(.data) where identity.isLocal:
                    AIMSettingsPageContainer {
                        AIMSettingsPageHeader(title: "Local data", back: back)
                        AIMSettingsForm { Section { Text("Conversations, projects, memories and provider keys stay in this local profile. Signing in opens a separate account. Local data is never uploaded or merged automatically.") } }
                    }
                case .page(.data):
                    AIMDataOverviewView(openDelete: { path.append(.deleteAccount) }, service: cloudContentService,
                        remoteStore: store,
                        onBack: { back() },
                        onDeleted: {
                            dismiss()
                            signOut()
                        }
                    )
                case .page(.about):
                    AIMAboutSettingsView(onBack: { back() })
                case let .provider(provider):
                    AIMProviderDetailView(chat: nativeChat, provider: provider, back: back)
                case .sessions:
                    AIMAccountSessionsView(service: accountSessions, signOut: signOut, back: back)
                case .account:
                    AIMProfileSettingsView(identity: identity, service: cloudContentService, nativeChat: nativeChat, onBack: back)
                case let .profileActivity(ids, title, timeZoneID):
                    AIMSettingsPageContainer {
                        AIMSettingsPageHeader(title: title, back: back)
                        AIMAccountActivityDetailList(
                            records: AccountActivityRecord.merge(nativeChat.activityRecords, accountID: identity.storageID).filter { ids.contains($0.id) },
                            accountID: identity.storageID,
                            calendar: activityCalendar(timeZoneID)
                        )
                    }
                case .activityImport:
                    AIMSettingsPageContainer {
                        AIMSettingsPageHeader(title: "Import earlier activity", back: back)
                        AIMAccountActivityImportView(chat: nativeChat)
                    }
                case .memorySummary:
                    AIMAccountMemoryView(chat: nativeChat, legacyService: cloudContentService, summary: true, openSummary: {}, back: back)
                case let .connector(connector):
                    AIMConnectorDetailView(connectors: connectors, connector: connector, open: { path.append($0) }, back: back)
                case let .connectorAccount(id):
                    AIMConnectorAccountView(connectors: connectors, id: id, open: { path.append($0) }, back: back)
                case .bflProvider:
                    AIMBFLProviderView(chat: nativeChat, back: back)
                case let .webAccount(id):
                    AIMWebAccountConnectorsView(service: cloudContentService, safeTop: 0, selectedAccountID: id, openMenu: back)
                case .webAccountConnectors:
                    AIMWebAccountConnectorsView(service: cloudContentService, safeTop: 0, openMenu: back)
                case .newConnector:
                    AIMConnectorEditorView(connectors: connectors, back: back)
                case .connectorPermissions:
                    AIMConnectorPermissionsView(connectors: connectors, back: back)
                case let .connectorTool(id, name):
                    AIMConnectorToolView(connectors: connectors, serverID: id, name: name, back: back)
                case .deleteAccount:
                    AIMDeleteAccountView(service: cloudContentService, userEmail: identity.accountEmail ?? "", onBack: back, onDeleted: { dismiss(); signOut() })
                }
                }
                    .background(Color(uiColor: .secondarySystemBackground))
                    .font(.system(.body)).tint(.primary)
                    .toolbar(.hidden, for: .navigationBar)
                    .settingsBackNavigation()
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .font(.system(.body)).tint(.primary)
        .onDisappear { Task { await connectors.close() } }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize || origin == .settings || pairingIsEditing || page != .connection ? [.large] : [Self.compactDetent, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .aimUniversalPanelSurface()
        .preferredColorScheme(selectedAppearance.colorScheme)
        .interactiveDismissDisabled(store.isPairing)
        .onAppear { if dynamicTypeSize.isAccessibilitySize { selectedDetent = .large } }
        .onChange(of: dynamicTypeSize) { _, size in
            if size.isAccessibilitySize { selectedDetent = .large }
        }
        .onChange(of: page) { _, newPage in
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedDetent = origin == .connectionShortcut && newPage == .connection && !pairingIsEditing && !dynamicTypeSize.isAccessibilitySize ? Self.compactDetent : .large
            }
        }
        .onChange(of: store.errorMessage) { _, error in
            guard page == .connection, error != nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedDetent = .large
            }
        }
    }

    private func activityCalendar(_ timeZoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        return calendar
    }

    private func beginPairingEditing(_ focus: @escaping () -> Void) {
        pairingIsEditing = true
        if selectedDetent == .large { focus(); return }
        withAnimation(.easeInOut(duration: 0.3), completionCriteria: .logicallyComplete) {
            selectedDetent = .large
        } completion: { focus() }
    }

    private var settingsRoot: some View {
        ZStack(alignment: .topTrailing) {
            Color(uiColor: .secondarySystemBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    profileHero.padding(.top, 42)

                    settingsCard(copy("Customize AIM", "Personnaliser AIM")) {
                        settingsRow("sidebar.personalization", icon: "slider.horizontal.3", page: .personalization)
                        divider
                        settingsRow("settings.memory", icon: "brain.head.profile", page: .memory)
                        divider
                        settingsRow(copyKey("Connectors", "Connecteurs"), icon: "puzzlepiece.extension", page: .plugins)
                    }
                    settingsCard(copy("Preferences", "Préférences")) {
                        settingsRow("General", icon: "gearshape", page: .general)
                        divider
                        settingsRow("Notifications", icon: "bell", page: .notifications)
                        divider
                        settingsRow("Appearance", icon: "paintbrush", page: .appearance)
                        divider
                        settingsRow("Voice", icon: "waveform", page: .voice)
                        divider
                        settingsRow("Configuration", icon: "slider.horizontal.3", page: .configuration)
                        divider
                        settingsRow("Sub-agents", icon: "person.2", page: .subagents)
                        divider
                        settingsRow("Import", icon: "square.and.arrow.down", page: .importData)
                    }
                    settingsCard(copy("Providers & computer", "Fournisseurs et ordinateur")) {
                        settingsRow("Providers", icon: "key", page: .providers)
                        divider
                        settingsRow(copyKey("Selected Mac", "Mac sélectionné"), icon: "desktopcomputer", page: .selectedMac)
                    }


                    settingsCard(copy("Account", "Compte")) {
                        settingsRow(copyKey("Profile", "Profil"), icon: "person.crop.circle", page: .profile, value: LocalizedStringKey(identity.accountEmail ?? "—"), identifier: "settings-profile-row")
                        divider
                        settingsRow("settings.usage", icon: "chart.bar", page: .usage)
                    }

                    settingsCard(copy("App settings", "Réglages de l’app")) {
                        settingsRow(copyKey("Security & login", "Sécurité et connexion"), icon: "lock.shield", page: .security, identifier: "settings-security-row")
                        divider
                        settingsRow("settings.connection", icon: "desktopcomputer", page: .connection, value: connectionValue, identifier: "settings-connection-row")
                        divider
                        settingsRow("settings.privacy", icon: "hand.raised", page: .privacy)
                        divider
                        settingsRow("settings.data", icon: "externaldrive", page: .data)
                    }

                    settingsCard(copy("Get help", "Obtenir de l’aide")) {
                        settingsRow(copyKey("About", "À propos"), icon: "info.circle", page: .about, identifier: "settings-about-row")
                    }

                    if !identity.isLocal {
                    Button(role: .destructive) {
                        dismiss(); signOut()
                    } label: {
                        Label("auth.sign_out", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 17, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 58)
                    }
                    .buttonStyle(.plain)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityIdentifier("settings-logout-button")
                    } else if let connectAccount {
                        Button("Connect a cloud account", action: connectAccount).padding(18)
                            .accessibilityIdentifier("settings-connect-account")
                        Text("Optional. Cloud data uses a separate profile; local data is not transferred.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(14)
            .accessibilityIdentifier("settings-close-button")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-root-screen")
    }

    private var localCloudNotice: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Optional cloud account", back: back)
            AIMSettingsForm {
                Section {
                    Text("Remote and cloud features require a configured server and a signed-in account. Local conversations and projects remain on this device.")
                    if let connectAccount { Button("Connect a cloud account", action: connectAccount) }
                }
            }
        }
    }

    private var profileHero: some View {
        Button { path.append(.page(.profile)) } label: {
            VStack(spacing: 11) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.82))
                        .frame(width: 88, height: 88)
                        .overlay {
                            Text(profileInitials)
                                .font(.system(size: 31, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(.regularMaterial, in: Circle())
                        .overlay { Circle().stroke(Color.white.opacity(0.7)) }
                }
                Text(profileName).font(AIMDesign.titleFont(size: 24, weight: .semibold))
                if let email = identity.accountEmail { Text(email).font(.subheadline).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            VStack(spacing: 0) { content() }
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var profileName: String {
        let value = identity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? copy("AIM user", "Utilisateur AIM") : value
    }

    private var profileInitials: String {
        let parts = profileName.split(separator: " ")
        let initials = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return initials.isEmpty ? "A" : initials.uppercased()
    }

    private func settingsHeader(title: LocalizedStringKey, showsBack: Bool) -> some View {
        HStack {
            Button {
                if showsBack { path.removeAll() } else { dismiss() }
            } label: {
                Image(systemName: showsBack ? "chevron.left" : "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityIdentifier(showsBack ? "settings-back-button" : "settings-close-button")

            Spacer()
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            if showsBack {
                Color.clear.frame(width: 42, height: 42)
            } else {
                Menu {
                    Button {
                        if let url = URL(string: "https://aim-ai.tech/terms-of-service") { openURL(url) }
                    } label: {
                        Label("settings.privacy.terms", systemImage: "scroll")
                    }
                    Button {
                        if let url = URL(string: "https://aim-ai.tech/privacy-policy") { openURL(url) }
                    } label: {
                        Label("settings.privacy.policy", systemImage: "hand.raised")
                    }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 42, height: 42)
                        .aimGlassCircle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(Text(copy("Legal information", "Informations légales")))
                .accessibilityIdentifier("settings-info-button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .aimSettingsHeader()
    }

    private func settingsRow(
        _ title: LocalizedStringKey,
        icon: String,
        page destination: AIMSettingsPage,
        value: LocalizedStringKey? = nil,
        identifier: String? = nil
    ) -> some View {
        Button {
            AIMHaptics.selection()
            path.append(.page(destination))
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Addresses such as the account e-mail may be exposed
                        // by UIKit as implicit mailto links. Keep the whole row
                        // as the only interactive target so it always opens the
                        // requested settings destination.
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier ?? "settings-\(String(describing: destination))-row")
    }

    private var divider: some View {
        Divider().padding(.leading, 56)
    }

    private func localPreferenceRow(
        title: String,
        icon: String,
        value: String,
        expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            AIMHaptics.selection()
            action()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                Text(title).font(.system(size: 16, weight: .medium))
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appearanceChoices: some View {
        HStack(spacing: 8) {
            preferenceChoice(copy("Light", "Clair"), icon: "sun.max", selected: selectedAppearance == .light) {
                appearance = AIMAppearancePreference.light.rawValue
            }
            preferenceChoice(copy("Dark", "Sombre"), icon: "moon", selected: selectedAppearance == .dark) {
                appearance = AIMAppearancePreference.dark.rawValue
            }
            preferenceChoice(copy("System", "Système"), icon: "iphone", selected: selectedAppearance == .system) {
                appearance = AIMAppearancePreference.system.rawValue
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var languageChoices: some View {
        HStack(spacing: 8) {
            preferenceChoice("Français", icon: nil, selected: selectedLanguage == .french) {
                interfaceLanguage = AIMInterfaceLanguage.french.rawValue
            }
            preferenceChoice("English", icon: nil, selected: selectedLanguage == .english) {
                interfaceLanguage = AIMInterfaceLanguage.english.rawValue
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var typographyChoices: some View {
        HStack(spacing: 8) {
            preferenceChoice("Lora", icon: "textformat", selected: selectedTypography == .lora) {
                typography = AIMTypographyPreference.lora.rawValue
            }
            preferenceChoice(copy("System", "Système"), icon: "iphone", selected: selectedTypography == .system) {
                typography = AIMTypographyPreference.system.rawValue
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func preferenceChoice(
        _ title: String,
        icon: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title).lineLimit(1).minimumScaleFactor(0.75)
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(selected ? Color.primary.opacity(0.10) : Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(selected ? 0.20 : 0.09)) }
        }
        .buttonStyle(.plain)
    }

    private var selectedAppearance: AIMAppearancePreference {
        AIMAppearancePreference(rawValue: appearance) ?? .system
    }

    private var selectedLanguage: AIMInterfaceLanguage {
        AIMInterfaceLanguage(rawValue: interfaceLanguage) ?? .english
    }

    private var selectedTypography: AIMTypographyPreference {
        AIMTypographyPreference(rawValue: typography) ?? .lora
    }

    private var typographyLabel: String {
        selectedTypography == .lora ? "Lora" : copy("System", "Système")
    }

    private var appearanceLabel: String {
        switch selectedAppearance {
        case .light: copy("Light", "Clair")
        case .dark: copy("Dark", "Sombre")
        case .system: copy("System", "Système")
        }
    }

    private var appearanceIcon: String {
        switch selectedAppearance {
        case .light: "sun.max"
        case .dark: "moon"
        case .system: "iphone"
        }
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }

    private func copyKey(_ english: String, _ french: String) -> LocalizedStringKey {
        LocalizedStringKey(copy(english, french))
    }

    private var connectionValue: LocalizedStringKey {
        switch store.overview.connectionState {
        case .paired: "settings.connection.paired"
        case .unpaired: "settings.connection.not_paired"
        case .needsRepair: "settings.connection.repair"
        }
    }

    private func informationPage(title: LocalizedStringKey, icon: String, body: String) -> some View {
        AIMSettingsPageContainer {
            settingsHeader(title: title, showsBack: true)
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: icon)
                        .font(.system(size: 28))
                        .frame(width: 62, height: 62)
                        .background(Color.primary.opacity(0.06), in: Circle())
                    Text(body)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 54)
            }
        }
    }
}

private struct AIMAboutSettingsView: View {
    let onBack: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "About", back: onBack)

            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 32, weight: .medium))
                            .frame(width: 76, height: 76)
                            .background(Color.primary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                        Text("AIM AI").font(.system(size: 24, weight: .semibold))
                        Text(version).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)

                    VStack(spacing: 0) {
                        legalButton("Terms of Service", icon: "doc.text", url: "https://aim-ai.tech/terms-of-service")
                        Divider().padding(.leading, 56)
                        legalButton("Privacy Policy", icon: "hand.raised", url: "https://aim-ai.tech/privacy-policy")
                    }
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(18)
            }
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    private func legalButton(_ title: String, icon: String, url: String) -> some View {
        Button {
            if let url = URL(string: url) { openURL(url) }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).frame(width: 28)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

@MainActor
@Observable
private final class AIMProfileStore {
    var profile: AIMUserProfile
    var savedProfile: AIMUserProfile
    var isLoading = false
    var isSaving = false
    var message: String?

    private let service: any CloudContentServicing

    init(identity: AppIdentity, service: any CloudContentServicing) {
        let fallback = AIMUserProfile(
            fullName: identity.displayName ?? "",
            preferredName: "",
            personalPreferences: ""
        )
        profile = fallback
        savedProfile = fallback
        self.service = service
    }

    var isDirty: Bool { profile != savedProfile }

    func load() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            profile = try await service.loadProfile()
            savedProfile = profile
        } catch {
            message = "Unable to load your profile."
        }
    }

    func save() async {
        guard !isSaving else { return }
        let normalized = AIMUserProfile(
            fullName: profile.fullName,
            preferredName: profile.preferredName,
            personalPreferences: profile.personalPreferences
        )
        isSaving = true
        message = nil
        defer { isSaving = false }
        do {
            try await service.saveProfile(normalized)
            profile = normalized
            savedProfile = normalized
            message = "Profile updated."
        } catch {
            message = "Unable to save your changes."
        }
    }
}

private struct AIMProfileSettingsView: View {
    let identity: AppIdentity
    let nativeChat: NativeChatStore
    let onBack: () -> Void
    @Environment(\.locale) private var locale
    @State private var store: AIMProfileStore

    init(identity: AppIdentity, service: any CloudContentServicing, nativeChat: NativeChatStore, onBack: @escaping () -> Void) {
        self.nativeChat = nativeChat
        self.identity = identity
        self.onBack = onBack
        _store = State(initialValue: AIMProfileStore(identity: identity, service: service))
    }

    @State private var leaving = false
    @State private var loaded = false
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsSubheader(title: "settings.profile", onBack: leave)
            AIMSettingsForm {
                if store.isLoading { ProgressView() }
                Section {
                    field(copy("Full Name", "Nom complet"), text: $store.profile.fullName, identifier: "profile-full-name-field")
                    field(copy("Nickname", "Prénom préféré"), text: $store.profile.preferredName, identifier: "profile-preferred-name-field")
                    LabeledContent(copy("Email", "Adresse e-mail"), value: identity.accountEmail ?? "—")
                }
                Section {
                    AIMSettingsEditor(title: copy("Personal Preferences", "Préférences personnelles"), text: $store.profile.personalPreferences)
                        .accessibilityIdentifier("profile-preferences-field")
                        .onChange(of: store.profile.personalPreferences) { _, value in
                            if value.count > 2_000 { store.profile.personalPreferences = String(value.prefix(2_000)) }
                        }
                } footer: { Text("\(store.profile.personalPreferences.count)/2000") }
                Section {
                    Button { Task { await saveProfile() } } label: {
                        HStack { Text(copy("Save Profile", "Enregistrer le profil")); Spacer(); if store.isSaving { ProgressView() } }
                    }.disabled(!store.isDirty || store.isSaving).accessibilityIdentifier("profile-save-button")
                    if let message = store.message { AIMSettingsMessage(text: localizedProfileMessage(message)) }
                }
            }
        }
        .task { if !loaded { loaded = true; await store.load() } }
        .interactiveDismissDisabled(store.isDirty || store.isSaving)
        .settingsDraftNavigationProtection(store.isDirty || store.isSaving, onBackAttempt: leave)
        .alert("Save changes?", isPresented: $leaving) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { onBack() }
            Button("Save") { Task { await saveProfile(); if !store.isDirty { onBack() } } }
        }
        .accessibilityIdentifier("profile-settings-screen")
    }
    private func leave() { guard !store.isSaving else { return }; if store.isDirty { leaving = true } else { onBack() } }
    private func saveProfile() async {
        await store.save()
        if !store.isDirty { nativeChat.profileInstructions = store.savedProfile.personalPreferences }
    }

    private func field(_ title: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(title, text: text)
                .font(.body)
                .padding(12)
                .frame(minHeight: 44)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.16)) }
                .accessibilityIdentifier(identifier)
        }
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }

    private func localizedProfileMessage(_ message: String) -> String {
        guard locale.language.languageCode?.identifier == "fr" else { return message }
        return switch message {
        case "Profile updated.": "Profil mis à jour."
        case "Unable to load your profile.": "Impossible de charger votre profil."
        default: "Impossible d’enregistrer les modifications."
        }
    }
}

@MainActor
@Observable
private final class AIMPreferencesStore {
    var preferences = AIMUserPreferences.defaults
    var isLoading = false
    var isSaving = false
    var error: String?

    private let service: any CloudContentServicing
    init(service: any CloudContentServicing) { self.service = service }

    func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { preferences = try await service.loadPreferences() }
        catch { self.error = String(localized: "settings.preferences.load_error") }
    }

    func save() async {
        isSaving = true; error = nil
        defer { isSaving = false }
        do { try await service.savePreferences(preferences) }
        catch { self.error = String(localized: "settings.preferences.save_error") }
    }
}

private struct AIMPreferencesSettingsView: View {
    let onBack: () -> Void
    @State private var store: AIMPreferencesStore

    init(service: any CloudContentServicing, onBack: @escaping () -> Void) {
        self.onBack = onBack
        _store = State(initialValue: AIMPreferencesStore(service: service))
    }

    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsSubheader(title: "sidebar.personalization", onBack: onBack)
            if store.isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                Form {
                    Section("settings.preferences.automation") {
                        Toggle("settings.preferences.auto_titles", isOn: $store.preferences.autoTitleGeneration)
                        Toggle("settings.preferences.smart_context", isOn: $store.preferences.smartContext)
                        Toggle("settings.preferences.web_search", isOn: $store.preferences.webSearchEnabled)
                        Toggle("settings.preferences.detailed", isOn: $store.preferences.detailedResponseEnabled)
                    }
                    Section("settings.preferences.responses") {
                        Picker("settings.preferences.tone", selection: $store.preferences.tone) {
                            ForEach(AIMTone.allCases, id: \.self) { Text(toneLabel($0)).tag($0) }
                        }
                        Picker("settings.preferences.style", selection: $store.preferences.style) {
                            ForEach(AIMResponseStyle.allCases, id: \.self) { Text(styleLabel($0)).tag($0) }
                        }
                        Picker("settings.preferences.expertise", selection: $store.preferences.expertise) {
                            ForEach(AIMExpertise.allCases, id: \.self) { Text(expertiseLabel($0)).tag($0) }
                        }
                        Picker("settings.preferences.length", selection: $store.preferences.responseLength) {
                            ForEach(AIMResponseLength.allCases, id: \.self) { Text(lengthLabel($0)).tag($0) }
                        }
                        Toggle("settings.preferences.emojis", isOn: $store.preferences.emojis)
                        if store.preferences.emojis {
                            Stepper(value: $store.preferences.maxEmojis, in: 0...20) {
                                Text(String(format: String(localized: "settings.preferences.max_emojis"), store.preferences.maxEmojis))
                            }
                        }
                    }
                    Section("settings.preferences.app") {
                        Toggle("settings.preferences.haptics", isOn: $store.preferences.hapticFeedback)
                        Picker("settings.preferences.retention", selection: $store.preferences.libraryRetentionDays) {
                            Text("30 days").tag(30)
                            Text("60 days").tag(60)
                            Text("90 days").tag(90)
                            Text("365 days").tag(365)
                        }
                    }
                    Section("settings.preferences.privacy") {
                        Toggle("settings.preferences.share_profile", isOn: $store.preferences.shareProfileWithAI)
                        Toggle("settings.preferences.memory", isOn: $store.preferences.memoryEnabled)
                    }
                    if let error = store.error {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                    Section {
                        Button {
                            Task { await store.save() }
                        } label: {
                            HStack {
                                Spacer()
                                if store.isSaving { ProgressView().padding(.trailing, 7) }
                                Text("common.save").fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(store.isSaving)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { await store.load() }
        .accessibilityIdentifier("preferences-settings-screen")
    }

    private func toneLabel(_ value: AIMTone) -> LocalizedStringKey { LocalizedStringKey("preferences.tone.\(value.rawValue)") }
    private func styleLabel(_ value: AIMResponseStyle) -> LocalizedStringKey { LocalizedStringKey("preferences.style.\(value.rawValue)") }
    private func expertiseLabel(_ value: AIMExpertise) -> LocalizedStringKey { LocalizedStringKey("preferences.expertise.\(value.rawValue)") }
    private func lengthLabel(_ value: AIMResponseLength) -> LocalizedStringKey { LocalizedStringKey("preferences.length.\(value.rawValue)") }
}

@MainActor
@Observable
private final class AIMMemoryStore {
    var content = ""
    var version = 0
    var isLoading = false
    var isSaving = false
    var message: String?
    private let service: any CloudContentServicing

    init(service: any CloudContentServicing) { self.service = service }

    func load() async {
        isLoading = true; message = nil
        defer { isLoading = false }
        do {
            let document = try await service.loadMemoryDocument()
            content = document.content; version = document.version
        } catch { message = String(localized: "settings.memory.load_error") }
    }

    func save() async {
        isSaving = true; message = nil
        defer { isSaving = false }
        do {
            let document = try await service.saveMemoryDocument(content: content, expectedVersion: version)
            version = document.version
            message = String(localized: "settings.memory.saved")
        } catch CloudContentError.conflict {
            message = String(localized: "settings.memory.conflict")
            let document = try? await service.loadMemoryDocument()
            if let document { content = document.content; version = document.version }
        } catch { message = String(localized: "settings.memory.save_error") }
    }
}

private struct AIMMemorySettingsView: View {
    let onBack: () -> Void
    @State private var store: AIMMemoryStore
    @FocusState private var editorFocused: Bool

    init(service: any CloudContentServicing, onBack: @escaping () -> Void) {
        self.onBack = onBack
        _store = State(initialValue: AIMMemoryStore(service: service))
    }

    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsSubheader(title: "settings.memory", onBack: onBack)
            if store.isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("settings.memory.editor_body")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $store.content)
                        .font(.system(.body, design: .monospaced))
                        .focused($editorFocused)
                        .padding(10)
                        .scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            if store.content.isEmpty && !editorFocused {
                                Text("settings.memory.placeholder")
                                    .foregroundStyle(.tertiary)
                                    .padding(18)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .allowsHitTesting(false)
                            }
                        }
                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await store.save() }
                    } label: {
                        HStack {
                            if store.isSaving { ProgressView().tint(.white) }
                            Text("common.save").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity).frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .disabled(store.isSaving)
                }
                .padding(18)
            }
        }
        .task { await store.load() }
        .accessibilityIdentifier("memory-settings-screen")
    }
}

private struct AIMSettingsSubheader: View {
    let title: LocalizedStringKey
    let onBack: () -> Void
    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .aimGlassCircle()
            .accessibilityLabel("Back")
            .accessibilityIdentifier("settings-page-back")
            Spacer()
            Text(title).font(.system(size: 17, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 14)
        .aimSettingsHeader()
        .foregroundStyle(.primary)
    }
}

private struct AIMUsageSettingsView: View {
    let store: MainExperienceStore
    let chat: NativeChatStore
    let onBack: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsSubheader(title: "settings.usage", onBack: onBack)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    metric(copy("Conversations", "Conversations"), value: store.overview.sessions.count, icon: "bubble.left.and.bubble.right")
                    metric("Chat", value: count(.chat), icon: "bubble.left")
                    metric("Code", value: count(.code), icon: "chevron.left.forwardslash.chevron.right")
                    metric("Agent", value: count(.agent), icon: "cpu")
                    metric(copy("Computers", "Ordinateurs"), value: store.overview.machines.count, icon: "desktopcomputer")
                    metric(copy("Remote ready", "Remote prêts"), value: responsiveComputers, icon: "bolt.horizontal.circle")
                }
                .padding(18)

                VStack(alignment: .leading, spacing: 14) {
                    Text("API usage").font(.headline)
                    Text("Estimated cost: $\(chat.estimatedUSD.formatted(.number.precision(.fractionLength(2...6))))")
                    Text("Estimates use reported token counts and catalog prices. Unknown costs are not counted; these statistics are not a supplier invoice.").font(.footnote).foregroundStyle(.secondary)
                    Divider()
                    Text("ChatGPT usage").font(.headline)
                    Text("Plan integration pending applicable OpenAI approval. Provider limits and costs apply to your provider account.").font(.footnote).foregroundStyle(.secondary)
                    Divider()
                    Text("AIM offer").font(.headline)
                    Text("AIM is free and open source. Model providers may charge for usage with your own keys.").font(.footnote).foregroundStyle(.secondary)
                }.padding(22)
                Text(copy(
                    "These statistics come from your synchronized Remote mirror. Provider costs are shown separately.",
                    "Ces statistiques proviennent de votre miroir Remote synchronisé. Elles n’incluent aucune estimation de facturation ou d’abonnement."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await store.load() }
        }
        .accessibilityIdentifier("usage-settings-screen")
    }

    private var responsiveComputers: Int {
        store.overview.machines.filter { store.commandHealth(for: $0.id) == .responsive }.count
    }

    private func count(_ mode: RemoteMode) -> Int {
        store.overview.sessions.filter { $0.mode == mode }.count
    }

    private func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.secondary)
            Text(value.formatted()).font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
        .padding(17)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.08)) }
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}

private struct AIMPrivacySettingsView: View {
    let onBack: () -> Void
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsSubheader(title: "settings.privacy", onBack: onBack)
            AIMSettingsForm {
                Section {
                    if let privacyURL = URL(string: "https://aim-ai.tech/privacy-policy") {
                        Link(destination: privacyURL) {
                            settingsLink("settings.privacy.policy", icon: "hand.raised")
                        }
                    }
                    if let termsURL = URL(string: "https://aim-ai.tech/terms-of-service") {
                        Link(destination: termsURL) {
                            settingsLink("settings.privacy.terms", icon: "doc.text")
                        }
                    }
                } footer: { Text("settings.privacy.legal_body") }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("settings.privacy.remote_security", systemImage: "lock.shield")
                            .font(.headline)
                        Text("settings.privacy.remote_security_body")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy-settings-screen")
    }

    private func settingsLink(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).frame(width: 32)
            Text(title).fontWeight(.medium)
            Spacer()
            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .frame(minHeight: 44)
    }
}

@MainActor
@Observable
private final class AIMDataExportStore {
    var isExporting = false
    var isDeleting = false
    var exportedFile: URL?
    var error: String?
    private let service: any CloudContentServicing
    init(service: any CloudContentServicing) { self.service = service }

    func export() async {
        isExporting = true; error = nil
        defer { isExporting = false }
        do {
            let data = try await service.exportUserData()
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("aim-ai-data-export-\(formatter.string(from: Date())).json")
            try data.write(to: url, options: .atomic)
            exportedFile = url
        } catch { self.error = String(localized: "settings.data.export_error") }
    }

    func deleteAccount(email: String, confirmation: String) async -> Bool {
        guard !isDeleting else { return false }
        isDeleting = true
        error = nil
        defer { isDeleting = false }
        do {
            try await service.deleteAccount(confirmEmail: email, confirmation: confirmation)
            return true
        } catch {
            self.error = "The account could not be deleted. Check the confirmation and try again."
            return false
        }
    }
}

private struct AIMDataSettingsView: View {
    let onBack: () -> Void
    let onDeleted: () -> Void
    let remoteStore: MainExperienceStore
    let userEmail: String
    @Environment(\.locale) private var locale
    @State private var store: AIMDataExportStore
    @State private var diagnosticFile: URL?
    @State private var confirmEmail = ""
    @State private var confirmText = ""
    @State private var confirmsDeletion = false

    init(
        service: any CloudContentServicing,
        remoteStore: MainExperienceStore,
        userEmail: String,
        onBack: @escaping () -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.onBack = onBack
        self.onDeleted = onDeleted
        self.remoteStore = remoteStore
        self.userEmail = userEmail
        _store = State(initialValue: AIMDataExportStore(service: service))
    }

    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsSubheader(title: "settings.data", onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("settings.data.export", systemImage: "square.and.arrow.up")
                            .font(.headline)
                        Text("settings.data.export_body")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let file = store.exportedFile {
                            ShareLink(item: file) {
                                Label("settings.data.share_export", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity).frame(height: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.primary)
                        } else {
                            Button { Task { await store.export() } } label: {
                                HStack {
                                    if store.isExporting { ProgressView() }
                                    Text("settings.data.create_export")
                                }
                                .frame(maxWidth: .infinity).frame(height: 48)
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.isExporting)
                        }
                    }
                    .padding(16)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Remote diagnostics", systemImage: "stethoscope")
                            .font(.headline)
                        Text("A redacted JSON report contains command stages and safe error codes, never messages, tokens, email addresses, or complete paths.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let diagnosticFile {
                            ShareLink(item: diagnosticFile) {
                                Label("Share diagnostic report", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity).frame(height: 48)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                Task { diagnosticFile = await remoteStore.diagnosticReportFile() }
                            } label: {
                                Label("Create diagnostic report", systemImage: "doc.badge.gearshape")
                                    .frame(maxWidth: .infinity).frame(height: 48)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(16)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("settings.data.delete_account", systemImage: "person.crop.circle.badge.minus")
                            .font(.headline).foregroundStyle(.red)
                        Text(copy(
                            "This permanently deletes your AIM AI account and synchronized data. Enter your email and SUPPRIMER to continue.",
                            "Cette action supprime définitivement votre compte AIM AI et les données synchronisées. Saisissez votre e-mail et SUPPRIMER pour continuer."
                        ))
                            .font(.subheadline).foregroundStyle(.secondary)
                        TextField(copy("Account email", "E-mail du compte"), text: $confirmEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        TextField("SUPPRIMER", text: $confirmText)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) { confirmsDeletion = true } label: {
                            HStack {
                                if store.isDeleting { ProgressView().controlSize(.small) }
                                Text(copy("Delete my account", "Supprimer mon compte"))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!deletionInputIsValid || store.isDeleting)
                        .accessibilityIdentifier("delete-account-button")
                    }
                    .padding(16)
                    .background(Color.red.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))

                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                .padding(18)
            }
        }
        .accessibilityIdentifier("data-settings-screen")
        .confirmationDialog(
            copy("Delete this account permanently?", "Supprimer définitivement ce compte ?"),
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button(copy("Delete permanently", "Supprimer définitivement"), role: .destructive) {
                Task {
                    if await store.deleteAccount(email: confirmEmail, confirmation: confirmText) {
                        onDeleted()
                    }
                }
            }
            Button(copy("Cancel", "Annuler"), role: .cancel) {}
        } message: {
            Text(copy(
                "This cannot be undone.",
                "Cette action est irréversible."
            ))
        }
    }

    private var deletionInputIsValid: Bool {
        !userEmail.isEmpty
            && confirmEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(userEmail) == .orderedSame
            && confirmText == "SUPPRIMER"
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}
