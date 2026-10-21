import AIMCore
import AVKit
import SwiftUI

struct AIMNativeChatView: View {
    @Environment(\.locale) private var locale
    let chat: NativeChatStore
    let remote: MainExperienceStore
    let delegations: RemoteDelegationService
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let openMenu: () -> Void
    let selectMode: (RemoteMode) -> Void
    let openProviders: () -> Void
    let openConnection: () -> Void
    let selectComputer: (String, String?) -> Void
    var selectThisDevice: () -> Void = {}
    var openPersonalization: () -> Void = {}
    var composerOnly = false
    var isNavigationPreview = false
    var previewProjectID: UUID?
    var backToProject: (() -> Void)?
    var onSubmitted: (UUID) -> Void = { _ in }
    @State private var attachments: [RemoteAttachmentReference] = []
    @State private var showingModels = false
    @State private var pendingMediaModel: MediaModel?
    @State private var mediaModel: MediaModel?
    @State private var showingDelegation = false
    @State private var showingVoice = false
    @State private var readingText: String?
    @State private var didOfferStartVoice = false
    @State private var exportURL: URL?
    @State private var previewInput: NativeChatAttachment?
    var body: some View {
        let conversationID = previewProjectID == nil ? chat.selectedID : nil
        let draftID = previewProjectID.map { chat.draftIdentifier(projectID: $0) } ?? chat.draftIdentifier(conversationID: conversationID)
        Group {
            if composerOnly { composer(conversationID: conversationID, draftID: draftID) }
            else {
        AIMConversationScaffold(safeTop: safeTop, safeBottom: safeBottom) { bottomOcclusion in
            if let conversation = chat.selected {
                AIMConversationTimeline(identity: conversation.id.uuidString, revision: "\(conversation.messages.count):\(conversation.messages.last?.text ?? "")", safeTop: safeTop, bottomOcclusion: bottomOcclusion) {
                    ForEach(conversation.messages) { message in
                        messageRow(message, in: conversation)
                    }
                }
            } else {
                VStack {
                    Spacer(minLength: 10)
                    Text("Got a question?").font(AIMDesign.titleFont(size: 29)).multilineTextAlignment(.center).padding(.horizontal, 20)
                    Spacer(minLength: 10)
                }.padding(.top, safeTop + 70).padding(.bottom, bottomOcclusion)
            }
        } header: {
            HStack(spacing: 0) {
                Button(action: backToProject ?? openMenu) {
                    Image(systemName: backToProject == nil ? "line.3.horizontal" : "chevron.left").font(.system(size: 19, weight: .semibold))
                        .frame(width: 44, height: 44).aimGlassCircle()
                }.accessibilityLabel(backToProject == nil ? "Open menu" : "Back to project")
                    .accessibilityIdentifier(backToProject == nil ? "main-menu-button" : "native-chat-project-back").modifier(AIMAttentionBadge())
                Spacer()
                if chat.selected == nil {
                    AIMCreationModeSelector(selection: .chat, select: selectMode)
                } else {
                    targetMenu
                }
                Spacer()
                Menu {
                    if chat.selected == nil {
                        executionDeviceActions
                    } else {
                        Menu("Project") {
                            Button("No project") { chat.assignProject(nil) }
                            ForEach(chat.projects) { project in Button(project.name) { chat.assignProject(project.id) } }
                        }
                        Button("Voice conversation") { showingVoice = true }
                        Button("Providers", action: openProviders)
                        Button("Delegate to a Mac") { showingDelegation = true }
                    }
                    if chat.selected != nil {
                        Button("New Chat") { chat.newConversation() }
                        Button("Export chats") {
                            do { exportURL = try chat.export() } catch { chat.errorMessage = error.localizedDescription }
                        }
                    }
                } label: {
                    if chat.selected == nil {
                        Circle().fill(chat.connectedProviders.contains(chat.provider) ? Color.green : Color.orange)
                            .frame(width: 8, height: 8).frame(width: 44, height: 44).aimGlassCircle()
                    } else {
                        Image(systemName: "ellipsis").font(.system(size: 19, weight: .semibold))
                            .frame(width: 44, height: 44).aimGlassCircle()
                    }
                }.accessibilityLabel(chat.selected == nil ? "Choose execution device" : "Conversation actions").accessibilityIdentifier(chat.selected == nil ? "native-chat-status" : "native-chat-actions")
            }.buttonStyle(.plain).foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.top, safeTop + 8).padding(.bottom, 8)
        } composer: { composer(conversationID: conversationID, draftID: draftID) }
            }
        }
        .aimBlocksBackgroundInteractions(showingModels || showingVoice || showingDelegation || exportURL != nil || readingText != nil || mediaModel != nil)
        .background(Color(uiColor: .systemBackground))
        .onChange(of: showingVoice) { _, showing in if showing { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
        .onChange(of: showingModels) { _, showing in if showing { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
        .onChange(of: showingDelegation) { _, showing in if showing { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
        .onDisappear { if !isNavigationPreview { chat.voiceController.stop(); chat.stopSpeaking() } }
        .sheet(item: visualApprovalPresentation) { pending in
            AIMVisualApprovalView(chat: chat, pending: pending).aimBlocksBackgroundInteractions(true)
        }
        .sheet(isPresented: $showingVoice) { AIMVoiceConversationView(chat: chat) }
        .alert("Read with your speech provider?", isPresented: Binding(get: { readingText != nil }, set: { if !$0 { readingText = nil } })) {
            Button("Read aloud") { if let text = readingText { chat.speak(text) }; readingText = nil }; Button("Cancel", role: .cancel) { readingText = nil }
        } message: { Text("A speech request uses your configured provider. Its API charges apply.") }
        .sheet(isPresented: $showingDelegation) { AIMDelegationView(service: delegations, remote: remote, initialText: chat.draftText) }
        .sheet(item: $previewInput) { input in AIMNativeInputPreview(input: input, original: chat.originalInputURL(input.id)) }
        .sheet(isPresented: $showingModels, onDismiss: { mediaModel = pendingMediaModel; pendingMediaModel = nil }) {
            AIMNativeModelPicker(chat: chat, remote: remote, selectComputer: selectComputer, openProviders: openProviders, createMedia: { model in pendingMediaModel = model; showingModels = false })
        }
        .sheet(item: $mediaModel) { model in AIMMediaCreatorView(store: chat.media, model: model, conversationID: chat.selectedID).aimBlocksBackgroundInteractions(true) }
        .sheet(item: Binding(get: { exportURL.map { ExportItem(url: $0) } }, set: { exportURL = $0?.url })) { item in
            ShareLink(item: item.url).padding(40).presentationDetents([.medium])
        }
        .task { guard !isNavigationPreview else { return }; if chat.models.isEmpty { await chat.loadModels() }; await chat.synchronize(); if !composerOnly && !didOfferStartVoice { didOfferStartVoice = true; showingVoice = chat.voiceController.startWithVoice } }
    }
    // A passive parent preview must neither present nor dismiss a live approval.
    var visualApprovalPresentation: Binding<NativeVisualApproval?> {
        Binding(get: { isNavigationPreview ? nil : chat.pendingVisualApproval },
                set: { if !isNavigationPreview { chat.pendingVisualApproval = $0 } })
    }
    private func composer(conversationID: UUID?, draftID: UUID) -> some View {
            VStack(spacing: 0) {
            if chat.executionTarget != .thisDevice {
                VStack(spacing: 8) {
                    Text("Awaiting Mac synchronization").font(.footnote).foregroundStyle(.secondary)
                    Button("This iPhone", action: selectThisDevice).font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.primary).padding(.horizontal, 20).padding(.bottom, 10)
                .accessibilityIdentifier("chat-awaiting-mac-synchronization")
            }


            AIMConversationComposer(text: Binding(get: { chat.draftText(conversationID: draftID) }, set: { chat.setDraftText($0, conversationID: draftID) }), attachments: Binding(get: { chat.inputReferences(draftID) }, set: { chat.setInputReferences($0, id: draftID) }), modelName: chat.modelName, modelID: chat.modelID,
                capabilities: nil, mode: .chat, approvalMode: nil, attachmentsEnabled: true, enabled: chat.executionTarget == .thisDevice && !chat.isSending && !chat.preparingVisualAnalysis,
                sendEnabled: chat.executionTarget == .thisDevice && !chat.modelID.isEmpty, loading: chat.isSending, sessionRunning: chat.isSending, expandedAtRest: false,
                accessibilityPrefix: "native-chat", openModelPicker: { if chat.connectedProviders.isEmpty { openProviders() } else { showingModels = true } }, safeBottom: safeBottom, openPersonalization: openPersonalization,
                send: { value, _ in
                    guard chat.selectedID == conversationID else { return false }
                    let sent = await chat.send(value, attachments: chat.inputAttachments(draftID))
                    if sent, let id = chat.selectedID { onSubmitted(id) }
                    return sent
                }, uploadAttachment: { data, name, mime, options in await chat.prepareInput(data, name: name, mimeType: mime, draftID: draftID, options: options) },
                changeModel: { _, _ in showingModels = true; return false }, changeApprovalMode: { _ in false },
                sendGoal: { _, _, _ in false }, stop: {
                    if let conversationID { chat.cancel(conversationID: conversationID) }
                    return true
                }, attachmentPreviewData: { id in chat.inputAttachments(draftID).first(where: { $0.id.uuidString == id })?.data ?? chat.inputAttachments(draftID).first(where: { $0.id.uuidString == id })?.video?.frames.first?.jpeg }, openAttachment: { id in previewInput = chat.inputAttachments(draftID).first(where: { $0.id.uuidString == id }) })
            }
    }
    private func messageRow(_ message: NativeChatMessage, in conversation: NativeChatConversation) -> some View {
                                VStack(alignment: .leading, spacing: 10) {
                                    if message.role == .user, let actions = message.actions, !actions.isEmpty {
                                        AIMConversationActions(actions: actions, attachments: conversation.messages.flatMap { $0.attachments ?? [] })
                                    }
                                    if message.actions == nil, let activities = message.skillActivities { ForEach(activities) { activity in
                                        Label(activity.name + " · " + activity.skill + (activity.isError ? " · unavailable" : ""), systemImage: "doc.text.magnifyingglass").font(.footnote).foregroundStyle(.secondary)
                                    } }
                                    if let ids = message.mediaAssetIDs { ForEach(ids, id: \.self) { id in
                                        if let asset = chat.media.visibleAssets.first(where: { $0.id == id }), let url = chat.media.localURL(asset: asset) {
                                            AIMChatMediaAttachment(asset: asset, url: url)
                                        } else { Label("Media unavailable on this device", systemImage: "photo").font(.footnote).foregroundStyle(.secondary) }
                                    } }
                                    if message.role == .user {
                                        VStack(alignment: .trailing, spacing: 8) {
                                            ForEach(message.attachments ?? []) { attachment in
                                                if let bytes = attachment.data ?? attachment.video?.frames.first?.jpeg, let image = UIImage(data: bytes) {
                                                    Button { previewInput = attachment } label: {
                                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 112, height: 112).clipped()
                                                            .overlay { if attachment.video != nil { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white).shadow(radius: 3) } }
                                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                                    }.buttonStyle(.plain).accessibilityLabel(attachment.name)
                                                } else {
                                                    Label(attachment.name, systemImage: "doc.text").font(.footnote).padding(12).background(.quaternary, in: Capsule())
                                                }
                                            }
                                            if !message.text.isEmpty { AIMChatUserBubble(text: message.text) }
                                        }.frame(maxWidth: .infinity, alignment: .trailing)
                                    } else {
                                        let live = chat.isSending && message.id == conversation.messages.last?.id
                                        if message.text.isEmpty, live, message.timeline?.entries.isEmpty != false, (message.actions ?? []).isEmpty {
                                            Label(locale.language.languageCode?.identifier == "fr" ? "Réflexion…" : "Thinking…", systemImage: "ellipsis")
                                                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("chat-thinking")
                                        }
                                        let citations = ProjectSourceCitationPresentation(message: message, attachments: conversation.messages.flatMap { $0.attachments ?? [] })
                                        AIMTurnTimelineView(text: message.text, timeline: message.timeline, actions: message.actions ?? [], sources: message.sources,
                                                            attachments: conversation.messages.flatMap { $0.attachments ?? [] }, live: live, citationPresentation: citations)
                                        if !message.text.isEmpty && !(chat.isSending && message.id == conversation.messages.last?.id) {
                                            let turn = conversation.turns.first(where: { $0.id == message.id && $0.completedAt != nil })
                                            let tokens: Int? = if let input = turn?.usage.inputTokens, let output = turn?.usage.outputTokens { input + output } else { nil }
                                            AIMChatMessageActions(text: citations.displayed(message.text, markdown: false), sources: message.sources ?? [],
                                                information: .init(tokens: tokens, costUSD: message.webSearchUsage?.providerTotalCostUSD ?? turn?.estimatedUSD,
                                                    duration: chat.activityRecords.first(where: { $0.id == message.id })?.duration,
                                                    providerCostConfirmed: message.webSearchUsage?.providerTotalCostUSD != nil,
                                                    webCostIncomplete: message.webSearchUsage.map { $0.providerTotalCostUSD == nil && $0.additionalCostUSD == nil } ?? false,
                                                    reconstructedEstimate: chat.activityRecords.first(where: { $0.id == message.id })?.costEstimateBasis != nil), readAloud: {
                                                if chat.voiceController.configuration.provider == .system { chat.speak(citations.displayed(message.text, markdown: false)) }
                                                else { readingText = citations.displayed(message.text, markdown: false) }
                                            })
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(message.id)
    }
    @ViewBuilder private var executionDeviceActions: some View {
        Section(locale.language.languageCode?.identifier == "fr" ? "Exécuter sur" : "Run requests on") {
            Button(action: selectThisDevice) {
                Label("This iPhone", systemImage: chat.executionTarget == .thisDevice ? "checkmark" : "iphone")
            }.accessibilityIdentifier("execution-device-iphone")
            ForEach(remote.overview.machines) { machine in
                Button { selectComputer(machine.id, nil) } label: {
                    Label(machine.name, systemImage: chat.executionTarget == .computer(machineID: machine.id) ? "checkmark" : "desktopcomputer")
                }.accessibilityIdentifier("execution-device-mac-\(machine.id)")
            }
        }
        Section {
            Button(action: openConnection) {
                Label(locale.language.languageCode?.identifier == "fr" ? "Gérer les Mac" : "Manage Macs", systemImage: "link")
            }.accessibilityIdentifier("native-manage-connections")
        }
    }
    private var targetMenu: some View {
        Menu {
            executionDeviceActions
        } label: {
            Circle().fill(chat.connectedProviders.contains(chat.provider) ? Color.green : Color.orange)
                .frame(width: 8, height: 8).frame(width: 32, height: 32).aimGlassCircle()
                .frame(width: 44, height: 44).contentShape(Circle())
        }.accessibilityLabel("Chat execution target: this iPhone").accessibilityIdentifier("native-chat-status")
    }
    private func searchActivityLabel(_ activity: NativeWebSearchActivity) -> String {
        let french = Locale.current.language.languageCode?.identifier == "fr"
        let state: String
        switch activity.status {
        case .running: state = french ? "Recherche en cours" : "Searching"
        case .completed: state = french ? "Terminée" : "Completed"
        case .failed: state = french ? "Interrompue" : "Interrupted"
        }
        return (french ? "Recherche web · " : "Web search · ") + state
    }
    private struct ExportItem: Identifiable { let url: URL; var id: URL { url } }
}

struct AIMNativeModelPicker: View {
    let chat: NativeChatStore
    let remote: MainExperienceStore
    let selectComputer: (String, String?) -> Void
    var openProviders: () -> Void = {}
    var createMedia: (MediaModel) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    private var items: [AIMModelPickerItem] {
        var result: [AIMModelPickerItem] = []
        var catalogs = chat.catalogModels
        if catalogs[chat.provider] == nil { catalogs[chat.provider] = chat.models }
        for (provider, models) in catalogs {
            for model in models {
                let favoriteKey = provider.rawValue + ":" + model.id
                result.append(.init(modelID: model.id, name: model.name, provider: provider.rawValue,
                                    groupProvider: provider == .openRouter ? model.provider : nil,
                                    subtitle: [provider == .openRouter ? "via OpenRouter" : nil, model.kindLabel].compactMap { $0 }.joined(separator: " · "),
                                    capabilities: model.capabilities.map(\.rawValue).sorted(),
                                    isAdded: chat.favorites.contains(favoriteKey),
                                    isPinned: chat.pinnedModels.contains(favoriteKey),
                                    available: chat.connectedProviders.contains(provider) && (model.isChatModel || MediaModel.from(model) != nil),
                                    unavailableReason: !model.isChatModel && MediaModel.from(model) == nil ? model.kindLabel : (chat.connectedProviders.contains(provider) ? nil : "Connect provider"), detail: model,
                                    isReferencePricing: chat.modelPricingIsReference(provider: provider, modelID: model.id), mediaModel: chat.media.models.first(where: { $0.id == model.id && $0.route == .openRouter }) ?? MediaModel.from(model)))
            }
        }
        for media in chat.media.models + MediaModel.blackForestLabs where !result.contains(where: { $0.modelID == media.id && $0.provider == (media.route == .openRouter ? "openrouter" : "blackForestLabs") }) {
            let route = media.route == .openRouter ? "openrouter" : "blackForestLabs"
            let key = route + ":" + media.id
            result.append(.init(modelID: media.id, name: media.name, provider: route, groupProvider: media.route == .openRouter ? String(media.id.split(separator: "/").first ?? "OpenRouter") : "Black Forest Labs", capabilities: [media.kind.rawValue], isAdded: chat.favorites.contains(key), isPinned: chat.pinnedModels.contains(key), available: chat.media.hasKey(media.route), unavailableReason: chat.media.hasKey(media.route) ? nil : "Connect provider", mediaModel: media))
        }
        // Keep account favorites visible when a key is absent or its catalog cannot be reached.
        for favorite in chat.favorites {
            guard let separator = favorite.firstIndex(of: ":") else { continue }
            let provider = String(favorite[..<separator]), modelID = String(favorite[favorite.index(after: separator)...])
            if !result.contains(where: { $0.provider == provider && $0.modelID == modelID }) {
                result.append(.init(modelID: modelID, name: modelID, provider: provider,
                                    isAdded: true, isPinned: chat.pinnedModels.contains(favorite), available: false, unavailableReason: "Connection or model unavailable"))
            }
        }
        // Local means the explicitly selected Mac; browsing never changes the execution target.
        if let machine = remote.selectedMachine {
            result += (machine.capabilities?.models ?? []).filter { $0.provider == "local" || $0.via == "local" }.map { model in
                .init(modelID: model.id, name: model.name, provider: "local", subtitle: machine.name,
                      capabilities: model.capabilities, isLocal: true, isAdded: model.isAdded ?? true,
                      isPinned: model.isPinned ?? false, available: model.isAvailable != false, unavailableReason: model.isAvailable == false ? "Unavailable on selected Mac" : nil, detail: model.detail, isReferencePricing: model.isReferencePricing == true)
            }
        }
        let groups = Dictionary(grouping: result) { CanonicalModelRouting.identity($0.modelID, provider: $0.provider) }
        return groups.map { canonical, values in
            let preferred = chat.preferredRoute(canonical)
            let routes = values.sorted {
                if ($0.provider == preferred) != ($1.provider == preferred) { return $0.provider == preferred }
                if $0.available != $1.available { return $0.available }
                let a = CanonicalModelRouting.rank($0.provider), b = CanonicalModelRouting.rank($1.provider)
                return a == b ? $0.provider < $1.provider : a < b
            }
            var item = routes[0]
            item.routes = routes
            item.isAdded = values.contains(where: \.isAdded)
            item.isPinned = values.contains(where: \.isPinned)
            if canonical.hasPrefix("black-forest-labs/") { item.groupProvider = "Black Forest Labs" }
            else if let publisher = item.groupProvider { item.groupProvider = CanonicalModelRouting.publisher(publisher) }
            return item
        }
    }

    var body: some View {
        AIMUnifiedModelPicker(items: items,
            selectedKey: AIMModelPickerItem.key(provider: chat.provider.rawValue, modelID: chat.modelID),
            executionDeviceName: "iPhone",
            loading: chat.isLoadingModels || chat.media.isLoadingCatalog,
            refresh: { Task { await chat.loadModelCatalogs(force: true); if !chat.usesNativeUITestFixture { await chat.media.refreshCatalog(force: true) } } },
            openProviders: { dismiss(); openProviders() }, remoteStore: remote,
            toggleAdded: { item in
                if item.provider == "blackForestLabs" { chat.toggleMediaFavorite(item.modelID); return }
                guard let provider = ChatProvider(rawValue: item.provider), !item.isLocal else { return }
                chat.toggleFavorite(modelID: item.modelID, provider: provider)
            },
            togglePinned: { item in
                if item.provider == "blackForestLabs" { chat.toggleMediaPinned(item.modelID); return }
                guard let provider = ChatProvider(rawValue: item.provider), !item.isLocal else { return }
                chat.togglePinned(modelID: item.modelID, provider: provider)
            }) { item in
                if item.isLocal, let machine = remote.selectedMachine {
                    selectComputer(machine.id, item.modelID); dismiss()
                } else if let media = item.mediaModel {
                    guard chat.executionTarget == .thisDevice else { chat.errorMessage = "Choose This iPhone explicitly before creating media here."; return }
                    createMedia(media)
                } else if let provider = ChatProvider(rawValue: item.provider) {
                    Task { if await chat.selectModel(provider: provider, modelID: item.modelID) { dismiss() } }
                }
            }
            .task { await chat.loadModelCatalogs(); if !chat.usesNativeUITestFixture { await chat.media.refreshCatalog() } }
    }

}

private struct AIMChatMediaAttachment: View {
    let asset: MediaAsset
    let url: URL
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading) {
                if asset.kind == .image, let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 18)) }
                else { Label("Play video", systemImage: "play.circle.fill").frame(minHeight: 52) }
                Text(asset.title).font(.caption).lineLimit(2)
            }
        }.buttonStyle(.plain).sheet(isPresented: $showing) {
            VStack {
                if asset.kind == .video { VideoPlayer(player: AVPlayer(url: url)) }
                else if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit() }
                ShareLink(item: url).padding()
                Button("Close") { showing = false }.padding()
            }.tint(.primary)
        }
    }
}

struct AIMNativeInputPreview: View {
    let input: NativeChatAttachment
    let original: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            ScrollView {
                if let video = input.video {
                    if let player { VideoPlayer(player: player).frame(height: 320) }
                    else { Text("Original video remains on " + video.originDeviceName).foregroundStyle(.secondary).padding() }
                    ForEach(video.frames) { frame in
                        if let image = UIImage(data: frame.jpeg) { Image(uiImage: image).resizable().scaledToFit(); Text("\(frame.seconds, specifier: "%.2f") s").font(.caption.monospacedDigit()) }
                    }
                    Text(video.transcript ?? video.audioNotice ?? "Local transcription unavailable").padding()
                } else if let data = input.data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
                else { Text(input.text ?? "Preview unavailable").padding() }
            }.navigationTitle(input.name).navigationBarTitleDisplayMode(.inline).toolbar { Button("Close") { dismiss() } }
        }.onAppear { if let original, input.video != nil { player = AVPlayer(url: original) } }
         .onDisappear { player?.pause(); player = nil }
    }
}

/// Coalesce provider bursts to a 30 Hz presentation cadence, with no artificial
/// wait for archived messages or Reduce Motion. Completion always shows all text.
struct AIMStreamingSourceMarkdown: View {
    let text: String
    let sources: [ConversationSource]?
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var display = StreamingTextPresentation()
    @State private var mounted = false

    var body: some View {
        AIMSourceMarkdown(text: mounted ? display.visible : text, sources: sources)
            .onAppear {
                display.update(text, animated: false); mounted = true
            }
            .onChange(of: text) { _, text in display.update(text, animated: live && !reduceMotion) }
            .onChange(of: reduceMotion) { _, reduced in if reduced { display.update(text, animated: false) } }
            .task(id: live) {
                guard live else { display.update(text, animated: false); return }
                while !Task.isCancelled {
                    if !display.isSettled { display.advance() }
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                }
            }
    }
}
