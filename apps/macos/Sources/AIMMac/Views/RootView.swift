import AppKit
import AIMApplication
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme
    @AppStorage("aim.computerUse.onboardingShown") private var computerUseOnboardingShown = false
    @AppStorage("aim.spend.onboardingShown") private var spendOnboardingShown = false
    @AppStorage("aim.sidebar.width") private var sidebarWidth = 260.0
    @AppStorage("aim.sidebar.visible") private var sidebarVisible = true
    @State private var sidebarDrag: CGFloat?
    @State private var tabs: [WorkbenchTab] = []
    @State private var selectedTab: UUID?
    @State private var panelVisible = false
    @State private var tabListVisible = false
    @State private var tabListTask: Task<Void, Never>?
    @State private var showConversationMenu = false
    @State private var renaming = false
    @State private var renameTitle = ""
    @State private var deleting = false
    @State private var continuingWorktree = false
    @State private var showingSpendOnboarding = false
    @State private var tabsRestored = false
    /// The selected tab and panel visibility each conversation had when it was left.
    @State private var panelStates: [String: (selected: UUID?, visible: Bool)] = [:]
    private var savedTabs: [SavedWorkbenchTab] { tabs.map(SavedWorkbenchTab.init) }
    /// The tabs of the conversation on screen: its own, terminals of its folder, and older global tabs.
    private var visibleTabs: [WorkbenchTab] {
        tabs.filter { tab in
            tab.kind.followsFolder ? tab.workspacePath == model.workspacePath
                : tab.conversationID == nil || tab.conversationID == model.selectedConversationID
        }
    }
    private func panelKey(_ conversation: UUID?) -> String { conversation?.uuidString ?? "none" }
    @AppStorage("aim.panel.width") private var storedPanelWidth = 440.0
    /// Live widths while a divider is dragged; saved once the drag ends.
    @State private var liveSidebarWidth: CGFloat?
    @State private var livePanelWidth: CGFloat?
    @State private var panelDrag: CGFloat?
    @State private var history: [Destination] = []
    @State private var historyIndex = -1
    @State private var restoringHistory = false
    @State private var isFullScreen = false
    /// Out of full screen the window buttons sit at the left of the bar; ours start after them.
    private var leadingInset: CGFloat { isFullScreen ? 0 : WindowChrome.trafficLightInset }

    private struct Destination: Equatable {
        let mode: AIMMode
        let conversation: UUID?
        let settings: SettingsSection?
        let project: UUID?
        let projectsVisible: Bool
    }
    private var destination: Destination {
        Destination(mode: model.mode, conversation: model.selectedConversationID, settings: model.settingsSection, project: model.selectedProjectID, projectsVisible: model.projectPageVisible)
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let sidebar = renderedSidebarWidth(geometry.size.width)
            let panel = renderedPanelWidth(geometry.size.width)
            VStack(spacing: 0) {
                toolbar(sidebarWidth: sidebarVisible ? sidebar : 0, rightWidth: panel)
                HStack(spacing: 0) {
                    if sidebarVisible {
                        Group {
                            if model.settingsSection != nil {
                                SettingsSidebar()
                            } else {
                                SidebarView()
                            }
                        }
                        .frame(width: sidebar)
                        resizeHandle { translation in
                            if sidebarDrag == nil { sidebarDrag = sidebar }
                            liveSidebarWidth = max(210, min(390, geometry.size.width * 0.36, (sidebarDrag ?? sidebar) + translation))
                        } end: {
                            if let liveSidebarWidth { sidebarWidth = Double(liveSidebarWidth) }
                            liveSidebarWidth = nil; sidebarDrag = nil
                        }
                    }
                    HStack(spacing: 0) {
                        if let section = model.settingsSection {
                            SettingsDetailView(section: section)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 0) {
                                if model.mode == .agent, let plan = model.agentPlan, !plan.steps.isEmpty {
                                    AgentPlanView(plan: plan).padding(.horizontal, 18).padding(.top, 10)
                                }
                                if model.showCustomize { CustomizeView() }
                                else if model.projectPageVisible { ProjectHomeView() }
                                else { ChatView() }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if panelVisible && !visibleTabs.isEmpty {
                                Rectangle().fill(AIMTheme.border(scheme)).frame(width: 1)
                                resizeHandle { translation in
                                    if panelDrag == nil { panelDrag = panel }
                                    livePanelWidth = max(300, min(maximumPanelWidth(geometry.size.width), (panelDrag ?? panel) - translation))
                                } end: {
                                    if let livePanelWidth { storedPanelWidth = Double(livePanelWidth) }
                                    livePanelWidth = nil; panelDrag = nil
                                }
                            }
                            WorkbenchTabs(tabs: $tabs, selection: $selectedTab)
                                .frame(width: panel)
                                .frame(width: panelVisible && !visibleTabs.isEmpty ? nil : 0)
                                .clipped().opacity(panelVisible ? 1 : 0)
                                .allowsHitTesting(panelVisible).accessibilityHidden(!panelVisible)
                        }
                    }
                    .background(AIMTheme.background(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.leading, sidebarVisible ? 0 : 8)
                    .padding(.trailing, 8).padding(.bottom, 8)
                }
            }
            .background(SidebarBackdrop(translucent: model.preferences.translucentSidebar))
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(AIMTheme.foreground(scheme))
        .aimReduceMotion(model.preferences.reduceMotion)
        .overlay {
            if model.showModelPicker {
                GeometryReader { proxy in
                    ZStack {
                        Color.black.opacity(0.08).ignoresSafeArea(.container).contentShape(Rectangle())
                            .onTapGesture { model.showModelPicker = false }
                        ModelPickerView()
                            .frame(width: min(900, proxy.size.width - 48), height: min(700, proxy.size.height - 40))
                            .background(scheme == .dark ? AIMTheme.sidebar(scheme) : .white, in: RoundedRectangle(cornerRadius: 26))
                            .clipShape(RoundedRectangle(cornerRadius: 26))
                            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(AIMTheme.border(scheme)))
                            .shadow(color: .black.opacity(0.14), radius: 25, y: 8)
                            .padding(20)
                    }.frame(width: proxy.size.width, height: proxy.size.height)
                        .onExitCommand { model.showModelPicker = false }
                }
            }
        }
        .overlay {
            if showingSpendOnboarding {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    SpendOnboardingView {
                        spendOnboardingShown = true
                        showingSpendOnboarding = false
                        if model.mode == .agent { presentComputerUseOnFirstAgentEntry() }
                    }
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if let request = model.pendingSpendExceptions.first {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    SpendExceptionView(request: request)
                        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $model.isShowingArchives) { ArchivedConversationsView() }
        .sheet(isPresented: $model.showWorkspaceHistory) { WorkspaceHistoryView() }
        .sheet(isPresented: $model.showProjects) { ProjectsView() }
        .sheet(isPresented: $continuingWorktree) {
            if let workspace = model.workspacePath { GitWorktreeView(workspace: workspace, continueConversation: true) }
        }
        .alert("Rename conversation", isPresented: $renaming) {
            TextField("Title", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let id = model.selectedConversationID { Task { await model.renameConversation(id, to: renameTitle) } } }
        }
        .confirmationDialog("Delete this conversation permanently?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { if let id = model.selectedConversationID { Task { await model.deleteConversation(id) } } }
        } message: { Text("This cannot be undone.") }
        .onChange(of: model.showProviderSetup) { _, show in
            if show { model.settingsSection = .providers; model.showProviderSetup = false }
        }
        .onChange(of: model.mode) { _, mode in
            if mode == .agent { presentComputerUseOnFirstAgentEntry() }
        }
        .onChange(of: model.isBootstrapping) { _, loading in
            if !loading { presentSpendOnboardingIfNeeded() }
            if !loading, model.mode == .agent { presentComputerUseOnFirstAgentEntry() }
        }
        .onChange(of: model.requestedPanel) { _, kind in
            if let kind { openPanel(kind); model.requestedPanel = nil }
        }
        .onChange(of: model.requestedWorkbench) { _, request in
            if let request { open(request); model.requestedWorkbench = nil }
        }
        .onChange(of: model.selectedConversationID) { previous, current in
            panelStates[panelKey(previous)] = (selectedTab, panelVisible)
            let state = panelStates[panelKey(current)]
            let visible = visibleTabs
            selectedTab = state?.selected.flatMap { id in visible.first { $0.id == id }?.id } ?? visible.last?.id
            panelVisible = (state?.visible ?? false) && !visible.isEmpty
        }
        .onChange(of: destination) { _, _ in recordDestination() }
        .onChange(of: model.isLoadingConversation) { _, loading in if !loading { recordDestination() } }
        .onAppear {
            recordDestination()
            if !model.isBootstrapping { presentSpendOnboardingIfNeeded() }
            if !model.isBootstrapping, model.mode == .agent { presentComputerUseOnFirstAgentEntry() }
            if !tabsRestored {
                do { tabs = try WorkbenchSessionStore().load().map { $0.restore() }; selectedTab = tabs.first?.id }
                catch { model.alertMessage = "Side chats could not be restored. Their saved file has not been changed."; return }
                tabsRestored = true
            }
        }
        .task(id: savedTabs) {
            guard tabsRestored else { return }
            do { try await Task.sleep(for: .milliseconds(300)); try WorkbenchSessionStore().save(savedTabs) }
            catch is CancellationError {} catch { model.alertMessage = "Could not save temporary side chats." }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if tabsRestored { try? WorkbenchSessionStore().save(savedTabs) }
        }
    }

    private func presentComputerUseOnFirstAgentEntry() {
        guard spendOnboardingShown, !computerUseOnboardingShown else { return }
        computerUseOnboardingShown = true
        openWindow(id: "computer-use")
    }

    private func presentSpendOnboardingIfNeeded() {
        guard !spendOnboardingShown else { return }
        showingSpendOnboarding = true
    }

    private func toolbar(sidebarWidth: CGFloat, rightWidth: CGFloat) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                Button { navigate(-1) } label: { Image(systemName: "arrow.left") }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(historyIndex <= 0).aimTooltip("Back", shortcut: "⌘[")
                Button { navigate(1) } label: { Image(systemName: "arrow.right") }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(historyIndex + 1 >= history.count).aimTooltip("Forward", shortcut: "⌘]")
                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .keyboardShortcut("\\", modifiers: .command)
                    .aimTooltip(sidebarVisible ? "Hide sidebar" : "Show sidebar", shortcut: "⌘\\")
                    .accessibilityIdentifier("toggle-sidebar")
            }
            .frame(width: max(100, sidebarWidth - 12 - leadingInset), alignment: .leading)
            if model.settingsSection != nil {
                Text("Settings").padding(.leading, 10)
            } else if model.projectPageVisible || model.selectedProjectID != nil {
                HStack(spacing: 9) {
                    Button("Projects") { Task { await model.openProjects() } }
                    if let project = model.projects.first(where: { $0.id == model.selectedProjectID }) {
                        Text("/").foregroundStyle(.tertiary)
                        Button(project.name) { Task { await model.openProjects(project.id) } }.lineLimit(1)
                    }
                    if let conversation = model.conversations.first(where: { $0.id == model.selectedConversationID }) {
                        Text("/").foregroundStyle(.tertiary)
                        Text(conversation.title).lineLimit(1)
                    }
                }.padding(.leading, 10)
            } else if let conversation = model.conversations.first(where: { $0.id == model.selectedConversationID }) {
                Text(conversation.title).lineLimit(1).padding(.leading, 10)
            }
            Spacer()
            if model.settingsSection == nil {
                if let conversation = model.conversations.first(where: { $0.id == model.selectedConversationID }) {
                Button { showConversationMenu.toggle() } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }
                .buttonStyle(.aimHover(radius: 8, active: showConversationMenu))
                .aimTooltip("Conversation options")
                .aimMenu(isPresented: $showConversationMenu, alignment: .trailing) {
                    AIMMenuItem("Rename", icon: "pencil", shortcut: "⌥⌘R") { renameTitle = conversation.title; renaming = true }
                    AIMMenuItem(conversation.pinnedAt == nil ? "Pin" : "Unpin", icon: "pin", shortcut: "⌥⌘P") {
                        Task { await model.setPinned(conversation.id, conversation.pinnedAt == nil) }
                    }
                    AIMMenuItem("Find in conversation", icon: "magnifyingglass", shortcut: "⌘F") { model.transcriptSearchRequest = UUID() }
                    AIMMenuItem("Copy conversation", icon: "doc.on.doc") { Task { await model.copyConversation(conversation.id) } }
                    AIMMenuDivider()
                    AIMMenuItem("New side chat", icon: "bubble.left.and.bubble.right", shortcut: "⌥⌘S") { openPanel(.sideChat) }
                    AIMMenuItem("Continue in a new chat", icon: "arrow.turn.down.right") {
                        if let last = model.messages.last { Task { await model.branchConversation(at: last, edit: false) } }
                    }.disabled(!model.canBranchConversation)
                    AIMMenuItem("Continue in a new worktree…", icon: "arrow.triangle.branch") { continuingWorktree = true }
                        .disabled(model.workspacePath == nil || !model.canBranchConversation)
                    AIMMenuItem("Action history", icon: "clock.arrow.circlepath") { model.showWorkspaceHistory = true }
                    if model.mode == .agent, model.agentMission != nil {
                        AIMMenuItem("Mission permissions…", icon: "checkmark.shield") { model.showMissionAuthorization = true }
                    }
                    AIMMenuDivider()
                    AIMMenuItem("Delete…", icon: "trash", destructive: true) { deleting = true }
                }
                .background {
                    // The menu's keyboard shortcuts stay available while it is closed.
                    Group {
                        Button("") { renameTitle = conversation.title; renaming = true }.keyboardShortcut("r", modifiers: [.command, .option])
                        Button("") { Task { await model.setPinned(conversation.id, conversation.pinnedAt == nil) } }.keyboardShortcut("p", modifiers: [.command, .option])
                        Button("") { model.transcriptSearchRequest = UUID() }.keyboardShortcut("f", modifiers: .command)
                        Button("") { openPanel(.sideChat) }.keyboardShortcut("s", modifiers: [.command, .option])
                    }
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
                }
                if panelVisible && !visibleTabs.isEmpty {
                    HStack(spacing: 5) {
                        Rectangle().fill(.primary.opacity(0.10)).frame(width: 1, height: 22)
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(visibleTabs) { tab in
                                        HStack(spacing: 5) {
                                            Button { selectedTab = tab.id } label: { Label(tab.title, systemImage: tab.kind.icon).lineLimit(1) }
                                            Button { closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                        }.padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(selectedTab == tab.id ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                            .id(tab.id)
                                    }
                                }
                            }
                            // A tab opened from the conversation is always brought into view.
                            .onChange(of: selectedTab) { _, id in if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .trailing) } } }
                        }
                        Button { openPanel(.newTab) } label: { Image(systemName: "plus") }.aimTooltip("New tab")
                    }.frame(width: max(200, rightWidth - 40))
                }
                Button {
                    tabListTask?.cancel(); tabListVisible = false
                    if visibleTabs.isEmpty { openPanel(.newTab) }
                    else { if !visibleTabs.contains(where: { $0.id == selectedTab }) { selectedTab = visibleTabs.last?.id }; panelVisible.toggle() }
                } label: {
                    HStack(spacing: 3) { Image(systemName: "rectangle.split.2x1"); if !visibleTabs.isEmpty { Text("\(visibleTabs.count)").font(.caption2) } }
                }
                .onHover { inside in
                    tabListTask?.cancel()
                    if inside && !visibleTabs.isEmpty {
                        tabListTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(600))
                            guard !Task.isCancelled else { return }; tabListVisible = true
                        }
                    }
                }
                .aimMenu(isPresented: $tabListVisible, alignment: .trailing, takesFocus: false) {
                    AIMMenuSection("Open tabs")
                    ForEach(visibleTabs) { tab in
                        AIMMenuItem(tab.title, icon: tab.kind.icon, checked: tab.id == selectedTab && panelVisible) {
                            selectedTab = tab.id; panelVisible = true
                        }
                    }
                }
                .accessibilityIdentifier("open-workbench")
            }
        }
        .buttonStyle(ToolbarIconStyle())
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(AIMTheme.secondaryText(scheme))
        .padding(.leading, 12 + leadingInset).padding(.trailing, 16).frame(height: WindowChrome.barHeight)
        .background(WindowChrome(isFullScreen: $isFullScreen).frame(width: 0, height: 0))
    }

    private func renderedSidebarWidth(_ total: CGFloat) -> CGFloat {
        max(210, min(390, total * 0.36, liveSidebarWidth ?? CGFloat(sidebarWidth)))
    }

    private func maximumPanelWidth(_ total: CGFloat) -> CGFloat {
        max(300, min(760, (total - (sidebarVisible ? renderedSidebarWidth(total) : 0)) * 0.53))
    }

    /// One clamp for what is drawn, where a drag starts and what is saved, so nothing jumps.
    private func renderedPanelWidth(_ total: CGFloat) -> CGFloat {
        max(300, min(maximumPanelWidth(total), livePanelWidth ?? CGFloat(storedPanelWidth)))
    }

    private func resizeHandle(change: @escaping (CGFloat) -> Void, end: @escaping () -> Void) -> some View {
        Color.clear.frame(width: 7).contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            // Global coordinates: the handle moves with the width it changes, so a local
            // translation would feed back into itself and make the divider jump.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    NSCursor.resizeLeftRight.set()
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { change(value.translation.width) }
                }
                .onEnded { _ in end(); NSCursor.arrow.set() })
            .accessibilityLabel("Resize panel")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: change(20)
                case .decrement: change(-20)
                @unknown default: break
                }
                end()
            }
    }

    private func openPanel(_ kind: WorkbenchPanelKind) {
        let tab = WorkbenchTab(kind: kind, workspacePath: model.workspacePath, conversationID: model.selectedConversationID)
        tabs.append(tab); selectedTab = tab.id; panelVisible = true
    }

    /// Sources and Actions reuse the conversation's tab for the same answer and bring the
    /// requested item into view; a page always opens in its own tab.
    private func open(_ request: WorkbenchRequest) {
        if request.kind != .browser, let tab = visibleTabs.first(where: { $0.kind == request.kind && $0.conversationID == model.selectedConversationID
            && (request.kind == .actions || $0.messageID == request.messageID) }) {
            tab.messageID = request.messageID; tab.focusID = request.focusID; tab.focusRevision += 1
            if !request.actions.isEmpty { tab.actions = request.actions }
            selectedTab = tab.id; panelVisible = true
            return
        }
        let tab = WorkbenchTab(kind: request.kind, workspacePath: model.workspacePath, conversationID: model.selectedConversationID)
        tab.messageID = request.messageID; tab.focusID = request.focusID; tab.actions = request.actions
        if let address = request.address {
            tab.initialAddress = address; tab.displayName = URL(string: address)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        }
        tabs.append(tab); selectedTab = tab.id; panelVisible = true
    }

    private func closeTab(_ id: UUID) {
        tabs.first(where: { $0.id == id })?.sideChat.close()
        tabs.removeAll { $0.id == id }
        if tabsRestored {
            do { try WorkbenchSessionStore().save(savedTabs) }
            catch { model.alertMessage = "Could not remove the saved side chat. It may reappear after restarting." }
        }
        if selectedTab == id { selectedTab = visibleTabs.last?.id }
        if visibleTabs.isEmpty { panelVisible = false }
    }

    private func recordDestination() {
        guard !restoringHistory, !model.isLoadingConversation, history.last != destination else { return }
        if historyIndex >= 0, history.indices.contains(historyIndex), history[historyIndex] == destination { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(destination); historyIndex = history.count - 1
    }

    private func navigate(_ offset: Int) {
        let index = historyIndex + offset
        guard history.indices.contains(index), !restoringHistory else { return }
        let target = history[index]
        restoringHistory = true
        Task {
            if target.projectsVisible {
                model.selectMode(target.mode, restoreRecent: false)
                await model.openProjects(target.project)
            }
            else if let id = target.conversation { await model.selectConversation(id) }
            else {
                model.selectMode(target.mode, restoreRecent: false)
                await model.selectProject(target.project)
            }
            model.settingsSection = target.settings
            historyIndex = index
            restoringHistory = false
        }
    }
}

private struct ToolbarIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AIMHoverStyle(radius: 8, minSize: 30).makeBody(configuration: configuration)
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var results: [ConversationSearchHit] = []
    @State private var renameTarget: Conversation?
    @State private var exportTarget: Conversation?
    @State private var deleteTarget: Conversation?
    @State private var hoveredConversation: UUID?
    @FocusState private var focusedConversation: UUID?
    @State private var title = ""
    @State private var showSpaces = false
    @State private var menuConversation: UUID?
    @State private var searching = false
    @State private var showFilter = false
    @FocusState private var searchFocused: Bool
    @AppStorage("aim.sidebar.kindFilter") private var kindFilter = SidebarKindFilter.all
    @AppStorage("aim.sidebar.unreadOnly") private var unreadOnly = false
    @Namespace private var selection

    private var conversations: [ConversationSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = model.conversations.filter { ($0.mode == .code) == (model.mode == .code) && $0.projectID == nil }
        guard !trimmed.isEmpty else { return local.map { ConversationSearchHit(conversation: $0) } }
        // Titles match as you type (any part of a word); full-text results follow.
        let titled = local.filter { $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .map { ConversationSearchHit(conversation: $0) }
        let ids = Set(titled.map(\.conversation.id))
        return titled + results.filter { !ids.contains($0.conversation.id) && $0.conversation.projectID == nil
            && (($0.conversation.mode == .code) == (model.mode == .code)) }
    }

    /// The list after the type and unread filters (Code shows code conversations only).
    private var visible: [ConversationSearchHit] {
        conversations.filter { hit in
            let mode = hit.conversation.mode
            let kindMatches = model.mode == .code || kindFilter == .all
                || (kindFilter == .chats && mode == .chat) || (kindFilter == .agents && mode == .agent)
            return kindMatches && (!unreadOnly || model.status(of: hit.conversation) == .unread)
        }
    }

    private var filtering: Bool { unreadOnly || (model.mode != .code && kindFilter != .all) }

    private var emptyText: String {
        if !query.isEmpty { return "No matching conversations" }
        if filtering { return "Nothing matches these filters" }
        return "Your conversations will appear here"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showSpaces.toggle() } label: {
                HStack(spacing: 8) {
                    Text(model.mode == .code ? "Code" : "Chat").font(.system(size: 20, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            .buttonStyle(.aimHover(radius: 9, active: showSpaces))
            .padding(.horizontal, 12).frame(height: 56)
            .accessibilityIdentifier("space-switcher")
            .aimMenu(isPresented: $showSpaces) {
                AIMMenuItem("Chat", subtitle: "Create, learn and explore", icon: "bubble.left",
                            checked: model.mode != .code) { model.selectMode(.chat) }
                AIMMenuItem("Code", subtitle: "Build, debug and ship", icon: "chevron.left.forwardslash.chevron.right",
                            checked: model.mode == .code) { model.selectMode(.code) }
            }

            VStack(spacing: 1) {
                SidebarNavRow(title: "New chat", shortcut: "⌘N", icon: .plus) { Task { await model.newGeneralConversation() } }
                SidebarNavRow(title: "Projects", icon: .symbol("folder")) { Task { model.showCustomize = false; await model.openProjects() } }
                    .disabled(model.isSending)
                SidebarNavRow(title: "Customize", icon: .symbol("briefcase"), selected: model.showCustomize) { Task { await model.openCustomize() } }
            }
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    if !searching, conversations.contains(where: { $0.conversation.pinnedAt != nil }) {
                        sectionTitle("Pinned")
                        ForEach(visible.filter { $0.conversation.pinnedAt != nil }.sorted { ($0.conversation.pinnedAt ?? .distantPast) > ($1.conversation.pinnedAt ?? .distantPast) }) { hit in
                            conversationRow(hit)
                        }
                    }
                    recentsHeader
                    ForEach(searching ? visible : visible.filter { $0.conversation.pinnedAt == nil }) { hit in conversationRow(hit) }
                    if visible.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 8)
                .animation(.snappy(duration: 0.28), value: visible.map(\.id))
            }

            if let title = model.updateSidebarTitle {
                Button { model.checkForUpdates() } label: {
                    Label { Text(title) } icon: { Image(systemName: "arrow.down.circle") }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .buttonStyle(.aimHover(radius: 8))
                .disabled(!model.updateController.canPresentUpdate)
                .accessibilityIdentifier("sidebar-update")
                .padding(.horizontal, 12)
            }
            UserProfileMenu().padding(12)
        }
        // RootView owns the shared backdrop, including Settings. A local opaque
        // fill would mask its material in Chat, Projects and Customize.
        #if DEBUG
        .onChange(of: model.debugOpenMenu) { _, menu in
            showSpaces = menu == "spaces"
            showFilter = menu == "sidebar-filter"
            if menu == "sidebar-search" { openSearch(); query = "quant" }
            if menu == nil, searching { closeSearch() }
        }
        #endif
        .task(id: "\(model.mode.rawValue):\(query):\(model.conversations)") {
            guard !query.isEmpty else { results = []; return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let matches = await model.searchConversationHits(query)
            guard !Task.isCancelled else { return }
            results = matches
        }
        .alert("Rename conversation", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let id = renameTarget?.id { Task { await model.renameConversation(id, to: title) } }
                renameTarget = nil
            }
        }
        .sheet(item: $exportTarget) { ConversationExportView(conversation: $0) }
        .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete conversation", role: .destructive) {
                if let id = deleteTarget?.id { Task { await model.deleteConversation(id) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { Text("This removes its messages from this Mac and cannot be undone.") }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 6)
    }

    /// "Recents" with search and filter buttons; search opens a field in its place.
    @ViewBuilder private var recentsHeader: some View {
        HStack(spacing: 2) {
            if searching {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Search conversations", text: $query)
                        .textFieldStyle(.plain).focusEffectDisabled().focused($searchFocused)
                        .onSubmit { if let first = visible.first { Task { await model.openSearchHit(first) } } }
                        .onExitCommand { closeSearch() }
                    Button { closeSearch() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.aimHover(radius: 6)).foregroundStyle(.secondary).accessibilityLabel("Close search")
                }
                .font(.system(size: 13))
                .padding(.leading, 9).padding(.trailing, 4).frame(height: 30)
                .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .trailing)))
            } else {
                Text("Recents").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                    .padding(.leading, 10)
                    .transition(.opacity)
                Spacer(minLength: 0)
                headerButton("magnifyingglass", "Search conversations", active: false) { openSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                headerButton(filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                             "Filter", active: showFilter || filtering) { showFilter.toggle() }
                    .aimMenu(isPresented: $showFilter) { filterMenu }
            }
        }
        .frame(height: 30)
        .padding(.top, 14).padding(.bottom, 4)
        .animation(.snappy(duration: 0.22), value: searching)
    }

    private func headerButton(_ icon: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 24)
        }
        .buttonStyle(.aimHover(radius: 7, active: active))
        .foregroundStyle(active ? .primary : .secondary)
        .aimTooltip(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var filterMenu: some View {
        if model.mode != .code {
            AIMMenuSection("Show")
            AIMMenuItem("All conversations", icon: "tray.full", checked: kindFilter == .all) { kindFilter = .all }
            AIMMenuItem("Chats", icon: "bubble.left", checked: kindFilter == .chats) { kindFilter = .chats }
            AIMMenuItem("Agent tasks", icon: "sparkles", checked: kindFilter == .agents) { kindFilter = .agents }
            AIMMenuDivider()
        }
        AIMMenuItem("Unread only", icon: "smallcircle.filled.circle", checked: unreadOnly) { unreadOnly.toggle() }
    }

    private func openSearch() {
        searching = true
        Task { try? await Task.sleep(for: .milliseconds(60)); searchFocused = true }
    }

    private func closeSearch() {
        query = ""
        searchFocused = false
        searching = false
    }

    private func conversationRow(_ hit: ConversationSearchHit) -> some View {
        let conversation = hit.conversation
        let selected = conversation.id == model.selectedConversationID
        let hovered = hoveredConversation == conversation.id || focusedConversation == conversation.id
        let menuOpen = menuConversation == conversation.id
        let status = model.status(of: conversation)
        return HStack(spacing: 0) {
            // The whole row opens the conversation (its margins included), not only the text.
            Button { Task { await model.openSearchHit(hit) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ConversationStatusDot(status: status, kind: conversation.mode)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title).font(.system(size: 13.5, weight: status == .unread ? .semibold : .regular)).lineLimit(1)
                            .foregroundStyle(selected || status == .unread ? Color.primary : Color.primary.opacity(0.82))
                            .contentTransition(.opacity)
                            .animation(.easeOut(duration: 0.3), value: conversation.title)
                        if let excerpt = hit.excerpt, !query.isEmpty {
                            Text(excerpt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10).padding(.vertical, hit.excerpt != nil && !query.isEmpty ? 5 : 0)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .focused($focusedConversation, equals: conversation.id)
            Button { menuConversation = menuOpen ? nil : conversation.id } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22)
            }
            .buttonStyle(.aimHover(radius: 6, active: menuOpen))
            .opacity(hovered || menuOpen ? 1 : 0)
            .accessibilityLabel("Options for \(conversation.title)")
            .aimMenu(isPresented: Binding(get: { menuConversation == conversation.id },
                                          set: { if !$0, menuConversation == conversation.id { menuConversation = nil } })) {
                conversationMenu(conversation)
            }
        }
        .padding(.trailing, 4)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.1 : 0.07))
                    .matchedGeometryEffect(id: "selection", in: selection)
            } else if hovered || menuOpen {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(scheme == .dark ? 0.06 : 0.04))
            }
        }
        .contentShape(Rectangle())
        .onHover { hoveredConversation = $0 ? conversation.id : nil }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.snappy(duration: 0.25), value: selected)
        .contextMenu { conversationActions(conversation) }
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func conversationMenu(_ conversation: Conversation) -> some View {
        AIMMenuItem("Rename…", icon: "pencil") { title = conversation.title; renameTarget = conversation }
        AIMMenuItem(conversation.pinnedAt == nil ? "Pin" : "Unpin", icon: conversation.pinnedAt == nil ? "pin" : "pin.slash") {
            Task { await model.setPinned(conversation.id, conversation.pinnedAt == nil) }
        }
        AIMMenuItem("Export…", icon: "square.and.arrow.up") { exportTarget = conversation }
            .disabled(model.isSending || model.responseSaveError != nil)
        AIMMenuItem("Copy conversation", icon: "doc.on.doc") { Task { await model.copyConversation(conversation.id) } }
        if !model.projects.isEmpty {
            AIMMenuDivider()
            AIMMenuSection("Move to project")
            if conversation.projectID != nil {
                AIMMenuItem("No project", icon: "tray") { Task { await model.moveConversation(conversation.id, toProject: nil) } }
                    .disabled(model.isSending)
            }
            ForEach(model.projects.prefix(6)) { project in
                AIMMenuItem(project.name, icon: "folder", checked: conversation.projectID == project.id) {
                    Task { await model.moveConversation(conversation.id, toProject: project.id) }
                }
                .disabled(model.isSending)
            }
        }
        AIMMenuDivider()
        AIMMenuItem("Delete…", icon: "trash", destructive: true) { deleteTarget = conversation }
    }

    @ViewBuilder private func conversationActions(_ conversation: Conversation) -> some View {
        Button("Rename…") { title = conversation.title; renameTarget = conversation }
        Button(conversation.pinnedAt == nil ? "Pin" : "Unpin", systemImage: conversation.pinnedAt == nil ? "pin" : "pin.slash") {
            Task { await model.setPinned(conversation.id, conversation.pinnedAt == nil) }
        }
        Menu("Move to project") {
            Button("No project") { Task { await model.moveConversation(conversation.id, toProject: nil) } }
            ForEach(model.projects) { project in
                Button(project.name) { Task { await model.moveConversation(conversation.id, toProject: project.id) } }
            }
        }.disabled(model.isSending)
        Button("Export…", systemImage: "square.and.arrow.up") { exportTarget = conversation }
            .disabled(model.isSending || model.responseSaveError != nil)
        Button("Copy conversation", systemImage: "doc.on.doc") { Task { await model.copyConversation(conversation.id) } }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { deleteTarget = conversation }
    }

}

enum SidebarKindFilter: String { case all, chats, agents }

/// A top row of the sidebar (New chat, Projects): a light pill inset from the edges; the
/// New chat "+" turns a quarter on hover.
private struct SidebarNavRow: View {
    enum Icon { case plus, symbol(String) }
    let title: String
    var shortcut: String?
    let icon: Icon
    var selected = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    switch icon {
                    case .plus:
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.primary.opacity(hovered ? 0.1 : 0.06)))
                            .rotationEffect(.degrees(hovered ? 90 : 0))
                    case .symbol(let name):
                        Image(systemName: name).font(.system(size: 13.5))
                            .frame(width: 20, height: 20)
                            .scaleEffect(hovered ? 1.06 : 1)
                    }
                }
                .foregroundStyle(.primary.opacity(0.85))
                Text(title).font(.system(size: 13.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(selected ? (scheme == .dark ? 0.1 : 0.07) : hovered && enabled ? (scheme == .dark ? 0.06 : 0.045) : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarPressStyle())
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: hovered)
        .modifier(OptionalTooltip(title: title, shortcut: shortcut))
    }
}

private struct OptionalTooltip: ViewModifier {
    let title: String
    let shortcut: String?
    func body(content: Content) -> some View {
        if let shortcut { content.aimTooltip(title, shortcut: shortcut) } else { content }
    }
}

private struct SidebarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The conversation's state, as in Claude: an empty ring at rest, green while it runs, blue
/// for an answer not read yet, red when the last answer failed.
struct ConversationStatusDot: View {
    let status: AppModel.ConversationStatus
    let kind: AIMMode
    @State private var breathing = false

    var body: some View {
        ZStack {
            switch status {
            case .idle:
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.2)
            case .running, .waiting:
                Circle().fill(Color.green.opacity(0.28)).scaleEffect(breathing ? 1.9 : 1)
                    .opacity(breathing ? 0 : 1)
                Circle().fill(Color.green)
            case .unread:
                Circle().fill(Color.blue)
            case .failed:
                Circle().fill(Color.red)
            }
        }
        .frame(width: 7, height: 7)
        .frame(width: 14, height: 14)
        .animation(.easeOut(duration: 0.2), value: status)
        .onAppear { startBreathing() }
        .onChange(of: status) { _, _ in startBreathing() }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private func startBreathing() {
        breathing = false
        guard status == .running || status == .waiting else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { breathing = true }
    }

    private var helpText: String {
        let what = kind == .agent ? "Agent task" : kind == .code ? "Code conversation" : "Chat"
        switch status {
        case .idle: return what
        case .running: return what + " · running"
        case .waiting: return what + " · waiting for a response or approval"
        case .unread: return what + " · new answer"
        case .failed: return what + " · the last answer failed"
        }
    }
}

private struct ArchivedConversationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var exportTarget: Conversation?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Archived conversations").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.settingsPrimary).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                SettingsCard {
                    if model.archivedConversations.isEmpty {
                        SettingsRow("No archived conversations", description: "Conversations you archive appear here.")
                    }
                    ForEach(model.archivedConversations) { conversation in
                        SettingsRow(conversation.title) {
                            Button("Export…") { exportTarget = conversation }.buttonStyle(.settings)
                                .disabled(model.isSending || model.responseSaveError != nil)
                            Button("Restore") { Task { await model.setArchived(conversation.id, false) } }.buttonStyle(.settings)
                        }
                    }
                }
            }
        }
        .padding(24).frame(width: 540, height: 380)
        .task { await model.loadArchives() }
        .sheet(item: $exportTarget) { ConversationExportView(conversation: $0) }
    }
}
