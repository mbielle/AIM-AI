import AIMCore
@preconcurrency import AVFoundation
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct AIMConversationView: View {
    let session: RemoteSession
    let store: MainExperienceStore
    let cloudContentService: any CloudContentServicing
    let messages: [RemoteMessage]
    let machineOnline: Bool
    let commandHealth: RemoteCommandHealth
    let isSending: Bool
    let errorMessage: String?
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let openMenu: () -> Void
    let openPersonalization: () -> Void
    let refreshHealth: () async -> Void
    let send: (String, [RemoteAttachmentReference]) async -> Bool
    let uploadAttachment: (Data, String, String, VideoPreparationOptions) async -> RemoteAttachmentReference?
    let approve: (Bool) async -> Bool
    let answerQuestion: (String) async -> Bool
    let changeModel: (String, String?) async -> Bool
    let changeApprovalMode: (String) async -> Bool
    let sendGoal: (String, Int, [RemoteAttachmentReference]) async -> Bool
    let stop: () async -> Bool
    let resume: () async -> Bool
    var selectThisDevice: (() -> Void)? = nil
    var selectComputer: ((String) -> Void)? = nil
    var executionAllowed = true
    var sharedDraft: Binding<String>? = nil
    var changeModelSelection: ((RemoteModelAnnouncement, String?) async -> Bool)? = nil
    var modelProvider: String? = nil

    @State private var detail: ConversationDetail?
    @State private var toolActivity: RemoteToolActivityGroup?
    @State private var toolPanel: RemoteToolPanel?
    @State private var showingStatusDetails = false
    @State private var sessionDrafts: [String: String] = [:]
    @State private var composerAttachments: [RemoteAttachmentReference] = []
    @State private var showingFind = false
    @State private var showingUploads = false
    @State private var showingProjects = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    @State private var workspaceDiff: RemoteDiffResult?

    @ViewBuilder
    private var pendingInteractionDock: some View {
        if let approval = session.pendingApproval {
            Group {
                if approval.kind == "visual" {
                    AIMRemoteVisualApprovalCard(approval: approval, store: store, online: machineOnline)
                } else {
                    AIMPendingApprovalCard(
                        approval: approval,
                        online: machineOnline,
                        busy: isSending,
                        respond: approve,
                        answerQuestion: answerQuestion
                    )
                }
            }
            .id(approval.messageID)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var composerText: String {
        get { sharedDraft?.wrappedValue ?? sessionDrafts[session.id, default: ""] }
        nonmutating set {
            if let sharedDraft { sharedDraft.wrappedValue = newValue }
            else { sessionDrafts[session.id] = newValue }
        }
    }

    private var remoteWorkText: String {
        let phase = session.phase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let generic = ["", "running", "working", "thinking", "working…", "thinking…", "working...", "thinking..."]
        return generic.contains(phase.lowercased())
            ? (Locale.current.language.languageCode?.identifier == "fr" ? "Synchronisation…" : "Syncing…") : phase
    }

    private var hasObservedTurnActivity: Bool {
        guard let latest = messages.last, latest.role == .assistant else { return false }
        return latest.timeline?.contains { value in
            let type = value.objectValue?["type"]?.stringValue
            return type == "turn" || type == "tool" || type == "reasoning"
        } == true
    }

    var body: some View {
        AIMConversationScaffold(safeTop: safeTop, safeBottom: safeBottom) { bottomOcclusion in
            AIMConversationTimeline(identity: session.id, revision: "\(messages.count):\(messages.last?.content ?? ""):\(store.queuedMessages.filter { $0.sessionID == session.id }.count)", safeTop: safeTop, bottomOcclusion: bottomOcclusion) {
                        if store.supportsContinuousGoals, session.mode != .chat {
                            AIMContinuityPanel(store: store, sessionID: session.id)
                        }
                        if store.isLoadingConversation && messages.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(0..<4, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.primary.opacity(0.07))
                                        .frame(width: index.isMultiple(of: 2) ? 280 : 220, height: 18)
                                }
                            }
                            .padding(.top, 70)
                            .redacted(reason: .placeholder)
                            .accessibilityIdentifier("conversation-loading-skeleton")
                        } else if messages.isEmpty {
                            ContentUnavailableView(
                                "remote.conversation.empty.title",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("remote.conversation.empty.body")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 90)
                        }

                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let turnActive = RemoteTimelineRules.keepsLatestTurnExpanded(role: message.role, isLatest: index == messages.count - 1, sessionStatus: session.status)
                            AIMRemoteMessageView(
                                message: message,
                                turnActive: turnActive,
                                endOfTurn: RemoteResponseRules.endOfTurn(
                                    messages: messages.map { .init(role: $0.role, content: $0.content, timeline: $0.timeline) },
                                    index: index,
                                    status: session.status
                                ),
                                openDetail: { selected in
                                    AIMHaptics.selection()
                                    detail = selected
                                    Task {
                                        guard let remoteID = selected.remoteID,
                                              let fullText = await store.requestDetail(id: remoteID),
                                              !fullText.isEmpty
                                        else { return }
                                        detail = .init(id: selected.id, title: selected.title, text: fullText)
                                    }
                                },
                                openToolGroup: { group in
                                    AIMHaptics.selection()
                                    toolActivity = group
                                }
                            )
                            .id(message.id)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                        }

                        if let action = store.reconnectionAction(for: session) {
                            HStack {
                                Label(action.name, systemImage: "wifi").font(.footnote).foregroundStyle(.secondary)
                                Button("Cancel") { store.cancelReconnection(for: session) }.font(.footnote).tint(.primary)
                            }.accessibilityIdentifier("remote-reconnection-line")
                            AIMConversationActions(actions: [action])
                        } else if session.status == "running", !session.readState.blocksReading,
                                  !hasObservedTurnActivity {
                            AIMRemoteWorkStatus(text: remoteWorkText)
                                .accessibilityIdentifier("conversation-progress")
                        }

                        ForEach(store.queuedMessages.filter { $0.sessionID == session.id }) { entry in
                            VStack(alignment: .trailing, spacing: 8) {
                                Text(entry.text).frame(maxWidth: .infinity, alignment: .trailing)
                                if !entry.attachments.isEmpty { Text("\(entry.attachments.count) attachment(s)").font(.caption) }
                                Label(entry.state == "waiting" ? "Waiting for connection" : entry.state == "sending" ? "Sending…" : "Delivery unconfirmed — check the conversation before sending again", systemImage: "clock")
                                    .font(.caption).foregroundStyle(.secondary)
                                if entry.state != "sending" {
                                    Button(entry.state == "waiting" ? "Cancel pending message" : "Dismiss pending message") { store.removeQueuedMessage(entry.id) }
                                        .font(.caption)
                                }
                            }
                            .padding(14)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityIdentifier("queued-message-\(entry.id)")
                        }





                        if RemoteSessionRules.primaryAction(status: session.status, interrupted: session.isInterrupted, mode: session.mode) == .resume {
                            Button {
                                Task { _ = await resume() }
                            } label: {
                                Label("remote.conversation.resume", systemImage: "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(Color.primary, in: Capsule())
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                            }
                            .buttonStyle(.plain)
                            .disabled(!machineOnline || isSending)
                        }

            }
        } header: {
            header
        } composer: {
            VStack(spacing: 0) {
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.horizontal, 18).padding(.bottom, 8)
                        .accessibilityIdentifier("conversation-error")
                }
                if let workspaceDiff, !workspaceDiff.files.isEmpty {
                    Button { toolPanel = .diff } label: {
                        HStack(spacing: 8) {
                            Text("\(workspaceDiff.files.count) files")
                            Text("+\(workspaceDiff.additions)").foregroundStyle(.green)
                            Text("−\(workspaceDiff.deletions)").foregroundStyle(.red)
                            Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .aimGlassCapsule()
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 7)
                }
                if !executionAllowed {
                    VStack(spacing: 8) {
                        Text("Choose this Mac as the execution target to continue here.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if let selectComputer {
                            Button(conversationMachine?.name ?? "Select Mac") { selectComputer(session.machineID) }
                                .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                                .accessibilityIdentifier("conversation-select-execution-target")
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 10)
                }
                pendingInteractionDock
                AIMConversationComposer(
                    text: Binding(get: { composerText }, set: { composerText = $0 }),
                    attachments: $composerAttachments,
                    modelName: session.modelID ?? "Choose model",
                    modelID: session.modelID ?? "",
                    capabilities: conversationMachine?.capabilities,
                    mode: session.mode,
                    approvalMode: session.approvalMode,
                    attachmentsEnabled: store.overview.machines.first(where: { $0.id == session.machineID })?.capabilities?.features["attachments"] == true,
                    enabled: executionAllowed,
                    sendEnabled: executionAllowed && session.status != "waiting_approval",
                    loading: isSending,
                    sessionRunning: executionAllowed && session.status == "running",
                    safeBottom: safeBottom,
                    openPersonalization: openPersonalization,
                    send: { text, attachments in
                        guard executionAllowed else { return false }
                        guard machineOnline, commandHealth == .responsive else {
                            AIMHaptics.error()
                            showingStatusDetails = true
                            return false
                        }
                        return await send(text, attachments)
                    },
                    uploadAttachment: uploadAttachment,
                    changeModel: changeModel,
                    changeApprovalMode: changeApprovalMode,
                    sendGoal: sendGoal,
                    stop: stop,
                    setModelAdded: store.selectedMachine?.capabilities?.features["modelLibrary"] == true
                        ? { model, added in await store.setModelAdded(model: model, added: added) } : nil,
                    changeModelSelection: changeModelSelection,
                    modelProvider: modelProvider, remoteStore: store, agentID: session.agentSystem
                )
            }
        }
        .aimBlocksBackgroundInteractions(detail != nil || toolActivity != nil || toolPanel != nil || showingFind || showingUploads || showingProjects || showingRename || confirmingDelete || showingStatusDetails)
        .sheet(item: $detail) { detail in
            AIMConversationDetailSheet(detail: detail)
        }
        .sheet(item: $toolActivity) { group in
            AIMToolActivityPanel(group: group, store: store)
        }
        .sheet(item: $toolPanel) { panel in
            AIMRemoteToolPanel(panel: panel, store: store)
        }
        .sheet(isPresented: $showingFind) {
            AIMFindInConversationPanel(session: session, store: store, initialMessages: messages)
        }
        .sheet(isPresented: $showingUploads) {
            AIMUploadedFilesPanel(session: session, store: store)
        }
        .sheet(isPresented: $showingProjects) {
            AIMConversationProjectPanel(session: session, store: store, cloudService: cloudContentService)
        }
        .alert("Rename conversation", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { _ = await store.renameSession(session, title: renameText) } }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { _ = await store.deleteSessions(ids: [session.id]) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will also be deleted from the computer.")
        }
        .onChange(of: session.status) { previous, current in
            guard previous == "running", current != "running" else { return }
            AIMHaptics.success()
        }
        .task {
            await refreshHealth()
            if supportsDiff { workspaceDiff = try? await store.requestDiff() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-screen")
    }

    private var header: some View {
        // Read the draft while building the header, not only in the deferred
        // popover closure, so edits invalidate the presentation's content.
        let pendingText = composerText
        let pendingAttachments = composerAttachments
        return HStack(spacing: 0) {
            Button(action: openMenu) {
                Image(systemName: session.mode == .chat ? "line.3.horizontal" : "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(Text("sidebar.open"))
            .accessibilityIdentifier("conversation-menu-button").modifier(AIMAttentionBadge())

            Spacer()

            Button {
                AIMHaptics.selection()
                showingStatusDetails.toggle()
            } label: {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.38), radius: 3)
                    .frame(width: 32, height: 32)
                    .aimGlassCircle()
            }
                .buttonStyle(.plain)
                .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                .contentShape(Circle())
                .accessibilityLabel(Text("Status"))
                .accessibilityValue(Text(statusDescription))
                .accessibilityIdentifier("conversation-header-status")
                .popover(isPresented: $showingStatusDetails, arrowEdge: .top) {
                    VStack(spacing: 12) {
                    AIMConversationStatusPopover(
                        session: session,
                        machine: conversationMachine,
                        color: statusColor,
                        status: statusDescription
                    )
                    if session.mode == .chat {
                        if let selectThisDevice {
                            Button { showingStatusDetails = false; selectThisDevice() } label: {
                                Label("This iPhone", systemImage: "iphone")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }
                        if let selectComputer {
                            Menu {
                                ForEach(store.overview.machines) { machine in
                                    Button(machine.name) { showingStatusDetails = false; selectComputer(machine.id) }
                                }
                            } label: {
                                Label("Computer", systemImage: "desktopcomputer")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                    if !machineOnline || commandHealth != .responsive {
                        Button("Send when reconnected") {
                            if store.queueMessage(text: pendingText, attachments: pendingAttachments, session: session) {
                                composerText = ""
                                composerAttachments = []
                                showingStatusDetails = false
                                AIMHaptics.success()
                            }
                        }
                        .disabled(pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty)
                        .padding(.bottom, 16)
                        .accessibilityIdentifier("queue-message-button")
                    }
                    }
                    .presentationCompactAdaptation(.popover)
                }

            Spacer()

            conversationMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, safeTop + 8)
        .padding(.bottom, 8)
    }

    private var statusColor: Color {
        guard machineOnline else { return .red }
        return switch commandHealth {
        case .responsive: .green
        case .unknown, .checking: .orange
        case .unresponsive, .incompatible: .red
        }
    }

    private var statusDescription: String {
        guard machineOnline else { return String(localized: "remote.conversation.offline") }
        return switch commandHealth {
        case .responsive: String(localized: "remote.conversation.online")
        case .unknown, .checking: String(localized: "remote.conversation.checking")
        case .unresponsive: String(localized: "remote.error.bridge_unresponsive")
        case .incompatible: String(localized: "remote.error.incompatible_version")
        }
    }

    private var conversationMachine: RemoteMachine? {
        store.overview.machines.first { $0.id == session.machineID }
    }

    private var conversationMenu: some View {
        Menu {
            Button {
                Task { _ = await store.setPinned(!session.isPinned, session: session) }
            } label: {
                Label(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin")
            }

            if session.mode == .chat {
                Button { showingProjects = true } label: { Label("Add or move to project", systemImage: "folder") }
                if conversationMachine?.capabilities?.features["attachment_metadata"] == true {
                    Button { showingUploads = true } label: { Label("Uploaded files", systemImage: "paperclip") }
                }
                if conversationMachine?.capabilities?.supports(RemoteCapabilities.Feature.history) == true {
                    Button { showingFind = true } label: { Label("Find in chat", systemImage: "magnifyingglass") }
                }
            } else {
                if supportsSessionManagement {
                    Button { renameText = session.title; showingRename = true } label: { Label("Rename", systemImage: "pencil") }
                }
                Button {
                    UIPasteboard.general.string = session.id
                    AIMHaptics.success()
                } label: { Label("Copy thread ID", systemImage: "square.on.square") }
                if supportsDiff {
                    Button { toolPanel = .diff } label: { Label("Files", systemImage: "folder") }
                    Button { toolPanel = .diff } label: { Label("Diff", systemImage: "doc.text.magnifyingglass") }
                }
                if supportsTerminal {
                    Button { toolPanel = .terminal } label: { Label("Terminal", systemImage: "terminal") }
                }
                if supportsBrowser {
                    Button { toolPanel = .browser } label: { Label("Browser", systemImage: "globe") }
                }
            }

            if supportsSessionManagement {
                Divider()
                Button {
                    Task { _ = await store.setArchived(session.archivedAt == nil, session: session) }
                } label: {
                    Label(session.archivedAt == nil ? "Archive" : "Restore", systemImage: session.archivedAt == nil ? "archivebox" : "tray.and.arrow.up")
                }
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                .aimGlassCircle()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(Text("remote.conversation.actions"))
    }

    private var supportsSessionManagement: Bool {
        conversationMachine?.capabilities?.supports(RemoteCapabilities.Feature.sessionManagement) == true
    }

    private var supportsTerminal: Bool {
        guard let features = conversationMachine?.capabilities?.features else { return false }
        if session.mode == .agent { return features[RemoteCapabilities.Feature.agentTerminal] == true }
        return features["terminal"] == true || features["code_terminal"] == true
    }

    private var supportsDiff: Bool {
        guard let features = conversationMachine?.capabilities?.features else { return false }
        if session.mode == .agent { return features[RemoteCapabilities.Feature.agentDiff] == true }
        return features["diff"] == true || features[RemoteCapabilities.Feature.structuredDiff] == true
    }

    private var supportsBrowser: Bool {
        guard let features = conversationMachine?.capabilities?.features else { return false }
        if session.mode == .agent { return features[RemoteCapabilities.Feature.agentBrowser] == true }
        return features["preview"] == true || features["browser"] == true
    }
}

private struct AIMConversationStatusPopover: View {
    let session: RemoteSession
    let machine: RemoteMachine?
    let color: Color
    let status: String
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .shadow(color: color.opacity(0.38), radius: 3)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text(status)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(color)
                }
            }

            Divider().opacity(0.55)

            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(machine?.name ?? copy("Unknown computer", "Ordinateur inconnu"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(machineDetails)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
            }

            if let workspace = session.workspace, !workspace.isEmpty {
                Label(URL(fileURLWithPath: workspace).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(17)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial)
    }

    private var machineDetails: String {
        [machine?.platform, machine?.appVersion.map { "AIM \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}

struct AIMSessionListView: View {
    let mode: RemoteMode
    let machines: [RemoteMachine]
    let commandHealth: [String: RemoteCommandHealth]
    let sessions: [RemoteSession]
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let openMenu: () -> Void
    let addDevice: () -> Void
    let openSession: (RemoteSession) -> Void
    let startNewSession: () -> Void
    let refreshHealth: () async -> Void

    @Environment(\.locale) private var locale
    @State private var machineFilter: String?
    @State private var sort: RemoteSessionSort = .priority
    @State private var showsArchived = false

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    machineRail
                        .padding(.bottom, 28)

                    HStack {
                        Text(showsArchived ? copy("Archived sessions", "Sessions archivées") : copy("Sessions", "Sessions"))
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(sort == .priority ? copy("Priority", "Priorité") : copy("Recent", "Récentes"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 16)

                    if filteredSessions.isEmpty {
                        Text(copy("No synchronized session yet.", "Aucune session synchronisée pour le moment."))
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 34)
                            .overlay {
                                RoundedRectangle(cornerRadius: 25, style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [5]))
                            }
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredSessions) { session in
                                sessionCard(session)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, safeTop + 94)
                .padding(.bottom, safeBottom + 110)
            }
            .scrollIndicators(.hidden)

            VStack {
                header
                Spacer()
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: startNewSession) {
                        Label(copy("New conversation", "Nouvelle conversation"), systemImage: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 19)
                            .frame(height: 52)
                            .background(.thinMaterial, in: Capsule())
                            .background(Color.primary.opacity(0.88), in: Capsule())
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .overlay { Capsule().stroke(Color.white.opacity(0.12)) }
                            .shadow(color: .black.opacity(0.17), radius: 14, y: 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("new-\(mode.rawValue)-button")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, safeBottom + 18)
            }
        }
        .background {
            ZStack {
                Color(uiColor: .systemBackground)
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("\(mode.rawValue)-sessions-screen")
            }
        }
        .task { await refreshHealth() }
    }

    private var header: some View {
        HStack {
            Button(action: openMenu) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            Spacer()
            Text(mode == .code ? "Code" : "Agent")
                .font(AIMDesign.titleFont(size: 23, weight: .semibold))
            Spacer()
            Menu {
                Picker(copy("Sort", "Trier"), selection: $sort) {
                    Label(copy("Priority", "Priorité"), systemImage: "bell").tag(RemoteSessionSort.priority)
                    Label(copy("Chronological", "Chronologique"), systemImage: "clock.arrow.circlepath").tag(RemoteSessionSort.chronological)
                }
                Divider()
                Button {
                    showsArchived.toggle()
                } label: {
                    Label(
                        showsArchived ? copy("Active sessions", "Sessions actives") : copy("Archived sessions", "Sessions archivées"),
                        systemImage: showsArchived ? "tray" : "archivebox"
                    )
                }
                Button(action: addDevice) {
                    Label(copy("Add connection", "Ajouter une connexion"), systemImage: "link.badge.plus")
                }
                Button(action: addDevice) {
                    Label(copy("Remote settings", "Réglages Remote"), systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("remote-session-list-menu")
        }
        .padding(.horizontal, 16)
        .padding(.top, safeTop + 10)
        .padding(.bottom, 14)
        .aimTranslucentHeader()
    }

    private var machineRail: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                machineFilterButton(id: nil, title: copy("All", "Tous"), color: machines.contains(where: { $0.isOnline() }) ? .green : .secondary)
                ForEach(machines) { machine in
                    machineFilterButton(id: machine.id, title: machine.name, color: machineStatusColor(machine), icon: "desktopcomputer")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func machineFilterButton(id: String?, title: String, color: Color, icon: String? = nil) -> some View {
        let selected = machineFilter == id
        return Button {
            withAnimation(.snappy(duration: 0.22)) { machineFilter = id }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                if let icon { Image(systemName: icon) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(selected ? Color.primary : Color.primary.opacity(0.055), in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(selected ? 0 : 0.08)) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id.map { "machine-filter-\($0)" } ?? "machine-filter-all")
    }

    private func sessionCard(_ session: RemoteSession) -> some View {
        HStack(spacing: 13) {
            Circle()
                .fill(session.pendingApproval != nil ? Color.orange : session.status == "running" ? Color.green : Color.secondary.opacity(0.42))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title)
                    .font(.system(size: 17, weight: .medium))
                    .lineLimit(1)
                if machines.count > 1 {
                    Text(machines.first { $0.id == session.machineID }?.name ?? String(localized: "remote.sessions.unknown_computer"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(session.workspace ?? String(localized: "remote.sessions.no_folder"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(session.updatedAt, style: .relative)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(17)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.10)) }
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .aimSwipeSafeTap { openSession(session) }
        .accessibilityIdentifier("session-row-\(session.id)")
    }

    private var filteredSessions: [RemoteSession] {
        let visible = sessions.filter { session in
            (machineFilter == nil || session.machineID == machineFilter) &&
                (showsArchived ? session.archivedAt != nil : session.archivedAt == nil)
        }
        return RemoteSessionOrdering.sorted(visible, by: sort)
    }

    private func machineStatusColor(_ machine: RemoteMachine) -> Color {
        guard machine.isOnline() else { return .red }
        return switch commandHealth[machine.id] ?? .unknown {
        case .responsive: .green
        case .checking, .unknown: .orange
        case .unresponsive, .incompatible: .red
        }
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}

enum AIMMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case list(AIMMarkdownListNode)
    case quote(String)
    case code(language: String?, content: String)
    case math(content: String, display: Bool)
    case table(headers: [String], rows: [[String]])
    case rule
}

/// Retained as a compatibility parser for older fixtures. Production rendering
/// uses the cmark-gfm AST adapter below.
private enum AIMLegacyMarkdownParser {
    static func blocks(from source: String) -> [AIMMarkdownBlock] {
        var result: [AIMMarkdownBlock] = []
        var paragraph: [String] = []
        var unordered: [String] = []
        var ordered: [String] = []
        var code: [String] = []
        var codeLanguage: String?
        var isInCodeBlock = false
        var math: [String] = []
        var isInMathBlock = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let value = paragraph.joined(separator: "\n")
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("$"), trimmed.hasSuffix("$"), !trimmed.hasPrefix("$$"), trimmed.count > 2 {
                result.append(.math(content: String(trimmed.dropFirst().dropLast()), display: false))
            } else {
                result.append(.paragraph(value))
            }
            paragraph.removeAll()
        }

        func flushLists() {
            if !unordered.isEmpty {
                result.append(.unorderedList(unordered))
                unordered.removeAll()
            }
            if !ordered.isEmpty {
                result.append(.orderedList(ordered))
                ordered.removeAll()
            }
        }

        func flushText() {
            flushParagraph()
            flushLists()
        }

        let normalized = AIMMarkdownNormalizer.normalize(source)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "$$" {
                if isInMathBlock {
                    result.append(.math(content: math.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), display: true))
                    math.removeAll()
                    isInMathBlock = false
                } else if !isInCodeBlock {
                    flushText()
                    isInMathBlock = true
                } else {
                    code.append(line)
                }
                lineIndex += 1
                continue
            }

            if isInMathBlock {
                math.append(line)
                lineIndex += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                if isInCodeBlock {
                    result.append(.code(language: codeLanguage, content: code.joined(separator: "\n").trimmingCharacters(in: .newlines)))
                    code.removeAll()
                    codeLanguage = nil
                    isInCodeBlock = false
                } else {
                    flushText()
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    isInCodeBlock = true
                }
                lineIndex += 1
                continue
            }

            if isInCodeBlock {
                code.append(line)
                lineIndex += 1
                continue
            }

            if trimmed.isEmpty {
                flushText()
                lineIndex += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushText()
                result.append(.rule)
                lineIndex += 1
                continue
            }

            if
                let headers = tableCells(in: trimmed),
                headers.count >= 2,
                lineIndex + 1 < lines.count,
                isTableDelimiter(lines[lineIndex + 1], columnCount: headers.count)
            {
                flushText()
                var rows: [[String]] = []
                lineIndex += 2
                while lineIndex < lines.count,
                      let cells = tableCells(in: lines[lineIndex]),
                      cells.count == headers.count
                {
                    rows.append(cells)
                    lineIndex += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }

            let headingMarks = trimmed.prefix { $0 == "#" }
            if !headingMarks.isEmpty, headingMarks.count <= 6, trimmed.dropFirst(headingMarks.count).first == " " {
                flushText()
                result.append(.heading(
                    level: headingMarks.count,
                    text: String(trimmed.dropFirst(headingMarks.count + 1))
                ))
                lineIndex += 1
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushText()
                result.append(.quote(String(trimmed.dropFirst(2))))
                lineIndex += 1
                continue
            }

            if let item = unorderedItem(in: trimmed) {
                flushParagraph()
                if !ordered.isEmpty { flushLists() }
                unordered.append(item)
                lineIndex += 1
                continue
            }

            if let item = orderedItem(in: trimmed) {
                flushParagraph()
                if !unordered.isEmpty { flushLists() }
                ordered.append(item)
                lineIndex += 1
                continue
            }

            flushLists()
            paragraph.append(trimmed)
            lineIndex += 1
        }

        if isInCodeBlock {
            result.append(.code(language: codeLanguage, content: code.joined(separator: "\n").trimmingCharacters(in: .newlines)))
        }
        if isInMathBlock {
            result.append(.math(content: math.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), display: true))
        }
        flushText()
        return result
    }

    private static func unorderedItem(in line: String) -> String? {
        guard line.count > 2 else { return nil }
        let prefix = line.prefix(2)
        guard prefix == "- " || prefix == "* " || prefix == "+ " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedItem(in line: String) -> String? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let marker = line[..<separator]
        guard marker.count > 1, marker.last == "." || marker.last == ")" else { return nil }
        guard marker.dropLast().allSatisfy(\.isNumber) else { return nil }
        return String(line[line.index(after: separator)...])
    }

    private static func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false

        for character in trimmed.dropFirst().dropLast() {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isTableDelimiter(_ line: String, columnCount: Int) -> Bool {
        guard let cells = tableCells(in: line), cells.count == columnCount else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            let withoutColons = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return withoutColons.count >= 3 && withoutColons.allSatisfy { $0 == "-" }
        }
    }
}

enum AIMMarkdownParser {
    static func blocks(from source: String) -> [AIMMarkdownBlock] {
        AIMMarkdownDocument(source: source).blocks.map { block in
            switch block {
            case let .heading(level, text): .heading(level: level, text: text)
            case let .paragraph(text): .paragraph(text)
            case let .unorderedList(items): .unorderedList(items)
            case let .orderedList(items): .orderedList(items)
            case let .list(node): .list(node)
            case let .quote(text): .quote(text)
            case let .code(language, content): .code(language: language, content: content)
            case let .math(content, display): .math(content: content, display: display)
            case let .table(headers, rows): .table(headers: headers, rows: rows)
            case .rule: .rule
            }
        }
    }
}

struct AIMMarkdownView: View {
    let source: String
    var baseFont: Font = AIMDesign.bodyFont(size: 18)
    var expands = true

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(AIMMarkdownParser.blocks(from: source).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }

        if expands {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
        }
    }

    @ViewBuilder
    private func blockView(_ block: AIMMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inlineMarkdown(text)
                .font(AIMDesign.titleFont(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .lineSpacing(3)
                .padding(.top, level == 1 ? 6 : 2)
        case let .paragraph(text):
            inlineMarkdown(text)
                .font(baseFont)
                .lineSpacing(5)
        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("•").font(baseFont.weight(.semibold))
                        inlineMarkdown(item).font(baseFont).lineSpacing(5)
                    }
                }
            }
        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).").font(baseFont.weight(.semibold))
                        inlineMarkdown(item).font(baseFont).lineSpacing(5)
                    }
                }
            }
        case let .list(node):
            nestedList(node, depth: 0)
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(Color.primary.opacity(0.25)).frame(width: 3)
                inlineMarkdown(text).font(baseFont).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case let .code(language, content):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let language {
                        Text(language.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Label("remote.conversation.copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Color(uiColor: .systemBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("remote.conversation.copy"))
                }
                ScrollView(.horizontal) {
                    Text(content)
                        .font(.system(size: 14, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .textSelection(.enabled)
                        .padding(.bottom, 6)
                }
                .scrollIndicators(.visible)
                .accessibilityIdentifier("markdown-code-scroll")
            }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case let .math(content, display):
            ScrollView(.horizontal) {
                AIMMathFormulaView(latex: content, fontSize: display ? 20 : 17, display: display)
                    .frame(minWidth: display ? 260 : nil, minHeight: display ? 40 : 24)
                    .padding(.vertical, display ? 8 : 0)
            }
            .scrollIndicators(.hidden)
        case let .table(headers, rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                            inlineMarkdown(header)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(nil)
                                .frame(width: 210, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .frame(minWidth: 92, maxWidth: 230, alignment: .leading)
                        }
                    }
                    .background(Color.primary.opacity(0.07))

                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        Divider().gridCellColumns(headers.count)
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineMarkdown(cell)
                                    .font(.system(size: 14))
                                    .lineLimit(nil)
                                    .frame(width: 210, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .frame(minWidth: 92, maxWidth: 230, alignment: .leading)
                            }
                        }
                        .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.12))
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("markdown-table-scroll")
        case .rule:
            Divider()
        }
    }

    private func inlineMarkdown(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return Text(source)
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 15, design: .monospaced)
                attributed[run.range].backgroundColor = Color.primary.opacity(0.065)
            } else if run.link?.scheme == SourceCitationLink.scheme {
                // A citation pill: the cited site in small gray type on a light background.
                attributed[run.range].font = .system(size: 13, weight: .medium)
                attributed[run.range].foregroundColor = .secondary
                attributed[run.range].backgroundColor = Color.primary.opacity(0.07)
            }
        }
        return Text(attributed)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 24
        case 3: 21
        default: 19
        }
    }

    private func nestedList(_ node: AIMMarkdownListNode, depth: Int) -> AnyView {
        let ordered: Bool
        let items: [AIMMarkdownListItemNode]
        switch node {
        case let .unordered(values):
            ordered = false
            items = values
        case let .ordered(values):
            ordered = true
            items = values
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(baseFont.weight(.semibold))
                            .frame(minWidth: 14, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 9) {
                            if !item.text.isEmpty {
                                inlineMarkdown(item.text)
                                    .font(baseFont)
                                    .lineSpacing(5)
                            }
                            ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                                nestedList(child, depth: depth + 1)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                }
            }
            .padding(.leading, depth == 0 ? 0 : 8)
        )
    }
}

private struct AIMRemoteMessageView: View {
    let message: RemoteMessage
    let turnActive: Bool
    let endOfTurn: RemoteEndOfTurn
    let openDetail: (ConversationDetail) -> Void
    let openToolGroup: (RemoteToolActivityGroup) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    var body: some View {
        if message.role == .user {
            AIMChatUserBubble(text: message.content)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                let timeline = RemoteTimelineRules.displayTimeline(for: message.timelineMessage)
                let tools = timeline.filter { if case .tool = $0 { return true }; return false }
                if let turn = turnLayout(timeline) {
                    AIMTurnTimelineView(layout: turn.layout, sources: ConversationSource.fromTimeline(message.timeline), live: turn.live) { _ in
                        openToolGroup(.init(id: message.id + ":actions", segments: tools))
                    }
                } else {
                if !tools.isEmpty {
                    Button { openToolGroup(.init(id: message.id + ":actions", segments: tools)) } label: {
                        Label("Actions · \(tools.count)", systemImage: "chevron.right")
                            .font(AIMDesign.controlFont(size: 14)).foregroundStyle(.primary)
                    }.buttonStyle(.plain)
                }
                ForEach(timeline, id: \.id) { segment in
                    if case .tool(_, let tool) = segment {
                        if ["running", "pending", "error", "failed"].contains(tool.status) || tool.warning?.isEmpty == false {
                            Button { openToolGroup(.init(id: message.id + ":actions", segments: tools)) } label: {
                                Text(tool.name.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption).foregroundStyle(tool.status == "error" || tool.status == "failed" ? Color.red : .secondary)
                            }.buttonStyle(.plain)
                        }
                    } else { segmentView(segment) }
                }
                }

                if let stats = message.runStats {
                    AIMChatRunSummary(tokens: stats.tokens, costUSD: stats.directCost,
                                      duration: stats.duration, preciseDuration: stats.milliseconds < 10_000)
                }

                if endOfTurn.actions {
                    AIMChatMessageActions(text: endOfTurn.text, sources: ConversationSource.fromTimeline(message.timeline))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Answers sent with their turn order (a "turn" entry) use the shared timeline view.
    private func turnLayout(_ segments: [RemoteTimelineSegment]) -> (layout: TurnLayout<ConversationAction>, live: Bool)? {
        guard let entries = message.timeline, let turn = entries.first(where: { $0.objectValue?["type"]?.stringValue == "turn" })?.objectValue else { return nil }
        let durations = Dictionary(entries.compactMap { value -> (String, Double)? in
            guard let object = value.objectValue, let id = object["id"]?.stringValue, let duration = object["duration"]?.numberValue else { return nil }
            return (id, duration)
        }, uniquingKeysWith: { first, _ in first })
        let live = turnActive
        let pieces: [TurnLayoutItem<ConversationAction>] = segments.enumerated().compactMap { ordinal, segment in
            switch segment {
            case let .reasoning(id, text, running):
                return .reasoning(id: id, text: text, duration: durations[id], running: running)
            case let .text(id, text, _):
                return .text(id: id, text: text)
            case let .tool(_, tool):
                let unknown = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                return .tools(id: "tools:" + tool.id, tools: [tool.observedAction(
                    conversationID: UUID(uuidString: message.sessionID) ?? unknown,
                    turnID: UUID(uuidString: message.id) ?? unknown, ordinal: ordinal)])
            default: return nil
            }
        }
        return (TurnLayout.ordered(pieces, duration: turn["duration"]?.numberValue), live)
    }

    @ViewBuilder
    private func segmentView(_ segment: RemoteTimelineSegment) -> some View {
        switch segment {
        case let .reasoning(id, text, running):
            Button {
                openDetail(.init(id: id, title: String(localized: "remote.conversation.reasoning"), text: text))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: running ? "clock.arrow.circlepath" : "clock")
                    Text("remote.conversation.reasoning")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case let .text(_, text, _):
            if !text.isEmpty {
                AIMSourceMarkdown(text: text, sources: ConversationSource.fromTimeline(message.timeline))
                    .textSelection(.enabled)
            }
        case let .tool(id, tool):
            Button {
                openDetail(.init(
                    id: id,
                    title: tool.name,
                    text: tool.localResult ?? tool.resultPreview ?? tool.error ?? "",
                    remoteID: tool.hasFullResult ? nil : tool.id
                ))
            } label: {
                Label(tool.name, systemImage: "hammer")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case let .approval(id, _, state, summary):
            Button {
                openDetail(.init(id: id, title: String(localized: "remote.conversation.approval"), text: summary ?? state))
            } label: {
                Label(summary ?? state, systemImage: "checkmark.shield")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case let .status(_, state):
            if state == "interrupted" || state == "error" {
                Label(state == "interrupted" ? "remote.conversation.interrupted" : "remote.conversation.failed", systemImage: "circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activitySummary(_ group: RemoteToolActivityGroup) -> String {
        let counts = Dictionary(grouping: group.tools, by: { $0.presentation.kind }).mapValues(\.count)
        var parts: [String] = []
        let french = locale.language.languageCode?.identifier == "fr"
        let files = (counts[.createFile] ?? 0) + (counts[.editFile] ?? 0)
        if files > 0 {
            parts.append(french
                ? (files == 1 ? "Créé ou modifié un fichier" : "Créé ou modifié \(files) fichiers")
                : (files == 1 ? "Created or edited a file" : "Created or edited \(files) files"))
        }
        let commands = counts[.command] ?? 0
        if commands > 0 {
            parts.append(french
                ? (commands == 1 ? "exécuté une commande" : "exécuté \(commands) commandes")
                : (commands == 1 ? "ran a command" : "ran \(commands) commands"))
        }
        let searches = (counts[.search] ?? 0) + (counts[.readFile] ?? 0) + (counts[.browser] ?? 0)
        if searches > 0 {
            parts.append(french
                ? (searches == 1 ? "consulté une source" : "consulté \(searches) sources")
                : (searches == 1 ? "checked a source" : "checked \(searches) sources"))
        }
        let described = files + commands + searches
        let other = max(0, group.tools.count - described)
        if other > 0 || parts.isEmpty {
            parts.append(french
                ? (group.tools.count == 1 ? "Utilisé un outil" : "Utilisé \(group.tools.count) outils")
                : (group.tools.count == 1 ? "Used a tool" : "Used \(group.tools.count) tools"))
        }
        guard let first = parts.first else { return "" }
        return ([first] + parts.dropFirst().map { $0.prefix(1).lowercased() + String($0.dropFirst()) }).joined(separator: ", ")
    }
}

enum AIMConversationComposerPresentation: Equatable {
    case compact
    case expanded

    static func state(
        focused: Bool,
        text: String,
        hasAttachments: Bool,
        hasActiveSecondaryState: Bool
    ) -> Self {
        focused
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasAttachments
            || hasActiveSecondaryState
            ? .expanded
            : .compact
    }
}

private struct AIMComposerInteractionState {
    var focused = false
    var expanding = false
    var menuPresented = false
    var restoreFocusAfterPresentation = false
}

/// Finite proposals keep long model names from widening the floating surface.
/// The model name yields to fixed touch targets on the same row.
struct AIMComposerControlsLayout: Layout {
    @Environment(\.displayScale) private var displayScale
    var expanded: Bool
    var hasPermission: Bool
    var largeType: Bool
    var preferredModelWidth: CGFloat
    var modelRowHeight: CGFloat
    private let target: CGFloat = 44
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(0, proposal.width ?? 320), height: max(target, modelRowHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let modelIndex = hasPermission ? 2 : 1
        let fixed = CGFloat(subviews.count - 1) * target
        // Keep all controls on one row, including accessibility text sizes.
        // At 320 points, the model and effort still have independent 44-point targets.
        let minimumModel: CGFloat = expanded ? 88 : 44
        let gap = min(5, max(0, (bounds.width - fixed - minimumModel) / CGFloat(subviews.count - 1)))
        let available = max(0, bounds.width - fixed - CGFloat(subviews.count - 1) * gap)
        let modelWidth = expanded ? min(preferredModelWidth, available) : available
        var x = bounds.minX
        for index in subviews.indices {
            if index == subviews.count - 2 { x = bounds.maxX - target * 2 - gap }
            let width = index == modelIndex ? modelWidth : target
            // Keep the last target inside the clipping edge at fractional screen pixels.
            let alignedX = floor(x * displayScale) / displayScale
            subviews[index].place(at: CGPoint(x: alignedX, y: bounds.midY), anchor: .leading,
                                 proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }
}

private enum AIMComposerMediaPanel: Equatable {
    case photos
    case camera
}

enum AIMMediaPanelGeometry {
    static let horizontalMargin: CGFloat = 8
    static let bottomMargin: CGFloat = 8
    static let maximumHeight: CGFloat = 600
    static let relativeHeight: CGFloat = 0.70

    static func frame(in size: CGSize) -> CGRect {
        let height = min(maximumHeight, (size.height * relativeHeight).rounded())
        return CGRect(
            x: horizontalMargin,
            y: size.height - bottomMargin - height,
            width: max(0, size.width - (horizontalMargin * 2)),
            height: max(0, height)
        )
    }
}

private final class AIMMediaOverlayWindow: UIWindow {
    /// Legacy presenter, not a validated solution for covering the keyboard.
    /// The isolated keyboard lab must pass continuity tests before replacement.
    static let mediaLevel = UIWindow.Level.alert

    override var canBecomeKey: Bool { false }
}

@MainActor
private final class AIMComposerAnchor {
    weak var view: UIView?
    private var pending: ((UIView) -> Void)?

    func whenReady(_ action: @escaping (UIView) -> Void) {
        pending = action
        resolve()
    }

    func cancel() { pending = nil }

    func resolve() {
        guard let view, view.window?.windowScene?.activationState == .foregroundActive,
              view.bounds.width > 0, view.bounds.height > 0, let action = pending else { return }
        pending = nil
        // Window attachment/layout callbacks can run inside a SwiftUI update.
        // Defer to its completion, rather than guessing a presentation delay.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.view === view, view.window != nil else { return }
            action(view)
        }
    }
}

private struct AIMComposerAnchorProbe: UIViewRepresentable {
    let anchor: AIMComposerAnchor
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView(); view.isUserInteractionEnabled = false
        view.anchor = anchor; anchor.view = view
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) {
        view.anchor = anchor; anchor.view = view; anchor.resolve()
    }
    final class AnchorView: UIView {
        weak var anchor: AIMComposerAnchor?
        override func didMoveToWindow() { super.didMoveToWindow(); anchor?.resolve() }
        override func layoutSubviews() { super.layoutSubviews(); anchor?.resolve() }
    }
}

@Observable
private final class AIMOverlayMotion {
    var expanded = false
    var interactive = false
    var source = CGRect.zero
    var menuSize: CGSize?
    var keyboardVisible = false
}

@MainActor
private final class AIMMediaOverlayPresenter: NSObject {
    private var pendingAnchor: AIMComposerAnchor?
    private var outsideShield: UIControl?
    private var window: AIMMediaOverlayWindow?
    private var hostedController: UIViewController?
    private var backgroundObserver: NSObjectProtocol?
    private var onDismiss: (() -> Void)?
    private var motion: AIMOverlayMotion?
    private var generation = UUID()
    private var dismissing = false
    private var completions: [() -> Void] = []

    func present(content: AnyView, anchor: AIMComposerAnchor, menu: Bool = false, width: CGFloat = 248, onDismiss: @escaping () -> Void) {
        tearDown(notify: false)
        self.onDismiss = onDismiss
        pendingAnchor = anchor
        let token = generation
        anchor.whenReady { [weak self] source in
            guard let self, self.generation == token else { return }
            self.pendingAnchor = nil
            self.presentReady(content: content, source: source, menu: menu, width: width)
        }
    }

    private func presentReady(content: AnyView, source: UIView, menu: Bool, width: CGFloat) {
        guard let scene = source.window?.windowScene else { tearDown(notify: true); return }
        let motion = AIMOverlayMotion()
        self.motion = motion
        motion.source = source.convert(source.bounds, to: source.window)
        motion.keyboardVisible = AIMExperimentalKeyboardHost.shared.window?.isHidden == false
        if menu {
            let measuring = UIHostingController(rootView: content)
            let width = min(width, max(1, scene.coordinateSpace.bounds.width - 16))
            let size = measuring.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            motion.menuSize = CGSize(width: width, height: min(max(54, size.height), scene.coordinateSpace.bounds.height - 100))
        }
        let root = AIMMediaOverlayRoot(content: content, motion: motion) { [weak self] in
            self?.dismiss(notify: true)
        }
        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
        controller.view.backgroundColor = .clear

        if AIMExperimentalKeyboardHost.enabled,
           let host = AIMExperimentalKeyboardHost.shared.window, !host.isHidden {
            // The system keyboard window can pass taps outside its own input
            // region through to the app. Intercept those in the source window
            // as well, so a tap outside always dismisses without losing focus.
            if let sourceWindow = source.window {
                let shield = UIControl(frame: sourceWindow.bounds)
                shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                shield.addTarget(self, action: #selector(tappedOutside), for: .touchUpInside)
                sourceWindow.addSubview(shield)
                outsideShield = shield
            }
            // The original editor remains first responder. Retain the hosting
            // controller as well as its view for SwiftUI actions and lifecycle.
            controller.view.frame = host.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(controller.view)
            hostedController = controller
            observeBackground()
            animateIn(controller)
            return
        }

        let overlayWindow = AIMMediaOverlayWindow(windowScene: scene)
        overlayWindow.backgroundColor = .clear
        overlayWindow.rootViewController = controller
        overlayWindow.windowLevel = AIMMediaOverlayWindow.mediaLevel
        overlayWindow.isHidden = false
        window = overlayWindow
        observeBackground()
        animateIn(controller)
    }

    private func animateIn(_ controller: UIViewController) {
        controller.view.layoutIfNeeded()
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, !self.dismissing else { return }
            withAnimation(UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.12) : .spring(duration: 0.3, bounce: 0.12)) {
                self.motion?.expanded = true
            } completion: { [weak self] in
                guard let self, self.generation == token, !self.dismissing else { return }
                self.motion?.interactive = true
            }
        }
    }

    private func observeBackground() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tearDown(notify: true) }
        }
    }

    @objc private func tappedOutside() { dismiss(notify: true) }

    func dismiss(notify: Bool = false, completion: (() -> Void)? = nil) {
        if let completion { completions.append(completion) }
        guard !dismissing else { return }
        guard let motion else {
            let pending = completions
            tearDown(notify: notify)
            pending.forEach { $0() }
            return
        }
        dismissing = true
        motion.interactive = false
        let token = generation
        withAnimation(UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.12) : .spring(duration: 0.26, bounce: 0.05)) {
            motion.expanded = false
        } completion: { [weak self] in
            guard let self, self.generation == token else { return }
            let pending = self.completions
            self.tearDown(notify: notify)
            pending.forEach { $0() }
        }
    }

    private func tearDown(notify: Bool) {
        pendingAnchor?.cancel(); pendingAnchor = nil
        generation = UUID(); dismissing = false; motion = nil; completions = []
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        hostedController?.view.removeFromSuperview()
        outsideShield?.removeFromSuperview(); outsideShield = nil
        hostedController = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        let callback = notify ? onDismiss : nil
        onDismiss = nil
        callback?()
    }
}

private struct AIMMediaOverlayRoot: View {
    let content: AnyView
    let motion: AIMOverlayMotion
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let mediaFrame = AIMMediaPanelGeometry.frame(in: proxy.size)
            let size = motion.menuSize ?? mediaFrame.size
            let frame = motion.menuSize == nil ? mediaFrame : CGRect(
                x: min(max(8, motion.source.minX), max(8, proxy.size.width - size.width - 8)),
                y: min(max(proxy.safeAreaInsets.top + 8, motion.source.maxY - size.height * (motion.keyboardVisible ? 0.5 : 1)), max(8, proxy.size.height - size.height - 8)),
                width: size.width, height: size.height)
            let reduced = UIAccessibility.isReduceMotionEnabled
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                Group {
                    if motion.menuSize != nil { ScrollView { content.fixedSize(horizontal: false, vertical: true) }.scrollBounceBehavior(.basedOnSize) }
                    else { content }
                }
                    .disabled(!motion.interactive)
                    .frame(width: frame.width, height: frame.height)
                    .background {
                        if motion.menuSize != nil {
                            if #available(iOS 26.0, *) {
                                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: AIMDesign.universalPanelRadius))
                            } else {
                                Rectangle().fill(.regularMaterial)
                            }
                        } else { Rectangle().fill(.ultraThinMaterial) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AIMDesign.universalPanelRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AIMDesign.universalPanelRadius, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.20), radius: 28, y: 10)
                    .contentShape(RoundedRectangle(cornerRadius: AIMDesign.universalPanelRadius, style: .continuous))
                    .position(x: frame.midX, y: frame.midY)
                    .scaleEffect(motion.expanded || reduced ? 1 : max(0.05, motion.source.width / frame.width), anchor: UnitPoint(x: frame.midX / max(1, proxy.size.width), y: frame.midY / max(1, proxy.size.height)))
                    .offset(x: motion.expanded || reduced ? 0 : motion.source.midX - frame.midX,
                            y: motion.expanded || reduced ? 0 : motion.source.midY - frame.midY)
                    .opacity(motion.expanded ? 1 : 0)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(motion.menuSize == nil ? "composer-media-overlay" : "composer-plus-overlay")
            }
        }
        .ignoresSafeArea()
    }
}

private struct AIMComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let enabled: Bool

    private let minimumHeight: CGFloat = 34
    private let maximumMeasuredHeight: CGFloat = 196

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> EditorView {
        let view = EditorView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.returnKeyType = .default
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "composer-native-text-view"
        return view
    }

    func updateUIView(_ view: EditorView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: min(selection.length, max(0, (text as NSString).length - min(selection.location, (text as NSString).length))))
            view.textRevision += 1
            view.invalidateIntrinsicContentSize()
        }
        view.isEditable = enabled
        view.requestedFocus = focused
        view.reconcileFocus()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: EditorView,
        context: Context
    ) -> CGSize? {
        guard let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 else { return nil }
        let key = "\(proposedWidth):\(uiView.textRevision):\(uiView.font?.fontName ?? ""):\(uiView.font?.pointSize ?? 0)"
        if uiView.measurementKey == key { return uiView.measuredSize }
        let fitted = uiView.sizeThatFits(CGSize(width: proposedWidth, height: .greatestFiniteMagnitude))
        let height = min(maximumMeasuredHeight, max(minimumHeight, ceil(fitted.height)))
        let size = CGSize(width: proposedWidth, height: height)
        uiView.measurementKey = key; uiView.measuredSize = size
        AIMComposerTrace.geometry("editor revision=\(uiView.textRevision) width=\(proposedWidth) height=\(height) selection=\(uiView.selectedRange.location):\(uiView.selectedRange.length)")
        return size
    }

    final class EditorView: UITextView {
        var textRevision = 0
        var measurementKey = ""
        var measuredSize = CGSize.zero
        var requestedFocus = false
        private var focusUpdateScheduled = false
        override func didMoveToWindow() { super.didMoveToWindow(); reconcileFocus() }
        override func layoutSubviews() { super.layoutSubviews(); reconcileFocus() }
        func reconcileFocus() {
            guard requestedFocus != isFirstResponder, !focusUpdateScheduled,
                  window?.windowScene?.activationState == .foregroundActive else { return }
            focusUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusUpdateScheduled = false
                guard self.window?.windowScene?.activationState == .foregroundActive else { return }
                if self.requestedFocus { self.becomeFirstResponder() }
                else { self.resignFirstResponder() }
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AIMComposerTextEditor

        init(parent: AIMComposerTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? EditorView)?.textRevision += 1
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            (textView as? EditorView)?.requestedFocus = true
            publishFocus(true, textView: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            (textView as? EditorView)?.requestedFocus = false
            // UIKit calls this synchronously while SwiftUI may be removing the
            // representable during navigation. Publishing on the next turn
            // avoids mutating SwiftUI state from that hierarchy update.
            publishFocus(false, textView: textView)
        }

        private func publishFocus(_ next: Bool, textView: UITextView) {
            guard parent.focused != next else { return }
            DispatchQueue.main.async { [weak textView] in
                // Ignore an older end-editing callback after focus was already
                // restored by a new gesture or transient panel dismissal.
                guard textView?.isFirstResponder == next, self.parent.focused != next else { return }
                self.parent.focused = next
            }
        }
    }
}

@MainActor
final class AIMAttachmentPreviewCache {
    static let shared = AIMAttachmentPreviewCache()
    private let images = NSCache<NSString, UIImage>()

    func image(for transferID: String) -> UIImage? {
        images.object(forKey: transferID as NSString)
    }

    func store(data: Data, for transferID: String) {
        guard let image = UIImage(data: data) else { return }
        images.setObject(image, forKey: transferID as NSString)
    }
}

struct AIMConversationComposer: View {
    @State private var videoChoiceName: String?
    @State private var videoChoiceContinuation: CheckedContinuation<VideoPreparationOptions?, Never>?
    @Binding var text: String
    @Binding var attachments: [RemoteAttachmentReference]
    let modelName: String
    let modelID: String
    let capabilities: RemoteCapabilities?
    let mode: RemoteMode
    let approvalMode: String?
    let attachmentsEnabled: Bool
    let enabled: Bool
    let sendEnabled: Bool
    let loading: Bool
    let sessionRunning: Bool
    var expandedAtRest = false
    var accessibilityPrefix = "conversation"
    var focusRequest = 0
    var openModelPicker: (() -> Void)? = nil
    let safeBottom: CGFloat
    let openPersonalization: () -> Void
    let send: (String, [RemoteAttachmentReference]) async -> Bool
    let uploadAttachment: (Data, String, String, VideoPreparationOptions) async -> RemoteAttachmentReference?
    let changeModel: (String, String?) async -> Bool
    let changeApprovalMode: (String) async -> Bool
    let sendGoal: (String, Int, [RemoteAttachmentReference]) async -> Bool
    let stop: () async -> Bool
    var setModelAdded: ((RemoteModelAnnouncement, Bool) async -> Bool)? = nil
    var changeModelSelection: ((RemoteModelAnnouncement, String?) async -> Bool)? = nil
    var modelProvider: String? = nil
    var remoteStore: MainExperienceStore? = nil
    var agentID: String? = nil
    var attachmentPreviewData: ((String) -> Data?)? = nil
    var openAttachment: ((String) -> Void)? = nil
    @State private var previewAttachment: RemoteAttachmentReference?

    @Environment(\.aimSidebarPresented) private var sidebarPresented
    @Environment(\.aimKeyboardOverlap) private var keyboardOverlap
    @Environment(\.aimComposerDocked) private var keyboardDocked
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .subheadline) private var modelLineHeight: CGFloat = 18
    @State private var showingFileImporter = false
    @State private var showingSystemPhotoPicker = false
    @State private var systemPhotoItems: [PhotosPickerItem] = []
    @State private var uploadingFiles = false
    @State private var attachmentError: LocalizedStringKey?
    @State private var preparingAttachment: String?
    @State private var failedAttachments: [String] = []
    @State private var showingGoal = false
    @State private var showingModels = false
    @State private var showingEffort = false
    @State private var showingContext = false
    @State private var mediaPanel: AIMComposerMediaPanel?
    @State private var speech = AIMSpeechTranscriber()
    @State private var interaction = AIMComposerInteractionState()
    @State private var mediaOverlayPresenter = AIMMediaOverlayPresenter()
    @State private var plusAnchor = AIMComposerAnchor()
    @State private var effortAnchor = AIMComposerAnchor()
    @State private var effortPresenter = AIMMediaOverlayPresenter()
    @State private var plusPulse = false

    private var focused: Bool {
        get { interaction.focused }
        nonmutating set { interaction.focused = newValue }
    }
    private var forceExpanded: Bool {
        get { interaction.expanding }
        nonmutating set { interaction.expanding = newValue }
    }
    private var showingPlusMenu: Bool {
        get { interaction.menuPresented }
        nonmutating set { interaction.menuPresented = newValue }
    }
    private var focusBeforeTransientPresentation: Bool {
        get { interaction.restoreFocusAfterPresentation }
        nonmutating set { interaction.restoreFocusAfterPresentation = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if presentation == .expanded {
                if let attachmentError {
                    Text(attachmentError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let speechError = speech.errorMessage {
                    Text(speechError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            expandedComposer

        }
        .padding(presentation == .compact ? 6 : 8)
        .aimComposerBackground()
        .background {
            AIMComposerDismissSwipe { if focused { dismissKeyboardCompletely() } }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityPrefix)-composer")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, presentation == .compact ? 28 : 16)
        // Participate in layout: welcome content and measured conversation
        // insets must end at the visible composer, not its pre-keyboard position.
        .padding(.bottom, composerBottomInset)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: presentation)
        .aimBlocksBackgroundInteractions(showingModels || showingGoal || showingContext || showingFileImporter || showingSystemPhotoPicker || showingPlusMenu || showingEffort || mediaPanel != nil)
        .onChange(of: focused) { _, _ in forceExpanded = false }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            guard focused, !showingPlusMenu, mediaPanel == nil,
                  !showingFileImporter, !showingSystemPhotoPicker else { return }
            // A system/interactive dismissal can hide the keyboard without an
            // end-editing callback. Collapse empty content in the same movement.
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
            withAnimation(reduceMotion ? nil : .easeOut(duration: duration)) {
                forceExpanded = false
                focused = false
            }
        }
        .sheet(isPresented: Binding(get: { videoChoiceName != nil }, set: { if !$0 { finishVideoChoice(nil) } })) {
            AIMVideoPreparationChoice(name: videoChoiceName ?? "Video", choose: finishVideoChoice)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            restoreComposerFocusIfNeeded()
            guard case let .success(urls) = result else { return }
            importFiles(Array(urls.prefix(RemoteAttachmentRules.maximumCount - attachments.count)))
        }
        .photosPicker(
            isPresented: $showingSystemPhotoPicker,
            selection: $systemPhotoItems,
            maxSelectionCount: max(1, RemoteAttachmentRules.maximumCount - attachments.count),
            matching: .any(of: [.images, .videos])
        )
        .sheet(isPresented: Binding(get: { previewAttachment != nil }, set: { if !$0 { previewAttachment = nil } })) {
            if let attachment = previewAttachment {
                if let input = remoteStore?.preparedRemoteInput(attachment.transferID) {
                    AIMNativeInputPreview(input: input, original: remoteStore?.originalRemoteInput(input))
                } else { NavigationStack {
                ScrollView {
                    if let image = AIMAttachmentPreviewCache.shared.image(for: attachment.transferID) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else { Text("Preview unavailable on this device.").foregroundStyle(.secondary) }
                    Text(attachment.name).font(.caption)
                }.navigationTitle("Preview").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Close") { previewAttachment = nil } }
            }
            }
            }
        }
        .sheet(isPresented: $showingGoal) {
            AIMGoalSheet(supportsContinuity: RemoteContinuityRules.supported(capabilities: capabilities, allowingExperimental: UserDefaults.standard.bool(forKey: "AIMExperimentalContinuityEnabled"))) { goal, maximumTurns in
                let succeeded = await sendGoal(goal, maximumTurns, attachments)
                if succeeded { attachments = [] }
                return succeeded
            }
        }
        .sheet(isPresented: $showingModels) {
            AIMModelSelectionSheet(models: models, selectedID: modelID, selectedProvider: modelProvider, toggleAdded: setModelAdded, remoteStore: remoteStore) { model in
                Task {
                    let announcedEffort = model.effortLevels?.contains(model.currentEffort ?? "") == true
                        ? model.currentEffort
                        : nil
                    let changed: Bool
                    if let changeModelSelection { changed = await changeModelSelection(model, announcedEffort) }
                    else { changed = await changeModel(model.id, announcedEffort) }
                    if changed {
                        showingModels = false
                    }
                }
            }
        }
        .sheet(isPresented: $showingContext) {
            AIMSessionContextSheet(
                mode: mode,
                modelName: displayedModelName,
                approvalMode: approvalMode,
                capabilities: capabilities
            )
        }
        .onChange(of: speech.transcript) { _, transcript in
            guard !transcript.isEmpty else { return }
            text = transcript
        }
        .onChange(of: systemPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            importSystemPhotos(items)
        }
        .onChange(of: showingSystemPhotoPicker) { wasPresented, isPresented in
            guard wasPresented, !isPresented, systemPhotoItems.isEmpty else { return }
            restoreComposerFocusIfNeeded()
        }
        .task(id: focusRequest) {
            guard focusRequest > 0, enabled else { return }
            guard !Task.isCancelled, enabled else { return }
            expandAndFocusComposer()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 14, coordinateSpace: .global)
                .onChanged { value in
                    // The composer moves as the keyboard retracts. Global coordinates and
                    // dismissal at the threshold keep that movement from cancelling the swipe.
                    guard focused,
                          value.translation.height > 42,
                          abs(value.translation.height) > abs(value.translation.width) * 1.25
                    else { return }
                    dismissKeyboardCompletely()
                }
        )
        .onChange(of: sidebarPresented) { _, isPresented in
            guard isPresented else { return }
            showingEffort = false
            showingPlusMenu = false
            mediaPanel = nil
        }
        .onChange(of: showingPlusMenu) { _, showing in
            if showing, !sidebarPresented {
                showingEffort = false
                mediaOverlayPresenter.present(content: AnyView(plusMenu.preferredColorScheme(colorScheme)), anchor: plusAnchor, menu: true) {
                    showingPlusMenu = false
                    restoreComposerFocusIfNeeded()
                    pulsePlusButton()
                }
            } else if mediaPanel == nil {
                mediaOverlayPresenter.dismiss { pulsePlusButton() }
            }
        }
        .onChange(of: mediaPanel) { _, panel in
            if panel == nil || sidebarPresented {
                mediaOverlayPresenter.dismiss()
            } else {
                presentMediaPanel()
            }
        }
        .onChange(of: showingEffort) { _, showing in
            if showing, !sidebarPresented {
                showingPlusMenu = false
                effortPresenter.present(content: AnyView(AIMEffortPopover(
                    modelName: displayedModelName, presentation: effort,
                    openModels: { showingEffort = false; if let openModelPicker { openModelPicker() } else { showingModels = true } },
                    select: { value in Task { _ = await changeModel(modelID, value) } }
                ).environment(\.colorScheme, colorScheme)), anchor: effortAnchor, menu: true, width: 332) {
                    showingEffort = false
                }
            } else { effortPresenter.dismiss() }
        }
        .onDisappear {
            videoChoiceContinuation?.resume(returning: nil)
            videoChoiceContinuation = nil
            mediaOverlayPresenter.dismiss()
            effortPresenter.dismiss()
            // Navigation can remove the composer while SwiftUI is still
            // committing the destination hierarchy. Defer the observable
            // speech-state mutation until that update has completed.
            let transcriber = speech
            DispatchQueue.main.async {
                transcriber.stop()
            }
        }
    }

    private var expandedComposer: some View {
        VStack(alignment: .leading, spacing: presentation == .compact ? 0 : 5) {
            VStack(alignment: .leading, spacing: 8) {
                attachmentPreview
                if let preparingAttachment {
                    HStack { ProgressView().controlSize(.small); Text(preparingAttachment).lineLimit(1) }.font(.caption)
                }
                ForEach(Array(failedAttachments.enumerated()), id: \.offset) { index, name in
                    HStack {
                        Label(name + " — import failed", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                        Spacer(minLength: 0)
                        Button { failedAttachments.remove(at: index) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    }
                }
                messageField
            }
            .frame(height: presentation == .compact ? 0 : nil)
            .opacity(presentation == .compact ? 0 : 1)
            .clipped()
            .allowsHitTesting(presentation == .expanded)
            .accessibilityHidden(presentation == .compact)

            AIMComposerControlsLayout(
                expanded: presentation == .expanded,
                hasPermission: mode != .chat && presentation == .expanded,
                largeType: dynamicTypeSize.isAccessibilitySize,
                preferredModelWidth: modelControlWidth,
                modelRowHeight: max(44, modelLineHeight + 16)
            ) {
                // One button and one anchor survive compact/expanded changes.
                plusButton
                if mode != .chat && presentation == .expanded { permissionControl }
                ZStack {
                    modelEffortControl
                        .opacity(presentation == .expanded ? 1 : 0)
                        .allowsHitTesting(presentation == .expanded)
                        .accessibilityHidden(presentation == .compact)
                    if presentation == .compact {
                        Button(action: expandAndFocusComposer) {
                            Text(text.isEmpty ? String(localized: "remote.chat.placeholder") : text)
                                .font(.body)
                                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: AIMDesign.standardTouchTarget, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(accessibilityPrefix)-message-field-launcher")
                    }
                }
                microphoneButton
                sendButton
            }
        }
    }

    private var presentation: AIMConversationComposerPresentation {
        if expandedAtRest || forceExpanded { return .expanded }
        return .state(
            focused: focused,
            text: text,
            hasAttachments: !attachments.isEmpty,
            hasActiveSecondaryState: showingModels
                || showingEffort
                || showingContext
                || showingGoal
                || speech.isRecording
        )
    }

    @ViewBuilder
    private var messageField: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("remote.chat.placeholder")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
            AIMComposerTextEditor(
                text: $text,
                focused: Binding(get: { focused }, set: { focused = $0 }),
                enabled: enabled && !loading
            )
            .accessibilityIdentifier("\(accessibilityPrefix)-message-field")
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.element.transferID) { index, attachment in
                    ZStack(alignment: .topTrailing) {
                        Button {
                            if let openAttachment { openAttachment(attachment.transferID) }
                            else { previewAttachment = attachment }
                        } label: { attachmentTile(attachment) }
                        .buttonStyle(.plain).accessibilityLabel("Preview " + attachment.name)
                        Button { attachments.removeAll { $0.transferID == attachment.transferID } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 25, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.62))
                                .frame(width: 52, height: 52)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .zIndex(1)
                        .accessibilityLabel(Text("remote.attachments.remove"))
                        .accessibilityIdentifier("\(accessibilityPrefix)-attachment-remove-\(index)")
                        .padding(3)
                    }
                    .frame(width: 112, height: 112)
                }
            }
            }
            .scrollIndicators(.hidden)
            .frame(height: 112)
            .accessibilityIdentifier("\(accessibilityPrefix)-attachment-strip")
        }
    }

    @ViewBuilder
    private func attachmentTile(_ attachment: RemoteAttachmentReference) -> some View {
        if let image = AIMAttachmentPreviewCache.shared.image(for: attachment.transferID) ?? attachmentPreviewData?(attachment.transferID).flatMap({ UIImage(data: $0) })
        {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 112, height: 112)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            HStack(spacing: 7) {
                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                Text(attachment.name).lineLimit(2)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.10)) }
        }
    }

    private var plusButton: some View {
        Button {
            AIMHaptics.selection()
            focusBeforeTransientPresentation = focused
            showingPlusMenu.toggle()
        } label: {
            Group {
                if uploadingFiles { ProgressView().controlSize(.small) }
                else { Image(systemName: "plus").font(.system(size: 20)) }
            }
            .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
            .background(Color(uiColor: .systemBackground), in: Circle())
            .overlay { Circle().stroke(Color.primary.opacity(0.12)) }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(.primary)
        .disabled(uploadingFiles)
        .accessibilityLabel(Text("remote.plus.menu"))
        .accessibilityIdentifier("\(accessibilityPrefix)-attachment-button")
        .background(AIMComposerAnchorProbe(anchor: plusAnchor).allowsHitTesting(false))
        .scaleEffect(plusPulse ? 0.90 : 1)
    }

    private var permissionButton: some View {
        Menu {
            ForEach(RemotePermissionRules.options(for: mode), id: \.id) { permission in
                Button {
                    Task { _ = await changeApprovalMode(permission.id) }
                } label: {
                    if approvalMode == permission.id {
                        Label(LocalizedStringKey(permission.labelKey), systemImage: "checkmark")
                    } else {
                        Text(LocalizedStringKey(permission.labelKey))
                    }
                }
                .disabled(!enabled)
            }
        } label: {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 19, weight: .medium))
                .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                .background(Color(uiColor: .systemBackground), in: Circle())
                .overlay { Circle().stroke(Color.primary.opacity(0.12)) }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(.primary)
        .accessibilityLabel(Text("remote.new.permissions"))
        .accessibilityIdentifier("\(accessibilityPrefix)-permission-button")
    }

    @ViewBuilder
    private var permissionControl: some View {
        if mode == .chat {
            Color.clear
                .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                .accessibilityHidden(true)
        } else {
            permissionButton
        }
    }

    private var modelEffortControl: some View {
        HStack(spacing: 0) {
            Button { if let openModelPicker { openModelPicker() } else { showingModels = true } } label: {
                GeometryReader { available in
                    Text(displayedModelName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, 14)
                        .padding(.trailing, effort.options.isEmpty ? 14 : 7)
                        .frame(width: available.size.width, height: available.size.height, alignment: .leading)
                        .clipped()
                        .mask {
                            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.76), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                        }
                }
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: max(44, modelLineHeight + 16))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.primary)
            .accessibilityLabel(displayedModelName)
            .accessibilityIdentifier("\(accessibilityPrefix)-model-button")

            if !effort.options.isEmpty {
                Button { showingEffort.toggle() } label: {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: AIMDesign.standardTouchTarget)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.primary)
                .accessibilityLabel(Text("remote.new.effort"))
                .accessibilityIdentifier("\(accessibilityPrefix)-effort-button")
                .background(AIMComposerAnchorProbe(anchor: effortAnchor).allowsHitTesting(false))
            }
        }
        .layoutPriority(1)
        .background(Color(uiColor: .systemBackground), in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.12)) }
    }

    private var microphoneButton: some View {
        Button { speech.toggle() } label: {
            Image(systemName: speech.isRecording ? "waveform" : "mic")
                .font(.system(size: 20))
                .foregroundStyle(speech.isRecording ? Color.red : Color.primary)
                .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                .background(Color(uiColor: .systemBackground), in: Circle())
                .overlay { Circle().stroke(Color.primary.opacity(0.12)) }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled || loading)
        .accessibilityLabel(Text(speech.isRecording ? "speech.stop" : "remote.composer.microphone"))
    }

    private var sendButton: some View {
        Button {
            AIMHaptics.impact()
            if sessionRunning {
                Task {
                    // Let the button transaction finish before the observable
                    // store publishes its sending/navigation state.
                    await Task.yield()
                    _ = await stop()
                }
            } else {
                let outgoing = text
                Task {
                    // `send` immediately mutates the observable store. Starting
                    // it in the button's update transaction triggers SwiftUI's
                    // "Modifying state during view update" diagnostic.
                    await Task.yield()
                    if await send(outgoing, attachments) {
                        // Creating the first chat also swaps the destination.
                        // Let that hierarchy update finish before clearing the
                        // binding owned by the outgoing composer.
                        try? await Task.sleep(for: .milliseconds(10))
                        text = ""
                        attachments = []
                    }
                }
            }
        } label: {
            Group {
                if sessionRunning { Image(systemName: "stop.fill") }
                else if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "paperplane") }
            }
            .font(.system(size: 20, weight: .medium))
            .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
            .background(Color.primary.opacity(canSend ? 1 : 0.09), in: Circle())
            .foregroundStyle(canSend ? Color(uiColor: .systemBackground) : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
        .disabled(!canSend)
        .accessibilityIdentifier("\(accessibilityPrefix)-send-button")
        .accessibilityLabel(sessionRunning ? String(localized: "Stop response") : String(localized: "Send message"))
    }

    private struct PlusAction: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let icon: String
        var enabled = true
        var reason: LocalizedStringKey? = nil
    }

    /// All modes use the same action projection. Capabilities disable actions with an explanation.
    private var imagesEnabled: Bool {
        attachmentsEnabled && RemoteEngineRules.supportsImageAttachments(agentID: agentID, capabilities: capabilities)
    }

    private var plusActions: [PlusAction] {
        var actions: [PlusAction] = []
        if mode != .chat {
            actions.append(.init(id: "plan", title: approvalMode == "plan" ? "remote.plan.disable" : "remote.plan.enable", icon: "list.bullet.clipboard"))
            let goals = (agentID == nil || agentID == "aim") && (capabilities?.features["goal"] == true || RemoteContinuityRules.supported(capabilities: capabilities, allowingExperimental: UserDefaults.standard.bool(forKey: "AIMExperimentalContinuityEnabled")))
            actions.append(.init(id: "goal", title: "remote.goal.title", icon: "target", enabled: goals))
        }
        let reason: LocalizedStringKey? = attachmentsEnabled ? nil : "Attachments require a compatible connected Mac."
        let imageReason: LocalizedStringKey? = reason ?? (imagesEnabled ? nil : "This agent’s current Mac bridge cannot send images to the model. Files remain available.")
        actions += [
            .init(id: "files", title: "remote.attachments.files", icon: "paperclip", enabled: attachmentsEnabled, reason: reason),
            .init(id: "photos", title: "remote.attachments.photos", icon: "photo.on.rectangle", enabled: imagesEnabled, reason: imageReason),
            .init(id: "camera", title: "remote.attachments.camera", icon: "camera", enabled: imagesEnabled && cameraIsAvailable, reason: imageReason ?? (cameraIsAvailable ? nil : "The camera is unavailable on this device.")),
            .init(id: "connectors", title: "remote.plus.connectors", icon: "square.grid.2x2"),
            .init(id: "context", title: "remote.plus.context", icon: "sparkles")
        ]
        return actions
    }

    private var plusMenu: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(plusActions) { action in
                    plusMenuButton(action.title, icon: action.icon) { performPlusAction(action.id) }.disabled(!action.enabled)
                    if let reason = action.reason { Text(reason).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 6) }
                }
            }.padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity)
        .frame(height: min(CGFloat(plusActions.count) * 56 + 12 + CGFloat(plusActions.filter { $0.reason != nil }.count) * 60,
                           max(280, UIScreen.main.bounds.height - 180)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-plus-menu")
    }

    private func performPlusAction(_ action: String) {
        switch action {
        case "plan":
            showingPlusMenu = false
            let next = approvalMode == "plan" ? RemotePermissionRules.modeAfterPlan(mode: mode, remembered: nil) : "plan"
            Task { _ = await changeApprovalMode(next) }
        case "goal": showingPlusMenu = false; showingGoal = true
        case "files": openFileImporter()
        case "photos": openMediaPanel(.photos)
        case "camera": openMediaPanel(.camera)
        case "connectors": showingPlusMenu = false; openPersonalization()
        case "context": showingPlusMenu = false; showingContext = true
        default: break
        }
    }

    private func plusMenuButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            plusMenuLabel(title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func plusMenuLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: 42)
                .background(Color.primary.opacity(0.065), in: Circle())
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 7)
        .frame(minHeight: 54)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func expandAndFocusComposer() {
        guard !forceExpanded else { return }
        AIMHaptics.selection()
        forceExpanded = true
        // The editor remains mounted in both presentations. Its updateUIView
        // requests focus after the expanded layout has entered the hierarchy.
        focused = true
    }

    private func openFileImporter() {
        AIMHaptics.selection()
        showingPlusMenu = false
        mediaOverlayPresenter.dismiss {
            guard !sidebarPresented else { return }
            showingFileImporter = true
        }
    }

    private func openMediaPanel(_ panel: AIMComposerMediaPanel) {
        AIMHaptics.selection()
        guard !sidebarPresented else { return }
        // Replace the menu directly. Closing it first added a second animation
        // and temporarily expanded an otherwise empty, unfocused composer.
        mediaPanel = panel
        showingPlusMenu = false
    }

    private func pulsePlusButton() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        withAnimation(.easeOut(duration: 0.08)) { plusPulse = true } completion: {
            withAnimation(.spring(duration: 0.2, bounce: 0.2)) { plusPulse = false }
        }
    }

    private func presentMediaPanel() {
        guard let mediaPanel else {
            mediaOverlayPresenter.dismiss()
            return
        }
        let content: AnyView
        switch mediaPanel {
        case .photos:
            content = AnyView(
                AIMPhotoLibraryPanel(
                    maximumSelectionCount: max(1, RemoteAttachmentRules.maximumCount - attachments.count),
                    openAllPhotos: {
                        self.mediaPanel = nil
                        mediaOverlayPresenter.dismiss {
                            guard !sidebarPresented else { return }
                            showingSystemPhotoPicker = true
                        }
                    },
                    completion: { selections in
                        self.mediaPanel = nil
                        if !selections.isEmpty { importSelectedPhotos(selections) }
                        restoreComposerFocusIfNeeded()
                    }
                )
            )
        case .camera:
            content = AnyView(
                AIMCameraPanel { data in
                    self.mediaPanel = nil
                    if let data { upload(data: data, name: "photo.jpg", mimeType: "image/jpeg") }
                    restoreComposerFocusIfNeeded()
                }
            )
        }
        mediaOverlayPresenter.present(content: AnyView(content.preferredColorScheme(colorScheme)), anchor: plusAnchor) {
            self.mediaPanel = nil
            restoreComposerFocusIfNeeded()
            pulsePlusButton()
        }
    }

    private func restoreComposerFocusIfNeeded() {
        guard focusBeforeTransientPresentation, !sidebarPresented else { return }
        focused = true
    }

    @MainActor
    private func dismissKeyboardCompletely() {
        forceExpanded = false
        focused = false
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

    private var composerBottomInset: CGFloat {
        keyboardDocked ? 0 : (keyboardOverlap > 0 ? keyboardOverlap + 4 : safeBottom + 8)
    }

    private var cameraIsAvailable: Bool {
        ProcessInfo.processInfo.environment["AIM_UI_TEST_FAKE_CAMERA"] == "1"
            || UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private var canSend: Bool {
        sessionRunning || (!loading && !uploadingFiles && sendEnabled && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty))
    }

    private var models: [RemoteModelAnnouncement] {
        let announced = capabilities?.models ?? []
        return announced.isEmpty
            ? [.init(id: modelID, name: modelName, provider: "")]
            : announced
    }

    private var displayedModelName: String {
        models.first(where: { $0.id == modelID && (modelProvider == nil || $0.provider == modelProvider) })?.name ?? modelName
    }

    private var effort: RemoteEffortPresentation {
        RemoteEffortRules.effort(capabilities: capabilities, modelID: modelID, provider: modelProvider)
    }

    private var intrinsicModelControlWidth: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let measured = (displayedModelName as NSString).size(withAttributes: [.font: font]).width
        return max(82, ceil(measured) + 30)
    }

    private var modelControlWidth: CGFloat {
        min(230, intrinsicModelControlWidth + (effort.options.isEmpty ? 0 : 44))
    }

    private func importFiles(_ urls: [URL]) {
        attachmentError = nil
        uploadingFiles = true
        Task {
            for url in urls {
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) { () -> (Data, String, String) in
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey, .contentTypeKey])
                        let size = values.fileSize ?? 0
                        let name = values.name ?? url.lastPathComponent
                        let mime = values.contentType?.preferredMIMEType ?? "application/octet-stream"
                        let candidate = RemoteAttachmentCandidate(name: name, size: size, mimeType: mime)
                        guard (["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) && size > 0 && size <= 250_000_000) || RemoteAttachmentRules.sort(existingCount: 0, candidates: [candidate]).accepted.count == 1 else {
                            throw RemoteServiceError.commandRejected("attachment_invalid")
                        }
                        return (try Data(contentsOf: url, options: .mappedIfSafe), name, mime)
                    }.value
                    await uploadData(loaded.0, name: loaded.1, mimeType: loaded.2)
                } catch {
                    attachmentError = "remote.attachments.invalid"
                    failedAttachments.append(url.lastPathComponent)
                }
            }
            uploadingFiles = false
        }
    }

    private func importSelectedPhotos(_ items: [AIMSelectedPhoto]) {
        attachmentError = nil
        guard !items.isEmpty else { return }
        uploadingFiles = true
        Task {
            for item in items.prefix(RemoteAttachmentRules.maximumCount - attachments.count) {
                await uploadData(item.data, name: item.name, mimeType: item.mimeType)
            }
            uploadingFiles = false
        }
    }

    private func importSystemPhotos(_ items: [PhotosPickerItem]) {
        let remaining = max(0, RemoteAttachmentRules.maximumCount - attachments.count)
        let pendingItems = Array(items.prefix(remaining))
        systemPhotoItems = []
        guard !pendingItems.isEmpty else {
            restoreComposerFocusIfNeeded()
            return
        }

        attachmentError = nil
        uploadingFiles = true
        Task {
            for (index, item) in pendingItems.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    attachmentError = "remote.attachments.failed"
                    continue
                }
                let contentType = item.supportedContentTypes.first ?? .jpeg
                let mimeType = contentType.preferredMIMEType ?? "image/jpeg"
                let fileExtension = contentType.preferredFilenameExtension ?? "jpg"
                await uploadData(data, name: "photo-\(index + 1).\(fileExtension)", mimeType: mimeType)
            }
            uploadingFiles = false
            restoreComposerFocusIfNeeded()
        }
    }

    private func upload(data: Data, name: String, mimeType: String) {
        uploadingFiles = true
        Task {
            await uploadData(data, name: name, mimeType: mimeType)
            uploadingFiles = false
        }
    }

    private func finishVideoChoice(_ options: VideoPreparationOptions?) {
        let continuation = videoChoiceContinuation; videoChoiceContinuation = nil; videoChoiceName = nil; continuation?.resume(returning: options)
    }
    private func uploadData(_ data: Data, name: String, mimeType: String) async {
        preparingAttachment = name
        defer { preparingAttachment = nil }
        if (mimeType.lowercased().hasPrefix("video/") || mimeType.lowercased().hasPrefix("image/") || ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif"].contains((name as NSString).pathExtension.lowercased())), !imagesEnabled {
            attachmentError = "This agent’s current Mac bridge cannot send images to the model. Your draft was kept."
            failedAttachments.append(name)
            return
        }
        let candidate = RemoteAttachmentCandidate(name: name, size: data.count, mimeType: mimeType)
        guard (["mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased()) && !data.isEmpty && data.count <= 250_000_000 && attachments.count < 4) || RemoteAttachmentRules.sort(existingCount: attachments.count, candidates: [candidate]).accepted.count == 1 else {
            attachmentError = "remote.attachments.invalid"
            failedAttachments.append(name)
            return
        }
        var options = VideoPreparationOptions()
        if ["mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased()) {
            guard let selected = await withCheckedContinuation({ continuation in videoChoiceContinuation = continuation; videoChoiceName = name }) else { return }
            options = selected
        }
        if let uploaded = await uploadAttachment(data, name, mimeType, options) {
            if mimeType.hasPrefix("image/") {
                AIMAttachmentPreviewCache.shared.store(data: data, for: uploaded.transferID)
            }
            if !attachments.contains(where: { $0.transferID == uploaded.transferID }) { attachments.append(uploaded) }
        } else {
            attachmentError = "remote.attachments.failed"
            failedAttachments.append(name)
        }
    }
}

private struct AIMSessionContextSheet: View {
    let mode: RemoteMode
    let modelName: String
    let approvalMode: String?
    let capabilities: RemoteCapabilities?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    row(copy("Mode", "Mode"), value: mode.rawValue.capitalized, icon: "rectangle.3.group")
                    Divider().padding(.leading, 56)
                    row(copy("Model", "Modèle"), value: modelName, icon: "sparkles")
                    if mode != .chat {
                        Divider().padding(.leading, 56)
                        row(copy("Permissions", "Permissions"), value: approvalMode ?? "—", icon: "checkmark.shield")
                    }
                    Divider().padding(.leading, 56)
                    row(
                        copy("Context supported", "Contexte pris en charge"),
                        value: capabilities?.features["context"] == true ? copy("Yes", "Oui") : copy("No", "Non"),
                        icon: "memorychip"
                    )
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(18)

                Text(copy(
                    "The exact context window and token usage are supplied by the computer when available; this screen never estimates them.",
                    "La fenêtre de contexte exacte et le nombre de jetons sont fournis par l’ordinateur lorsqu’ils sont disponibles ; cet écran ne les estime jamais."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
            }
            .navigationTitle(Text("remote.plus.context"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .aimUniversalPanelSurface()
    }

    private func row(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            Text(title).fontWeight(.medium)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}

private struct AIMModelSelectionSheet: View {
    let models: [RemoteModelAnnouncement]
    let selectedID: String
    var selectedProvider: String? = nil
    var toggleAdded: ((RemoteModelAnnouncement, Bool) async -> Bool)? = nil
    var remoteStore: MainExperienceStore? = nil
    let select: (RemoteModelAnnouncement) -> Void

    var body: some View {
        let values = models.map { model in
            AIMModelPickerItem(modelID: model.id, name: model.name, provider: model.provider,
                               groupProvider: model.provider == ChatProvider.openRouter.rawValue && model.detail?.id.contains("/") == true ? model.detail?.provider : nil,
                               subtitle: model.via.map { "via \($0)" }, capabilities: model.capabilities.isEmpty ? model.detail?.capabilities.map(\.rawValue).sorted() ?? [] : model.capabilities,
                               isLocal: model.provider == "local" || model.via == "local",
                               isAdded: model.isAdded ?? true, isPinned: model.isPinned ?? false, isFeatured: model.isFeatured ?? false, available: model.isAvailable != false, unavailableReason: model.isAvailable == false ? "Connection or model unavailable on this Mac" : nil, detail: model.detail,
                               isReferencePricing: model.isReferencePricing == true)

        }
        let groups = Dictionary(grouping: values) { CanonicalModelRouting.identity($0.modelID, provider: $0.provider) }
        let items = groups.map { canonical, values in
            let preferred = remoteStore?.preferredModelRoute(canonical)
            let routes = values.sorted {
                if ($0.provider == preferred) != ($1.provider == preferred) { return $0.provider == preferred }
                if $0.available != $1.available { return $0.available }
                let a = CanonicalModelRouting.rank($0.provider), b = CanonicalModelRouting.rank($1.provider)
                return a == b ? $0.provider < $1.provider : a < b
            }
            var item = routes[0]; item.routes = routes
            item.isAdded = values.contains(where: \.isAdded); item.isPinned = values.contains(where: \.isPinned)
            item.isFeatured = values.contains(where: \.isFeatured)
            if canonical.hasPrefix("black-forest-labs/") { item.groupProvider = "Black Forest Labs" }
            return item
        }
        return AIMUnifiedModelPicker(items: items, selectedKey: selectedKey,
           executionDeviceName: remoteStore?.selectedMachineDisplayName,
           refresh: remoteStore.map { store in { Task { await store.load() } } },
           remoteStore: remoteStore,
           toggleAdded: toggleAdded.map { action in { item in
               guard let model = models.first(where: { $0.id == item.modelID && $0.provider == item.provider }) else { return }
               Task { _ = await action(model, !item.isAdded) }
           } }) { item in
            if let model = models.first(where: { $0.id == item.modelID && $0.provider == item.provider }) { remoteStore?.rememberModelRoute(model); select(model) }
        }
    }

    private var selectedKey: String? {
        let matches = models.filter { $0.id == selectedID && (selectedProvider == nil || $0.provider == selectedProvider) }
        // Legacy sessions without a provider may have an ambiguous model id.
        // A checkmark must not imply that the first provider will execute it.
        guard matches.count == 1, let selected = matches.first else { return nil }
        return AIMModelPickerItem.key(provider: selected.provider, modelID: selected.id)
    }
}

private struct AIMEffortPopover: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var draggedIndex: Int?
    let modelName: String
    let presentation: RemoteEffortPresentation
    let openModels: () -> Void
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Button(action: openModels) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text(modelName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(currentLabel)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            GeometryReader { proxy in
                let count = max(1, presentation.options.count)
                let segmentWidth = (proxy.size.width - 20) / CGFloat(count)
                let selected = selectedIndex

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(uiColor: .systemBackground).opacity(0.62))

                    Capsule()
                        .fill(colorScheme == .dark ? Color.white : Color.black)
                        .frame(width: segmentWidth * CGFloat(selected + 1))

                    HStack(spacing: 0) {
                        ForEach(Array(presentation.options.enumerated()), id: \.element.value) { index, option in
                        Button {
                            draggedIndex = index
                            select(option.value)
                        } label: {
                            Circle()
                                .fill(index == selected ? Color(uiColor: .systemBackground) : dotColor(at: index))
                                .frame(width: index == selected ? 40 : 12, height: index == selected ? 40 : 12)
                                .overlay {
                                    if index == selected {
                                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                    }
                                }
                                .shadow(color: index == selected ? .black.opacity(0.16) : .clear, radius: 5, y: 2)
                                .frame(width: segmentWidth, height: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(option.label))
                        .accessibilityAddTraits(index == selected ? .isSelected : [])
                        }
                    }
                }
                .frame(height: 48)
                .padding(10)
                .background { Capsule().fill(.clear).aimGlassCapsule() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("effort-track")
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        draggedIndex = min(count - 1, max(0, Int((value.location.x - 10) / max(1, segmentWidth))))
                    }
                    .onEnded { _ in
                        if let index = draggedIndex, presentation.options.indices.contains(index) {
                            select(presentation.options[index].value)
                        }
                    })
            }
            .frame(height: 68)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effort-selector")
    }

    private var currentLabel: String {
        presentation.options.indices.contains(selectedIndex) ? presentation.options[selectedIndex].label : ""
    }

    private var selectedIndex: Int {
        draggedIndex ?? presentation.options.firstIndex(where: { $0.value == presentation.currentValue }) ?? 0
    }

    private func dotColor(at index: Int) -> Color {
        index < selectedIndex
            ? Color(uiColor: .systemBackground).opacity(0.20)
            : Color.secondary.opacity(0.36)
    }
}

private struct AIMContinuityPanel: View {
    @Environment(\.scenePhase) private var scenePhase
    let store: MainExperienceStore
    let sessionID: String
    @State private var correction = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Continuous objective", systemImage: "target").font(.headline)
                Spacer()
                Button { Task { _ = await store.refreshContinuousGoal() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isSending)
            }
            if let state = store.continuitySnapshots[sessionID] {
                Text(title(for: state.state)).font(.subheadline)
                if let reason = state.waitingReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if let cost = state.countedUSD { Text("Counted spend: $\(cost)").font(.caption) }
                if let unknown = state.unknownSpendAttempts, unknown > 0 {
                    Text("\(unknown) charges awaiting confirmation").font(.caption)
                }
                if let result = state.result, !result.isEmpty { Text(result).textSelection(.enabled) }
                HStack {
                    if ["paused", "waitingUser"].contains(state.state) {
                        Button("Resume") { Task { _ = await store.resumeContinuousGoal() } }
                    } else if !["cancelled", "accepted", "verified", "failed"].contains(state.state) {
                        Button("Pause") { Task { _ = await store.pauseContinuousGoal() } }
                    }
                    if state.state == "awaitingReview" {
                        Button("Validate result") { Task { _ = await store.acceptContinuousGoal() } }
                    }
                    if !["cancelled", "accepted", "verified", "failed"].contains(state.state) {
                        Button("Cancel", role: .destructive) { Task { _ = await store.cancelContinuousGoal() } }
                    }
                }.disabled(store.isSending)
                if !["cancelled", "accepted", "verified", "failed"].contains(state.state) {
                    TextField("Correction", text: $correction, axis: .vertical)
                    Button("Send correction") {
                        let text = correction
                        Task { if await store.correctContinuousGoal(text) { correction = "" } }
                    }.disabled(store.isSending || correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else { Text("Refresh to follow the objective on your Mac.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .task(id: "\(sessionID):\(scenePhase)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refreshContinuousGoalInBackground(sessionID: sessionID)
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func title(for state: String) -> String {
        switch state {
        case "queued": "Ready to continue"
        case "running": "Working on the objective"
        case "waitingEvent": "Waiting for an event"
        case "waitingNetwork": "Waiting for the network or provider"
        case "waitingUser": "Your response is needed"
        case "awaitingReview": "Result ready for your review"
        case "paused": "Paused"
        case "blocked": "Inspection needed before continuing"
        case "verified": "Objective criteria verified"
        case "accepted": "Result validated by you"
        case "failed": "Execution failed"
        case "cancelled": "Cancelled"
        default: "State unavailable"
        }
    }
}

private struct AIMGoalSheet: View {
    let submit: (String, Int) async -> Bool
    let supportsContinuity: Bool
    init(supportsContinuity: Bool = false, submit: @escaping (String, Int) async -> Bool) {
        self.supportsContinuity = supportsContinuity; self.submit = submit
    }
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var maximumTurns = 10
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("remote.goal.intro", systemImage: "target")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("remote.goal.placeholder", text: $text, axis: .vertical)
                    .lineLimit(4...8)
                    .padding(14)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
                Picker("remote.goal.turns", selection: $maximumTurns) {
                    if supportsContinuity { Text("Continuous").tag(0) }
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("20").tag(20)
                }
                .pickerStyle(.segmented)
                .onAppear { if supportsContinuity { maximumTurns = 0 } }
                Button {
                    sending = true
                    Task {
                        if await submit(text, maximumTurns) { dismiss() }
                        sending = false
                    }
                } label: {
                    Group {
                        if sending { ProgressView().tint(Color(uiColor: .systemBackground)) }
                        else { Text("remote.goal.start") }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.plain)
                .background(Color.primary, in: Capsule())
                .foregroundStyle(Color(uiColor: .systemBackground))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                Spacer()
            }
            .padding(18)
            .navigationTitle("remote.goal.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .aimUniversalPanelSurface()
    }
}

private struct AIMCameraPanel: View {
    let completion: (Data?) -> Void
    @Environment(\.locale) private var locale
    @State private var cameraPosition = AVCaptureDevice.Position.back
    @State private var flashMode = AVCaptureDevice.FlashMode.off
    @State private var captureRequest = 0
    @State private var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if isUITestCamera {
                    LinearGradient(
                        colors: [Color(red: 0.18, green: 0.24, blue: 0.30), Color(red: 0.52, green: 0.59, blue: 0.63)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 54, weight: .light))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                } else if authorizationStatus == .authorized, cameraIsAvailable {
                    AIMCameraPreview(
                        cameraPosition: $cameraPosition,
                        flashMode: flashMode,
                        captureRequest: captureRequest
                    ) { data in
                        completion(data)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                } else if authorizationStatus == .notDetermined {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                } else {
                    ContentUnavailableView(
                        copy("Camera unavailable", "Appareil photo indisponible"),
                        systemImage: "camera.slash",
                        description: Text(copy(
                            "Allow camera access in Settings to take a photo.",
                            "Autorisez l’accès à l’appareil photo dans Réglages pour prendre une photo."
                        ))
                    )
                    .foregroundStyle(.white)
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.04), .black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

                VStack {
                    Spacer()
                    cameraControls
                        .padding(.bottom, 24)
                }
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task {
            await requestCameraAuthorizationIfNeeded()
        }
    }

    private var cameraControls: some View {
        HStack {
            Button {
                AIMHaptics.selection()
                completion(nil)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(copy("Back", "Retour")))

            Spacer()

            Button {
                AIMHaptics.impact(.medium)
                if isUITestCamera {
                    completion(fakeCameraImageData())
                } else {
                    captureRequest += 1
                }
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 72, height: 72)
                    .overlay { Circle().stroke(.white.opacity(0.42), lineWidth: 8).padding(-7) }
                    .shadow(color: .black.opacity(0.25), radius: 7, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!isUITestCamera && !UIImagePickerController.isSourceTypeAvailable(.camera))
            .accessibilityLabel(Text(copy("Take photo", "Prendre une photo")))
            .accessibilityIdentifier("camera-capture-button")

            Spacer()

            Menu {
                Button {
                    AIMHaptics.impact()
                    cameraPosition = cameraPosition == .back ? .front : .back
                } label: {
                    Label(copy("Flip camera", "Retourner la caméra"), systemImage: "camera.rotate")
                }
                Button {
                    AIMHaptics.selection()
                    flashMode = flashMode == .off ? .on : .off
                } label: {
                    Label(
                        flashMode == .off
                            ? copy("Turn flash on", "Activer le flash")
                            : copy("Turn flash off", "Désactiver le flash"),
                        systemImage: flashMode == .off ? "bolt" : "bolt.slash"
                    )
                }
                .disabled(
                    cameraPosition == .front
                        || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition)?.hasFlash != true
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(copy("Camera options", "Options de l’appareil photo")))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
    }

    private var cameraIsAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition) != nil
    }

    private var isUITestCamera: Bool {
        ProcessInfo.processInfo.environment["AIM_UI_TEST_FAKE_CAMERA"] == "1"
    }

    private func requestCameraAuthorizationIfNeeded() async {
        guard !isUITestCamera else { return }
        guard authorizationStatus == .notDetermined else { return }
        let granted = await AIMMediaPermissionBridge.request { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) }
        authorizationStatus = granted ? .authorized : .denied
    }

    private func fakeCameraImageData() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
        return renderer.jpegData(withCompressionQuality: 0.88) { context in
            UIColor(red: 0.28, green: 0.38, blue: 0.46, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}

private struct AIMCameraPreview: UIViewControllerRepresentable {
    @Binding var cameraPosition: AVCaptureDevice.Position
    let flashMode: AVCaptureDevice.FlashMode
    let captureRequest: Int
    let completion: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> AIMCameraPreviewController {
        let controller = AIMCameraPreviewController()
        controller.previewLayer.session = context.coordinator.session
        context.coordinator.configure(position: cameraPosition)
        context.coordinator.start()
        return controller
    }

    func updateUIViewController(_ controller: AIMCameraPreviewController, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.position != cameraPosition {
            context.coordinator.configure(position: cameraPosition)
        }
        guard captureRequest != context.coordinator.lastCaptureRequest else { return }
        context.coordinator.lastCaptureRequest = captureRequest
        context.coordinator.capture(flashMode: flashMode)
    }

    static func dismantleUIViewController(_ controller: AIMCameraPreviewController, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        var parent: AIMCameraPreview
        let session = AVCaptureSession()
        private let photoOutput = AVCapturePhotoOutput()
        private var videoInput: AVCaptureDeviceInput?
        private let sessionQueue = DispatchQueue(label: "ai.aim.camera.capture", qos: .userInitiated)
        private(set) var position = AVCaptureDevice.Position.unspecified
        var lastCaptureRequest = 0
        private var captureInFlight = false // Confined to sessionQueue.

        init(parent: AIMCameraPreview) { self.parent = parent }

        func configure(position: AVCaptureDevice.Position) {
            self.position = position
            sessionQueue.async { self.configureSession(position: position) }
        }

        private func configureSession(position: AVCaptureDevice.Position) {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device)
            else { return }

            session.beginConfiguration()
            session.sessionPreset = .photo
            if let videoInput { session.removeInput(videoInput) }
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()
        }

        func start() {
            let session = session
            sessionQueue.async {
                guard !session.isRunning else { return }
                session.startRunning()
            }
        }

        func stop() {
            let session = session
            sessionQueue.async {
                guard session.isRunning else { return }
                session.stopRunning()
            }
        }

        func capture(flashMode: AVCaptureDevice.FlashMode) {
            // Configuration, start/stop and submission must never overlap.
            sessionQueue.async {
                guard !self.captureInFlight else { return }
                guard self.session.isRunning,
                      self.photoOutput.connection(with: .video)?.isActive == true else {
                    DispatchQueue.main.async { self.parent.completion(nil) }
                    return
                }
                self.captureInFlight = true
                let settings = AVCapturePhotoSettings()
                // AVFoundation throws an exception if this exceeds the maximum.
                settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
                settings.flashMode = self.photoOutput.supportedFlashModes.contains(flashMode) ? flashMode : .off
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }

        func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error: Error?
        ) {
            let data = error == nil ? photo.fileDataRepresentation() : nil
            sessionQueue.async {
                self.captureInFlight = false
                guard self.session.isRunning else { return }
                DispatchQueue.main.async { self.parent.completion(data) }
            }
        }
    }
}

private final class AIMCameraPreviewController: UIViewController {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }
}

private struct AIMSelectedPhoto {
    let data: Data
    let name: String
    let mimeType: String
}

private struct AIMPhotoLibraryPanel: View {
    let maximumSelectionCount: Int
    let openAllPhotos: () -> Void
    let completion: ([AIMSelectedPhoto]) -> Void
    @Environment(\.locale) private var locale
    @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var selectedIDs: [String] = []
    @State private var importing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if isUITestPhotoLibrary {
                    fakePhotoGrid
                } else if authorizationStatus == .authorized || authorizationStatus == .limited {
                    if assets.isEmpty {
                        ContentUnavailableView(
                            copy("No photos", "Aucune photo"),
                            systemImage: "photo.on.rectangle.angled",
                            description: Text(copy(
                                "Your recent photos will appear here.",
                                "Vos photos récentes apparaîtront ici."
                            ))
                        )
                    } else {
                        photoGrid
                    }
                } else if authorizationStatus == .notDetermined {
                    ProgressView().controlSize(.large)
                } else {
                    ContentUnavailableView {
                        Label(copy("Photos unavailable", "Photos indisponibles"), systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text(copy(
                            "Allow photo access in Settings to show recent images here.",
                            "Autorisez l’accès aux photos dans Réglages pour afficher vos images récentes ici."
                        ))
                    } actions: {
                        Button(copy("Open Settings", "Ouvrir Réglages")) {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomControls
        }
        .background(Color(uiColor: .systemBackground))
        .task { await prepareLibrary() }
        .accessibilityElement(children: .contain)
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
                spacing: 3
            ) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    let selected = selectedIDs.contains(asset.localIdentifier)
                    Button { toggle(asset) } label: {
                        AIMPhotoThumbnail(asset: asset)
                            .aspectRatio(1, contentMode: .fill)
                            .overlay(alignment: .topTrailing) {
                                ZStack {
                                    Circle()
                                        .fill(selected ? Color.accentColor : Color.black.opacity(0.28))
                                        .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                                    if selected {
                                        Text(selectionNumber(for: asset))
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 25, height: 25)
                                .padding(7)
                            }
                            .clipped()
                    }
                    .buttonStyle(.plain)
                    .aspectRatio(1, contentMode: .fit)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(copy("Photo", "Photo")))
                    .accessibilityValue(Text(selected ? copy("Selected", "Sélectionnée") : copy("Not selected", "Non sélectionnée")))
                    .accessibilityIdentifier("photo-thumbnail-\(asset.localIdentifier)")
                }
            }
            .padding(.bottom, 106)
        }
        .scrollIndicators(.hidden)
    }

    private var fakePhotoGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
                spacing: 3
            ) {
                ForEach(0..<15, id: \.self) { index in
                    let id = "ui-test-photo-\(index)"
                    let selected = selectedIDs.contains(id)
                    Button { toggle(id: id) } label: {
                        LinearGradient(
                            colors: [
                                Color(hue: Double(index) / 18, saturation: 0.48, brightness: 0.82),
                                Color(hue: Double(index + 3) / 18, saturation: 0.34, brightness: 0.48),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .overlay(alignment: .topTrailing) {
                            ZStack {
                                Circle()
                                    .fill(selected ? Color.accentColor : Color.black.opacity(0.28))
                                    .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                                if selected {
                                    Text(String((selectedIDs.firstIndex(of: id) ?? 0) + 1))
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 25, height: 25)
                            .padding(7)
                        }
                    }
                    .buttonStyle(.plain)
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel(Text(copy("Photo \(index + 1)", "Photo \(index + 1)")))
                    .accessibilityValue(Text(selected ? copy("Selected", "Sélectionnée") : copy("Not selected", "Non sélectionnée")))
                    .accessibilityIdentifier("fake-photo-\(index)")
                }
            }
            .padding(.bottom, 106)
        }
        .scrollIndicators(.hidden)
    }

    private var bottomControls: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.back"))
            .accessibilityIdentifier("photos-close-button")

            Spacer()

            Button {
                if selectedIDs.isEmpty {
                    openAllPhotos()
                } else {
                    importSelection()
                }
            } label: {
                HStack(spacing: 9) {
                    if importing {
                        ProgressView().controlSize(.small)
                    }
                    Text(selectedIDs.isEmpty
                         ? copy("All Photos", "Toutes les photos")
                         : copy("Add \(selectedIDs.count)", "Ajouter \(selectedIDs.count)"))
                }
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 24)
                .frame(height: 58)
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.58), in: Capsule())
                .aimGlassCapsule()
            }
            .buttonStyle(.plain)
            .disabled(importing)
            .accessibilityIdentifier("photos-primary-button")
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    private func close() {
        completion([])
    }

    private func toggle(_ asset: PHAsset) {
        toggle(id: asset.localIdentifier)
    }

    private func toggle(id: String) {
        AIMHaptics.selection()
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else if selectedIDs.count < maximumSelectionCount {
            selectedIDs.append(id)
        }
    }

    private func selectionNumber(for asset: PHAsset) -> String {
        guard let index = selectedIDs.firstIndex(of: asset.localIdentifier) else { return "" }
        return String(index + 1)
    }

    private func prepareLibrary() async {
        if isUITestPhotoLibrary {
            authorizationStatus = .limited
            return
        }
        if authorizationStatus == .notDetermined {
            authorizationStatus = await AIMMediaPermissionBridge.request {
                PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: $0)
            }
        }
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 240
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var loaded: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in loaded.append(asset) }
        assets = loaded
    }

    private func importSelection() {
        if isUITestPhotoLibrary {
            importing = true
            let photos = selectedIDs.enumerated().compactMap { index, _ -> AIMSelectedPhoto? in
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320))
                let data = renderer.jpegData(withCompressionQuality: 0.84) { context in
                    UIColor(hue: CGFloat(index) / 12, saturation: 0.42, brightness: 0.72, alpha: 1).setFill()
                    context.cgContext.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
                }
                return .init(data: data, name: "photo-\(index + 1).jpg", mimeType: "image/jpeg")
            }
            importing = false
            completion(photos)
            return
        }
        let selectedAssets = selectedIDs.compactMap { selectedID in
            assets.first(where: { $0.localIdentifier == selectedID })
        }
        guard !selectedAssets.isEmpty else { return }
        importing = true
        Task {
            var photos: [AIMSelectedPhoto] = []
            for (index, asset) in selectedAssets.enumerated() {
                if let photo = await loadPhoto(asset, index: index) {
                    photos.append(photo)
                }
            }
            importing = false
            completion(photos)
        }
    }

    private func loadPhoto(_ asset: PHAsset, index: Int) async -> AIMSelectedPhoto? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { @Sendable data, uti, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                let type = uti.flatMap(UTType.init) ?? .jpeg
                let resourceName = PHAssetResource.assetResources(for: asset).first?.originalFilename
                let fallback = "photo-\(index + 1).\(type.preferredFilenameExtension ?? "jpg")"
                continuation.resume(returning: .init(
                    data: data,
                    name: resourceName ?? fallback,
                    mimeType: type.preferredMIMEType ?? "image/jpeg"
                ))
            }
        }
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }

    private var isUITestPhotoLibrary: Bool {
        ProcessInfo.processInfo.environment["AIM_UI_TEST_FAKE_PHOTOS"] == "1"
    }

}

private struct AIMPhotoThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.primary.opacity(0.055)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .onAppear { requestThumbnail() }
        .onDisappear {
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        }
    }

    private func requestThumbnail() {
        let scale = UIScreen.main.scale
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 180 * scale, height: 180 * scale),
            contentMode: .aspectFill,
            options: options
        ) { @Sendable result, _ in
            guard let result else { return }
            DispatchQueue.main.async { image = result }
        }
    }
}

private struct AIMToolActivityPanel: View {
    let group: RemoteToolActivityGroup
    let store: MainExperienceStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selectedToolID: String?
    @State private var details: [String: RemoteJSONValue] = [:]
    @State private var loadingToolID: String?

    init(group: RemoteToolActivityGroup, store: MainExperienceStore) {
        self.group = group
        self.store = store
        _selectedToolID = State(initialValue: group.tools.count == 1 ? group.tools.first?.id : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if selectedToolID != nil, group.tools.count > 1 {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedToolID = nil }
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: selectedToolID == nil || group.tools.count == 1 ? "xmark" : "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                        .aimGlassCircle()
                }
                .buttonStyle(.plain)

                Spacer()
                Text(selectedTool.map(toolTitle) ?? panelTitle)
                    .font(AIMDesign.controlFont(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Color.clear.frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .aimUniversalPanelHeader()

            if let tool = selectedTool {
                toolDetail(tool)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                toolList
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .aimUniversalPanelSurface()
        .accessibilityIdentifier("tool-activity-panel")
        .task(id: selectedToolID) {
            guard let selectedTool else { return }
            loadDetailIfNeeded(selectedTool)
        }
    }

    private var selectedTool: RemoteTimelineTool? {
        guard let selectedToolID else { return nil }
        return group.tools.first { $0.id == selectedToolID }
    }

    private var toolList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(group.tools, id: \.id) { tool in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedToolID = tool.id }
                        loadDetailIfNeeded(tool)
                    } label: {
                        HStack(alignment: .top, spacing: 13) {
                            Image(systemName: toolIcon(tool.presentation.kind))
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(toolTitle(tool))
                                    .font(AIMDesign.bodyFont(size: 17, weight: .semibold))
                                if let subtitle = toolSubtitle(tool) {
                                    Text(subtitle)
                                        .font(AIMDesign.bodyFont(size: 15))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            if let additions = tool.presentation.additions {
                                Text("+\(additions)").foregroundStyle(.green)
                            }
                            if let deletions = tool.presentation.deletions {
                                Text("−\(deletions)").foregroundStyle(.red)
                            }
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .font(AIMDesign.captionFont(size: 14, weight: .medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 69)
                }
            }
        }
    }

    private func toolDetail(_ tool: RemoteTimelineTool) -> some View {
        let object = details[tool.id]?.objectValue ?? [:]
        let nestedPresentation = object["presentation"]?.objectValue ?? [:]
        let command = nestedPresentation["command"]?.stringValue
            ?? object["command"]?.stringValue
            ?? tool.presentation.command
        let output = object["output"]?.stringValue
            ?? tool.output
            ?? object["content"]?.stringValue
            ?? object["detail"]?.stringValue
            ?? nestedPresentation["output"]?.stringValue
            ?? tool.presentation.outputPreview
            ?? tool.error
        let diff = object["diff"]?.stringValue
            ?? nestedPresentation["diff"]?.stringValue
            ?? tool.presentation.diff
        let path = nestedPresentation["path"]?.stringValue
            ?? object["path"]?.stringValue
            ?? tool.presentation.path

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let bytes = tool.previewJPEG, let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                }
                if let timestamp = tool.timestamp { Text("\(timestamp, specifier: "%.2f") s").font(.caption) }
                if let duration = tool.duration { Text("Duration · \(duration, specifier: "%.1f") s").font(.caption) }
                if loadingToolID == tool.id {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 18)
                }
                detailSection(copy("Input", "Entrée"), content: tool.input ?? tool.parameters.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? copy("Not provided", "Non fournie"), monospaced: true)
                if output == nil { detailSection(copy("Output", "Sortie"), content: copy("Not provided", "Non fournie"), monospaced: false) }
                if let path {
                    detailSection(copy("File", "Fichier"), content: path, monospaced: true)
                }
                if let command {
                    detailSection(copy("Command", "Commande"), content: command, monospaced: true)
                }
                if let diff, !diff.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(copy("Changes", "Modifications"))
                            .font(AIMDesign.bodyFont(size: 17, weight: .semibold))
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                Text(String(line))
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(diffColor(String(line)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 2)
                                    .background(diffBackground(String(line)))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                if let output, !output.isEmpty, output != diff {
                    detailSection(copy("Output", "Sortie"), content: output, monospaced: tool.presentation.kind == .command)
                }
                if let next = object["next_offset"]?.numberValue, next.isFinite, next >= 0 {
                    Button(copy("Load more output", "Charger la suite")) { loadMoreDetail(tool, offset: Int(next)) }
                        .disabled(loadingToolID == tool.id)
                }
                if object["source_truncated"]?.boolValue == true {
                    Text(copy("Output exceeds the remote preview limit. The complete source remains on the execution Mac.", "La sortie dépasse la limite d’aperçu distant. La source complète reste sur le Mac d’exécution.")).font(.caption).foregroundStyle(.secondary)
                }
                if command == nil, path == nil, diff == nil, output == nil {
                    ContentUnavailableView(copy("No detail available", "Aucun détail disponible"), systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 44)
                }
            }
            .padding(22)
        }
    }

    private func detailSection(_ title: String, content: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(AIMDesign.bodyFont(size: 17, weight: .semibold))
            Text(content)
                .font(monospaced ? .system(size: 14, design: .monospaced) : AIMDesign.bodyFont(size: 16))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func loadDetailIfNeeded(_ tool: RemoteTimelineTool) {
        guard !tool.hasFullResult, details[tool.id] == nil else { return }
        loadingToolID = tool.id
        Task {
            if let value = await store.requestDetailValue(id: tool.id) {
                details[tool.id] = value
            }
            if loadingToolID == tool.id { loadingToolID = nil }
        }
    }

    private func loadMoreDetail(_ tool: RemoteTimelineTool, offset: Int) {
        guard loadingToolID == nil else { return }
        loadingToolID = tool.id
        Task {
            if let page = await store.requestDetailValue(id: tool.id, offset: offset)?.objectValue {
                var merged = details[tool.id]?.objectValue ?? [:]
                merged["output"] = .string((merged["output"]?.stringValue ?? "") + (page["output"]?.stringValue ?? ""))
                merged["next_offset"] = page["next_offset"] ?? .null
                merged["source_truncated"] = page["source_truncated"] ?? .bool(false)
                details[tool.id] = .object(merged)
            }
            loadingToolID = nil
        }
    }
    private var panelTitle: String {
        copy(group.tools.count == 1 ? "Tool activity" : "Tool activities", group.tools.count == 1 ? "Activité de l’outil" : "Activités des outils")
    }

    private func toolTitle(_ tool: RemoteTimelineTool) -> String {
        if let title = tool.presentation.title, !title.isEmpty { return title }
        return switch tool.presentation.kind {
        case .command: copy("Ran a command", "Commande exécutée")
        case .createFile: copy("Created a file", "Fichier créé")
        case .editFile: copy("Edited a file", "Fichier modifié")
        case .readFile: copy("Read a file", "Fichier consulté")
        case .search: copy("Searched", "Recherche effectuée")
        case .browser: copy("Browsed", "Navigation effectuée")
        case .generic: tool.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func toolSubtitle(_ tool: RemoteTimelineTool) -> String? {
        tool.presentation.subtitle ?? tool.presentation.path ?? tool.presentation.command ?? tool.resultPreview
    }

    private func toolIcon(_ kind: RemoteToolPresentationKind) -> String {
        switch kind {
        case .command: "terminal"
        case .createFile, .editFile: "doc.badge.plus"
        case .readFile: "doc.text"
        case .search: "magnifyingglass"
        case .browser: "safari"
        case .generic: "hammer"
        }
    }

    private func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        return .primary
    }

    private func diffBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.10) }
        return .clear
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}

private struct AIMFindInConversationPanel: View {
    let session: RemoteSession
    let store: MainExperienceStore
    let initialMessages: [RemoteMessage]
    @Environment(\.dismiss) private var dismiss
    @State private var history: [RemoteMessage] = []
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    searchBar(proxy: proxy)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                    if loading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading the complete encrypted history…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error {
                        ContentUnavailableView {
                            Label("History unavailable", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        } description: { Text(error) } actions: {
                            Button("Retry") { Task { await load() } }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(matchingMessages) { message in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(message.role == .user ? "You" : "AIM")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(highlighted(message.content))
                                            .font(AIMDesign.bodyFont(size: 17))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(14)
                                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .id(message.id)
                                }
                            }
                            .padding(16)
                        }
                    }
                }
                .onChange(of: query) { _, _ in selectedIndex = 0 }
                .onChange(of: selectedIndex) { _, newValue in
                    guard matchingMessages.indices.contains(newValue) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(matchingMessages[newValue].id, anchor: .center) }
                }
            }
            .navigationTitle("Find in chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task { await load() }
        .presentationDetents([.large])
        .aimUniversalPanelSurface()
    }

    private func searchBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search messages", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text(query.isEmpty ? "0" : "\(matchingMessages.isEmpty ? 0 : selectedIndex + 1)/\(matchingMessages.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { move(-1, proxy: proxy) } label: { Image(systemName: "chevron.up") }
                .disabled(matchingMessages.isEmpty)
            Button { move(1, proxy: proxy) } label: { Image(systemName: "chevron.down") }
                .disabled(matchingMessages.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .aimGlassCapsule()
    }

    private var matchingMessages: [RemoteMessage] {
        let ids = Set(RemoteConversationSearch.matchingMessageIDs(query: query, messages: history))
        return history.filter { ids.contains($0.id) }
    }

    private func move(_ delta: Int, proxy: ScrollViewProxy) {
        guard !matchingMessages.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + matchingMessages.count) % matchingMessages.count
        proxy.scrollTo(matchingMessages[selectedIndex].id, anchor: .center)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return value }
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value[searchStart...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            value[range].backgroundColor = .yellow.opacity(0.42)
            searchStart = range.upperBound
        }
        return value
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        do {
            history = try await store.loadCompleteHistory(for: session)
            if history.isEmpty { history = initialMessages }
        } catch {
            self.error = "Keep AIM open on the computer and try again."
            history = initialMessages
        }
        loading = false
    }
}

private struct AIMUploadedFilesPanel: View {
    let session: RemoteSession
    let store: MainExperienceStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RemoteSessionAttachment] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if failed {
                    ContentUnavailableView("Files unavailable", systemImage: "paperclip.badge.ellipsis")
                } else if items.isEmpty {
                    ContentUnavailableView("No uploaded files", systemImage: "paperclip")
                } else {
                    List(items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.mimeType.hasPrefix("image/") ? "photo" : "doc")
                                .frame(width: 32, height: 32)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).lineLimit(1)
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) · \(item.source)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.isExpired() { Text("Expired").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Uploaded files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task {
            do { items = try await store.attachmentMetadata(for: session) }
            catch { failed = true }
            loading = false
        }
        .presentationDetents([.medium, .large])
        .aimUniversalPanelSurface()
    }
}

private struct AIMConversationProjectPanel: View {
    let session: RemoteSession
    let store: MainExperienceStore
    let cloudService: any CloudContentServicing
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [AIMProject] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if session.projectID != nil {
                    Button(role: .destructive) { select(nil) } label: { Label("Remove from project", systemImage: "folder.badge.minus") }
                }
                ForEach(projects) { project in
                    Button { select(project.id) } label: {
                        HStack {
                            Label(project.name, systemImage: "folder")
                            Spacer()
                            if project.id == session.projectID { Image(systemName: "checkmark") }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .overlay {
                if loading { ProgressView() }
                else if failed { ContentUnavailableView("Projects unavailable", systemImage: "folder.badge.questionmark") }
            }
            .navigationTitle("Add to project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task {
            do { projects = try await cloudService.loadProjects() }
            catch { failed = true }
            loading = false
        }
        .presentationDetents([.medium, .large])
        .aimUniversalPanelSurface()
    }

    private func select(_ projectID: String?) {
        Task {
            if await store.setProject(projectID, session: session) { dismiss() }
        }
    }
}

struct ConversationDetail: Identifiable {
    let id: String
    let title: String
    let text: String
    let remoteID: String?

    init(id: String, title: String, text: String, remoteID: String? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.remoteID = remoteID
    }
}

private struct AIMConversationDetailSheet: View {
    let detail: ConversationDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(detail.text)
                    .font(.system(size: 15, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .navigationTitle(detail.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("main.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .aimUniversalPanelSurface()
    }
}

private extension RemoteTimelineDisplayItem {
    var stableID: String {
        switch self {
        case let .segment(segment): segment.id
        case let .toolGroup(group): group.id
        }
    }
}

private enum RemoteToolPanel: String, Identifiable {
    case terminal, diff, browser
    var id: String { rawValue }
}

private struct AIMRemoteToolPanel: View {
    let panel: RemoteToolPanel
    let store: MainExperienceStore

    @Environment(\.dismiss) private var dismiss
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var diff: RemoteDiffResult?
    @State private var terminalCommand = ""
    @State private var terminalHistory: [(command: String, result: RemoteTerminalResult)] = []
    @State private var preview: RemotePreviewResult?
    @State private var browserURL = ""
    @State private var browserTarget = ""
    @State private var browserText = ""
    @State private var selectedDiffFile: RemoteChangedFile?

    var body: some View {
        NavigationStack {
            Group {
                switch panel {
                case .terminal: terminalView
                case .diff: diffView
                case .browser: browserView
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if panel == .diff, selectedDiffFile != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { selectedDiffFile = nil } label: { Image(systemName: "chevron.left") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("main.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .aimUniversalPanelSurface()
        .task {
            if panel == .diff { await loadDiff() }
            if panel == .browser { await loadPreview(script: nil) }
        }
    }

    private var terminalView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if terminalHistory.isEmpty {
                        ContentUnavailableView("remote.tool.terminal.empty", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 44)
                    }
                    ForEach(Array(terminalHistory.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 7) {
                            Text("$ \(entry.command)").foregroundStyle(.secondary)
                            Text(entry.result.output.isEmpty ? String(localized: "remote.tool.no_output") : entry.result.output)
                            if let code = entry.result.exitCode {
                                Text(String(format: String(localized: "remote.tool.exit_code"), code))
                                    .foregroundStyle(code == 0 ? Color.green : Color.red)
                            }
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }

            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red).padding(.horizontal) }

            HStack(spacing: 10) {
                TextField("remote.tool.terminal.placeholder", text: $terminalCommand)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .onSubmit { Task { await runTerminal() } }
                Button {
                    if loading { Task { await stopTerminal() } }
                    else { Task { await runTerminal() } }
                } label: {
                    if loading { Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }
                .disabled(!loading && terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
            .background(.ultraThinMaterial)
        }
    }

    private var diffView: some View {
        Group {
            if loading {
                ProgressView("remote.tool.loading").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("remote.tool.unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if let diff {
                if selectedDiffFile == nil, !diff.files.isEmpty {
                    List {
                        Section {
                            ForEach(diff.files) { file in
                                Button { selectedDiffFile = file } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text")
                                        Text(file.path).lineLimit(1)
                                        Spacer()
                                        Text("+\(file.additions)").foregroundStyle(.green)
                                        Text("−\(file.deletions)").foregroundStyle(.red)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 14).monospacedDigit())
                                }
                                .foregroundStyle(.primary)
                            }
                        } header: {
                            Text("\(diff.files.count) files · +\(diff.additions) −\(diff.deletions)")
                        }
                        Section {
                            Button("View complete diff") {
                                selectedDiffFile = RemoteChangedFile(path: "", status: "all", additions: diff.additions, deletions: diff.deletions)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                ScrollView([.horizontal, .vertical]) {
                    if diff.diff.isEmpty {
                        Text("remote.tool.diff.empty")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if diff.base != nil || diff.directory != nil {
                                HStack(spacing: 12) {
                                    if let base = diff.base {
                                        Label(base, systemImage: "arrow.triangle.branch")
                                    }
                                    if let directory = diff.directory {
                                        Label(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder")
                                    }
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }

                            ForEach(Array(RemoteDiffRules.lines(in: visibleDiff(diff)).enumerated()), id: \.offset) { _, line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(diffForeground(line.kind))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, line.kind == .hunkHeader ? 5 : 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(diffBackground(line.kind))
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 8)
                    }
                }
                }
            }
        }
    }

    private func visibleDiff(_ result: RemoteDiffResult) -> String {
        guard let file = selectedDiffFile, !file.path.isEmpty else { return result.diff }
        let marker = "diff --git "
        let chunks = result.diff.components(separatedBy: marker)
        return chunks.first(where: { chunk in
            chunk.hasPrefix("a/\(file.path) b/\(file.path)") || chunk.contains(" b/\(file.path)\n")
        }).map { marker + $0 } ?? result.diff
    }

    private func diffForeground(_ kind: RemoteDiffLineKind) -> Color {
        switch kind {
        case .addition: .green
        case .deletion: .red
        case .hunkHeader: .blue
        case .fileHeader: .primary
        case .metadata: .secondary
        case .context: .primary.opacity(0.82)
        }
    }

    private func diffBackground(_ kind: RemoteDiffLineKind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.08)
        case .deletion: .red.opacity(0.08)
        case .hunkHeader: .blue.opacity(0.07)
        case .fileHeader: .primary.opacity(0.035)
        case .metadata, .context: .clear
        }
    }

    private var browserView: some View {
        VStack(spacing: 18) {
            if loading { ProgressView("remote.tool.preview.loading") }
            else if let errorMessage {
                ContentUnavailableView("remote.tool.unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if preview?.isBrowserSnapshot == true {
                nativeBrowserView
            } else if let url = preview?.url {
                AIMPreviewWebView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.1)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("remote.tool.preview.stop", role: .destructive) {
                    Task { try? await store.stopPreview(); preview = nil }
                }
            } else if preview?.needsServer == true {
                Text("remote.tool.preview.choose_script").font(.headline)
                ForEach(preview?.scripts ?? [], id: \.self) { script in
                    Button(script) { Task { await loadPreview(script: script) } }
                        .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView("remote.tool.preview.empty", systemImage: "globe")
            }
        }
        .padding(20)
    }

    private var nativeBrowserView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("https://…", text: $browserURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL).textFieldStyle(.roundedBorder)
                Button("Open") { Task { await browserAction("browser_navigate", arguments: ["url": browserURL]) } }
                    .disabled(loading || browserURL.isEmpty)
            }
            HStack {
                Button("Refresh") { Task { await browserAction("browser_snapshot", arguments: [:]) } }
                Button("Back") { Task { await browserAction("browser_navigate_back", arguments: [:]) } }
                Spacer()
                Button("Close", role: .destructive) { Task { try? await store.stopPreview(); preview = nil } }
            }.disabled(loading)
            if let failure = preview?.browserError { Text(failure).font(.footnote).foregroundStyle(.red) }
            ScrollView {
                Text(preview?.browserSnapshot ?? "").font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if preview?.observationID != nil {
                TextField("Element reference", text: $browserTarget).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().textFieldStyle(.roundedBorder)
                TextField("Text to enter", text: $browserText, axis: .vertical).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Click") { Task { await browserTargetAction("browser_click", text: nil) } }
                    Button("Type") { Task { await browserTargetAction("browser_type", text: browserText) } }
                }.disabled(loading || browserTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    @MainActor private func browserTargetAction(_ name: String, text: String?) async {
        guard let observation = preview?.observationID else { return }
        var arguments = ["target": browserTarget, "observation_id": observation]
        if let text { arguments["text"] = text }
        await browserAction(name, arguments: arguments)
    }
    @MainActor private func browserAction(_ name: String, arguments: [String: String]) async {
        guard !loading else { return }
        loading = true; errorMessage = nil
        preview = RemotePreviewResult(browserSnapshot: preview?.browserSnapshot, isBrowserSnapshot: true)
        defer { loading = false }
        do { preview = try await store.performBrowserAction(name, arguments: arguments) }
        catch { errorMessage = String(localized: "remote.error.command_failed") }
    }

    private var title: LocalizedStringKey {
        switch panel {
        case .terminal: "remote.tool.terminal"
        case .diff: "remote.tool.diff"
        case .browser: "remote.tool.browser"
        }
    }

    @MainActor
    private func loadDiff() async {
        loading = true; errorMessage = nil
        defer { loading = false }
        do { diff = try await store.requestDiff() }
        catch { errorMessage = String(localized: "remote.error.command_failed") }
    }

    @MainActor
    private func runTerminal() async {
        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !loading else { return }
        terminalCommand = ""
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            let result = try await store.runTerminalCommand(command)
            terminalHistory.append((command, result))
        } catch {
            errorMessage = String(localized: "remote.error.command_failed")
        }
    }

    @MainActor
    private func stopTerminal() async {
        do { try await store.stopTerminalCommand() }
        catch { errorMessage = String(localized: "remote.error.command_failed") }
    }

    @MainActor
    private func loadPreview(script: String?) async {
        loading = true; errorMessage = nil
        defer { loading = false }
        do { preview = try await store.startPreview(script: script) }
        catch { errorMessage = String(localized: "remote.error.command_failed") }
    }
}

private struct AIMPreviewWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}

/// The same message chrome is used for device Chat and for Remote timelines.
struct AIMChatUserBubble: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        HStack {
            Spacer(minLength: 42)
            AIMMarkdownView(source: text, baseFont: AIMDesign.bodyFont(size: 17), expands: false)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(AIMDesign.userMessageBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 19))
        }
        .accessibilityIdentifier("chat-user-bubble")
    }
}

struct AIMChatRunSummary: View {
    let tokens: Int?
    let costUSD: Double?
    var duration: Double? = nil
    var preciseDuration = false
    var body: some View {
        HStack(spacing: 7) {
            if let duration {
                Text(duration.formatted(.number.precision(.fractionLength(preciseDuration ? 1 : 0))) + " s")
            }
            if let tokens {
                if duration != nil { Text("·") }
                Text(String(format: String(localized: "remote.conversation.tokens"), tokens))
            }
            if let costUSD {
                if duration != nil || tokens != nil { Text("·") }
                Text(costUSD, format: .currency(code: "USD").precision(.fractionLength(4)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct AIMChatMessageActions: View {
    let text: String
    var sources: [ConversationSource] = []
    @State private var showingSources = false
    @State private var showingInformation = false
    var information: AIMChatResponseInformation? = nil
    var readAloud: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 0) {
            if !ConversationSourceProjection(text: text, sources: sources).sources.isEmpty {
                let cited = ConversationSourceProjection(text: text, sources: sources).sources
                Button { showingSources = true } label: {
                    HStack(spacing: 6) {
                        HStack(spacing: -6) {
                            ForEach(Array(cited.prefix(3).enumerated()), id: \.element.id) { index, source in
                                AIMSourceIcon(domain: source.domain, size: 20, sourceURL: source.url).zIndex(Double(3 - index))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
                            }
                        }
                        Text("Sources").font(.footnote)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Sources").accessibilityIdentifier("message-sources")
            }
            Button { UIPasteboard.general.string = text } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 14)).frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("remote.conversation.copy"))
            .accessibilityIdentifier("chat-copy-response")
            if let readAloud {
                Button(action: readAloud) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 14)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Read aloud")
            }
            if let information {
                Button { showingInformation = true } label: {
                    Image(systemName: "info.circle").font(.system(size: 14)).frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("response.information"))
                .accessibilityIdentifier("chat-response-information")
                .popover(isPresented: $showingInformation) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("response.information").font(.headline)
                        AIMChatRunSummary(tokens: information.tokens, costUSD: information.costUSD, duration: information.duration)
                        Text(information.providerCostConfirmed ? "response.cost_confirmed" : "response.cost_estimated")
                            .font(.footnote).foregroundStyle(.secondary)
                        if information.webCostIncomplete {
                            Text("budget.web_cost_incomplete").font(.footnote).foregroundStyle(.secondary)
                        }
                        if information.reconstructedEstimate {
                            Text("response.cost_reconstructed").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20).frame(idealWidth: 290, maxWidth: 330, alignment: .leading)
                    .presentationCompactAdaptation(.popover)
                    .accessibilityIdentifier("chat-response-information-panel")
                }
            }
        }
        .sheet(isPresented: $showingSources) { AIMSourcesPanel(sources: ConversationSourceProjection(text: text, sources: sources).sources) }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(.secondary)
    }
}

struct AIMChatResponseInformation {
    let tokens: Int?
    let costUSD: Double?
    let duration: Double?
    let providerCostConfirmed: Bool
    let webCostIncomplete: Bool
    var reconstructedEstimate = false
}

private struct AIMVideoPreparationChoice: View {
    let name: String
    let choose: (VideoPreparationOptions?) -> Void
    @State private var mode: PreparedVideoAttachment.Mode = .automatic
    @State private var start = "0"
    @State private var end = "10"
    var body: some View {
        NavigationStack {
            Form {
                Picker("Analysis", selection: $mode) {
                    Text("Automatic").tag(PreparedVideoAttachment.Mode.automatic)
                    Text("Detailed").tag(PreparedVideoAttachment.Mode.detailed)
                    Text("Excerpt").tag(PreparedVideoAttachment.Mode.excerpt)
                }
                if mode == .excerpt {
                    TextField("Start (seconds)", text: $start).keyboardType(.decimalPad)
                    TextField("End (seconds)", text: $end).keyboardType(.decimalPad)
                }
                Text("Preparation is local. Sampled images keep their decoded timestamps; events between samples may be missed. Long videos are analysed in chronological batches when needed. Local transcription depends on this device’s speech engine.").font(.footnote).foregroundStyle(.secondary)
                Button("Prepare") { choose(.init(mode: mode, start: Double(start), end: Double(end))) }
                Button("Cancel", role: .cancel) { choose(nil) }
            }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct AIMRemoteWorkStatus: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var illuminated = false
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .opacity(reduceMotion || illuminated ? 1 : 0.55)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: illuminated)
            .onAppear { illuminated = true }
    }
}
