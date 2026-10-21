import AIMCore
import LocalAuthentication
import SwiftUI
import UIKit

struct MainExperienceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var interfaceLocale
    let identity: AppIdentity
    let directConnection: AIMDirectConnectionStore?
    let sessionStore: SessionStore?
    let cloudContentService: any CloudContentServicing
    let accountSessions: (any AccountSessionServicing)?
    var connectAccount: (() -> Void)? = nil
    @State private var appLock: AppLockService
    @State private var delegations: RemoteDelegationService
    @State private var didApplyStartScreen = false
    @State private var nativeChat: NativeChatStore
    @State private var presentedProjectID: UUID?
    @State private var searchState: AIMSearchState
    @State private var recentFilters: AIMConversationFilters

    @State private var store: MainExperienceStore
    @State private var drawerOpen = false
    @State private var settingsPresentation: AIMSettingsPresentation?
    @State private var pendingAccountConnection = false
    @State private var didOfferPairing = false
    @State private var backgroundedAt: Date?
    @AppStorage("aim.appearance") private var appearance = AIMAppearancePreference.system.rawValue
    @State private var drawerDrag: CGFloat = 0
    @State private var drawerMotion = AIMDrawerMotionState()
    @State private var drawerGestureStart: CGFloat?
    @State private var drawerGestureRest: CGFloat = 0
    @State private var isCompletingConversationBack = false
    private enum BackTarget: Equatable {
        case project(UUID)
        case projectList
        case destination(MainDestination)
    }
    @State private var creationFocusRequest = 0
    @State private var didRequestInitialCreationFocus = false
    @State private var forwardSourceDestination: MainDestination?
    @State private var forwardProgress: CGFloat = 0
    @State private var keyboardOverlap: CGFloat = 0
    @State private var panelPresentations = AIMPanelPresentationState()

    init(identity: AppIdentity, sessionStore: SessionStore? = nil, remoteService: any RemoteServicing, directConnection: AIMDirectConnectionStore? = nil, cloudContentService: any CloudContentServicing, accountSessions: (any AccountSessionServicing)? = nil, contentSync: (any AccountContentSyncing)? = nil, connectAccount: (() -> Void)? = nil) {
        _searchState = State(initialValue: AIMSearchState(accountID: identity.storageID))
        _recentFilters = State(initialValue: AIMConversationFilters(accountID: identity.storageID, surface: "recent"))
        self.accountSessions = identity.isLocal ? nil : accountSessions
        _delegations = State(initialValue: RemoteDelegationService(accountID: identity.storageID, remote: remoteService))
        #if DEBUG && targetEnvironment(simulator)
        if remoteService is UITestRemoteService {
            // Unsigned Simulator fixtures have no production Keychain entitlement.
            // The real service remains fail-closed and always uses system authentication.
            _appLock = State(initialValue: AppLockService(accountID: identity.storageID, authenticator: UITestLockAuthenticator(), secureStore: UITestLockStore()))
        } else { _appLock = State(initialValue: AppLockService(accountID: identity.storageID)) }
        #else
        _appLock = State(initialValue: AppLockService(accountID: identity.storageID))
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if remoteService is UITestRemoteService {
            _nativeChat = State(initialValue: NativeChatStore(accountID: identity.storageID, sync: identity.isLocal ? nil : contentSync, credentials: UITestLockStore()))
        } else { _nativeChat = State(initialValue: NativeChatStore(accountID: identity.storageID, sync: identity.isLocal ? nil : contentSync)) }
        #else
        _nativeChat = State(initialValue: NativeChatStore(accountID: identity.storageID, sync: identity.isLocal ? nil : contentSync))
        #endif
        self.identity = identity
        self.directConnection = directConnection
        self.sessionStore = sessionStore
        self.connectAccount = connectAccount
        self.cloudContentService = identity.isLocal ? LocalContentService(storageID: identity.storageID) : cloudContentService
        let directProbe: (@MainActor () async throws -> Bool)?
        if let directConnection { directProbe = { try await directConnection.service.isAuthenticatedDirectSession() } }
        else { directProbe = nil }
        let experience = MainExperienceStore(service: remoteService, queueAccountID: identity.storageID,
            recoverAuthentication: { await sessionStore?.recoverForProtectedOperation() ?? false },
            directSessionProbe: directProbe)
        experience.setSecurityContextValidator {
            if identity.isLocal { return directConnection != nil }
            guard case let .authenticated(current) = sessionStore?.state else { return false }
            return current.id == identity.storageID
        }
        _store = State(initialValue: experience)
    }

    private var authenticatedSurface: some View {
        Group {
            if appLock.isLocked || appLock.isConcealed {
                VStack(spacing: 24) {
                    Image(systemName: "faceid").font(.system(size: 48))
                    Text("AIM").font(AIMDesign.titleFont(size: 30))
                    if !appLock.isConcealed {
                        Button("Unlock AIM") { Task { await appLock.unlock() } }
                            .disabled(appLock.isAuthenticating).accessibilityIdentifier("app-lock-unlock")
                        if let error = appLock.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                .accessibilityIdentifier("app-lock-screen")
                .onAppear { dismissKeyboard(); nativeChat.voiceController.stop(); nativeChat.stopSpeaking(); nativeChat.media.suspend(); nativeChat.suspendForProtection() }
            } else {
                unlockedBody
            }
        }
    }

    var body: some View {
        readObservedSurface
        .onChange(of: AIMNotificationCenter.shared.pendingConversation) { _, _ in openPendingNotification() }
        .onChange(of: appLock.isConcealed) { _, _ in updateNotificationPresence(); openPendingNotification() }
        .onChange(of: appLock.isLocked) { _, locked in
            openPendingNotification(); updateNotificationPresence()
            if !locked && scenePhase == .active { Task { if await checkAccountSession() { nativeChat.resumePendingSubmissions() } } }
        }
        .onChange(of: nativeChat.selectedID) { _, _ in updateNotificationPresence() }
        .onChange(of: store.destination) { _, _ in updateNotificationPresence() }
        .onChange(of: settingsPresentation != nil) { _, _ in updateNotificationPresence() }
        .onChange(of: drawerOpen) { _, _ in updateNotificationPresence() }
        .onChange(of: nativeChat.conversations.map(\.id)) { _, _ in openPendingNotification() }
        .onChange(of: store.overview.sessions.map(\.id)) { _, _ in openPendingNotification() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive: appLock.becameInactive(); updateNotificationPresence()
            case .background:
                appLock.enteredBackground(); updateNotificationPresence()
                Task { await directConnection?.setForeground(false) }
            case .active:
                appLock.becameActive(); updateNotificationPresence(); openPendingNotification()
                Task { await directConnection?.setForeground(true) }
            @unknown default: break
            }
        }
        .task {
            // This lifecycle belongs to the whole experience, including the
            // app-lock screen; an inactive camera/Face ID sheet is not a logout.
            await directConnection?.setForeground(scenePhase != .background)
        }
        .onDisappear {
            // A profile/account surface exits explicitly. Do not attach this to
            // unlockedBody: it disappears on background when AppLock conceals it.
            Task { await directConnection?.disconnect(rememberChoice: false) }
        }
    }

    private var readObservedSurface: some View {
        authenticatedSurface
        .onChange(of: nativeChat.conversations) { _, _ in updateNotificationPresence() }
        .onChange(of: store.overview.sessions) { _, _ in updateNotificationPresence() }
        .onChange(of: store.messages.map { $0.id + ":" + $0.readState.rawValue }) { _, _ in acknowledgeVisibleResponses() }
        .onChange(of: store.overview.sessions.map(\.readState)) { _, _ in acknowledgeVisibleResponses() }
    }

    private func checkAccountSession() async -> Bool {
        do { try await accountSessions?.register(device: UIDevice.current.name, platform: "iOS " + UIDevice.current.systemVersion) }
        catch AccountServiceError.revoked {
            nativeChat.media.suspend()
            await AIMSkillsStore.shared.configure(account: nil)
            await nativeChat.stopAndWait(); appLock.lock(); await store.lockRemote()
            try? await accountSessions?.acknowledgeLocalStop()
            await AIMNotificationCenter.shared.disconnect(); await sessionStore?.signOut(); return false
        } catch { /* Offline and prepared-server states do not erase local account data. */ }
        return true
    }

    private var unlockedBody: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width
            let safeArea = AIMWindowSafeArea.current
            let drawerWidth = CGFloat(RemoteDrawerRules.width(containerWidth: containerWidth))
            let contentHeight = max(1, geometry.size.height)
            let activeDrawerDrag = (!drawerOpen && backTarget != nil) ? 0 : drawerDrag
            let conversationBackOffset = (!drawerOpen && backTarget != nil)
                ? min(containerWidth, max(0, drawerDrag))
                : 0
            let conversationBackProgress = containerWidth > 0 ? conversationBackOffset / containerWidth : 0
            let contentOffset = CGFloat(
                RemoteDrawerRules.offset(
                    isOpen: drawerOpen,
                    dragTranslation: activeDrawerDrag,
                    containerWidth: containerWidth
                )
            )
            let progress = RemoteDrawerRules.progress(offset: contentOffset, containerWidth: containerWidth)

            ZStack(alignment: .leading) {
                AIMSidebarView(
                    identity: identity,
                    sessions: AccountConversationIdentity.sessions(accountID: identity.storageID.uuidString, native: nativeChat.searchSessions, remote: store.recentChatSessions),
                    filters: recentFilters,
                    status: { nativeChat.conversationStatus(session: $0) },
                    nativeSessions: nativeChat.conversations,
                    openNativeSession: { conversation in
                        Task { await openChatConversation(conversation.id.uuidString); closeDrawer() }
                    },
                    machines: store.overview.machines,
                    selection: store.destination,
                    safeTop: safeArea.top,
                    safeBottom: safeArea.bottom,
                    startNewChat: {
                        nativeChat.newConversation()
                        store.startNewChat()
                        closeDrawer()
                    },
                    navigate: requestNavigation,
                    openSession: requestSidebarSession,
                    deleteSessions: { ids in await store.deleteSessions(ids: ids) },
                    cloudService: cloudContentService,
                    moveSessions: { ids, projectID in
                        var failed = Set<String>()
                        for id in ids {
                            guard let session = store.overview.sessions.first(where: { $0.id == id }),
                                  await store.setProject(projectID, session: session) else { failed.insert(id); continue }
                        }
                        return failed
                    },
                    openSettings: {
                        settingsPresentation = AIMSettingsPresentation(initialPage: .root)
                        drawerOpen = false
                    },
                    closeDrawer: closeDrawer,
                    drawerIsOpen: $drawerOpen,
                    drawerPanChanged: { translation, currentlyOpen in
                        handleDrawerPanChanged(translation: translation, currentlyOpen: currentlyOpen)
                    },
                    drawerPanEnded: { translation, projectedTranslation, currentlyOpen in
                        handleDrawerPanEnded(
                            translation: translation,
                            projectedTranslation: projectedTranslation,
                            currentlyOpen: currentlyOpen,
                            containerWidth: containerWidth
                        )
                    }
                )
                .frame(width: drawerWidth)
                .frame(height: contentHeight)
                // Keep the drawer out of the rendered hierarchy while it is
                // fully closed. Otherwise iOS' translucent keyboard reveals
                // its conversation rows underneath the active screen.
                .opacity(progress > 0.001 ? 1 : 0)
                .accessibilityHidden(progress < 0.5)

                if let target = backTarget, conversationBackOffset > 0 {
                    backPreview(target, safeTop: safeArea.top, safeBottom: safeArea.bottom)
                    .frame(width: containerWidth, height: contentHeight)
                    .background(Color(uiColor: .systemBackground))
                    .scaleEffect(0.96 + (0.04 * conversationBackProgress))
                    .offset(x: -28 * (1 - conversationBackProgress))
                    .allowsHitTesting(false).accessibilityHidden(true)
                }

                if let forwardSourceDestination, forwardProgress > 0.001 {
                    destinationView(
                        destination: forwardSourceDestination,
                        safeTop: safeArea.top,
                        safeBottom: safeArea.bottom
                    )
                    .frame(width: containerWidth, height: contentHeight)
                    .background(Color(uiColor: .systemBackground))
                    .scaleEffect(1 - (0.035 * (1 - forwardProgress)))
                    .offset(x: -24 * (1 - forwardProgress))
                    .allowsHitTesting(false)
                }

                AIMMovingConversation(
                    offset: contentOffset + conversationBackOffset + (containerWidth * forwardProgress),
                    motion: drawerMotion,
                    open: drawerOpen,
                    close: closeDrawer,
                    changed: { handleDrawerPanChanged(translation: $0, currentlyOpen: true) },
                    ended: { translation, projected in
                        handleDrawerPanEnded(translation: translation, projectedTranslation: projected,
                                             currentlyOpen: true, containerWidth: containerWidth)
                    }
                ) {
                destinationView(
                    destination: store.destination,
                    safeTop: safeArea.top,
                    safeBottom: safeArea.bottom
                )
                    .environment(\.aimSidebarPresented, drawerOpen || progress > 0.001)
                    .environment(\.aimKeyboardOverlap, keyboardOverlap)
                    .environment(\.aimPanelPresentationState, panelPresentations)
                    .frame(width: containerWidth, height: contentHeight)
                    .background(Color(uiColor: .systemBackground))
                    .overlay(alignment: .top) {
                        if !drawerOpen, settingsPresentation == nil, nativeNoticeVisible {
                            AIMNativeChatErrorNotice(chat: nativeChat)
                                .padding(.horizontal, 16).padding(.top, safeArea.top + 62)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    // The separate cover intercepts touches. Disabling the
                    // entire SwiftUI subtree can deactivate its text editor.
                    .allowsHitTesting(AIMExperimentalKeyboardHost.enabled || !drawerOpen)
                }
                .frame(width: containerWidth, height: contentHeight)

                if drawerOpen {
                    Color.clear
                        .frame(width: max(0, containerWidth - drawerWidth))
                        .contentShape(Rectangle())
                        .onTapGesture { closeDrawer() }
                        .accessibilityLabel(Text("sidebar.close"))
                        .accessibilityAddTraits(.isButton)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .frame(height: contentHeight, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                ZStack {
                    Color(uiColor: .systemBackground)
                    if progress > 0.001 {
                        AIMSidebarBackground()
                    }
                }
                .ignoresSafeArea()
            }
            .background {
                AIMHorizontalPanObserver(
                    enabled: settingsPresentation == nil && !panelPresentations.blocksBackground,
                    includeScrollViews: false,
                    drawerIsOpen: $drawerOpen,
                    changed: { translation, currentlyOpen in
                        handleDrawerPanChanged(translation: translation, currentlyOpen: currentlyOpen)
                    },
                    ended: { translation, projectedTranslation, currentlyOpen in
                        handleDrawerPanEnded(
                            translation: translation,
                            projectedTranslation: projectedTranslation,
                            currentlyOpen: currentlyOpen,
                            containerWidth: containerWidth
                        )
                    }
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background {
                AIMKeyboardLayoutObserver(overlap: $keyboardOverlap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // The page always occupies the whole window. Individual composers use
        // UIKeyboardLayoutGuide to move above the keyboard without resizing the
        // sidebar, title or conversation hierarchy.
        .ignoresSafeArea(.container)
        .ignoresSafeArea(.keyboard)
        .onChange(of: settingsPresentation?.id) { _, presentationID in
            if presentationID != nil { dismissKeyboard() }
        }
        .sheet(item: $settingsPresentation, onDismiss: {
            if pendingAccountConnection { pendingAccountConnection = false; connectAccount?() }
        }) { presentation in
            AIMSettingsPanel(
                directConnection: directConnection,
                identity: identity,
                store: store,
                cloudContentService: cloudContentService,
                appLock: appLock, nativeChat: nativeChat, accountSessions: accountSessions,
                initialPage: presentation.initialPage,
                origin: presentation.origin,
                connectAccount: connectAccount.map { _ in
                    { Task {
                        nativeChat.media.suspend()
                        await nativeChat.stopAndWait()
                        await directConnection?.disconnect(rememberChoice: false)
                        pendingAccountConnection = true
                        settingsPresentation = nil
                    } }
                },
                signOut: {
                    Task {
                        nativeChat.media.suspend()
                        await AIMSkillsStore.shared.configure(account: nil)
                        await nativeChat.stopAndWait()
                        await store.lockRemote()
                        // This stop-only RPC succeeds only for our revoked session.
                        // Never acknowledge before its local producer has stopped.
                        try? await accountSessions?.acknowledgeLocalStop()
                        await AIMNotificationCenter.shared.disconnect()
                        await sessionStore?.signOut()
                    }
                }
            )
            .preferredColorScheme(selectedAppearance.colorScheme)
        }
        .task {
            AIMLogoImageCache.shared.prewarmKnown()
            await directConnection?.start()
            await AIMSkillsStore.shared.configure(account: identity.storageID)
            AIMSkillsStore.shared.selectMac(store.selectedMachineID)
            AIMSkillsStore.shared.importRead = { name in try await store.skillCommand(name: name) }
            AIMSkillsStore.shared.importWrite = { skill in try await store.installSkill(skill) }
            store.queueDeliveryActive = scenePhase == .active
            guard await checkAccountSession() else { return }
            if !identity.isLocal || directConnection != nil { await store.loadRemoteSecurity() }
            if let state = store.deviceAuthorizationState, state.version == 2 { try? appLock.preserveLegacyProtection(state.legacyProtected) }
            if appLock.isLocked { return }
            if let profile = try? await cloudContentService.loadProfile() { nativeChat.profileInstructions = profile.personalPreferences }
            if !identity.isLocal || directConnection != nil { await store.load() }
            if !didApplyStartScreen { didApplyStartScreen = true; if let mode = RemoteMode(rawValue: UserDefaults.standard.string(forKey: "aim.start-screen") ?? "chat"), mode != .chat { store.mode = mode; store.navigate(to: .newRemote(mode)) } }
            await AIMNotificationCenter.shared.bind(accountID: identity.storageID, service: nativeChat.notificationService)
            await nativeChat.syncAccountData()
            if scenePhase == .active && !appLock.isLocked && !appLock.isConcealed { nativeChat.resumePendingSubmissions() }
            await nativeChat.media.synchronize()
            if store.macSettingsAvailability == .ready { await AIMSkillsStore.shared.refreshMac(); await store.refreshMacConnectors() }
            Task {
                await store.probeSelectedRemoteHealth()
                await store.deliverQueuedMessages()
            }
            // Direct Chat works without pairing. Pairing is offered through Computer connection.
            if !didRequestInitialCreationFocus,
               case .newChat = store.destination
            {
                didRequestInitialCreationFocus = true
                focusCreationComposerAfterTransition()
            }
            guard !identity.isLocal || directConnection != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                guard await checkAccountSession() else { return }
                await nativeChat.synchronize()
                await nativeChat.syncAccountData()
                if scenePhase == .active && !appLock.isLocked && !appLock.isConcealed { nativeChat.resumePendingSubmissions() }
                await nativeChat.media.synchronize()
                if !identity.isLocal || directConnection != nil { await store.load() }
                if !identity.isLocal || directConnection != nil { await store.loadRemoteSecurity() }
                if store.macSettingsAvailability == .ready { await AIMSkillsStore.shared.refreshMac(); await store.refreshMacConnectors() }
                    await store.probeSelectedRemoteHealth()
                await store.deliverQueuedMessages()
                if store.selectedSessionID != nil {
                    await store.refreshSelectedSession()
                }
                // Direct Chat works without pairing. Pairing is offered through Computer connection.
            }
        }
        .task(id: (store.selectedSessionID ?? "") + String(describing: directConnection?.state)) {
            guard !identity.isLocal || directConnection != nil else { return }
            await store.observeRemoteChanges()
        }
        .onChange(of: directConnection?.state) { _, state in
            guard case .connected = state else { store.invalidateRemoteSecurityContext(); return }
            Task {
                await store.loadRemoteSecurity(); await store.load(); await store.probeSelectedRemoteHealth()
            }
        }
        .onChange(of: store.selectedMachineID) { _, id in
            AIMSkillsStore.shared.selectMac(id)
            Task { await store.refreshMacConnectors(); if store.macSettingsAvailability == .ready { await AIMSkillsStore.shared.refreshMac() } }
        }
        .onChange(of: store.macSettingsAvailability) { _, availability in
            if availability == .ready { Task { await AIMSkillsStore.shared.refreshMac(); await store.refreshMacConnectors() } }
        }
        .onDisappear {
            Task { await nativeChat.stopAndWait() }
            nativeChat.media.suspend()
            store.queueDeliveryActive = false
            store.invalidateRemoteSecurityContext()
        }
        .onChange(of: scenePhase) { _, phase in
            store.queueDeliveryActive = phase == .active
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                backgroundedAt = nil
                Task {
                    if !identity.isLocal || directConnection != nil { await store.loadRemoteSecurity() }
                            if !identity.isLocal || directConnection != nil { await store.load() }
                    if store.selectedSessionID != nil { await store.refreshSelectedSession() }
                    await store.probeSelectedRemoteHealth()
                    await store.deliverQueuedMessages()
                }
            default:
                break
            }
        }
        .background {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("authenticated-shell")
        }
        .onChange(of: store.isSending) { wasSending, isSending in
            guard wasSending, !isSending else { return }
            if store.errorMessage == nil { AIMHaptics.success() }
            else { AIMHaptics.error() }
        }
    }

    private func acknowledgeVisibleResponses() {
        guard scenePhase == .active, !appLock.isLocked, !appLock.isConcealed,
              settingsPresentation == nil, !drawerOpen,
              !panelPresentations.blocksBackground else { return }
        let id: String
        if case let .conversation(value) = store.destination { id = value }
        else if case .newChat = store.destination, let value = nativeChat.selectedID { id = value.uuidString }
        else { return }
        let sessions = AccountConversationIdentity.sessions(accountID: identity.storageID.uuidString, native: nativeChat.searchSessions, remote: store.overview.sessions)
        guard let session = sessions.first(where: { AccountConversationIdentity.matches($0.id, id) }) else { return }
        if nativeChat.executionTarget == .thisDevice || displayedRemoteSession(id) == nil {
            guard let loaded = nativeChat.selected, AccountConversationIdentity.matches(loaded.id.uuidString, id) else { return }
            nativeChat.acknowledge(session: session, loadedResponseIDs: Set(loaded.messages.filter { $0.role == .assistant }.map { $0.id.uuidString }))
        } else {
            guard store.selectedSessionID.map({ AccountConversationIdentity.matches($0, id) }) == true else { return }
            nativeChat.acknowledge(session: session, loadedResponseIDs: Set(store.messages.filter { $0.role == .assistant && !$0.readState.blocksReading }.map(\.id)))
        }
    }

    private func conversationSearchResults(_ query: String) -> [RemoteSession] {
        let matching = Set((nativeChat.search(query) + store.searchSessions(matching: query)).map { AccountConversationIdentity.normalized($0.id) })
        return AccountConversationIdentity.sessions(accountID: identity.storageID.uuidString, native: nativeChat.searchSessions, remote: store.searchSessions(matching: ""))
            .filter { matching.contains(AccountConversationIdentity.normalized($0.id)) }
    }

    private func updateNotificationPresence() {
        let viewedConversation: UUID?
        if settingsPresentation == nil, !drawerOpen, !panelPresentations.blocksBackground, !appLock.isLocked, !appLock.isConcealed {
            if case let .conversation(id) = store.destination {
                if nativeChat.executionTarget == .thisDevice || displayedRemoteSession(id) == nil {
                    viewedConversation = nativeChat.selected.flatMap { AccountConversationIdentity.matches($0.id.uuidString, id) ? $0.id : nil }
                } else {
                    viewedConversation = displayedRemoteSession(id).flatMap { !$0.readState.blocksReading && store.messages.allSatisfy({ !$0.readState.blocksReading }) ? UUID(uuidString: $0.id) : nil }
                }
            } else if case .newChat = store.destination { viewedConversation = nativeChat.selectedID }
            else { viewedConversation = nil }
        } else { viewedConversation = nil }
        acknowledgeVisibleResponses()
        let sessions = AccountConversationIdentity.sessions(accountID: identity.storageID.uuidString, native: nativeChat.searchSessions, remote: store.overview.sessions)
        AIMNotificationCenter.shared.reconcileAttention(sessions.map { ($0, nativeChat.conversationStatus(session: $0)) }, visible: scenePhase == .active ? viewedConversation : nil)
        Task { await AIMNotificationCenter.shared.presence(foreground: scenePhase == .active, conversation: viewedConversation, concealed: appLock.isLocked || appLock.isConcealed) }
    }
    private func openPendingNotification() {
        guard !appLock.isLocked, !appLock.isConcealed, let id = AIMNotificationCenter.shared.pendingConversation else { return }
        if let conversation = nativeChat.conversations.first(where: { $0.id == id }) {
            Task { await openChatConversation(conversation.id.uuidString) }
            AIMNotificationCenter.shared.pendingConversation = nil
        } else if let conversation = store.overview.sessions.first(where: { AccountConversationIdentity.matches($0.id, id.uuidString) }) {
            requestSession(conversation); AIMNotificationCenter.shared.pendingConversation = nil
        }
    }

    private func nativeChatView(safeTop: CGFloat, safeBottom: CGFloat, composerOnly: Bool = false,
                                preview: Bool = false, previewProjectID: UUID? = nil) -> some View {
        AIMNativeChatView(chat: nativeChat, remote: store, delegations: delegations, safeTop: safeTop, safeBottom: safeBottom,
            openMenu: openDrawer, selectMode: requestCreationMode,
            openProviders: openNativeProviders, openConnection: openNativeConnection, selectComputer: selectNativeComputer, selectThisDevice: selectThisDevice, openPersonalization: { store.navigate(to: .personalization) },
            composerOnly: composerOnly, isNavigationPreview: preview, previewProjectID: previewProjectID,
            backToProject: !composerOnly ? nativeConversationProjectID.map { id in { beginBack(.project(id)) } } : nil,
            onSubmitted: { id in
                if composerOnly { Task { await openChatConversation(id.uuidString) } }
            })
    }
    private func openNativeProviders() { settingsPresentation = AIMSettingsPresentation(initialPage: .providers) }
    private func openNativeConnection() { settingsPresentation = AIMSettingsPresentation(initialPage: .connection, origin: .connectionShortcut) }
    private func selectNativeComputer(_ id: String, _ modelID: String?) {
        Task {
            await store.selectMachine(id: id)
            nativeChat.executionTarget = .computer(machineID: id)
            if let modelID,
               let model = store.selectedMachine?.capabilities?.models.first(where: {
                   $0.id == modelID && ($0.provider == "local" || $0.via == "local")
               }) { store.selectModel(model) }
            if let conversation = nativeChat.selected { await openChatConversation(conversation.id.uuidString) }
            else if case let .conversation(conversationID) = store.destination { await openChatConversation(conversationID) }
            else { store.startNewChat() }
        }
    }

    private func selectThisDevice() {
        nativeChat.executionTarget = .thisDevice
        if case let .conversation(id) = store.destination {
            Task { await openChatConversation(id) }
        }
    }

    private func openChatConversation(_ id: String) async {
        // Consultation can load both references but never queues a model turn.
        if let native = nativeChat.conversations.first(where: { AccountConversationIdentity.matches($0.id.uuidString, id) }) {
            await nativeChat.open(native)
        }
        if case let .computer(machineID) = nativeChat.executionTarget,
           let remote = store.overview.sessions.first(where: { $0.mode == .chat && $0.machineID == machineID && AccountConversationIdentity.matches($0.id, id) }) {
            await store.selectSession(remote)
        } else {
            store.mode = .chat
            store.navigate(to: .conversation(id))
        }
    }

    private func displayedRemoteSession(_ id: String) -> RemoteSession? {
        let matches = store.overview.sessions.filter { AccountConversationIdentity.matches($0.id, id) }
        if case let .computer(machineID) = nativeChat.executionTarget {
            return matches.first(where: { $0.machineID == machineID }) ?? matches.first
        }
        return matches.first
    }

    private var nativeNoticeVisible: Bool {
        guard nativeChat.errorMessage != nil, nativeChat.executionTarget == .thisDevice else { return false }
        switch store.destination {
        case .newChat, .projects: return true
        case .conversation(let id): return nativeChat.conversations.contains { AccountConversationIdentity.matches($0.id.uuidString, id) }
        default: return false
        }
    }

    @ViewBuilder
    private func destinationView(
        destination: MainDestination,
        safeTop: CGFloat,
        safeBottom: CGFloat
    ) -> some View {
        switch destination {
        case .newChat:
            if nativeChat.executionTarget == .thisDevice {
                nativeChatView(safeTop: safeTop, safeBottom: safeBottom)
            } else {
            AIMNewChatView(
                text: creationTextBinding(for: .chat),
                attachments: creationAttachmentsBinding(for: .chat),
                titleKey: store.creationTitleKey,
                computerState: store.computerState,
                machines: store.overview.machines,
                selectedMachineID: store.selectedMachineID,
                selectedMachineName: store.selectedMachineDisplayName,
                selectMachine: { id in Task { await store.selectMachine(id: id) } },
                commandHealth: store.selectedMachine.map { store.commandHealth(for: $0.id) } ?? .unresponsive,
                inlineErrorMessage: store.inlineErrorMessage,
                commandErrorMessage: store.errorMessage,
                isSending: store.isSending,
                capabilities: store.selectedMachine?.capabilities,
                modelID: store.selectedModelID,
                modelName: store.selectedMachine?.capabilities?.models.first(where: {
                    $0.id == store.selectedModelID && (store.selectedModelProvider == nil || $0.provider == store.selectedModelProvider)
                })?.name
                    ?? AIMModelNamePresentation.displayName(for: store.selectedModelID),
                safeTop: safeTop,
                safeBottom: safeBottom,
                focusRequest: creationFocusRequest,
                openMenu: openDrawer,
                selectMode: requestCreationMode,
                openPersonalization: { store.navigate(to: .personalization) },
                retry: {
                    Task {
                        if !identity.isLocal || directConnection != nil { await store.load() }
                        await store.probeSelectedRemoteHealth()
                    }
                },
                send: { text, attachments in
                    await store.sendNewChat(text: text, attachments: attachments)
                },
                uploadAttachment: { data, name, mimeType, options in
                    await store.uploadNewChatAttachment(data: data, name: name, mimeType: mimeType, options: options)
                },
                changeModel: { modelID, effort in
                    guard store.selectedMachine?.capabilities?.models.contains(where: { $0.id == modelID }) == true else {
                        return false
                    }
                    store.selectedModelID = modelID
                    store.selectedEffort = effort
                    return true
                },
                usePhone: { nativeChat.executionTarget = .thisDevice },
                changeModelSelection: { model, effort in
                    guard store.selectedMachine?.capabilities?.models.contains(where: { $0.id == model.id && $0.provider == model.provider }) == true else { return false }
                    store.selectModel(model)
                    store.selectedEffort = effort
                    return true
                },
                modelProvider: store.selectedModelProvider,
                manageConnections: openNativeConnection,
                remoteStore: store
            )
            }
        case .newRemote where identity.isLocal && directConnection == nil, .code where identity.isLocal && directConnection == nil, .agent where identity.isLocal && directConnection == nil:
            VStack(spacing: 20) {
                HStack { Button(action: openDrawer) { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44) }; Spacer() }
                ContentUnavailableView("Mac connection unavailable", systemImage: "desktopcomputer",
                    description: Text("Direct pairing could not be opened on this iPhone. Unlock the iPhone and reopen AIM, then use Computer connection in Settings. A cloud account is optional. Chat and projects remain available locally."))
                if let connectAccount { Button("Connect a cloud account", action: connectAccount) }
                Spacer()
            }.padding(.top, safeTop).padding(.horizontal, 20)
        case let .newRemote(mode):
            AIMNewRemoteSessionView(
                mode: mode,
                store: store,
                safeTop: safeTop,
                safeBottom: safeBottom,
                focusRequest: creationFocusRequest,
                selectMode: requestCreationMode,
                cancel: { store.navigate(to: mode == .code ? .code : .agent) },
                openPersonalization: { store.navigate(to: .personalization) }
            )
        case .search:
            AIMSearchView(
                state: searchState, safeBottom: safeBottom,
                sessions: AccountConversationIdentity.sessions(accountID: identity.storageID.uuidString, native: nativeChat.searchSessions, remote: store.overview.sessions),
                safeTop: safeTop,
                machines: store.overview.machines,
                thisDeviceID: nativeChat.deviceID,
                status: { nativeChat.conversationStatus(session: $0) },
                openMenu: openDrawer,
                results: conversationSearchResults,
                openSession: { session in
                    if let item = nativeChat.conversations.first(where: { AccountConversationIdentity.matches($0.id.uuidString, session.id) }) {
                        Task { await openChatConversation(item.id.uuidString) }
                    } else { requestSession(session) }
                }
            )
        case .library:
            AIMLibraryView(service: cloudContentService, media: nativeChat.media, safeTop: safeTop, openMenu: openDrawer)
        case .personalization:
            AIMPersonalizationView(service: cloudContentService, safeTop: safeTop, openMenu: openDrawer, connectors: nativeChat.connectors, remote: store.macConnectors.map { .init($0, available: store.macSettingsAvailability == .ready) }, openSettings: { destination in nativeChat.pendingSettingsDestination = destination; settingsPresentation = .init(initialPage: .plugins) })
        case .code:
            AIMSessionListView(
                mode: .code,
                machines: store.overview.machines,
                commandHealth: store.effectiveCommandHealthByMachineID,
                sessions: store.overview.sessions.filter { $0.mode == .code },
                safeTop: safeTop,
                safeBottom: safeBottom,
                openMenu: openDrawer,
                addDevice: { settingsPresentation = AIMSettingsPresentation(initialPage: .connection, origin: .connectionShortcut) },
                openSession: requestSession,
                startNewSession: {
                    store.startNewRemoteSession(mode: .code)
                    focusCreationComposerAfterTransition()
                },
                refreshHealth: { await store.probeSelectedRemoteHealth() }
            )
        case .agent:
            AIMSessionListView(
                mode: .agent,
                machines: store.overview.machines,
                commandHealth: store.effectiveCommandHealthByMachineID,
                sessions: store.overview.sessions.filter { $0.mode == .agent },
                safeTop: safeTop,
                safeBottom: safeBottom,
                openMenu: openDrawer,
                addDevice: { settingsPresentation = AIMSettingsPresentation(initialPage: .connection, origin: .connectionShortcut) },
                openSession: requestSession,
                startNewSession: {
                    store.startNewRemoteSession(mode: .agent)
                    focusCreationComposerAfterTransition()
                },
                refreshHealth: { await store.probeSelectedRemoteHealth() }
            )
        case .projects:
            projectsView(safeTop: safeTop, safeBottom: safeBottom, selection: $presentedProjectID)
        case let .conversation(id):
            if nativeChat.conversations.contains(where: { AccountConversationIdentity.matches($0.id.uuidString, id) }),
               nativeChat.executionTarget == .thisDevice || displayedRemoteSession(id) == nil {
                nativeChatView(safeTop: safeTop, safeBottom: safeBottom)
            } else if let session = displayedRemoteSession(id) {
                AIMConversationView(
                    session: session,
                    store: store,
                    cloudContentService: cloudContentService,
                    messages: store.messages,
                    machineOnline: store.overview.machines.first(where: { $0.id == session.machineID })?.isOnline() == true,
                    commandHealth: store.commandHealth(for: session.machineID),
                    isSending: store.isSending,
                    errorMessage: store.errorMessage,
                    safeTop: safeTop,
                    safeBottom: safeBottom,
                    openMenu: {
                        switch session.mode {
                        case .code: store.navigate(to: .code)
                        case .agent: store.navigate(to: .agent)
                        case .chat: openDrawer()
                        }
                    },
                    openPersonalization: { store.navigate(to: .personalization) },
                    refreshHealth: {
                        await store.probeRemoteHealth(machineID: session.machineID)
                    },
                    send: { text, attachments in await store.sendMessage(text, attachments: attachments) },
                    uploadAttachment: { data, name, mimeType, options in
                        await store.uploadAttachment(data: data, name: name, mimeType: mimeType, options: options)
                    },
                    approve: { approved in await store.respondToApproval(approved: approved) },
                    answerQuestion: { answers in await store.respondToQuestion(answers: answers) },
                    changeModel: { model, effort in await store.setModel(model, effort: effort, provider: session.modelProvider) },
                    changeApprovalMode: { mode in await store.setApprovalMode(mode) },
                    sendGoal: { text, maximumTurns, attachments in
                        await store.sendGoal(text, maximumTurns: maximumTurns, attachments: attachments)
                    },
                    stop: { await store.stopGeneration() },
                    resume: { await store.resumeTurn() },
                    selectThisDevice: selectThisDevice,
                    selectComputer: { selectNativeComputer($0, nil) },
                    executionAllowed: session.mode != .chat || nativeChat.executionTarget == .computer(machineID: session.machineID),
                    sharedDraft: session.mode == .chat ? UUID(uuidString: session.id).map { conversationID in
                        Binding(get: { nativeChat.draftText(conversationID: conversationID) }, set: { nativeChat.setDraftText($0, conversationID: conversationID) })
                    } : nil,
                    changeModelSelection: { model, effort in await store.setModel(model.id, effort: effort, provider: model.provider) },
                    modelProvider: session.modelProvider
                )
            } else {
                AIMMissingConversationView(
                    openMenu: openDrawer,
                    retry: { Task { await store.load() } },
                    startNewChat: { store.startNewChat() }
                )
            }
        }
    }

    private func handleDrawerPanChanged(translation: CGFloat, currentlyOpen: Bool) {
        guard !panelPresentations.blocksBackground, settingsPresentation == nil,
              !isCompletingConversationBack else { return }
        if drawerGestureStart == nil {
            drawerGestureStart = drawerMotion.displayedOffset()
            drawerGestureRest = drawerOpen ? drawerMotion.restingOffset : 0
        }
        guard currentlyOpen || translation > 0 || (drawerGestureStart ?? 0) > 0 else { return }
        if !currentlyOpen && backTarget != nil { drawerDrag = translation }
        else { drawerDrag = translation + (drawerGestureStart ?? 0) - drawerGestureRest }
    }

    private func handleDrawerPanEnded(
        translation: CGFloat,
        projectedTranslation: CGFloat,
        currentlyOpen: Bool,
        containerWidth: CGFloat
    ) {
        guard !panelPresentations.blocksBackground, settingsPresentation == nil else { drawerDrag = 0; drawerGestureStart = nil; return }
        if !currentlyOpen,
           translation > 0,
           let backDestination = backTarget
        {
            drawerGestureStart = nil
            if max(translation, projectedTranslation) > 62 {
                AIMHaptics.impact(.medium)
                beginBack(backDestination, width: containerWidth)
            } else {
                withAnimation(AIMDesign.drawerAnimation) { drawerDrag = 0 }
            }
            return
        }

        let adjustment = (drawerGestureStart ?? drawerMotion.displayedOffset()) - drawerGestureRest
        drawerGestureStart = nil
        let translation = translation + adjustment
        let projectedTranslation = projectedTranslation + adjustment
        guard currentlyOpen || translation > 0 else {
            withAnimation(AIMDesign.drawerAnimation) { drawerDrag = 0 }
            return
        }
        let wasOpen = currentlyOpen
        let shouldOpen = RemoteDrawerRules.shouldOpen(
            currentlyOpen: currentlyOpen,
            translation: translation,
            predictedTranslation: projectedTranslation,
            containerWidth: containerWidth
        )
        if shouldOpen, !wasOpen, !AIMExperimentalKeyboardHost.enabled {
            // Preserve focus for a cancelled interactive reveal. Once the
            // threshold commits, let the keyboard animate away while the
            // drawer completes its own animation.
            dismissKeyboard()
        }
        withAnimation(AIMDesign.drawerAnimation) {
            drawerOpen = shouldOpen
            drawerDrag = 0
        }
        if shouldOpen != wasOpen { AIMHaptics.impact(.medium) }
    }

    private func requestNavigation(_ destination: MainDestination) {
        closeDrawer()
        AIMHaptics.selection()
        store.navigate(to: destination)
    }

    private func requestSession(_ session: RemoteSession) {
        if session.mode == .chat, nativeChat.conversations.contains(where: { AccountConversationIdentity.matches($0.id.uuidString, session.id) }) {
            Task { await openChatConversation(session.id); closeDrawer() }; return
        }
        closeDrawer()
        Task { await openSessionAnimated(session) }
    }

    /// The drawer already supplies the right-to-left movement for chat rows.
    /// Preparing the destination before closing it produces one coherent
    /// transition instead of stacking the forward-page animation on top.
    private func requestSidebarSession(_ session: RemoteSession) {
        if session.mode == .chat, nativeChat.conversations.contains(where: { AccountConversationIdentity.matches($0.id.uuidString, session.id) }) {
            Task { await openChatConversation(session.id); closeDrawer() }; return
        }
        store.prepareSessionSelection(session)
        closeDrawer()
        Task { await store.loadPreparedSession(session) }
    }

    @MainActor
    private func openSessionAnimated(_ session: RemoteSession) async {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        forwardSourceDestination = store.destination
        forwardProgress = reduceMotion ? 0 : 1
        await store.selectSession(session)
        guard !reduceMotion else {
            forwardSourceDestination = nil
            AIMHaptics.impact(.light)
            return
        }
        await Task.yield()
        withAnimation(.timingCurve(0.22, 0.72, 0.22, 1, duration: 0.34)) {
            forwardProgress = 0
        }
        try? await Task.sleep(for: .milliseconds(340))
        forwardSourceDestination = nil
        AIMHaptics.impact(.light)
    }

    private func requestCreationMode(_ mode: RemoteMode) {
        guard mode != store.mode else { return }
        dismissKeyboard()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            store.switchCreationMode(to: mode)
            focusCreationComposerAfterTransition()
        }
    }

    private func focusCreationComposerAfterTransition() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            creationFocusRequest += 1
        }
    }

    private func creationTextBinding(for mode: RemoteMode) -> Binding<String> {
        Binding(
            get: { store.creationDraft(for: mode).text },
            set: { value in
                var draft = store.creationDraft(for: mode)
                draft.text = value
                store.updateCreationDraft(draft, for: mode)
            }
        )
    }

    private func creationAttachmentsBinding(for mode: RemoteMode) -> Binding<[RemoteAttachmentReference]> {
        Binding(
            get: { store.creationDraft(for: mode).attachments },
            set: { value in
                var draft = store.creationDraft(for: mode)
                draft.attachments = value
                store.updateCreationDraft(draft, for: mode)
            }
        )
    }

    private var nativeConversationProjectID: UUID? {
        guard case let .conversation(id) = store.destination,
              let conversation = nativeChat.conversations.first(where: { AccountConversationIdentity.matches($0.id.uuidString, id) }),
              let projectID = conversation.projectID.flatMap(UUID.init(uuidString:)),
              nativeChat.projects.contains(where: { $0.id == projectID }) else { return nil }
        return projectID
    }
    private var backTarget: BackTarget? {
        if case .projects = store.destination,
           let id = presentedProjectID, nativeChat.projects.contains(where: { $0.id == id }) { return .projectList }
        if let id = nativeConversationProjectID { return .project(id) }
        guard case let .conversation(id) = store.destination, let session = store.selectedSession,
              AccountConversationIdentity.matches(session.id, id) else { return nil }
        switch session.mode {
        case .code: return .destination(.code)
        case .agent: return .destination(.agent)
        case .chat: return nil
        }
    }
    private func projectsView(safeTop: CGFloat, safeBottom: CGFloat, selection: Binding<UUID?>, preview: Bool = false) -> some View {
        AIMNativeProjectsView(chat: nativeChat, service: cloudContentService, safeTop: safeTop, safeBottom: safeBottom,
            openMenu: openDrawer, selectedProjectID: selection,
            openConversation: { id in if !preview { Task { await openChatConversation(id.uuidString) } } },
            startChat: { if !preview { nativeChat.startProjectChat($0) } },
            projectComposer: { project in AnyView(nativeChatView(safeTop: 0, safeBottom: safeBottom,
                composerOnly: true, preview: preview, previewProjectID: preview ? project.id : nil)) },
            backFromProject: { if !preview { beginBack(.projectList) } })
    }
    @ViewBuilder private func backPreview(_ target: BackTarget, safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        switch target {
        case .project(let id): projectsView(safeTop: safeTop, safeBottom: safeBottom, selection: .constant(id), preview: true)
        case .projectList: projectsView(safeTop: safeTop, safeBottom: safeBottom, selection: .constant(nil), preview: true)
        case .destination(let destination): destinationView(destination: destination, safeTop: safeTop, safeBottom: safeBottom)
        }
    }
    private func commitBack(_ target: BackTarget) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch target {
            case .project(let id):
                guard nativeChat.projects.contains(where: { $0.id == id }) else { store.navigate(to: .projects); presentedProjectID = nil; break }
                presentedProjectID = id; nativeChat.startProjectChat(id); store.navigate(to: .projects)
            case .projectList: presentedProjectID = nil
            case .destination(let destination): store.navigate(to: destination)
            }
            drawerDrag = 0; drawerGestureStart = nil; isCompletingConversationBack = false
        }
    }
    private func beginBack(_ target: BackTarget, width: CGFloat? = nil) {
        guard !isCompletingConversationBack else { return }
        dismissKeyboard(); drawerGestureStart = nil
        if UIAccessibility.isReduceMotionEnabled { commitBack(target); return }
        isCompletingConversationBack = true
        let windowWidth = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.bounds.width ?? 390
        withAnimation(.timingCurve(0.22, 0.72, 0.22, 1, duration: 0.26)) { drawerDrag = width ?? windowWidth }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            commitBack(target)
        }
    }

    private func openDrawer() {
        if !AIMExperimentalKeyboardHost.enabled { dismissKeyboard() }
        AIMHaptics.impact(.medium)
        withAnimation(AIMDesign.drawerAnimation) {
            drawerDrag = 0
            drawerOpen = true
        }
    }

    private func closeDrawer() {
        guard drawerOpen else { return }
        AIMHaptics.impact()
        withAnimation(AIMDesign.drawerAnimation) {
            drawerDrag = 0
            drawerOpen = false
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.endEditing(true) }
    }

    private func offerPairingIfNeeded() {
        guard !didOfferPairing, store.shouldOfferPairing else { return }
        didOfferPairing = true
        settingsPresentation = AIMSettingsPresentation(initialPage: .connection, origin: .connectionShortcut)
    }

    private var selectedAppearance: AIMAppearancePreference {
        AIMAppearancePreference(rawValue: appearance) ?? .system
    }
}

private struct AIMHorizontalPanObserver: UIViewRepresentable {
    let enabled: Bool
    let includeScrollViews: Bool
    @Binding var drawerIsOpen: Bool
    let changed: (CGFloat, Bool) -> Void
    let ended: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            includeScrollViews: includeScrollViews,
            drawerIsOpen: $drawerIsOpen,
            changed: changed,
            ended: ended
        )
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.hierarchyChanged = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.changed = changed
        context.coordinator.ended = ended
        context.coordinator.includeScrollViews = includeScrollViews
        context.coordinator.drawerIsOpen = $drawerIsOpen
        context.coordinator.setEnabled(enabled)
        context.coordinator.attach(from: uiView)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        uiView.hierarchyChanged = nil
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        var hierarchyChanged: (() -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            hierarchyChanged?()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hierarchyChanged?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hierarchyChanged?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var includeScrollViews: Bool
        var drawerIsOpen: Binding<Bool>
        var changed: (CGFloat, Bool) -> Void
        var ended: (CGFloat, CGFloat, Bool) -> Void
        weak var installedView: UIView?
        weak var attachment: UIView?
        var supplementalRecognizers: [UIPanGestureRecognizer] = []
        var enabled = true

        lazy var recognizer: UIPanGestureRecognizer = {
            makeRecognizer()
        }()

        init(
            includeScrollViews: Bool,
            drawerIsOpen: Binding<Bool>,
            changed: @escaping (CGFloat, Bool) -> Void,
            ended: @escaping (CGFloat, CGFloat, Bool) -> Void
        ) {
            self.includeScrollViews = includeScrollViews
            self.drawerIsOpen = drawerIsOpen
            self.changed = changed
            self.ended = ended
        }

        func attach(from attachmentView: UIView) {
            attachment = attachmentView
            guard attachmentView.window != nil else { return }
            // Observe the presenting content's hierarchy, never UIWindow:
            // presented sheets are siblings and must not feed this recognizer.
            var responder: UIResponder? = attachmentView
            var contentHost: UIView?
            while let candidate = responder {
                if let controller = candidate as? UIViewController { contentHost = controller.view; break }
                responder = candidate.next
            }
            guard let contentHost else { return }
            if includeScrollViews {
                installSupplementalRecognizers(on: scrollViews(in: contentHost))
            } else {
                attach(to: contentHost)
            }
        }

        func setEnabled(_ enabled: Bool) {
            self.enabled = enabled
            recognizer.isEnabled = enabled
            supplementalRecognizers.forEach { $0.isEnabled = enabled }
        }

        func detach() {
            attach(to: nil)
            supplementalRecognizers.forEach { $0.view?.removeGestureRecognizer($0) }
            supplementalRecognizers = []
        }

        private func scrollViews(in root: UIView) -> [UIScrollView] {
            var result: [UIScrollView] = []
            if let scrollView = root as? UIScrollView { result.append(scrollView) }
            root.subviews.forEach { result.append(contentsOf: scrollViews(in: $0)) }
            return result
        }

        func attach(to view: UIView?) {
            guard installedView !== view else { return }
            installedView?.removeGestureRecognizer(recognizer)
            installedView = view
            view?.addGestureRecognizer(recognizer)
        }

        private func installSupplementalRecognizers(on views: [UIScrollView]) {
            let current = Set(supplementalRecognizers.compactMap(\.view).map(ObjectIdentifier.init))
            let requested = Set(views.map(ObjectIdentifier.init))
            guard current != requested else { return }
            supplementalRecognizers.forEach { $0.view?.removeGestureRecognizer($0) }
            supplementalRecognizers = views.map { view in
                let supplemental = makeRecognizer()
                supplemental.isEnabled = enabled
                view.addGestureRecognizer(supplemental)
                return supplemental
            }
        }

        private func makeRecognizer() -> UIPanGestureRecognizer {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .changed:
                changed(translation, drawerIsOpen.wrappedValue)
            case .ended:
                let projected = translation + recognizer.velocity(in: recognizer.view).x * 0.18
                ended(translation, projected, drawerIsOpen.wrappedValue)
            case .cancelled, .failed:
                // A cancelled system gesture must not commit a navigation.
                ended(0, 0, drawerIsOpen.wrappedValue)
            default:
                break
            }
        }

        private var hasPresentedPanel: Bool {
            func presented(in controller: UIViewController) -> Bool {
                if controller.presentedViewController != nil { return true }
                return controller.children.contains { presented(in: $0) }
            }
            guard let root = attachment?.window?.rootViewController else { return true }
            return presented(in: root)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, !hasPresentedPanel else { return false }
            var candidate = touch.view
            while let view = candidate {
                if view is UIControl { return false }
                if let scroll = view as? UIScrollView,
                   scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                candidate = view.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, !hasPresentedPanel,
                  let recognizer = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = recognizer.velocity(in: recognizer.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

@MainActor
private enum AIMWindowSafeArea {
    static var current: EdgeInsets {
        let insets = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets ?? .zero
        return EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
    }
}

private struct AIMBulkProjectPicker: View {
    let service: any CloudContentServicing
    let move: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [AIMProject] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await loadProjects() } }
                }
                Button("New project", systemImage: "folder.badge.plus") { creating = true }
                ForEach(projects) { project in
                    Button(project.name) { Task { await select(project.id) } }
                }
            }
            .disabled(busy || loading)
            .overlay { if busy || loading { ProgressView() } }
            .navigationTitle("Move to project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .alert("New project", isPresented: $creating) {
                TextField("Name", text: $name)
                Button("Create") {
                    Task {
                        busy = true
                        do {
                            let project = try await service.createProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: nil, customContext: nil)
                            projects.insert(project, at: 0)
                            name = ""
                            busy = false
                            await select(project.id)
                        } catch { self.error = String(localized: "Unable to create project"); busy = false }
                    }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(busy)
        .task { await loadProjects() }
    }
    private func loadProjects() async {
        loading = true
        error = nil
        do { projects = try await service.loadProjects() }
        catch { self.error = String(localized: "Projects unavailable") }
        loading = false
    }
    private func select(_ id: String) async {
        busy = true
        if await move(id) { dismiss() }
        else { error = String(localized: "Some conversations could not be moved. Only those remain selected; try again.") }
        busy = false
    }
}

private struct AIMSidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AIMDesign.sidebarBackground(for: colorScheme)
            .ignoresSafeArea()
    }
}

private struct AIMSidebarView: View {
    let identity: AppIdentity
    let sessions: [RemoteSession]
    let filters: AIMConversationFilters
    let status: (RemoteSession) -> ConversationActivityState
    private var visibleSessions: [RemoteSession] { sessions.filter { filters.includes($0, status: status($0)) } }
    var nativeSessions: [NativeChatConversation] = []
    var openNativeSession: (NativeChatConversation) -> Void = { _ in }
    let machines: [RemoteMachine]
    let selection: MainDestination
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let startNewChat: () -> Void
    let navigate: (MainDestination) -> Void
    let openSession: (RemoteSession) -> Void
    let deleteSessions: (Set<String>) async -> Bool
    let cloudService: any CloudContentServicing
    let moveSessions: (Set<String>, String) async -> Set<String>
    let openSettings: () -> Void
    let closeDrawer: () -> Void
    @Binding var drawerIsOpen: Bool
    let drawerPanChanged: (CGFloat, Bool) -> Void
    let drawerPanEnded: (CGFloat, CGFloat, Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var selectionMode = false
    @State private var selectedSessionIDs: Set<String> = []
    @State private var pendingDeletion: Set<String> = []
    @State private var isDeleting = false
    @State private var movingToProject = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AIMDesign.sidebarBackground(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: safeTop + 80)

                    VStack(spacing: 1) {
                        sidebarRow("sidebar.search", icon: "LucideSearch", destination: .search)
                        sidebarRow("sidebar.library", icon: "LucideLibrary", destination: .library)
                        sidebarRow("sidebar.personalization", icon: "LucideBlocks", destination: .personalization)
                        sidebarRow("Code", icon: "LucideCode", destination: .code)
                        sidebarRow("Agent", icon: "LucideBot", destination: .agent)
                        sidebarRow("sidebar.projects", icon: "LucideFolder", destination: .projects)
                    }
                    .padding(.horizontal, 20)

                    HStack {
                    Text("Récent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .padding(.top, 18)
                    Spacer()
                    AIMConversationFilterMenu(filters: filters, compact: true).accessibilityIdentifier("recent-conversation-filter")
                    }.padding(.horizontal, 24)

                    VStack(alignment: .leading, spacing: 2) {
                        if visibleSessions.isEmpty {
                            Text("sidebar.no_chats")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 14)
                        } else {
                            ForEach(visibleSessions) { session in
                                if let conversation = nativeSessions.first(where: { AccountConversationIdentity.matches($0.id.uuidString, session.id) }) {
                                    Button { openNativeSession(conversation) } label: {
                                        HStack(spacing: 10) {
                                            AIMConversationStatusDot(status: status(session))
                                            Text(conversation.title).font(.system(size: 16)).foregroundStyle(.primary).lineLimit(1)
                                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    }.buttonStyle(.plain)
                                } else { sidebarSessionRow(session) }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 7)
                    .padding(.bottom, 104)
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("sidebar-scroll")

            sidebarHeader

            if selectionMode {
                selectionToolbar
            } else {
                Button(action: startNewChat) {
                    HStack(spacing: 10) {
                        Image("LucideNewChat")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 20, height: 20)
                        Text("sidebar.new_chat")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .background(Color.primary, in: Capsule())
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 7)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("new-chat-button")
            }
        }
        .sheet(isPresented: $movingToProject) {
            AIMBulkProjectPicker(service: cloudService) { projectID in
                let failed = await moveSessions(selectedSessionIDs, projectID)
                selectedSessionIDs = failed
                if failed.isEmpty { selectionMode = false }
                return failed.isEmpty
            }
        }
        .confirmationDialog(
            copy("Delete conversations?", "Supprimer les conversations ?"),
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(copy("Delete", "Supprimer"), role: .destructive) {
                let ids = pendingDeletion
                pendingDeletion = []
                isDeleting = true
                Task {
                    if await deleteSessions(ids) {
                        selectedSessionIDs.subtract(ids)
                        if selectedSessionIDs.isEmpty { selectionMode = false }
                        AIMHaptics.success()
                    } else {
                        AIMHaptics.error()
                    }
                    isDeleting = false
                }
            }
            Button(copy("Cancel", "Annuler"), role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(copy(
                "This removes the synchronized Remote copy. The original conversation can remain on the computer.",
                "Cela supprime la copie Remote synchronisée. La conversation d’origine peut rester sur l’ordinateur."
            ))
        }
    }

    private func sidebarSessionRow(_ session: RemoteSession) -> some View {
        HStack(spacing: 10) {
            AIMConversationStatusDot(status: status(session))
            if selectionMode {
                Image(systemName: selectedSessionIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedSessionIDs.contains(session.id) ? Color.accentColor : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary.opacity(0.72))
                    .lineLimit(1)
                if machines.count > 1 {
                    Text(machines.first { $0.id == session.machineID }?.name ?? String(localized: "remote.sessions.unknown_computer"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 43)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .aimSwipeSafeTap {
            if selectionMode {
                toggleSelection(session.id)
            } else {
                openSession(session)
            }
        }
        .contextMenu {
            Button {
                selectionMode = true
                selectedSessionIDs.insert(session.id)
                AIMHaptics.selection()
            } label: {
                Label(copy("Select", "Sélectionner"), systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                pendingDeletion = [session.id]
            } label: {
                Label(copy("Delete", "Supprimer"), systemImage: "trash")
            }
        }
        .accessibilityIdentifier("sidebar-session-\(session.id)")
    }

    private var selectionToolbar: some View {
        HStack(spacing: 8) {
            Button {
                selectionMode = false
                selectedSessionIDs = []
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-selection-cancel")

            Text("\(selectedSessionIDs.count)")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .aimGlassCapsule()
                .accessibilityIdentifier("sidebar-selection-count")

            Menu {
                Button("Move to project", systemImage: "folder") { movingToProject = true }
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = selectedSessionIDs }
                    .accessibilityIdentifier("sidebar-selection-delete")
            } label: {
                Group {
                    if isDeleting { ProgressView() }
                    else { Image(systemName: "ellipsis") }
                }
                .frame(width: 44, height: 44)
                .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .disabled(selectedSessionIDs.isEmpty || isDeleting)
            .accessibilityIdentifier("sidebar-selection-actions")
        }
        .padding(.trailing, 16)
        .padding(.bottom, safeBottom + 16)
    }

    private func toggleSelection(_ id: String) {
        if selectedSessionIDs.contains(id) { selectedSessionIDs.remove(id) }
        else { selectedSessionIDs.insert(id) }
        AIMHaptics.selection()
    }

    private var sidebarHeader: some View {
        VStack {
            HStack(spacing: 12) {
                Text("AIM AI")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)

                Spacer(minLength: 8)

                Button(action: openSettings) {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(Color(red: 70 / 255, green: 81 / 255, blue: 98 / 255))
                            .frame(width: 38, height: 38)
                            .overlay {
                                Text(initials)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                        Text(displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                    .padding(.leading, 5)
                    .padding(.trailing, 14)
                    .frame(height: 48)
                    .aimGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(displayName))
                .accessibilityIdentifier("profile-menu")
            }
            .padding(.horizontal, 16)
            .padding(.top, safeTop + 16)

            Spacer()
        }
        .background(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: safeTop + 100)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
        }
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }

    private func sidebarRow(_ title: LocalizedStringKey, icon: String, destination: MainDestination) -> some View {
        Button {
            navigate(destination)
        } label: {
            HStack(spacing: 16) {
                Image(icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28)
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 18))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .background(selection == destination ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier(for: destination))
    }

    private var sidebarCloseGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                guard value.translation.width < -62,
                      abs(value.translation.width) > abs(value.translation.height) * 1.2
                else { return }
                closeDrawer()
            }
    }

    private var displayName: String {
        let value = identity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty { return value.split(separator: " ").first.map(String.init) ?? value }
        return identity.accountEmail?.split(separator: "@").first.map(String.init) ?? "AIM"
    }

    private var initials: String {
        String(displayName.prefix(1)).uppercased()
    }

    private func accessibilityIdentifier(for destination: MainDestination) -> String {
        switch destination {
        case .search: "sidebar-search"
        case .library: "sidebar-library"
        case .personalization: "sidebar-personalization"
        case .code: "sidebar-code"
        case .agent: "sidebar-agent"
        case .projects: "sidebar-projects"
        case .newChat: "sidebar-new-chat"
        case .newRemote: "sidebar-new-remote"
        case .conversation: "sidebar-conversation"
        }
    }
}

private struct AIMNewChatView: View {
    @Environment(\.locale) private var locale
    @Environment(\.aimSidebarPresented) private var sidebarPresented
    @State private var showingStatusDetails = false
    @Binding var text: String
    @Binding var attachments: [RemoteAttachmentReference]
    let titleKey: String
    let computerState: NewChatComputerState
    let machines: [RemoteMachine]
    let selectedMachineID: String?
    let selectedMachineName: String?
    let selectMachine: (String) -> Void
    let commandHealth: RemoteCommandHealth
    let inlineErrorMessage: String?
    let commandErrorMessage: String?
    let isSending: Bool
    let capabilities: RemoteCapabilities?
    let modelID: String
    let modelName: String
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let focusRequest: Int
    let openMenu: () -> Void
    let selectMode: (RemoteMode) -> Void
    let openPersonalization: () -> Void
    let retry: () -> Void
    let send: (String, [RemoteAttachmentReference]) async -> Bool
    let uploadAttachment: (Data, String, String, VideoPreparationOptions) async -> RemoteAttachmentReference?
    let changeModel: (String, String?) async -> Bool
    var usePhone: (() -> Void)? = nil
    var changeModelSelection: ((RemoteModelAnnouncement, String?) async -> Bool)? = nil
    var modelProvider: String? = nil
    var manageConnections: (() -> Void)? = nil
    var remoteStore: MainExperienceStore? = nil

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: openMenu) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay { Circle().stroke(Color.primary.opacity(0.08)) }
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(Text("sidebar.open"))
                    .accessibilityIdentifier("main-menu-button").modifier(AIMAttentionBadge())

                    Spacer()

                    AIMCreationModeSelector(selection: .chat, select: selectMode)

                    Spacer()

                    connectionIndicator
                }
                .padding(.horizontal, 16)
                .padding(.top, safeTop + 12)

                Spacer(minLength: 24)

                VStack(spacing: 10) {
                    Text(LocalizedStringKey(titleKey))
                        .font(AIMDesign.titleFont(size: 29))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("new-chat-title")
                }
                .padding(.horizontal, 30)

                Spacer(minLength: 24)

                AIMConversationComposer(
                    text: $text,
                    attachments: $attachments,
                    modelName: modelName,
                    modelID: modelID,
                    capabilities: capabilities,
                    mode: .chat,
                    approvalMode: nil,
                    attachmentsEnabled: RemoteAttachmentRules.availableAtCreation(
                        capabilities: capabilities,
                        mode: .chat
                    ),
                    enabled: true,
                    sendEnabled: true,
                    loading: isSending,
                    sessionRunning: false,
                    expandedAtRest: false,
                    accessibilityPrefix: "new-chat",
                    focusRequest: focusRequest,
                    safeBottom: safeBottom,
                    openPersonalization: openPersonalization,
                    send: { text, attachments in
                        guard canSend else {
                            AIMHaptics.error()
                            showingStatusDetails = true
                            return false
                        }
                        return await send(text, attachments)
                    },
                    uploadAttachment: uploadAttachment,
                    changeModel: changeModel,
                    changeApprovalMode: { _ in false },
                    sendGoal: { _, _, _ in false },
                    stop: { false },
                    changeModelSelection: changeModelSelection,
                    modelProvider: modelProvider,
                    remoteStore: remoteStore
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-chat-screen")
        .onChange(of: sidebarPresented) { _, presented in
            if presented { showingStatusDetails = false }
        }
    }

    private var machineSelection: some View {
        Menu {
            ForEach(machines) { machine in
                Button { selectMachine(machine.id) } label: {
                    Label(machine.name, systemImage: selectedMachineID == machine.id ? "checkmark" : "desktopcomputer")
                }
            }
        } label: {
            Label(selectedMachineName ?? String(localized: "remote.new.choose_computer"), systemImage: "desktopcomputer")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .disabled(machines.isEmpty)
        .accessibilityLabel(Text("remote.new.choose_computer"))
        .accessibilityValue(Text(selectedMachineName ?? "remote.new.no_computer"))
        .accessibilityIdentifier("new-chat-computer-selection")
    }

    private var connectionIndicator: some View {
        Button {
            AIMHaptics.selection()
            showingStatusDetails.toggle()
        } label: {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.38), radius: 3)
                .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                .aimGlassCircle()
                .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Status"))
        .accessibilityValue(Text(stateText ?? "remote.conversation.online"))
        .accessibilityIdentifier("new-chat-header-status")
        .popover(isPresented: $showingStatusDetails, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(locale.language.languageCode?.identifier == "fr" ? "Exécuter sur" : "Run requests on")
                        .font(.caption).foregroundStyle(.secondary)
                    if let usePhone {
                        Button { showingStatusDetails = false; usePhone() } label: {
                            Label("This iPhone", systemImage: "iphone").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.accessibilityIdentifier("execution-device-iphone")
                    }
                    ForEach(machines) { machine in
                        Button { showingStatusDetails = false; selectMachine(machine.id) } label: {
                            Label(machine.name, systemImage: machine.id == selectedMachineID ? "checkmark" : "desktopcomputer")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.accessibilityIdentifier("execution-device-mac-\(machine.id)")
                    }
                    if let manageConnections {
                        Divider()
                        Button { showingStatusDetails = false; manageConnections() } label: {
                            Label(locale.language.languageCode?.identifier == "fr" ? "Gérer les Mac" : "Manage Macs", systemImage: "link")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.accessibilityIdentifier("native-manage-connections")
                    }
                    Divider()
                    Text(stateText ?? "remote.conversation.online")
                        .font(.body)
                        .foregroundStyle(stateIsError ? Color.red : Color.primary)
                        .accessibilityIdentifier("computer-state")
                    if let commandErrorMessage {
                        Text(commandErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("new-chat-command-error")
                    }
                    if shouldOfferRetry {
                        Button("main.refresh", action: retry)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("retry-remote-button")
                    }
                }
                .font(.system(.body))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(width: 286)
            .fixedSize(horizontal: false, vertical: true)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var statusColor: Color {
        switch computerState {
        case .loading, .synchronizing, .noModels, .chooseComputer, .selectionUnavailable: .orange
        case .available:
            switch commandHealth {
            case .responsive: .green
            case .unknown, .checking: .orange
            case .unresponsive, .incompatible: .red
            }
        default: .red
        }
    }

    private var canSend: Bool {
        if case .available = computerState, commandHealth == .responsive { return true }
        return false
    }

    private var stateIsError: Bool {
        switch computerState {
        case .unavailable, .needsRepair, .incompatible, .readFailure: true
        case .available:
            commandHealth == .unresponsive || commandHealth == .incompatible
        default: false
        }
    }

    private var shouldOfferRetry: Bool {
        switch computerState {
        case .unavailable, .synchronizing, .noModels, .selectionUnavailable, .readFailure: return true
        default: break
        }
        if case .available = computerState {
            return commandHealth == .unresponsive || commandHealth == .incompatible
        }
        return false
    }

    private var stateText: LocalizedStringKey? {
        switch computerState {
        case .loading:
            "main.loading"
        case .unpaired:
            "remote.new.not_paired"
        case .needsRepair:
            "remote.new.needs_repair"
        case .noComputer:
            "remote.new.no_computer"
        case .chooseComputer:
            "remote.new.choose_computer"
        case .selectionUnavailable:
            "remote.new.selection_unavailable"
        case .suspended:
            "remote.connection.suspended"
        case .offline:
            "remote.new.offline"
        case .synchronizing:
            "remote.new.synchronizing"
        case .readFailure(_, let messageKey):
            LocalizedStringKey(messageKey)
        case .noModels:
            "remote.new.models_pending"
        case .incompatible:
            "remote.error.incompatible_version"
        case .available:
            switch commandHealth {
            case .responsive:
                nil
            case .checking, .unknown:
                "remote.conversation.checking"
            case .unresponsive:
                "remote.error.bridge_unresponsive"
            case .incompatible:
                "remote.error.incompatible_version"
            }
        case .unavailable:
            if let inlineErrorMessage {
                LocalizedStringKey(inlineErrorMessage)
            } else {
                "main.error.load"
            }
        }
    }
}

private struct AIMMissingConversationView: View {
    let openMenu: () -> Void
    let retry: () -> Void
    let startNewChat: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: openMenu) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(Text("sidebar.open"))
                Spacer()
            }
            .padding(.horizontal, 16)
            .safeAreaPadding(.top, 12)

            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("remote.error.session_unavailable")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("settings.connection.try_again", action: retry)
                    .buttonStyle(.bordered)
                Button("sidebar.new_chat", action: startNewChat)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
            }
            .padding(.top, 12)
            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
    }
}
