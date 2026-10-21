import AppKit
import AIMAgentKit
import AIMApplication
import AIMCore
import AVKit
import AIMMacPlatform
import SwiftUI
import UniformTypeIdentifiers

struct AIMComposer: View {
    private enum DictationPhase { case idle, starting, recording, transcribing }
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var placeholder: String
    @State private var preview: TextAttachment?
    @State private var imagePreview: ImageAttachment?
    @State private var videoPreview: TextAttachment?
    @State private var dropTargeted = false
    @State private var recorder = DictationRecorder()
    @State private var dictationPhase: DictationPhase = .idle
    @State private var dictationEngine: DictationEngine = .apple
    @State private var dictationTask: Task<Void, Never>?
    @State private var dictationRunID = UUID()
    @State private var dictationError: String?
    /// A recording kept after a failed transcription (also found again after a relaunch).
    @State private var pendingDictation: URL?
    @State private var showDictationMenu = false
    @State private var showEffort = false
    @State private var projectWorkspaces: [ProjectSource] = []
    @State private var gitBranch: String?
    @State private var showWorktrees = false
    @State private var showFolders = false
    @State private var showAddMenu = false
    @State private var showEngines = false
    @State private var showPolicies = false
    @State private var editorHeight: CGFloat = 36

    #if DEBUG
    /// Gallery only: a still waveform shape.
    static let galleryLevels: [Float] = (0..<DictationRecorder.historyLength).map { (index: Int) -> Float in
        guard index >= 20 else { return 0 }
        let wave = Float(abs(sin(Double(index) * 0.7)))
        return wave * (index % 9 < 5 ? 0.9 : 0.05)
    }
    #endif

    private var dictationStarting: Bool { dictationPhase == .starting }
    private var dictationRecording: Bool { dictationPhase == .recording }
    private var dictationStopping: Bool { dictationPhase == .transcribing }
    private var dictating: Bool { dictationPhase != .idle }

    private var expanded: Bool {
        model.mode != .chat || !model.pendingAttachments.isEmpty || !model.pendingImages.isEmpty || model.composerText.contains("\n") || model.composerText.count > 70
    }
    private var empty: Bool {
        model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && model.pendingAttachments.isEmpty && model.pendingImages.isEmpty
    }
    private var answeringAgentQuestion: Bool {
        model.mode == .agent && model.pendingAgentQuestions.contains { $0.conversationID == model.selectedConversationID }
    }

    private func folderItem(_ path: String, title: String) -> some View {
        AIMMenuItem(title, subtitle: abbreviated(path), icon: "folder", checked: path == model.workspacePath) {
            chooseRecentWorkspace(path)
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {

            VStack(spacing: answeringAgentQuestion ? 5 : 12) {
                if model.isImportingAttachment {
                    HStack { ProgressView().controlSize(.small); Text(model.importingAttachmentName.map { "Preparing " + $0 } ?? "Reading attachments…").font(.caption); Spacer(); Button("Cancel") { model.cancelAttachmentImport() }.buttonStyle(.plain).font(.caption) }
                }
                if !model.attachmentImportErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.attachmentImportErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                        Button("Dismiss") { model.attachmentImportErrors = [] }.buttonStyle(.plain).font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                QueuedMessagesView()
                if let pendingDictation, !dictating {
                    DictationRetryBar(engine: dictationEngine, reason: dictationError,
                                      retry: { retryDictation(pendingDictation, with: dictationEngine) },
                                      local: { transcribeLocally(pendingDictation) },
                                      discard: { DictationRecorder.discard(pendingDictation); self.pendingDictation = nil; dictationError = nil })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let dictationError, pendingDictation == nil || dictating {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(dictationError).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button("Dismiss") { self.dictationError = nil }.buttonStyle(.plain).font(.caption)
                    }
                }
                if !model.pendingAttachments.isEmpty || !model.pendingImages.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(model.pendingAttachments) { attachment in
                                AttachmentChip(name: attachment.name, icon: attachment.video == nil ? "doc.text" : "play.fill", data: attachment.video?.frames.first?.jpeg) {
                                    if attachment.video != nil { videoPreview = attachment } else { preview = attachment }
                                } remove: {
                                    model.pendingAttachments.removeAll { $0.id == attachment.id }
                                }
                            }
                            ForEach(model.pendingImages) { image in
                                AttachmentChip(name: image.name, icon: "photo", data: image.data) { imagePreview = image } remove: {
                                    model.pendingImages.removeAll { $0.id == image.id }
                                }
                            }
                        }
                    }
                    if !model.pendingImages.isEmpty,
                       model.availableModels.first(where: { $0.id == model.selectedModelID })?.supportsImageInput == false {
                        Text("The current model catalog lists this model as text-only. Choose a model that can read images before sending.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                ZStack(alignment: .topLeading) {
                  if dictating {
                    DictationWaveform(levels: recorder.levels, transcribing: dictationStopping, starting: dictationStarting,
                                      preparing: LocalDictationModels.shared.preparing.contains(dictationEngine.id))
                        .frame(height: max(36, min(editorHeight, 60)))
                        .transition(.opacity)
                  } else {
                    if model.composerText.isEmpty {
                        Text(placeholder).font(.system(size: 16)).foregroundStyle(.tertiary)
                            .padding(.top, 4).allowsHitTesting(false)
                    }
                    ComposerTextEditor(text: $model.composerText, height: $editorHeight, placeholder: placeholder,
                                       sendWithCommandReturn: model.preferences.sendWithCommandReturn,
                                       smartPunctuation: model.preferences.smartPunctuation) { alternate in
                        guard !dictationStarting, !dictationRecording, !dictationStopping else { return }
                        Task { await model.sendComposer(alternate: alternate) }
                    }.frame(height: answeringAgentQuestion ? min(editorHeight, 32) : editorHeight)
                  }
                }
                HStack(spacing: 6) {
                    attachmentButton
                    // While dictating, only cancel, stop and send stay (as in ChatGPT).
                    if !dictating {
                        Group { modelButton; effortButton }.transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    // In Agent and Code the gauge sits in the gray strip below.
                    if !dictating, model.preferences.showContextGauge, !model.selectedModelID.isEmpty, model.mode == .chat || answeringAgentQuestion { ContextGauge() }
                    dictationButton
                    if model.canSteerActiveMission && !empty {
                        Button { Task { await model.sendComposer() } } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(AIMTheme.background(scheme))
                                .frame(width: 32, height: 32)
                                .background(AIMTheme.foreground(scheme), in: Circle())
                        }
                        .buttonStyle(AIMIconButtonStyle())
                        .aimTooltip("Send correction to running mission")
                        .accessibilityLabel("Send correction to running mission")
                    }
                    sendButton
                }
                .animation(.easeOut(duration: 0.15), value: showsVoice)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: dictating)
            }
            .animation(.easeOut(duration: 0.2), value: pendingDictation)
            .padding(.horizontal, 18)
            .padding(.vertical, answeringAgentQuestion ? 7 : 12)
            .background(scheme == .dark ? AIMTheme.muted(scheme) : .white, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            if model.mode != .chat && !answeringAgentQuestion {
                HStack(spacing: 6) {
                    if model.mode == .agent {
                        let progress = model.agentInstallProgress.values.sorted { $0.engine.rawValue < $1.engine.rawValue }.first
                        ComposerChip(title: progress.map { "Téléchargement \($0.percent) %" } ?? engineTitle(model.selectedAgentEngineID), icon: "sparkles",
                                     showsChevron: true, active: showEngines,
                                     agentEngine: model.selectedAgentEngineID) { showEngines.toggle() }
                            .disabled(model.conversationIsWorking)
                            .aimTooltip(progress?.message ?? "Choisir ou télécharger un agent")
                            .aimMenu(isPresented: $showEngines) {
                                AIMMenuSection("Agent")
                                ForEach(model.engineStatuses.filter { $0.id != .externalStdio || $0.isInstalled }, id: \.id) { status in
                                    AgentEngineMenuRow(status: status, title: engineTitle(status.id))
                                }
                                if model.selectedConversationID != nil {
                                    AIMMenuSection("Nouvelle conversation pour changer d’agent")
                                }
                            }
                    }
                    ComposerChip(title: policyTitle(model.approvalPolicy),
                                 icon: model.approvalPolicy == .plan ? "lightbulb" : "checkmark.shield",
                                 showsChevron: true, active: showPolicies) { showPolicies.toggle() }
                        .disabled(model.conversationIsWorking)
                        .aimMenu(isPresented: $showPolicies) {
                            AIMMenuSection("Permissions")
                            ForEach(ApprovalPolicy.allCases, id: \.self) { policy in
                                AIMMenuItem(policyTitle(policy), subtitle: policySubtitle(policy), icon: policyIcon(policy),
                                            checked: model.approvalPolicy == policy) {
                                    model.approvalPolicy = policy
                                    model.workspacePlanOnly = policy == .plan
                                }
                            }
                            if model.mode == .agent, model.agentMission != nil {
                                AIMMenuDivider()
                                AIMMenuItem("Mission permissions…", subtitle: "Apps and sites the agent may use without asking", icon: "checkmark.shield") {
                                    showPolicies = false; model.showMissionAuthorization = true
                                }
                            }
                        }
                    ComposerChip(title: model.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose folder",
                                 icon: "folder", showsChevron: true, active: showFolders) { showFolders.toggle() }
                        .disabled(model.isLoadingConversation || model.isChangingWorkspace || model.conversationIsWorking)
                        .aimMenu(isPresented: $showFolders) {
                            let projectFolders = projectWorkspaces.filter(\.writeAccessGranted)
                            if !projectFolders.isEmpty {
                                AIMMenuSection("Project folders")
                                ForEach(projectFolders) { source in folderItem(source.canonicalPath, title: source.displayName) }
                            }
                            if !model.recentWorkspacePaths.isEmpty {
                                AIMMenuSection("Recent folders")
                                ForEach(model.recentWorkspacePaths.prefix(6), id: \.self) { path in
                                    folderItem(path, title: URL(fileURLWithPath: path).lastPathComponent)
                                }
                            }
                            if !projectFolders.isEmpty || !model.recentWorkspacePaths.isEmpty { AIMMenuDivider() }
                            AIMMenuItem("Choose another folder…", icon: "folder.badge.plus") { chooseWorkspace() }
                            if let path = model.workspacePath {
                                AIMMenuItem("Open in \(FileOpenDestination.name(model.preferences.fileOpenApp))", icon: "arrow.up.forward.app") {
                                    FileOpenDestination.open(URL(fileURLWithPath: path, isDirectory: true), with: model.preferences.fileOpenApp)
                                }
                            }
                        }
                    Spacer(minLength: 0)
                    if let gitBranch, model.mode == .code {
                        ComposerChip(title: gitBranch, icon: "arrow.triangle.branch", showsChevron: false, active: false) {
                            showWorktrees = true
                        }
                        .aimTooltip("Choose Git worktree")
                    }
                    if model.preferences.showContextGauge, !model.selectedModelID.isEmpty { ContextGauge() }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(model.mode == .chat || answeringAgentQuestion ? AIMTheme.background(scheme) : AIMTheme.muted(scheme), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        // Chat ↔ Agent: the gray strip slides in and out instead of the bar jumping.
        .animation(.snappy(duration: 0.28), value: model.mode)
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.primary.opacity(dropTargeted && model.canImportAttachments ? 0.45 : 0.07), lineWidth: dropTargeted && model.canImportAttachments ? 2 : 0.7))
        .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.045), radius: 14, y: 3)
        // Always its natural height: the parent must never squeeze the button row.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: model.preferences.fullWidthConversations ? .infinity : 760)
        .frame(maxWidth: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canImportAttachments, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            let context = model.attachmentImportContext
            Task { await model.importAttachments(urls, context: context) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: Binding(get: { model.pendingVisualApproval }, set: { model.pendingVisualApproval = $0 })) { pending in MacVisualApprovalView(pending: pending).environment(model) }
        .sheet(item: $preview) { TextAttachmentPreview(attachment: $0) }
        .sheet(item: $imagePreview) { ImageAttachmentPreview(attachment: $0) }
        .sheet(item: Binding(get: { model.pendingVideoImport }, set: { model.pendingVideoImport = $0 })) { pending in
            MacVideoPreparationChoice(name: pending.urls.first(where: { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) })?.lastPathComponent ?? "Video") { options in
                model.pendingVideoImport = nil
                if let options { Task { await model.importAttachments(pending.urls, context: pending.context, videoOptions: options) } }
            }
        }
        .sheet(item: $videoPreview) { attachment in
            if let video = attachment.video { MacPreparedVideoPreview(attachment: attachment, video: video) }
        }
        .sheet(isPresented: Binding(get: { model.showMediaCreator }, set: { model.showMediaCreator = $0 })) { ImageGenerationView() }
        .sheet(isPresented: $showWorktrees) {
            if let workspace = model.workspacePath { GitWorktreeView(workspace: workspace) }
        }
        .onChange(of: model.dictationContext) { _, _ in cancelDictation() }
        #if DEBUG
        .onChange(of: model.debugDictation) { _, state in
            switch state {
            case "recording", "transcribing":
                recorder.debugShow(levels: Self.galleryLevels)
                dictationPhase = state == "recording" ? .recording : .transcribing
            case "retry":
                dictationPhase = .idle
                pendingDictation = URL(fileURLWithPath: "/tmp/gallery-dictation.m4a")
                dictationError = "The Internet connection appears to be offline."
            case "menu": showDictationMenu = true
            default:
                showDictationMenu = false; dictationPhase = .idle; pendingDictation = nil; dictationError = nil
            }
        }
        .onChange(of: model.debugOpenMenu) { _, menu in
            showPolicies = menu == "policies"; showFolders = menu == "folders"; showAddMenu = menu == "add"
            showEffort = menu == "effort"
        }
        #endif
        .onChange(of: model.conversationIsWorking) { _, sending in if sending { cancelDictation() } }
        .onChange(of: model.dictationRequestID) { _, _ in
            if dictationRecording { finishDictation(send: false) } else if !dictating { startDictation() }
        }
        .onChange(of: model.attachmentPickerRequestID) { _, _ in
            if model.canImportAttachments { chooseAttachments() }
        }
        .onDisappear { cancelDictation() }
        .onAppear {
            dictationEngine = DictationEngine.effective(hasOpenAIKey: model.connectedProviders.contains(.openAI))
            // Load an on-device model early: its first load on a Mac can take a minute.
            if dictationEngine.isLocalModel { LocalDictationModels.shared.prepare(dictationEngine) }
            if pendingDictation == nil { pendingDictation = DictationRecorder.pending().first }
        }
        .task(id: "\(model.selectedProjectID?.uuidString ?? ""):\(model.projectSourceRevision)") {
            if let projectID = model.selectedProjectID {
                projectWorkspaces = (try? await model.sources(for: projectID)) ?? []
            } else { projectWorkspaces = [] }
        }
        .task(id: model.workspacePath ?? "") {
            gitBranch = nil
            guard let workspace = model.workspacePath else { return }
            let service = GitWorktreeService()
            guard let entries = try? await service.list(workspace: workspace),
                  let current = entries.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == workspace }),
                  let branch = current.branch else { return }
            gitBranch = branch.replacingOccurrences(of: "refs/heads/", with: "")
        }
    }

    private func engineTitle(_ id: AgentEngineID) -> String {
        switch id {
        case .aim: "AIM Agent"
        case .openClaw: "OpenClaw"
        case .hermes: "Hermes"
        case .externalStdio: "External adapter"
        }
    }

    private var attachmentButton: some View {
        Button { if dictating { cancelDictation() } else { showAddMenu.toggle() } } label: {
            // "+" turns into "×" (a 45° turn) to cancel a dictation.
            Image(systemName: "plus").font(.system(size: 17))
                .rotationEffect(.degrees(dictating ? 45 : 0))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.aimHover(radius: 9, active: showAddMenu || showDictationMenu))
        .aimTooltip(dictating ? "Cancel dictation" : "Add files and more", shortcut: dictating ? nil : "⇧⌘A")
        .accessibilityLabel(dictating ? "Cancel dictation" : "Add attachment or create media")
        .aimMenu(isPresented: $showDictationMenu, maxWidth: 440) {
            DictationSettingsMenu(selected: $dictationEngine, hasOpenAIKey: model.connectedProviders.contains(.openAI))
        }
        .aimMenu(isPresented: $showAddMenu) {
            AIMMenuItem("Attach files or images", icon: "paperclip", shortcut: "⇧⌘A", action: chooseAttachments)
                .disabled(!model.canImportAttachments)
            if model.mode == .chat {
                AIMMenuItem("Create an image or video", icon: "sparkles.rectangle.stack") { model.openMediaCreator() }
                    .disabled(model.conversationIsWorking || model.isGeneratingImage || model.isShuttingDown)
            }
            AIMMenuDivider()
            AIMMenuItem("Dictation settings", subtitle: DictationSettingsMenu.title(dictationEngine), icon: "waveform", shortcut: "›") {
                // Opens in place of this menu, anchored on the same button.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { showDictationMenu = true }
            }
        }
    }

    /// How the selected model is reached: plan usage or API billing.
    private var routeLabel: String {
        switch model.selectedProvider {
        case .chatgpt: "via ChatGPT plan"
        case .openRouter: "via OpenRouter"
        case .local: "on this Mac"
        default: "via \(model.selectedProvider.name) API key"
        }
    }

    private var modelButton: some View {
        Button { model.showModelPicker = true } label: {
            HStack(spacing: 5) {
                if model.selectedModelID.isEmpty {
                    Image(systemName: "cube").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 19, height: 19)
                    Text("Add models").lineLimit(1)
                } else {
                    let presentation = model.selectedModelPresentation
                    ModelCreatorLogo(creator: presentation.creator, size: 19)
                    Text(presentation.name).lineLimit(1)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(AIMIconButtonStyle())
        .aimTooltip(model.selectedModelID.isEmpty ? "Choose model" : "Choose model · \(routeLabel)", shortcut: "⇧⌘M").accessibilityIdentifier("model-picker")
        .disabled(model.isLoadingConversation)
    }

    private var dictationButton: some View {
        Group {
            if dictationRecording {
                // Stop: the text goes into the bar for review.
                Button { finishDictation(send: false) } label: {
                    RoundedRectangle(cornerRadius: 2.5).fill(AIMTheme.foreground(scheme)).frame(width: 11, height: 11)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                }
                .accessibilityLabel("Stop dictation and review the text")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if dictationStopping || dictationStarting {
                ProgressView().controlSize(.small).frame(width: 30, height: 30)
            } else {
                Button(action: startDictation) {
                    Image(systemName: "mic").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 28, height: 32)
                }
                .accessibilityLabel("Dictate")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .buttonStyle(AIMIconButtonStyle())
        .disabled(model.conversationIsWorking || model.isLoadingConversation || model.isBootstrapping || model.isShuttingDown || model.isImportingAttachment || model.responseSaveError != nil)
        .aimTooltip(dictationRecording ? "Stop and review" : "Dictate · \(DictationSettingsMenu.title(dictationEngine))")
    }

    @ViewBuilder private var effortButton: some View {
        if !model.selectedModelID.isEmpty,
           OpenAIReasoningEffort.offered(provider: model.selectedProvider, modelID: model.selectedModelID,
               openRouterParameters: model.availableModels.first(where: { $0.id == model.selectedModelID })?.supportedParameters) {
            Button { showEffort.toggle() } label: {
                Text(model.effectiveReasoningEffort?.label(provider: model.selectedProvider) ?? "Default")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).frame(height: 30)
            }.buttonStyle(.aimHover(radius: 9, active: showEffort)).aimTooltip("Reasoning effort")
                .aimMenu(isPresented: $showEffort, maxWidth: 520) {
                    OpenAIReasoningSettingsView(modelID: model.selectedModelID).padding(8)
                        .frame(width: CGFloat(max(300, 74 * OpenAIReasoningEffort.levels(provider: model.selectedProvider, modelID: model.selectedModelID,
                            info: model.modelInfo(provider: model.selectedProvider, modelID: model.selectedModelID)?.reasoning).count)))
                }
        } else if model.selectedProvider == .local, model.builtInModelFile(model.selectedModelID) != nil {
            // No thinking switch for this local model: its settings take the effort button's place.
            Button { model.openLocalModelSettings() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.aimHover(radius: 9)).aimTooltip("Model settings").accessibilityLabel("Model settings")
        }
    }

    private func policySubtitle(_ policy: ApprovalPolicy) -> String {
        switch policy {
        case .alwaysAsk: "Asks before every action."
        case .smart: "Reads freely, asks before changing anything."
        case .autoApprove: "Edits the folder and runs verified reads; other commands still ask."
        case .plan: "Looks and plans, changes nothing."
        }
    }

    private func policyIcon(_ policy: ApprovalPolicy) -> String {
        switch policy {
        case .alwaysAsk: "hand.raised"
        case .smart: "checkmark.shield"
        case .autoApprove: "bolt"
        case .plan: "lightbulb"
        }
    }

    private func policyTitle(_ policy: ApprovalPolicy) -> String {
        switch policy {
        case .plan: "Plan · read only"
        case .alwaysAsk: "Always ask"
        case .smart: "Smart"
        case .autoApprove: "Auto"
        }
    }

    private func startDictation() {
        if DictationLanguage.detected == nil, let written = model.messages.last(where: { $0.role == .user })?.content {
            DictationLanguage.learn(from: written)
        }
        let engine = DictationEngine.effective(hasOpenAIKey: model.connectedProviders.contains(.openAI))
        dictationEngine = engine
        switch DictationAvailability.check(engine, hasOpenAIKey: model.connectedProviders.contains(.openAI),
                                           isDownloaded: LocalDictationModels.shared.isReady) {
        case .ready: break
        case .needsOpenAIKey:
            dictationError = "Add an OpenAI API key in Settings → Providers, or choose another engine in Dictation settings."
            showDictationMenu = true
            return
        case .needsDownload:
            dictationError = "Download this model first in Dictation settings."
            showDictationMenu = true
            return
        }
        let context = model.dictationContext
        let runID = UUID()
        dictationRunID = runID
        dictationError = nil
        dictationPhase = .starting
        dictationTask = Task {
            do {
                try await recorder.start()
                guard model.dictationContext == context, dictationRunID == runID else { recorder.cancel(); return }
                dictationPhase = .recording
            } catch is CancellationError {
            } catch {
                if dictationRunID == runID { dictationError = error.localizedDescription; dictationPhase = .idle }
            }
            if dictationRunID == runID { dictationTask = nil }
        }
    }

    /// Stop: transcribe, then either put the text in the bar or send it at once.
    private func finishDictation(send: Bool) {
        let url: URL
        do { url = try recorder.stop() }
        catch { dictationError = error.localizedDescription; dictationPhase = .idle; return }
        transcribe(url, with: dictationEngine, send: send)
    }

    /// With a downloaded model, transcribe offline; otherwise open the downloads.
    private func transcribeLocally(_ url: URL) {
        if let local = LocalDictationModels.shared.installed.first { retryDictation(url, with: local.engine) }
        else { showDictationMenu = true }
    }

    private func retryDictation(_ url: URL, with engine: DictationEngine) {
        pendingDictation = nil
        transcribe(url, with: engine, send: false)
    }

    private func transcribe(_ url: URL, with engine: DictationEngine, send: Bool) {
        let context = model.dictationContext
        let runID = UUID()
        dictationRunID = runID
        dictationError = nil
        dictationPhase = .transcribing
        dictationTask = Task {
            do {
                let text: String
                switch engine {
                case .apple: text = try await AppleFileDictation.transcribe(url)
                case .openAI: text = try await model.transcribeWithOpenAI(Data(contentsOf: url), language: DictationLanguage.code())
                case .whisper, .parakeet: text = try await LocalDictationModels.shared.transcribe(url, with: engine)
                }
                guard dictationRunID == runID, !Task.isCancelled else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalDictationError.noSpeech }
                // The audio is deleted only once its text is safe.
                DictationRecorder.discard(url)
                dictationPhase = .idle
                guard model.dictationContext == context else { return }
                insertTranscript(text)
                if send { await model.sendComposer() }
            } catch is CancellationError {
                if dictationRunID == runID { pendingDictation = url; dictationPhase = .idle }
            } catch {
                guard dictationRunID == runID else { return }
                pendingDictation = url
                dictationError = error.localizedDescription
                dictationPhase = .idle
            }
            if dictationRunID == runID { dictationTask = nil }
        }
    }

    private func insertTranscript(_ text: String) {
        model.composerText = DictationText.appending(text, to: model.composerText)
        dictationError = nil
    }

    private func cancelDictation() {
        dictationRunID = UUID()
        dictationTask?.cancel(); dictationTask = nil
        // A recording still being transcribed is kept for Retry; one in progress is dropped.
        if dictationRecording || dictationStarting { recorder.cancel() }
        dictationPhase = .idle
    }

    /// Empty composer: the button starts a spoken conversation with AIM. As soon as there is
    /// something to send it becomes Send, and Stop while a response is streaming.
    private var showsVoice: Bool {
        model.voiceSession != nil || (empty && !model.conversationIsWorking && !dictating)
    }

    @ViewBuilder private var sendButton: some View {
        if showsVoice {
            Button { Task { await model.toggleVoiceConversation() } } label: {
                Image(systemName: model.voiceSession == nil ? "waveform" : "stop.fill")
                    .font(.system(size: model.voiceSession == nil ? 15 : 12, weight: .semibold))
                    .foregroundStyle(model.voiceSession == nil ? AIMTheme.background(scheme) : .white)
                    .frame(width: 32, height: 32)
                    .background(model.voiceSession == nil ? AIMTheme.foreground(scheme) : Color.red, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBootstrapping || dictationStarting || dictationRecording || dictationStopping)
            .aimTooltip(model.voiceSession == nil ? "Talk with AIM" : "End voice conversation")
            .accessibilityLabel(model.voiceSession == nil ? "Talk with AIM" : "End voice conversation")
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else {
            Button {
                // While dictating: stop, transcribe, then send automatically.
                if dictationRecording { finishDictation(send: true); return }
                Task {
                    if model.conversationIsWorking { await model.cancelCurrentTurn() }
                    else { await model.sendComposer() }
                }
            } label: {
                Image(systemName: model.conversationIsWorking ? "stop.fill" : "arrow.up")
                    .font(.system(size: model.conversationIsWorking ? 12 : 16, weight: .semibold))
                    .foregroundStyle(AIMTheme.background(scheme))
                    .frame(width: 32, height: 32)
                    .background(AIMTheme.foreground(scheme), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBootstrapping || dictationStarting || dictationStopping || (!model.conversationIsWorking && !dictationRecording && (empty || model.isLoadingConversation || model.isImportingAttachment || model.isImportingProjectDocument || model.responseSaveError != nil)))
            .aimTooltip(model.conversationIsWorking ? "Stop response" : (dictationRecording ? "Stop dictation and send" : "Send message"))
            .accessibilityLabel(model.conversationIsWorking ? "Stop response" : (dictationRecording ? "Stop dictation and send" : "Send message"))
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    private func chooseWorkspace() {
        let conversationID = model.selectedConversationID
        let mode = model.mode
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Workspace"
        if let current = model.workspacePath, FileManager.default.fileExists(atPath: current) {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard model.selectedConversationID == conversationID, model.mode == mode else { return }
            Task {
                guard model.selectedConversationID == conversationID, model.mode == mode else { return }
                await model.chooseWorkspace(url.path)
            }
        }
    }

    private func chooseRecentWorkspace(_ path: String) {
        let conversationID = model.selectedConversationID
        let mode = model.mode
        Task {
            guard model.selectedConversationID == conversationID, model.mode == mode else { return }
            await model.chooseWorkspace(path)
        }
    }

    private func chooseAttachments() {
        guard model.canImportAttachments else { return }
        let context = model.attachmentImportContext
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Source files often have custom extensions. Content validation is performed
        // by the importer, not by a type filter that can disable legitimate files.
        panel.allowsOtherFileTypes = true
        panel.prompt = "Attach"
        panel.message = "Choose up to 4 documents, images or videos. Preparation stays on this Mac until you send."
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await model.importAttachments(urls, context: context) }
        }
    }
}

struct ImageAttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let attachment: ImageAttachment
    @State private var showSave = false
    @State private var saveError: String?
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(attachment.name, systemImage: "photo").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let image = NSImage(data: attachment.data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("\(attachment.data.count) bytes · saved image snapshot")
                .font(.caption).foregroundStyle(.secondary)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Save image…") { showSave = true }
                Spacer()
                Button("Use as chat attachment") {
                    model.reuseImageInComposer(attachment)
                    dismiss()
                }
                .disabled(!model.canImportAttachments)
            }
        }.padding(24).frame(width: 680, height: 540)
            .fileExporter(isPresented: $showSave,
                          document: ImageExportDocument(data: attachment.data, mimeType: attachment.mimeType),
                          contentType: attachment.mimeType == "image/png" ? .png : .jpeg,
                          defaultFilename: (attachment.name as NSString).deletingPathExtension) { result in
                if case .failure = result { saveError = "The image could not be saved. Choose a writable location and try again." }
            }
    }
}

struct ImageExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .jpeg] }
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        mimeType = configuration.contentType == .png ? "image/png" : "image/jpeg"
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct TextAttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: TextAttachment
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(attachment.name, systemImage: "doc.text").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(attachment.content.utf8.count) bytes · saved text snapshot").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(attachment.content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(24).frame(width: 620, height: 440)
    }
}

/// A pill under the Agent composer (agent, permissions, folder).
private struct ComposerChip: View {
    let title: String
    let icon: String
    let showsChevron: Bool
    let active: Bool
    var agentEngine: AgentEngineID? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let agentEngine {
                    AgentEngineLogo(engine: agentEngine, size: 16)
                } else {
                    Image(systemName: icon).font(.system(size: 11.5))
                }
                Text(title).lineLimit(1)
                if showsChevron { Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(AIMTheme.menuSurface(scheme), in: Capsule())
            .overlay(Capsule().strokeBorder(AIMTheme.cardBorder(scheme)))
        }
        .buttonStyle(.aimHover(radius: 14, active: active))
        .fixedSize()
    }
}

/// A file or image waiting to be sent: open it, or remove it with the small cross.
private struct AttachmentChip: View {
    let name: String
    let icon: String
    var data: Data? = nil
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                ZStack {
                    if let data, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 100, height: 100).clipped()
                    } else {
                        VStack(spacing: 6) { Image(systemName: icon).font(.title2); Text(name).font(.caption).lineLimit(2) }
                            .padding(8).frame(width: 100, height: 100)
                    }
                    if icon == "play.fill" { Image(systemName: icon).font(.title).foregroundStyle(.white).shadow(radius: 3) }
                }.clipShape(RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityLabel("Open \(name)")
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.7)).frame(width: 30, height: 30)
            }.buttonStyle(.plain).accessibilityLabel("Remove \(name)")
        }.background(AIMTheme.menuSurface(scheme), in: RoundedRectangle(cornerRadius: 14))

    }
}

/// Messages typed while a turn runs (Follow-up: Queue), sent one by one after it.
private struct QueuedMessagesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let target = model.activeTurnConversationID ?? model.selectedConversationID
        let queued = model.queuedMessages.filter { $0.conversationID == target }
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(queued) { item in row(item) }
            }
        }
    }

    private func row(_ item: AppModel.QueuedMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(item.text.isEmpty ? "Attachments" : item.text).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 6)
            Text("Sends after this turn").font(.system(size: 11)).foregroundStyle(.tertiary)
            Button { model.removeQueuedMessage(item.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.aimHover(radius: 6)).aimTooltip("Remove from the queue")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MacVideoPreparationChoice: View {
    let name: String
    let choose: (VideoPreparationOptions?) -> Void
    @State private var mode: PreparedVideoAttachment.Mode = .automatic
    @State private var start = "0"
    @State private var end = "10"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(name).font(.headline)
            Picker("Analysis", selection: $mode) {
                Text("Automatic").tag(PreparedVideoAttachment.Mode.automatic)
                Text("Detailed").tag(PreparedVideoAttachment.Mode.detailed)
                Text("Excerpt").tag(PreparedVideoAttachment.Mode.excerpt)
            }.pickerStyle(.segmented)
            if mode == .excerpt { HStack { TextField("Start (seconds)", text: $start); TextField("End (seconds)", text: $end) } }
            Text("Preparation is local. Images preserve their decoded timestamps. Events between samples may be missed. Local transcription depends on the speech engine; no paid transcription starts here.").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel", role: .cancel) { choose(nil) }; Button("Prepare") { choose(.init(mode: mode, start: Double(start), end: Double(end))) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480)
    }
}

private struct MacVisualApprovalView: View {
    @Environment(AppModel.self) private var model
    let pending: AppModel.PendingMacVisualApproval
    @State private var provider: ChatProvider = .openRouter
    @State private var models: [ChatModel] = []
    @State private var modelID = ""
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Visual analysis").font(.title2)
            Text("The main model stays " + pending.primaryModel + ". Choose a visual analyst on this Mac.")
            Picker("Provider", selection: $provider) {
                ForEach(ChatProvider.allCases.filter { model.connectedProviders.contains($0) }, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Visual model", selection: $modelID) {
                Text("Choose model").tag("")
                ForEach(models.filter { $0.supportsImageInput == true }) { Text($0.name).tag($0.id) }
            }
            Text("Provider charges apply unless the selected model runs locally. Media cost has no verified upper bound here; the existing budget must admit each request. The selected provider, model and Mac never change automatically.").font(.callout).foregroundStyle(.secondary)
            if let alert = model.alertMessage { Text(alert).foregroundStyle(.red) }
            if model.isAnalysingVisualInput { ProgressView("Analysing media…") }
            HStack {
                Button("Refuse", role: .cancel) { task?.cancel(); model.pendingVisualApproval = nil }
                Spacer()
                Button("Authorize once") { run(false) }.disabled(modelID.isEmpty || model.isAnalysingVisualInput)
                Button("Always authorize") { run(true) }.disabled(modelID.isEmpty || model.isAnalysingVisualInput)
            }
        }.padding(24).frame(width: 560)
        .interactiveDismissDisabled(model.isAnalysingVisualInput)
        .task(id: provider) { modelID = ""; do { models = try await model.catalog(for: provider) } catch { model.alertMessage = error.localizedDescription } }
        .onAppear { if !model.connectedProviders.contains(provider), let first = ChatProvider.allCases.first(where: { model.connectedProviders.contains($0) }) { provider = first } }
        .onDisappear { task?.cancel() }
    }
    private func run(_ remember: Bool) { task = Task { _ = await model.analyseVisualInput(pending, choice: .init(provider: provider, modelID: modelID), remember: remember) } }
}
