import AIMCore
import SwiftUI
import UIKit

struct AIMNewRemoteSessionView: View {
    @State private var showingConnectionStatus = false
    @State private var creationError: String?
    let mode: RemoteMode
    let store: MainExperienceStore
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let focusRequest: Int
    let selectMode: (RemoteMode) -> Void
    let cancel: () -> Void
    let openPersonalization: () -> Void

    @State private var panel: SelectionPanel?

    private enum SelectionPanel: String, Identifiable {
        case folder
        case engine
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                GeometryReader { available in
                    ScrollView {
                        VStack(spacing: 16) {
                            Spacer(minLength: 0)

                            Text(mode == .code ? "remote.new.code_title" : "remote.new.agent_title")
                                .font(AIMDesign.titleFont(size: 34))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 520)

                            if store.offersWorkerPlacement {
                                AIMWorkerPlacementControl(store: store).padding(.horizontal, 24)
                            }

                            ForEach(store.queuedMessages.filter { $0.creation?.mode == mode }) { entry in
                                VStack(spacing: 8) {
                                    Text(entry.state == "review" ? "Delivery needs review. It will not be retried automatically." : "Will send when the selected Mac reconnects.").font(.footnote)
                                    Text(entry.text).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                                    Button("Cancel pending message") { store.removeQueuedMessage(entry.id) }
                                }.padding(.horizontal, 24)
                            }
                            if let error = creationError ?? store.errorMessage {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: available.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }

                contextChips
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                AIMConversationComposer(
                    text: creationText,
                    attachments: creationAttachments,
                    modelName: selectedModelName,
                    modelID: store.selectedModelID,
                    capabilities: store.selectedMachine?.capabilities,
                    mode: mode,
                    approvalMode: store.selectedApprovalMode,
                    attachmentsEnabled: RemoteAttachmentRules.availableAtCreation(
                        capabilities: store.selectedMachine?.capabilities,
                        mode: mode
                    ),
                    enabled: true,
                    sendEnabled: true,
                    loading: store.isSending,
                    sessionRunning: false,
                    expandedAtRest: true,
                    focusRequest: focusRequest,
                    safeBottom: safeBottom,
                    openPersonalization: openPersonalization,
                    send: { text, attachments in
                        guard store.selectedMachine?.isOnline() == true,
                              store.selectedMachine.map({ !store.isRemoteSuspended(machineID: $0.id) }) == true,
                              selectedMachineHealth == .responsive else {
                            AIMHaptics.error()
                            showingConnectionStatus = true
                            return false
                        }
                        guard canCompose else {
                            AIMHaptics.error()
                            creationError = creationUnavailableReason
                            return false
                        }
                        creationError = nil
                        return await store.createRemoteSession(text: text, attachments: attachments)
                    },
                    uploadAttachment: { data, name, mimeType, options in
                        await store.uploadNewSessionAttachment(data: data, name: name, mimeType: mimeType, options: options)
                    },
                    changeModel: { modelID, effort in
                        store.selectedModelID = modelID
                        store.selectedEffort = effort
                        return true
                    },
                    changeApprovalMode: { approvalMode in
                        store.selectedApprovalMode = approvalMode
                        return true
                    },
                    sendGoal: { goal, maximumTurns, attachments in
                        await store.createRemoteSession(
                            text: goal,
                            attachments: attachments,
                            goalMaximumTurns: maximumTurns
                        )
                    },
                    stop: { false },
                    changeModelSelection: { model, effort in
                        guard store.selectedMachine?.capabilities?.models.contains(where: { $0.id == model.id && $0.provider == model.provider }) == true else { return false }
                        store.selectModel(model)
                        store.selectedEffort = effort
                        return true
                    },
                    modelProvider: store.selectedModelProvider, remoteStore: store, agentID: mode == .agent ? store.selectedAgentSystem : nil
                )
                .layoutPriority(1)
            }

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("new-\(mode.rawValue)-screen")
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            if store.remoteFolders.isEmpty { await store.loadFolders() }
        }
        .sheet(item: $panel) { selection in
            switch selection {
            case .folder:
                AIMRemoteFolderSheet(store: store) { path in
                    store.authorizeWorkerWorkspace(path)
                    panel = nil
                }
            case .engine:
                AIMRemoteEngineSheet(
                    engines: availableEngines,
                    selectedID: store.selectedAgentSystem,
                    store: store
                ) { engine in
                    store.selectedAgentSystem = engine.id.rawValue
                    panel = nil
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: cancel) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .focusable(false)
            Spacer()
            AIMCreationModeSelector(selection: mode, select: selectMode)
            Spacer()
            Button { showingConnectionStatus.toggle() } label: {
                Circle().fill(connectionStatusColor)
                    .frame(width: 8, height: 8)
                    .frame(width: AIMDesign.standardTouchTarget, height: AIMDesign.standardTouchTarget)
                    .aimGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Status")
            .accessibilityIdentifier("new-remote-header-status")
            .popover(isPresented: $showingConnectionStatus) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(connectionStatusText)
                    machinePicker
                    Button("Retry") { Task { await store.load(); await store.probeSelectedRemoteHealth() } }
                    if !creationText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !creationAttachments.wrappedValue.isEmpty {
                        Button("Send when reconnected") {
                            if store.queueCreation() { showingConnectionStatus = false }
                        }.disabled(store.selectedWorkspace == nil || store.selectedMachine == nil)
                    }
                }.padding(20).frame(width: 286).presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, safeTop + 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var machinePicker: some View {
        if store.overview.machines.count > 1 || store.selectedMachine == nil {
            Menu {
                ForEach(store.overview.machines) { machine in
                    Button {
                        Task { await store.selectMachine(id: machine.id) }
                    } label: {
                        Label(machine.name, systemImage: store.selectedMachine?.id == machine.id ? "checkmark" : "desktopcomputer")
                    }
                }
            } label: {
                machineLabel(showsChevron: true)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityIdentifier("new-remote-computer-selection")
        } else {
            machineLabel(showsChevron: false)
        }
    }

    private func machineLabel(showsChevron: Bool) -> some View {
        return HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
            Text(store.selectedMachineDisplayName ?? String(localized: "remote.new.choose_computer"))
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .frame(height: 38)
        .contentShape(Capsule())
    }

    private var connectionStatusColor: Color {
        switch store.computerState {
        case .available: machineStatusColor(selectedMachineHealth)
        case .loading, .chooseComputer, .selectionUnavailable, .synchronizing, .noModels: .orange
        default: .red
        }
    }

    private var connectionStatusText: LocalizedStringKey {
        switch store.computerState {
        case .loading: "main.loading"
        case .unpaired: "remote.new.not_paired"
        case .needsRepair: "remote.new.needs_repair"
        case .noComputer: "remote.new.no_computer"
        case .chooseComputer: "remote.new.choose_computer"
        case .selectionUnavailable: "remote.new.selection_unavailable"
        case .offline: "remote.new.offline"
        case .suspended: "remote.connection.suspended"
        case .synchronizing: "remote.new.synchronizing"
        case let .readFailure(_, key): LocalizedStringKey(key)
        case .noModels: "remote.new.models_pending"
        case .incompatible: "remote.error.incompatible_version"
        case .unavailable: "main.error.load"
        case .available:
            switch selectedMachineHealth {
            case .responsive: "remote.conversation.online"
            case .unknown, .checking: "remote.new.checking_bridge"
            case .unresponsive: "remote.error.bridge_unresponsive"
            case .incompatible: "remote.error.incompatible_version"
            }
        }
    }

    private func machineStatusColor(_ health: RemoteCommandHealth) -> Color {
        guard store.selectedMachine?.isOnline() == true else { return .red }
        return switch health {
        case .responsive: .green
        case .unknown, .checking: .orange
        case .unresponsive, .incompatible: .red
        }
    }

    private var contextChips: some View {
        HStack(spacing: 10) {
            Button { panel = .folder } label: {
                chipLabel(selectedFolderName, icon: "folder", emphasized: store.selectedWorkspace == nil)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityIdentifier("new-remote-folder-button")

            if mode == .agent {
                Button { panel = .engine } label: {
                    HStack(spacing: 9) {
                        AIMAgentLogo(id: store.selectedAgentSystem ?? "aim")
                        Text(selectedEngineName).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption)
                    }.padding(.horizontal, 15).frame(height: AIMDesign.contextChipHeight).aimGlassCapsule()
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityIdentifier("new-remote-engine-button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipLabel(_ title: String, icon: String, emphasized: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
            Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 15)
        .frame(height: AIMDesign.contextChipHeight)
        .aimGlassCapsule()
    }

    private var availableModels: [RemoteModelAnnouncement] {
        store.selectedMachine?.capabilities?.models ?? []
    }

    private var availableEngines: [RemoteEngine] {
        RemoteEngineRules.engines(capabilities: store.selectedMachine?.capabilities)
    }

    private var selectedFolderName: String {
        guard let path = store.selectedWorkspace else { return String(localized: "remote.new.folder") }
        return store.remoteFolders.first(where: { $0.path == path })?.name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private var selectedModelName: String {
        availableModels.first(where: { $0.id == store.selectedModelID && (store.selectedModelProvider == nil || $0.provider == store.selectedModelProvider) })?.name
            ?? AIMModelNamePresentation.displayName(for: store.selectedModelID)
    }

    private var selectedEngineName: String {
        guard let selected = store.selectedAgentSystem else { return "Agent" }
        return availableEngines.first(where: { $0.id.rawValue == selected })?.name ?? selected
    }

    private var canCompose: Bool {
        guard store.selectedMachine?.isOnline() == true, store.selectedWorkspace != nil else { return false }
        guard availableModels.contains(where: { $0.id == store.selectedModelID }) else { return false }
        if mode == .agent {
            guard let id = store.selectedAgentSystem, availableEngines.first(where: { $0.id.rawValue == id })?.selectable == true else { return false }
            if id != "aim" { return store.selectedModelProvider == "openrouter" || store.selectedModelProvider == "openRouter" }
        }
        return true
    }

    private var creationUnavailableReason: String {
        if store.selectedWorkspace == nil { return "Choose a folder on the selected Mac before sending." }
        if !availableModels.contains(where: { $0.id == store.selectedModelID }) { return "The selected model is unavailable on this Mac. Choose a compatible model." }
        if mode == .agent {
            if availableEngines.first(where: { $0.id.rawValue == store.selectedAgentSystem })?.selectable != true { return "The selected agent is unavailable on this Mac. Open Agent to install it or review its status." }
            if store.selectedAgentSystem != "aim", store.selectedModelProvider?.lowercased() != "openrouter" { return "This agent requires an OpenRouter model and credentials on the selected Mac." }
        }
        return "The selected Mac is not ready for this conversation. Your draft is preserved."
    }

    private var selectedMachineHealth: RemoteCommandHealth {
        guard let machineID = store.selectedMachine?.id else { return .unresponsive }
        return store.commandHealth(for: machineID)
    }

    private var creationText: Binding<String> {
        Binding(
            get: { store.creationDraft(for: mode).text },
            set: { value in
                var draft = store.creationDraft(for: mode)
                draft.text = value
                store.updateCreationDraft(draft, for: mode)
            }
        )
    }

    private var creationAttachments: Binding<[RemoteAttachmentReference]> {
        Binding(
            get: { store.creationDraft(for: mode).attachments },
            set: { value in
                var draft = store.creationDraft(for: mode)
                draft.attachments = value
                store.updateCreationDraft(draft, for: mode)
            }
        )
    }
}

private struct AIMRemoteFolderSheet: View {
    let store: MainExperienceStore
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 7) {
                if store.isLoadingFolders { ProgressView().controlSize(.small) }
                Text(store.currentFolderPath ?? copy("Folders already open on your computer", "Dossiers déjà ouverts sur votre ordinateur"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if store.currentFolderPath != nil {
                    Button { newFolderName = ""; showingCreateFolder = true } label: {
                        Image(systemName: "folder.badge.plus").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain).aimGlassCircle()
                    .accessibilityLabel(Text(copy("Create a folder", "Créer un dossier")))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 3) {
                    if store.currentFolderPath != nil {
                        Button { Task { await store.loadFolders(path: nil) } } label: {
                            Label(copy("Back to starting folders", "Revenir aux dossiers de départ"), systemImage: "arrow.left")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(store.remoteFolders) { folder in
                        HStack(spacing: 7) {
                            Button { Task { await store.loadFolders(path: folder.path) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder")
                                        .frame(width: 34, height: 34)
                                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.name).lineLimit(1)
                                        if store.currentFolderPath == nil {
                                            Text(folder.path)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button { select(folder.path) } label: {
                                Label(copy("Choose", "Choisir"), systemImage: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .frame(height: 36)
                                    .background(Color.primary, in: Capsule())
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 58)
                    }

                    if !store.isLoadingFolders && store.remoteFolders.isEmpty {
                        ContentUnavailableView(copy("No folder available", "Aucun dossier disponible"), systemImage: "folder")
                            .padding(.top, 36)
                    }
                    if let reference = store.lastRemoteDiagnosticReference, store.errorMessage != nil {
                        Text(reference)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .aimUniversalPanelSurface()
        .presentationDetents([.fraction(0.56), .large])
        .presentationDragIndicator(.visible)
        .task { if store.remoteFolders.isEmpty { await store.loadFolders() } }
        .alert(copy("Create a folder", "Créer un dossier"), isPresented: $showingCreateFolder) {
            TextField(copy("Folder name", "Nom du dossier"), text: $newFolderName)
            Button(copy("Create", "Créer")) {
                Task {
                    if let folder = await store.createFolder(name: newFolderName) { select(folder.path); dismiss() }
                }
            }
            Button(copy("Cancel", "Annuler"), role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").frame(width: 42, height: 42).background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(copy("Choose a folder", "Choisir un dossier")).font(.system(size: 17, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 42, height: 42)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}

private struct AIMRemoteEngineSheet: View {
    let engines: [RemoteEngine]
    let selectedID: String?
    let store: MainExperienceStore
    let select: (RemoteEngine) -> Void
    @State private var installing: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 42, height: 42).background(Color.primary.opacity(0.055), in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(copy("Agent", "Agent")).font(.system(size: 17, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            VStack(spacing: 0) {
                ForEach(engines, id: \.id.rawValue) { engine in
                    Button {
                        guard engine.selectable else { return }
                        select(engine)
                    } label: {
                        HStack(spacing: 13) {
                            AIMAgentLogo(id: engine.id.rawValue).frame(width: 38, height: 38)
                            Text(engine.name).font(.system(size: 16, weight: .medium))
                            Spacer()
                            if selectedID == engine.id.rawValue {
                                Image(systemName: "checkmark.circle.fill")
                            } else if !engine.selectable {
                                Text(copy("Unavailable", "Indisponible")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(engine.selectable ? Color.primary : Color.secondary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.selectable)
                    .accessibilityIdentifier("remote-agent-" + engine.id.rawValue)
                    if !engine.selectable, engine.id != .aim {
                        if store.selectedMachine?.capabilities?.features["remoteDownloads"] == true {
                            Button("Install on selected Mac") { installing = engine.id.rawValue }.frame(minHeight: 44)
                        } else { Text("Update the selected Mac to install this agent remotely.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                    }
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 22))
            .padding(18)
            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
        .aimUniversalPanelSurface()
        .sheet(isPresented: Binding(get: { installing != nil }, set: { if !$0 { installing = nil } }), onDismiss: { Task { await store.load() } }) {
            if let installing, let machine = store.selectedMachine {
                AIMRemoteDownloadsView(store: store, machineID: machine.id, machineName: machine.name, agent: installing)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func copy(_ english: String, _ french: String) -> String {
        locale.language.languageCode?.identifier == "fr" ? french : english
    }
}


private struct AIMWorkerPlacementControl: View {
    @Bindable var store: MainExperienceStore
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(locale.language.languageCode?.identifier == "fr" ? "Placer les nouveaux objectifs continus automatiquement" : "Place new continuous goals automatically",
                isOn: $store.automaticWorkerPlacement)
            Text(locale.language.languageCode?.identifier == "fr"
                ? "Seuls les Macs compatibles et les dossiers que vous avez choisis sont utilisés. Une mission déjà envoyée conserve son Mac lors d'une reconnexion."
                : "Only compatible Macs and folders you selected are used. A submitted mission keeps its Mac when reconnecting.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("worker-placement-control")
    }
}
