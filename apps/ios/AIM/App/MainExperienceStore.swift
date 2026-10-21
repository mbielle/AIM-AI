import AIMCore
import CryptoKit
import Foundation
import Observation
import UIKit

enum AIMRemoteSecurityPhase: Equatable {
    case authorized
    case loading, unavailable, configurePIN, existingPIN, passkeyOnly
}

enum MainDestination: Equatable {
    case newChat
    case newRemote(RemoteMode)
    case search
    case library
    case personalization
    case code
    case agent
    case projects
    case conversation(String)
}

enum NewChatComputerState: Equatable {
    case loading
    case unpaired
    case needsRepair
    case noComputer
    case chooseComputer
    case selectionUnavailable(name: String?)
    case offline(name: String?)
    case suspended(name: String?)
    case synchronizing(name: String?)
    case noModels(name: String?)
    case readFailure(name: String?, messageKey: String)
    case incompatible(name: String?)
    case available(name: String)
    case unavailable
}

struct AIMCreationDraft: Equatable {
    var text = ""
    var attachments: [RemoteAttachmentReference] = []
}

struct AIMQueuedMessage: Codable, Identifiable {
    let id: UUID
    let sessionID: String
    let machineID: String
    let text: String
    let attachments: [RemoteAttachmentReference]
    var state: String = "waiting"
    var creation: AIMQueuedCreation? = nil
}

struct AIMQueuedCreation: Codable {
    let mode: RemoteMode
    let workspace: String
    let modelID: String
    let provider: String?
    let approvalMode: String
    let agentSystem: String?
    let effort: String?
    let pendingSessionID: String?
}

private struct ContinuityClientReceipts: Codable {
    var snapshots: [String: RemoteContinuitySnapshot]
    var commandIDs: [String: String]
    var admittedCreations: [String: ContinuityCreationAdmission]?
    var workerWorkspaces: [String: String]?
    var workerPlacements: [String: RemoteWorkerPlacement]?
}
private struct ContinuityCreationAdmission: Codable {
    let fingerprint: String
    let sessionID: String
}

private struct AIMCreationConfiguration {
    var machineID: String?
    var workspace: String?
    var modelID: String
    var provider: String?
    var effort: String?
    var approvalMode: String
    var agentSystem: String?
}

@MainActor
@Observable
final class MainExperienceStore {
    private(set) var queuedMessages: [AIMQueuedMessage] = []
    private var queueURL: URL?
    private let mediaAccountID: UUID?
    private var queueStorageAvailable = true
    private var continuityStorageAvailable = true
    private(set) var continuitySnapshots: [String: RemoteContinuitySnapshot] = [:]
    private(set) var continuityCommandIDs: [String: String] = [:]
    var experimentalContinuityEnabled = UserDefaults.standard.bool(forKey: "AIMExperimentalContinuityEnabled") {
        didSet { UserDefaults.standard.set(experimentalContinuityEnabled, forKey: "AIMExperimentalContinuityEnabled") }
    }
    private var refreshingContinuityStatus = false
    private var admittedContinuousCreations: [String: ContinuityCreationAdmission] = [:]
    private(set) var workerWorkspaces: [String: String] = [:]
    private var workerPlacements: [String: RemoteWorkerPlacement] = [:]
    var automaticWorkerPlacement = UserDefaults.standard.bool(forKey: "AIMAutomaticWorkerPlacement") {
        didSet { UserDefaults.standard.set(automaticWorkerPlacement, forKey: "AIMAutomaticWorkerPlacement") }
    }
    private var drainingQueue = false
    var queueDeliveryActive = true
    private struct AnsweredApproval: Hashable {
        let account: UUID?
        let machine: String
        let session: String
        let message: String
    }
    private var answeredApprovals: Set<AnsweredApproval> = []
    private var answeredApprovalOrder: [AnsweredApproval] = []
    private(set) var overview = RemoteOverview(connectionState: .unpaired, machines: [], sessions: [])
    private(set) var messages: [RemoteMessage] = []
    private var messageReadGeneration: UInt64 = 0
    private(set) var macConnectors: [ConnectorDescriptor] = []
    private var macConnectorMachineID: String?
    private(set) var isLoading = false
    private(set) var isPairing = false
    private(set) var isSending = false
    private(set) var isLoadingConversation = false
    private(set) var errorMessage: String?
    private(set) var pairingDiagnosticCode: String?
    private(set) var inlineErrorMessage: String?
    private(set) var hasLoaded = false
    private(set) var remoteFolders: [RemoteFolder] = []
    private(set) var currentFolderPath: String?
    private(set) var isLoadingFolders = false
    private(set) var folderSnapshot: RemoteFolderSnapshot?
    private(set) var commandHealthByMachineID: [String: RemoteCommandHealth] = [:]
    private(set) var lastRemoteDiagnosticReference: String?
    private(set) var remoteUnlockState: RemoteUnlockState?
    private(set) var remoteProtectionPolicy: RemoteProtectionPolicy?
    private(set) var remotePolicyResolved = false
    private var remotePolicyLoadFailed = false
    private var remoteUnlockExpiresAt: Date?
    private(set) var isLoadingRemoteSecurity = false
    private(set) var remoteSecurityError: String?
    private(set) var remoteSecurityDiagnosticCode: String?
    private var remoteSecurityGeneration = UUID()
    private var securityContextIsCurrent: @MainActor () -> Bool = { true }
    private(set) var remotePINLockedUntil: Date?
    private(set) var remotePINAttempts: Int?
    private(set) var isRemoteUnlocked = false
    private(set) var deviceAuthorizationState: RemoteDeviceAuthorizationState?
    private(set) var remoteSecurityNeedsRepair = false
    private(set) var remoteBiometricsConfigured = false
    private(set) var remoteBiometricCredentialUnavailable = false
    private(set) var destination: MainDestination = .newChat
    let creationTitleKey: String
    var mode: RemoteMode = .chat
    var selectedMachineID: String?
    var selectedSessionID: String?
    var selectedWorkspace: String?
    var selectedModelID = "claude-sonnet-5" {
        didSet { if oldValue != selectedModelID { selectedModelProvider = nil } }
    }
    var selectedModelProvider: String?
    var selectedEffort: String?
    var selectedApprovalMode = "review"
    var selectedAgentSystem: String?
    var creationDrafts: [RemoteMode: AIMCreationDraft] = [
        .chat: .init(),
        .code: .init(),
        .agent: .init(),
    ]

    func preferredModelRoute(_ canonical: String) -> String? {
        guard let owner = mediaAccountID, let target = selectedSession?.machineID ?? selectedMachine?.id else { return nil }
        return machineSelectionDefaults.string(forKey: CanonicalModelRouting.preferenceKey(account: owner, target: target, model: canonical))
    }
    func rememberModelRoute(_ model: RemoteModelAnnouncement) {
        guard let owner = mediaAccountID, let target = selectedSession?.machineID ?? selectedMachine?.id else { return }
        machineSelectionDefaults.set(model.provider, forKey: CanonicalModelRouting.preferenceKey(account: owner, target: target, model: CanonicalModelRouting.identity(model.id, provider: model.provider)))
    }
    private struct PreferredRemoteMachine: Codable { let id: String; let name: String }
    private var preferredRemoteMachine: PreferredRemoteMachine?
    private let machineSelectionDefaults: UserDefaults
    private let machineSelectionKey: String?
    private(set) var suspendedRemoteMachineIDs: Set<String> = []
    private let suspensionKey: String?
    private var remoteEventTask: Task<Void, Never>?
    var observationNotice: String?
    var observationAttempts = 0
    private struct InterruptedObservation: Codable { var key: String; var started: Date; var attempts: Int }
    private var interruptedTurn: String?
    private var interruptionStarted: Date?
    private var cancelledObservationTurns: Set<String> = []
    private var interruptionKey: String? { mediaAccountID.map { "aim.remote.interrupted-turn.v1." + $0.uuidString.lowercased() } }
    private var cancelledObservationKey: String? { mediaAccountID.map { "aim.remote.cancelled-turns.v1." + $0.uuidString.lowercased() } }
    private func persistInterruption() {
        guard let key = interruptionKey else { return }
        if let turn = interruptedTurn, let started = interruptionStarted, let data = try? JSONEncoder().encode(InterruptedObservation(key: turn, started: started, attempts: observationAttempts)) { machineSelectionDefaults.set(data, forKey: key) }
        else { machineSelectionDefaults.removeObject(forKey: key) }
    }
    func cancelReconnection(for session: RemoteSession) {
        guard let key = liveTurn(session) else { return }
        cancelledObservationTurns.insert(key)
        if let preference = cancelledObservationKey { machineSelectionDefaults.set(Array(cancelledObservationTurns), forKey: preference) }
        interruptedTurn = nil; interruptionStarted = nil; observationAttempts = 0; persistInterruption()
        remoteEventTask?.cancel()
    }
    func recordObservationInterruption(for session: RemoteSession?, expectedTurn: String? = nil) {
        guard let key = liveTurn(session), expectedTurn == nil || expectedTurn == key, !cancelledObservationTurns.contains(key) else { return }
        if interruptedTurn == key { observationAttempts += 1 }
        else { interruptedTurn = key; interruptionStarted = .now; observationAttempts = 1 }
        persistInterruption()
    }
    private func liveTurn(_ session: RemoteSession?) -> String? {
        guard let session, session.status == "running", !session.readState.blocksReading,
              !isRemoteSuspended(machineID: session.machineID), selectedSessionID == session.id,
              messages.allSatisfy({ !$0.readState.blocksReading }) else { return nil }
        guard let user = messages.last(where: { $0.role == .user }) else { return nil }
        return session.id + ":" + user.id
    }
    func reconnectionAction(for session: RemoteSession) -> ConversationAction? {
        guard !observationPaused, observationAttempts > 0, let key = liveTurn(session), key == interruptedTurn, !cancelledObservationTurns.contains(key),
              let conversation = UUID(uuidString: session.id) else { return nil }
        let turn = messages.last(where: { $0.role == .user }).flatMap { UUID(uuidString: $0.id) } ?? conversation
        return .init(id: key + ":tracking", conversationID: conversation, turnID: turn, ordinal: 999,
            name: (Locale.current.language.languageCode?.identifier == "fr" ? "Reconnexion… " : "Reconnecting… ") + String(observationAttempts),
            state: .waiting, startedAt: interruptionStarted ?? .now,
            input: "Resume observation of the existing Mac turn. No command or provider request is resubmitted.",
            output: "Tracking disconnected · attempts: " + String(observationAttempts))
    }
    private var observationResumeWaiter: CheckedContinuation<Void, Never>?
    private var observationPreferenceKey: String? { mediaAccountID.map { "aim.remote.observation-paused.v1." + $0.uuidString.lowercased() } }
    var observationPaused = false
    func pauseObservation() {
        observationPaused = true; observationNotice = "Live updates paused. Mac tasks continue."
        if let key = observationPreferenceKey { machineSelectionDefaults.set(true, forKey: key) }
        remoteEventTask?.cancel()
    }
    func resumeObservation() {
        observationPaused = false; observationAttempts = 0; observationNotice = "Reconnecting to the selected Mac…"
        if let key = observationPreferenceKey { machineSelectionDefaults.set(false, forKey: key) }
        observationResumeWaiter?.resume(); observationResumeWaiter = nil
        remoteEventTask?.cancel()
    }
    private let localRemoteAccessPolicy: RemoteLocalAccessPolicy
    private var installedRemoteAccessPolicy = false
    private var remoteMessageCache: [String: [RemoteMessage]] = [:]
    private(set) var pairingSuccessMessage: String?
    private let service: any RemoteServicing
    private let recoverAuthentication: @MainActor () async -> Bool
    private let directSessionProbe: (@MainActor () async throws -> Bool)?
    private var directSessionAuthorized = false
    private let biometricSecretStore: any BiometricSecretStoring
    private var folderSnapshots: [String: RemoteFolderSnapshot] = [:]
    private var commandHealthUpdatedAtByMachineID: [String: Date] = [:]
    private var commandHealthGeneration = UUID()
    private var commandHealthRevisionByMachineID: [String: UInt64] = [:]
    private var pendingCreationSessionIDs: [RemoteMode: String] = [:]
    private var creationConfigurations: [RemoteMode: AIMCreationConfiguration] = [:]

    init(
        service: any RemoteServicing,
        queueAccountID: UUID? = nil,
        biometricSecretStore: (any BiometricSecretStoring)? = nil,
        machineSelectionDefaults: UserDefaults = .standard,
        recoverAuthentication: @escaping @MainActor () async -> Bool = { false },
        directSessionProbe: (@MainActor () async throws -> Bool)? = nil,
        titleDraw: () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.service = service
        self.directSessionProbe = directSessionProbe
        self.machineSelectionDefaults = machineSelectionDefaults
        mediaAccountID = queueAccountID
        if let owner = queueAccountID {
            cancelledObservationTurns = Set(machineSelectionDefaults.stringArray(forKey: "aim.remote.cancelled-turns.v1." + owner.uuidString.lowercased()) ?? [])
            if let data = machineSelectionDefaults.data(forKey: "aim.remote.interrupted-turn.v1." + owner.uuidString.lowercased()), let value = try? JSONDecoder().decode(InterruptedObservation.self, from: data) { interruptedTurn = value.key; interruptionStarted = value.started; observationAttempts = value.attempts }
        }
        if let owner = queueAccountID, machineSelectionDefaults.bool(forKey: "aim.remote.observation-paused.v1." + owner.uuidString.lowercased()) {
            observationPaused = true; observationNotice = "Live updates paused. Mac tasks continue."
        }
        let localSuspensionKey = queueAccountID.map { "aim.remote.suspended-machines.v1." + $0.uuidString.lowercased() }
        suspensionKey = localSuspensionKey
        let savedSuspensions = Set(localSuspensionKey.flatMap { machineSelectionDefaults.stringArray(forKey: $0) } ?? [])
        suspendedRemoteMachineIDs = savedSuspensions
        localRemoteAccessPolicy = RemoteLocalAccessPolicy(suspendedMachineIDs: savedSuspensions)
        machineSelectionKey = queueAccountID.map { "aim.remote.preferred-machine.v1." + $0.uuidString.lowercased() }
        self.biometricSecretStore = biometricSecretStore ?? KeychainBiometricSecretStore(
            account: queueAccountID.map { "fallback-pin." + $0.uuidString.lowercased() } ?? "fallback-pin")
        self.recoverAuthentication = recoverAuthentication
        creationTitleKey = RemoteCreationTitles.key(for: .chat, draw: titleDraw())
        if let machineSelectionKey, let data = machineSelectionDefaults.data(forKey: machineSelectionKey),
           let saved = try? JSONDecoder().decode(PreferredRemoteMachine.self, from: data), !saved.id.isEmpty {
            preferredRemoteMachine = saved; selectedMachineID = saved.id
        }
        if let queueAccountID {
            queueURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Outbox", isDirectory: true)
                .appendingPathComponent(queueAccountID.uuidString + ".json")
            if let queueURL, FileManager.default.fileExists(atPath: queueURL.path) {
                do {
                    queuedMessages = try JSONDecoder().decode([AIMQueuedMessage].self, from: Data(contentsOf: queueURL))
                    for index in queuedMessages.indices where queuedMessages[index].state == "sending" {
                        queuedMessages[index].state = "review"
                    }
                } catch { queueStorageAvailable = false }
            }
            if let url = queueURL?.deletingPathExtension().appendingPathExtension("continuity.json"),
               FileManager.default.fileExists(atPath: url.path) {
                do {
                    let saved = try JSONDecoder().decode(ContinuityClientReceipts.self, from: Data(contentsOf: url))
                    continuitySnapshots = saved.snapshots; continuityCommandIDs = saved.commandIDs
                    admittedContinuousCreations = saved.admittedCreations ?? [:]
                    workerWorkspaces = saved.workerWorkspaces ?? [:]; workerPlacements = saved.workerPlacements ?? [:]
                } catch { continuityStorageAvailable = false }
            }
        }
    }

    private func saveQueue() throws {
        guard queueStorageAvailable else { throw CocoaError(.fileReadCorruptFile) }
        guard let queueURL else { return }
        try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var protectedURL = queueURL.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        try JSONEncoder().encode(queuedMessages).write(to: queueURL, options: [.atomic, .completeFileProtection])
    }

    func queueMessage(text: String, attachments: [RemoteAttachmentReference], session: RemoteSession) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        let entry = AIMQueuedMessage(id: UUID(), sessionID: session.id, machineID: session.machineID, text: text, attachments: attachments)
        queuedMessages.append(entry)
        do { try saveQueue(); return true }
        catch { queuedMessages.removeAll { $0.id == entry.id }; errorMessage = String(localized: "Unable to save the pending message"); return false }
    }

    func removeQueuedMessage(_ id: UUID) {
        guard !queuedMessages.contains(where: { $0.id == id && $0.state == "sending" }) else { return }
        let previous = queuedMessages
        queuedMessages.removeAll { $0.id == id }
        do { try saveQueue() } catch { queuedMessages = previous; errorMessage = String(localized: "Unable to save the pending message") }
    }

    func queueCreation() -> Bool {
        let draft = creationDraft(for: mode)
        guard mode != .chat, queueStorageAvailable, let machine = selectedMachine,
              let workspace = selectedWorkspace, !selectedModelID.isEmpty,
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty else { return false }
        let configuration = AIMQueuedCreation(mode: mode, workspace: workspace, modelID: selectedModelID,
            provider: selectedModelProvider, approvalMode: selectedApprovalMode, agentSystem: selectedAgentSystem,
            effort: selectedEffort, pendingSessionID: pendingCreationSessionIDs[mode])
        let id = UUID()
        let entry = AIMQueuedMessage(id: id, sessionID: id.uuidString, machineID: machine.id,
            text: draft.text, attachments: draft.attachments, creation: configuration)
        queuedMessages.append(entry)
        do { try saveQueue() }
        catch { queuedMessages.removeAll { $0.id == id }; errorMessage = "Unable to save the pending conversation."; return false }
        creationDrafts[mode] = .init(); pendingCreationSessionIDs[mode] = nil
        return true
    }

    private func queuedPayload(_ entry: AIMQueuedMessage) -> RemoteJSONValue {
        var payload = RemoteAttachmentRules.messagePayload(text: entry.text, attachments: entry.attachments).objectValue ?? [:]
        payload["client_request_id"] = .string(entry.id.uuidString.lowercased())
        return .object(payload)
    }

    private func deliverQueuedCreation(_ entry: AIMQueuedMessage, configuration: AIMQueuedCreation) async throws {
        guard let machine = overview.machines.first(where: { $0.id == entry.machineID }), machine.isOnline(),
              !isRemoteSuspended(machineID: machine.id), !needsProtectionGate(for: configuration.mode),
              machine.capabilities?.models.contains(where: { $0.id == configuration.modelID && (configuration.provider == nil || $0.provider == configuration.provider) && $0.isAvailable != false }) == true else {
            throw RemoteServiceError.commandRejected("queued_target_or_model_unavailable")
        }
        if configuration.mode == .agent {
            let agent = configuration.agentSystem ?? "aim"
            guard RemoteEngineRules.engines(capabilities: machine.capabilities).first(where: { $0.id.rawValue == agent })?.selectable == true,
                  agent == "aim" || configuration.provider?.lowercased() == "openrouter" else { throw RemoteServiceError.commandRejected("queued_agent_unavailable") }
        }
        if let sessionID = configuration.pendingSessionID {
            let result = try await remoteService(machineID: machine.id).sendCommand(machineID: machine.id, sessionID: sessionID,
                type: .userMessage, payload: queuedPayload(entry))
            guard result.succeeded else { throw RemoteServiceError.commandRejected(result.errorCode ?? "queue_failed") }
        } else {
            _ = try await remoteService(machineID: machine.id).createSession(.init(machineID: machine.id, mode: configuration.mode,
                modelID: configuration.modelID, workspace: configuration.workspace, approvalMode: configuration.approvalMode,
                text: entry.text, agentSystem: configuration.agentSystem, effort: configuration.effort,
                attachments: entry.attachments, delegationID: entry.id, provider: configuration.provider))
        }
    }

    func deliverQueuedMessages() async {
        guard !queuedMessages.isEmpty else { return }
        guard queueDeliveryActive, !drainingQueue, !isSending, queueStorageAvailable else { return }
        drainingQueue = true
        defer { drainingQueue = false }
        var dispatchedSessions = Set<String>()
        for entry in queuedMessages where entry.state == "waiting" {
            guard queueDeliveryActive, !Task.isCancelled else { return }
            guard !isRemoteSuspended(machineID: entry.machineID) else { continue }
            if let creation = entry.creation {
                guard overview.machines.first(where: { $0.id == entry.machineID })?.isOnline() == true,
                      !needsProtectionGate(for: creation.mode) else { continue }
                await probeRemoteHealth(machineID: entry.machineID)
                guard queueDeliveryActive, commandHealth(for: entry.machineID) == .responsive, !Task.isCancelled,
                      let index = queuedMessages.firstIndex(where: { $0.id == entry.id }) else { continue }
                queuedMessages[index].state = "sending"
                do { try saveQueue() } catch { queuedMessages[index].state = "waiting"; return }
                do {
                    try await deliverQueuedCreation(entry, configuration: creation)
                    queuedMessages.removeAll { $0.id == entry.id }; try saveQueue()
                } catch {
                    if let index = queuedMessages.firstIndex(where: { $0.id == entry.id }) { queuedMessages[index].state = "review" }
                    try? saveQueue(); return
                }
                continue
            }
            guard !dispatchedSessions.contains(entry.sessionID) else { continue }
            guard queuedMessages.first(where: { $0.sessionID == entry.sessionID })?.id == entry.id else { continue }
            guard let session = overview.sessions.first(where: { $0.id == entry.sessionID }),
                  !needsProtectionGate(for: session.mode), session.status != "waiting_approval", session.status != "running",
                  overview.machines.first(where: { $0.id == entry.machineID })?.isOnline() == true else { continue }
            await probeRemoteHealth(machineID: entry.machineID)
            guard queueDeliveryActive, commandHealth(for: entry.machineID) == .responsive, !Task.isCancelled,
                  let index = queuedMessages.firstIndex(where: { $0.id == entry.id }) else { continue }
            queuedMessages[index].state = "sending"
            do { try saveQueue() } catch { queuedMessages[index].state = "waiting"; return }
            do {
                let result = try await remoteService(machineID: entry.machineID).sendCommand(machineID: entry.machineID, sessionID: entry.sessionID,
                    type: .userMessage, payload: RemoteAttachmentRules.messagePayload(text: entry.text, attachments: entry.attachments))
                guard result.succeeded else { throw RemoteServiceError.commandRejected(result.errorCode ?? "unknown") }
                dispatchedSessions.insert(entry.sessionID)
                queuedMessages.removeAll { $0.id == entry.id }
                try saveQueue()
                if selectedSessionID == entry.sessionID { await refreshSelectedSession() }
            } catch {
                if let index = queuedMessages.firstIndex(where: { $0.id == entry.id }) { queuedMessages[index].state = "review" }
                try? saveQueue()
                // An uncertain delivery is never automatically retried.
                return
            }
        }
    }

    var computerState: NewChatComputerState {
        if !hasLoaded { return .loading }
        // A background refresh must not replace a previously usable, paired
        // snapshot with the full-screen loading error. The cached mirror remains
        // useful while the next refresh retries.
        if inlineErrorMessage != nil,
           overview.connectionState != .paired || overview.machines.isEmpty
        {
            return .unavailable
        }
        switch overview.connectionState {
        case .unpaired:
            return .unpaired
        case .needsRepair:
            return .needsRepair
        case .paired:
            guard !overview.machines.isEmpty else { return .noComputer }
            guard let machine = selectedMachine else {
                return selectedMachineID == nil ? .chooseComputer : .selectionUnavailable(name: selectedMachineDisplayName)
            }
            guard !isRemoteSuspended(machineID: machine.id) else { return .suspended(name: machine.name) }
            guard machine.isOnline() else { return .offline(name: machine.name) }
            if commandHealth(for: machine.id) == .incompatible { return .incompatible(name: machine.name) }
            if let failure = machine.keyRequestFailure {
                let key = switch failure.code {
                case .bridgeUnresponsive: "remote.error.key_request_unresponsive"
                case .unreadablePayload: "remote.error.envelope_unreadable"
                case .encryptionKeyPending: "remote.error.key_publication_missing"
                case .authenticationRequired: "remote.error.authentication_required"
                case .deviceNotPaired: "remote.error.not_paired"
                case .networkUnavailable: "remote.error.network_unavailable"
                default: "remote.error.key_publication_failed"
                }
                return .readFailure(name: machine.name, messageKey: key)
            }
            if machine.readState.blocksReading {
                let key = switch machine.readState {
                case .keyPending: "remote.error.key_unavailable"
                case .historicalKeyMissing: "remote.error.historical_key_missing"
                case .envelopeUnreadable: "remote.error.envelope_unreadable"
                case .invalidData: "remote.error.capabilities_invalid"
                case .unavailable: "remote.error.network_unavailable"
                default: "remote.error.unreadable_payload"
                }
                return .readFailure(name: machine.name, messageKey: key)
            }
            guard let capabilities = machine.capabilities else { return .synchronizing(name: machine.name) }
            guard !capabilities.models.isEmpty else { return .noModels(name: machine.name) }
            return .available(name: machine.name)
        }
    }

    var recentChatSessions: [RemoteSession] {
        return RemoteSessionOrdering.sorted(
            overview.sessions.filter { $0.archivedAt == nil && !needsProtectionGate(for: $0.mode) },
            by: .priority
        )
    }

    func searchSessions(matching query: String) -> [RemoteSession] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return overview.sessions
            .filter { session in
                guard !needsProtectionGate(for: session.mode) else { return false }
                guard !needle.isEmpty else { return true }
                let haystack = [session.title, session.workspace ?? "", session.mode.rawValue]
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return haystack.contains(needle)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var shouldOfferPairing: Bool {
        // A mirror read can fail before this iPhone is paired (for example
        // while the computer is still publishing its first state). That is
        // precisely when the connection panel must remain reachable and be
        // offered automatically.
        guard hasLoaded, inlineErrorMessage == nil else { return false }
        return overview.connectionState == .unpaired || overview.connectionState == .needsRepair
    }

    var filteredSessions: [RemoteSession] {
        RemoteSessionOrdering.sorted(
            overview.sessions.filter { session in
                session.archivedAt == nil && session.mode == mode && (selectedMachineID == nil || session.machineID == selectedMachineID)
            },
            by: .priority
        )
    }

    func sessions(mode: RemoteMode, machineID: String?, archived: Bool, sort: RemoteSessionSort) -> [RemoteSession] {
        RemoteSessionOrdering.sorted(
            overview.sessions.filter { session in
                session.mode == mode &&
                    (machineID == nil || session.machineID == machineID) &&
                    (archived ? session.archivedAt != nil : session.archivedAt == nil)
            },
            by: sort
        )
    }

    func remoteMachineName(for session: RemoteSession) -> String {
        overview.machines.first { $0.id == session.machineID }?.name ?? String(localized: "remote.sessions.unknown_computer")
    }

    var selectedSession: RemoteSession? {
        overview.sessions.first { $0.id == selectedSessionID }
    }

    var selectedMachine: RemoteMachine? {
        if let selectedMachineID {
            return overview.machines.first { $0.id == selectedMachineID }
        }
        return overview.machines.count == 1 ? overview.machines.first : nil
    }

    func isRemoteSuspended(machineID: String) -> Bool {
        suspendedRemoteMachineIDs.contains(machineID)
    }

    /// This preference affects only this account on this iPhone. Pairing and Mac tasks remain intact.
    func setRemoteEnabled(_ enabled: Bool, machineID: String) {
        localRemoteAccessPolicy.setEnabled(enabled, machineID: machineID)
        if enabled { suspendedRemoteMachineIDs.remove(machineID) }
        else { suspendedRemoteMachineIDs.insert(machineID) }
        if let suspensionKey { machineSelectionDefaults.set(Array(suspendedRemoteMachineIDs).sorted(), forKey: suspensionKey) }
        if selectedSession?.machineID == machineID || selectedMachineID == machineID {
            remoteEventTask?.cancel()
        }
        commandHealthGeneration = UUID()
        commandHealthByMachineID.removeValue(forKey: machineID)
    }

    private func installRemoteAccessPolicy() async {
        guard !installedRemoteAccessPolicy else { return }
        if let controlled = service as? any RemoteAccessPolicyReceiving { await controlled.setLocalAccessPolicy(localRemoteAccessPolicy) }
        installedRemoteAccessPolicy = true
    }

    /// Every machine-specific service boundary goes through this check, including queued commands.
    private func remoteService(machineID: String) throws -> any RemoteServicing {
        guard securityContextIsCurrent(), !Task.isCancelled else { throw RemoteServiceError.sessionUnavailable }
        guard !isRemoteSuspended(machineID: machineID) else {
            throw RemoteServiceError.commandRejected("remote_access_suspended")
        }
        return service
    }

    var selectedMachineDisplayName: String? {
        selectedMachine?.name ?? (selectedMachineID == preferredRemoteMachine?.id ? preferredRemoteMachine?.name : nil)
    }
    private func preferredCreationMachineID() -> String? {
        // A missing/offline explicit choice never silently targets another computer.
        if let preferredRemoteMachine { return preferredRemoteMachine.id }
        return overview.machines.count == 1 ? overview.machines.first?.id : nil
    }

    var remoteSecurityPhase: AIMRemoteSecurityPhase {
        if isLoadingRemoteSecurity { return .loading }
        return remoteDeviceAuthorized ? .authorized : .unavailable
    }
    // Compatibility queries are deliberately inert. No legacy state can
    // enable a section gate or reintroduce PIN setup through an old route.
    var remoteCanConfigurePIN: Bool { false }
    var remoteProtectionEnabled: Bool { false }
    var remoteRequiresUnlock: Bool { false }
    var remoteSecurityHasPIN: Bool { false }
    var remoteSecurityConfigured: Bool { remoteDeviceAuthorized }
    var remoteRequiresSetup: Bool { false }
    var remoteNeedsProtectionGate: Bool { false }
    var remoteAuthorizationNeeded: Bool { !remoteDeviceAuthorized }

    /// Device authentication is owned by AppLockService. Network authorization
    /// never hides cached history or presents the retired AIM PIN interface.
    func needsProtectionGate(for mode: RemoteMode) -> Bool { false }

    var remoteDeviceAuthorized: Bool {
        (directSessionProbe != nil ? directSessionAuthorized : deviceAuthorizationState?.version == 2) && isRemoteUnlocked
            && remoteUnlockExpiresAt.map { $0 > .now } == true
    }

    func saveRemoteProtectionPolicy(_ modes: [RemoteMode]) async -> Bool {
        remoteSecurityDiagnosticCode = "legacy_security_retired"
        remoteSecurityError = "App protection is managed with Face ID in Settings. Remote uses this paired device’s authorization."
        return false
    }

    func commandHealth(for machineID: String) -> RemoteCommandHealth {
        guard let machine = overview.machines.first(where: { $0.id == machineID }), machine.isOnline() else {
            return .unresponsive
        }
        let health = commandHealthByMachineID[machineID] ?? .unknown
        if health == .responsive,
           Date().timeIntervalSince(commandHealthUpdatedAtByMachineID[machineID] ?? .distantPast) > 45
        {
            return .unknown
        }
        return health
    }

    var effectiveCommandHealthByMachineID: [String: RemoteCommandHealth] {
        Dictionary(uniqueKeysWithValues: overview.machines.map { ($0.id, commandHealth(for: $0.id)) })
    }

    private func setCommandHealth(_ health: RemoteCommandHealth, machineID: String) {
        commandHealthRevisionByMachineID[machineID, default: 0] &+= 1
        commandHealthByMachineID[machineID] = health
        commandHealthUpdatedAtByMachineID[machineID] = Date()
    }

    func probeSelectedRemoteHealth() async {
        guard let machine = selectedMachine else { return }
        await probeRemoteHealth(machineID: machine.id)
    }

    func probeRemoteHealth(machineID: String) async {
        guard !isRemoteSuspended(machineID: machineID), securityContextIsCurrent(), !Task.isCancelled,
              let machine = overview.machines.first(where: { $0.id == machineID }), machine.isOnline() else { return }
        guard commandHealthByMachineID[machine.id] != .checking, commandHealth(for: machine.id) != .responsive else { return }
        setCommandHealth(.checking, machineID: machine.id)
        let generation = commandHealthGeneration
        let revision = commandHealthRevisionByMachineID[machine.id]
        defer {
            if generation == commandHealthGeneration, revision == commandHealthRevisionByMachineID[machine.id],
               commandHealthByMachineID[machine.id] == .checking {
                setCommandHealth(.unknown, machineID: machine.id)
            }
        }
        // A successful newer command, changed mirror or device context fences this probe.
        func isCurrent() -> Bool {
            guard generation == commandHealthGeneration, revision == commandHealthRevisionByMachineID[machine.id],
                  securityContextIsCurrent(), !Task.isCancelled,
                  let current = overview.machines.first(where: { $0.id == machine.id }), current.isOnline() else { return false }
            // Presence/name/catalogue refreshes do not invalidate an actual host reply.
            return current.keyVersion == machine.keyVersion && current.appVersion == machine.appVersion
        }
        do {
            try await remoteService(machineID: machine.id).checkBridge(machineID: machine.id)
            guard isCurrent() else { return }
            setCommandHealth(.responsive, machineID: machine.id)
            lastRemoteDiagnosticReference = nil
        } catch {
            guard isCurrent() else { return }
            registerCommandFailure(error, machineID: machine.id)
            if case RemoteServiceError.commandFailure = error { errorMessage = commandMessage(for: error) }
            if commandHealthByMachineID[machine.id] == .checking { setCommandHealth(.unresponsive, machineID: machine.id) }
        }
    }

    func deleteSessions(ids: Set<String>) async -> Bool {
        let existingIDs = Set(overview.sessions.map(\.id))
        let deletionIDs = Array(ids.intersection(existingIDs))
        guard !deletionIDs.isEmpty else { return false }
        do {
            try await service.deleteSessions(ids: deletionIDs)
            let deleted = Set(deletionIDs)
            overview = .init(
                connectionState: overview.connectionState,
                machines: overview.machines,
                sessions: overview.sessions.filter { !deleted.contains($0.id) }
            )
            if let selectedSessionID, deleted.contains(selectedSessionID) {
                self.selectedSessionID = nil
                messages = []
                destination = .newChat
            }
            return true
        } catch {
            errorMessage = String(localized: "remote.error.command_failed")
            return false
        }
    }

    func setPinned(_ pinned: Bool, session: RemoteSession) async -> Bool {
        do {
            try await service.setSessionPinned(pinned, sessionID: session.id)
            let current = overview.sessions.first { $0.id == session.id } ?? session
            replaceSession(current.replacing(isPinned: pinned))
            return true
        } catch {
            errorMessage = commandMessage(for: error)
            return false
        }
    }

    func setProject(_ projectID: String?, session: RemoteSession) async -> Bool {
        do {
            try await service.setSessionProject(projectID, sessionID: session.id)
            let current = overview.sessions.first { $0.id == session.id } ?? session
            replaceSession(current.replacing(projectID: .some(projectID)))
            return true
        } catch {
            errorMessage = commandMessage(for: error)
            return false
        }
    }

    func renameSession(_ session: RemoteSession, title: String) async -> Bool {
        do {
            let normalizedTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            guard !normalizedTitle.isEmpty else { return false }
            try await remoteService(machineID: session.machineID).renameSession(normalizedTitle, machineID: session.machineID, sessionID: session.id)
            let current = overview.sessions.first { $0.id == session.id } ?? session
            replaceSession(current.replacing(title: normalizedTitle))
            return true
        } catch {
            errorMessage = commandMessage(for: error)
            return false
        }
    }

    func setArchived(_ archived: Bool, session: RemoteSession) async -> Bool {
        do {
            try await remoteService(machineID: session.machineID).setSessionArchived(archived, machineID: session.machineID, sessionID: session.id)
            let current = overview.sessions.first { $0.id == session.id } ?? session
            replaceSession(current.replacing(archivedAt: .some(archived ? Date() : nil)))
            return true
        } catch {
            errorMessage = commandMessage(for: error)
            return false
        }
    }

    func loadCompleteHistory(for session: RemoteSession) async throws -> [RemoteMessage] {
        guard supports(RemoteCapabilities.Feature.history, session: session) else {
            throw RemoteServiceError.commandFailure(
                .init(code: .unsupportedCommand, stage: .failed, serverCode: "history_unavailable", diagnosticReference: "REMOTE-HISTORY-UNSUPPORTED")
            )
        }
        var cursor: String?
        var all: [RemoteMessage] = []
        var visited: Set<String> = []
        repeat {
            let page = try await remoteService(machineID: session.machineID).loadHistory(
                machineID: session.machineID,
                sessionID: session.id,
                cursor: cursor,
                limit: 100
            )
            all.append(contentsOf: page.messages)
            if !page.hasMore { break }
            guard let next = page.nextCursor, visited.insert(next).inserted else {
                throw RemoteServiceError.commandRejected("curseur_historique_invalide")
            }
            cursor = next
            try Task.checkCancellation()
        } while true
        return Dictionary(grouping: all, by: \.id)
            .compactMap { $0.value.max(by: { $0.sequence < $1.sequence }) }
            .sorted { $0.sequence < $1.sequence }
    }

    func attachmentMetadata(for session: RemoteSession) async throws -> [RemoteSessionAttachment] {
        try await remoteService(machineID: session.machineID).loadAttachmentMetadata(machineID: session.machineID, sessionID: session.id)
    }

    func supports(_ feature: String, session: RemoteSession) -> Bool {
        overview.machines.first(where: { $0.id == session.machineID })?.capabilities?.supports(feature) == true
    }

    private func removingAnsweredApprovals(from value: RemoteOverview) -> RemoteOverview {
        .init(connectionState: value.connectionState, machines: value.machines, sessions: value.sessions.map { session in
            guard let pending = session.pendingApproval,
                  answeredApprovals.contains(.init(account: mediaAccountID, machine: session.machineID,
                      session: session.id, message: pending.messageID)) else { return session }
            if let current = overview.sessions.first(where: { $0.id == session.id && $0.machineID == session.machineID }),
               current.updatedAt >= session.updatedAt, let currentPending = current.pendingApproval,
               currentPending.messageID != pending.messageID {
                return current
            }
            return session.replacing(pendingApproval: .some(nil))
        })
    }

    private func replaceSession(_ replacement: RemoteSession) {
        overview = .init(
            connectionState: overview.connectionState,
            machines: overview.machines,
            sessions: overview.sessions.map { $0.id == replacement.id ? replacement : $0 }
        )
    }

    func load() async {
        await load(allowsAuthenticationRecovery: true)
    }

    private func load(allowsAuthenticationRecovery: Bool) async {
        await installRemoteAccessPolicy()
        guard !isLoading else { return }
        isLoading = true
        do {
            overview = removingAnsweredApprovals(from: try await service.loadOverview())
            errorMessage = nil
            inlineErrorMessage = nil
            if let selectedMachineID, selectedMachineID != preferredRemoteMachine?.id, !overview.machines.contains(where: { $0.id == selectedMachineID }) {
                self.selectedMachineID = nil
            }
            if selectedMachineID == nil {
                selectedMachineID = preferredCreationMachineID()
            }
            // Keep the last explicit model reference. A missing model requires
            // a choice in the picker; refreshing never changes provider/billing.
            if let selectedSessionID, !overview.sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
                messages = []
            }
        } catch let RemoteServiceError.pairingFailed(failure)
            where failure.stage == .authentication && allowsAuthenticationRecovery
        {
            isLoading = false
            if await recoverAuthentication() {
                await load(allowsAuthenticationRecovery: false)
                return
            }
            inlineErrorMessage = String(localized: "main.error.load")
        } catch {
            inlineErrorMessage = String(localized: "main.error.load")
        }
        hasLoaded = true
        isLoading = false
    }

    func navigate(to destination: MainDestination) {
        self.destination = destination
        if destination == .code { mode = .code }
        if destination == .agent { mode = .agent }
        selectedSessionID = nil
        messages = []
    }

    func creationDraft(for mode: RemoteMode) -> AIMCreationDraft {
        creationDrafts[mode] ?? .init()
    }

    func updateCreationDraft(_ draft: AIMCreationDraft, for mode: RemoteMode) {
        creationDrafts[mode] = draft
    }

    func switchCreationMode(to newMode: RemoteMode) {
        saveCreationConfiguration(for: mode)
        mode = newMode
        restoreCreationConfiguration(for: newMode)
        destination = newMode == .chat ? .newChat : .newRemote(newMode)
        selectedSessionID = nil
        messages = []
    }

    func startNewChat() {
        saveCreationConfiguration(for: mode)
        mode = .chat
        creationDrafts[.chat] = .init()
        pendingCreationSessionIDs[.chat] = nil
        selectedMachineID = preferredCreationMachineID()
        navigate(to: .newChat)
    }

    func startNewRemoteSession(mode: RemoteMode) {
        guard mode != .chat else { startNewChat(); return }
        saveCreationConfiguration(for: self.mode)
        self.mode = mode
        creationDrafts[mode] = .init()
        selectedMachineID = preferredCreationMachineID()
        selectedWorkspace = nil
        pendingCreationSessionIDs[mode] = nil
        let capabilities = selectedMachine?.capabilities
        selectedEffort = nil
        selectedApprovalMode = mode == .code || directSessionProbe != nil ? "review" : "smart"
        selectedAgentSystem = mode == .agent
            ? RemoteEngineRules.engines(capabilities: capabilities).first(where: { $0.id == .aim && $0.selectable })?.id.rawValue
            : nil
        restoreFolderSnapshot(machineID: selectedMachineID, path: nil)
        currentFolderPath = nil
        destination = .newRemote(mode)
        saveCreationConfiguration(for: mode)
    }

    private func saveCreationConfiguration(for mode: RemoteMode) {
        creationConfigurations[mode] = .init(
            machineID: selectedMachineID,
            workspace: selectedWorkspace,
            modelID: selectedModelID,
            provider: selectedModelProvider,
            effort: selectedEffort,
            approvalMode: selectedApprovalMode,
            agentSystem: selectedAgentSystem
        )
    }

    private func restoreCreationConfiguration(for mode: RemoteMode) {
        if let saved = creationConfigurations[mode], saved.machineID == preferredCreationMachineID() {
            selectedMachineID = saved.machineID
            selectedWorkspace = saved.workspace
            selectedModelID = saved.modelID
            selectedModelProvider = saved.provider
            selectedEffort = saved.effort
            selectedApprovalMode = saved.approvalMode
            selectedAgentSystem = saved.agentSystem
            return
        }

        selectedMachineID = preferredCreationMachineID()
        let capabilities = selectedMachine?.capabilities
        selectedEffort = RemoteEffortRules.effort(
            capabilities: capabilities,
            modelID: selectedModelID
        ).currentValue
        selectedWorkspace = nil
        selectedApprovalMode = directSessionProbe != nil || mode == .code ? "review" : mode == .agent ? "smart" : "review"
        selectedAgentSystem = mode == .agent
            ? RemoteEngineRules.engines(capabilities: capabilities).first(where: { $0.id == .aim && $0.selectable })?.id.rawValue
            : nil
        saveCreationConfiguration(for: mode)
    }

    func loadFolders(path: String? = nil) async {
        guard !isLoadingFolders, let machine = selectedMachine else { return }
        restoreFolderSnapshot(machineID: machine.id, path: path)
        isLoadingFolders = true
        setCommandHealth(.checking, machineID: machine.id)
        errorMessage = nil
        defer { isLoadingFolders = false }
        do {
            let listing = try await remoteService(machineID: machine.id).loadFolders(machineID: machine.id, path: path)
            remoteFolders = listing.folders
            currentFolderPath = listing.currentPath
            let snapshot = RemoteFolderSnapshot(machineID: machine.id, path: path, folders: listing.folders)
            folderSnapshots[folderCacheKey(machineID: machine.id, path: path)] = snapshot
            folderSnapshot = snapshot
            setCommandHealth(.responsive, machineID: machine.id)
            lastRemoteDiagnosticReference = nil
        } catch {
            registerCommandFailure(error, machineID: machine.id)
            let previous = folderSnapshots[folderCacheKey(machineID: machine.id, path: path)]
            folderSnapshot = previous.map {
                .init(
                    machineID: $0.machineID,
                    path: $0.path,
                    folders: $0.folders,
                    loadedAt: $0.loadedAt,
                    isFromCache: true,
                    errorCode: commandErrorCode(error)
                )
            }
            errorMessage = commandMessage(for: error)
        }
    }

    func createFolder(name: String) async -> RemoteFolder? {
        guard let machine = selectedMachine, let parent = currentFolderPath else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        isLoadingFolders = true
        errorMessage = nil
        defer { isLoadingFolders = false }
        do {
            let folder = try await remoteService(machineID: machine.id).createFolder(machineID: machine.id, parent: parent, name: cleanName)
            if !remoteFolders.contains(where: { $0.path == folder.path }) {
                remoteFolders.append(folder)
                remoteFolders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            let snapshot = RemoteFolderSnapshot(machineID: machine.id, path: parent, folders: remoteFolders)
            folderSnapshots[folderCacheKey(machineID: machine.id, path: parent)] = snapshot
            folderSnapshot = snapshot
            setCommandHealth(.responsive, machineID: machine.id)
            return folder
        } catch {
            registerCommandFailure(error, machineID: machine.id)
            errorMessage = commandMessage(for: error)
            return nil
        }
    }

    func selectMachine(id: String) async {
        guard securityContextIsCurrent(), let machine = overview.machines.first(where: { $0.id == id }) else { return }
        preferredRemoteMachine = .init(id: machine.id, name: machine.name)
        if let machineSelectionKey, let bytes = try? JSONEncoder().encode(preferredRemoteMachine) {
            machineSelectionDefaults.set(bytes, forKey: machineSelectionKey)
        }
        guard selectedMachineID != id else { return }
        selectedMachineID = id
        selectedWorkspace = nil
        pendingCreationSessionIDs[mode] = nil
        restoreFolderSnapshot(machineID: id, path: nil)
        currentFolderPath = nil
        let capabilities = overview.machines.first(where: { $0.id == id })?.capabilities
        // Preserve the selected reference, including an unavailable model.
        // The user must choose its replacement explicitly on this target.
        selectedAgentSystem = mode == .agent
            ? RemoteEngineRules.engines(capabilities: capabilities).first(where: { $0.id == .aim && $0.selectable })?.id.rawValue
            : nil
        if mode != .chat { await loadFolders() }
    }

    var offersWorkerPlacement: Bool {
        overview.machines.filter { $0.capabilities?.worker?.version == 1 }.count > 1
    }
    func authorizeWorkerWorkspace(_ path: String) {
        selectedWorkspace = path
        guard let machineID = selectedMachine?.id, path.hasPrefix("/") else { return }
        workerWorkspaces[machineID] = path
        do { try saveContinuityReceipts() }
        catch { errorMessage = commandMessage(for: error) }
    }

    func createRemoteSession(
        text: String,
        attachments: [RemoteAttachmentReference] = [],
        goalMaximumTurns: Int? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode != .chat, (!trimmed.isEmpty || !attachments.isEmpty), !isSending else { return false }
        var placementKey: String?
        if goalMaximumTurns != nil {
            let fields = [mode.rawValue, selectedModelID, selectedModelProvider ?? "", selectedApprovalMode, selectedEffort ?? "", selectedAgentSystem ?? "", trimmed,
                goalMaximumTurns.map(String.init) ?? ""]
            guard let data = try? JSONEncoder().encode(fields) else { return false }
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if automaticWorkerPlacement || workerPlacements[key] != nil {
            guard continuityStorageAvailable, queueURL != nil else { errorMessage = "The saved worker placement needs review before sending."; return false }
            guard attachments.isEmpty else { errorMessage = "Automatic placement does not support attachments."; return false }
            placementKey = key
            let placement: RemoteWorkerPlacement
            if let previous = workerPlacements[key] {
                guard previous.version == 1 else { errorMessage = "This saved placement needs review."; return false }
                placement = previous
            } else {
                var authorized = workerWorkspaces
                if let machine = selectedMachine, let path = selectedWorkspace { authorized[machine.id] = path }
                guard let chosen = RemoteWorkerPlacementRules.choose(machines: overview.machines, mode: mode,
                    modelID: selectedModelID, authorizedWorkspaces: authorized, allowingExperimental: experimentalContinuityEnabled) else {
                    errorMessage = "No available computer supports this goal and has a folder you selected."; return false
                }
                placement = chosen
                workerPlacements[key] = chosen
                do { try saveContinuityReceipts() }
                catch { workerPlacements[key] = nil; errorMessage = commandMessage(for: error); return false }
            }
            // Persist before submitting; reconnect can only target the same worker.
            selectedMachineID = placement.machineID; selectedWorkspace = placement.workspace
            }
        }
        guard let machine = selectedMachine, machine.isOnline(), let selectedWorkspace else {
            if placementKey != nil { errorMessage = "The computer assigned to this goal is offline. Reconnect to recover its admission." }
            return false
        }
        guard supportsExplicitModelRoute(selectedModelID, machine: machine) else { return false }
        if placementKey != nil, !RemoteContinuityRules.supported(capabilities: machine.capabilities, allowingExperimental: experimentalContinuityEnabled) {
            errorMessage = "The assigned computer no longer advertises this goal contract. Review its availability before recovering the admission."
            return false
        }
        isSending = true
        setCommandHealth(.checking, machineID: machine.id)
        errorMessage = nil
        defer { isSending = false }
        do {
            let continuous = goalMaximumTurns != nil && RemoteContinuityRules.supported(capabilities: machine.capabilities, allowingExperimental: experimentalContinuityEnabled)
            let fields = [mode.rawValue, machine.id, selectedWorkspace, selectedModelID, selectedModelProvider ?? "", selectedApprovalMode,
                selectedEffort ?? "", selectedAgentSystem ?? "", trimmed, goalMaximumTurns.map(String.init) ?? ""]
                + attachments.flatMap { [$0.transferID, $0.name, $0.mimeType, String($0.size)] }
            let fingerprint = SHA256.hash(data: try JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
            let sessionID: String
            if continuous, let admission = admittedContinuousCreations[mode.rawValue], admission.fingerprint == fingerprint {
                // The objective already runs on the Mac. Recover its view instead
                // of sending the initial prompt or admitting a second mission.
                sessionID = admission.sessionID
            } else if let pendingCreationSessionID = pendingCreationSessionIDs[mode] {
                var payload = RemoteAttachmentRules.messagePayload(text: trimmed, attachments: attachments)
                if let goalMaximumTurns, var object = payload.objectValue {
                    object["goal"] = RemoteContinuityRules.supported(capabilities: machine.capabilities, allowingExperimental: experimentalContinuityEnabled)
                        ? RemoteContinuousGoalConfiguration(maximumTurns: goalMaximumTurns == 0 ? nil : goalMaximumTurns).json
                        : RemoteGoalConfiguration(maximumTurns: goalMaximumTurns).json
                    payload = .object(object)
                }
                let result = try await remoteService(machineID: machine.id).sendCommand(
                    machineID: machine.id,
                    sessionID: pendingCreationSessionID,
                    type: .userMessage,
                    payload: payload
                )
                guard result.succeeded else {
                    throw RemoteServiceError.commandRejected(result.errorCode ?? "unknown")
                }
                sessionID = pendingCreationSessionID
            } else {
                sessionID = try await remoteService(machineID: machine.id).createSession(
                    .init(
                        machineID: machine.id,
                        mode: mode,
                        modelID: selectedModelID,
                        workspace: selectedWorkspace,
                        approvalMode: selectedApprovalMode,
                        text: trimmed,
                        agentSystem: mode == .agent ? selectedAgentSystem : nil,
                        effort: selectedEffort,
                        attachments: attachments,
                        goal: goalMaximumTurns.map { maximum in
                            RemoteContinuityRules.supported(capabilities: machine.capabilities, allowingExperimental: experimentalContinuityEnabled)
                                ? RemoteGoalConfiguration(continuous: true, maximumTurns: maximum == 0 ? nil : maximum)
                                : RemoteGoalConfiguration(maximumTurns: maximum)
                        },
                        provider: selectedModelProvider
                    )
                )
            }
            if continuous {
                admittedContinuousCreations[mode.rawValue] = ContinuityCreationAdmission(fingerprint: fingerprint, sessionID: sessionID)
                try saveContinuityReceipts()
            }
            overview = removingAnsweredApprovals(from: try await service.loadOverview())
            guard let session = overview.sessions.first(where: { $0.id == sessionID }) else {
                throw RemoteServiceError.sessionUnavailable
            }
            await selectSession(session)
            if continuous { admittedContinuousCreations.removeValue(forKey: mode.rawValue) }
            if let placementKey { workerPlacements.removeValue(forKey: placementKey) }
            if continuous || placementKey != nil { try saveContinuityReceipts() }
            pendingCreationSessionIDs[mode] = nil
            creationDrafts[mode] = .init()
            setCommandHealth(.responsive, machineID: machine.id)
            lastRemoteDiagnosticReference = nil
            return true
        } catch {
            registerCommandFailure(error, machineID: machine.id)
            errorMessage = commandMessage(for: error)
            return false
        }
    }

    private func preparedRemoteURL(_ transferID: String) -> URL? {
        guard let owner = mediaAccountID, let id = UUID(uuidString: transferID) else { return nil }
        return URL.applicationSupportDirectory.appending(path: "Chat/" + owner.uuidString + "/RemotePreviews/" + id.uuidString.lowercased() + ".json")
    }
    private func retainPreparedRemoteInput(_ input: NativeChatAttachment, transferID: String) throws {
        guard let output = preparedRemoteURL(transferID) else { throw NativeDocumentError.invalidSelection }
        try NativeChatAttachment.validate([input])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(input).write(to: output, options: [.atomic, .completeFileProtection])
    }
    func preparedRemoteInput(_ transferID: String) -> NativeChatAttachment? {
        guard let url = preparedRemoteURL(transferID), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= RemoteAttachmentRules.maximumSize, let data = try? Data(contentsOf: url),
              let input = try? JSONDecoder().decode(NativeChatAttachment.self, from: data),
              (try? NativeChatAttachment.validate([input])) != nil else { return nil }
        return input
    }
    func originalRemoteInput(_ input: NativeChatAttachment) -> URL? {
        guard let owner = mediaAccountID else { return nil }
        return PrivateInputMedia.original(root: URL.applicationSupportDirectory.appending(path: "Chat/" + owner.uuidString), accountID: owner, attachmentID: input.id)
    }

    private func prepareRemoteInput(_ data: Data, name: String, mimeType: String, options: VideoPreparationOptions) async throws -> (data: Data, mimeType: String, preview: Data?, input: NativeChatAttachment?) {
        let ext = (name as NSString).pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "m4v"].contains(ext)
        let isImage = ["png", "jpg", "jpeg", "heic", "heif"].contains(ext)
        guard isVideo || isImage else { return (data, mimeType, nil, nil) }
        guard let owner = mediaAccountID, data.count <= (isVideo ? 250_000_000 : 20_000_000) else { throw NativeDocumentError.limit }
        let root = URL.applicationSupportDirectory.appending(path: "Chat/" + owner.uuidString)
        let scratch = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent((name as NSString).lastPathComponent)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        if isImage {
            let job = Task.detached { try NativeChatAttachment.prepare(file) }
            let input = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            _ = try PrivateInputMedia.retain(file, root: root, accountID: owner, attachmentID: input.id)
            return (input.data ?? data, input.mimeType, input.data, input)
        }
        let deviceID = UserDefaults.standard.string(forKey: "aim.activity.installation") ?? "unknown"
        let video = try await VideoPreparationService.prepare(file, mode: options.mode, range: try options.range(), originDeviceID: deviceID, originDeviceName: UIDevice.current.name)
        _ = try PrivateInputMedia.retain(file, root: root, accountID: owner, attachmentID: video.id)
        let input = NativeChatAttachment(id: video.id, name: name, kind: .document, mimeType: PreparedInputTransfer.mimeType, text: video.context, video: video)
        return (try PreparedInputTransfer.encode(input), PreparedInputTransfer.mimeType, video.frames.first?.jpeg, input)
    }

    func uploadNewSessionAttachment(data: Data, name: String, mimeType: String, options: VideoPreparationOptions = .init()) async -> RemoteAttachmentReference? {
        guard
            mode != .chat,
            let machine = selectedMachine,
            let selectedWorkspace,
            RemoteAttachmentRules.availableAtCreation(capabilities: machine.capabilities, mode: mode)
        else { return nil }

        do {
            let prepared = try await prepareRemoteInput(data, name: name, mimeType: mimeType, options: options)
            let sessionID: String
            if let pendingCreationSessionID = pendingCreationSessionIDs[mode] {
                sessionID = pendingCreationSessionID
            } else {
                sessionID = try await remoteService(machineID: machine.id).createSession(
                    .init(
                        machineID: machine.id,
                        mode: mode,
                        modelID: selectedModelID,
                        workspace: selectedWorkspace,
                        approvalMode: selectedApprovalMode,
                        text: "",
                        agentSystem: mode == .agent ? selectedAgentSystem : nil,
                        effort: selectedEffort,
                        defersInitialMessage: true,
                        provider: selectedModelProvider
                    )
                )
                pendingCreationSessionIDs[mode] = sessionID
            }
            let reference = try await remoteService(machineID: machine.id).uploadAttachment(
                data: prepared.data,
                name: name,
                mimeType: prepared.mimeType,
                machineID: machine.id,
                sessionID: sessionID
            )
            if let input = prepared.input { try retainPreparedRemoteInput(input, transferID: reference.transferID) }
            if let preview = prepared.preview { AIMAttachmentPreviewCache.shared.store(data: preview, for: reference.transferID) }
            return reference
        } catch {
            registerCommandFailure(error, machineID: machine.id)
            errorMessage = commandMessage(for: error)
            return nil
        }
    }

    func selectSession(_ session: RemoteSession) async {
        prepareSessionSelection(session)
        await loadPreparedSession(session)
    }

    func prepareSessionSelection(_ session: RemoteSession) {
        if let selectedSessionID { remoteMessageCache[selectedSessionID] = messages }
        selectedMachineID = session.machineID
        selectedSessionID = session.id
        destination = .conversation(session.id)
        messages = needsProtectionGate(for: session.mode) ? [] : remoteMessageCache[session.id] ?? []
        isLoadingConversation = true
    }

    func loadPreparedSession(_ session: RemoteSession) async {
        messageReadGeneration &+= 1
        let readGeneration = messageReadGeneration, context = remoteSecurityGeneration
        defer { if readGeneration == messageReadGeneration { isLoadingConversation = false } }
        do {
            let loaded = try await remoteService(machineID: session.machineID).loadMessages(sessionID: session.id, machineID: session.machineID)
            guard readGeneration == messageReadGeneration, context == remoteSecurityGeneration, securityContextIsCurrent(), !isRemoteSuspended(machineID: session.machineID), selectedSessionID == session.id else { return }
            messages = preservingActiveAssistantText(in: loaded, session: session)
            remoteMessageCache[session.id] = messages
        } catch {
            guard readGeneration == messageReadGeneration, context == remoteSecurityGeneration, securityContextIsCurrent() else { return }
            errorMessage = isRemoteSuspended(machineID: session.machineID) ? String(localized: "remote.connection.suspended") : String(localized: "main.error.messages")
        }
    }

    func sendNewChat(
        text: String,
        attachments: [RemoteAttachmentReference] = []
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty || !attachments.isEmpty,
            !isSending,
            overview.connectionState == .paired,
            let machine = selectedMachine,
            machine.isOnline()
        else { return false }
        let matches = machine.capabilities?.models.filter { $0.id == selectedModelID && (selectedModelProvider == nil || $0.provider == selectedModelProvider) } ?? []
        guard supportsExplicitModelRoute(selectedModelID, machine: machine) else { return false }
        guard matches.count == 1 else {
            errorMessage = "Choose a model and provider available on the selected computer."
            return false
        }

        isSending = true
        setCommandHealth(.checking, machineID: machine.id)
        errorMessage = nil
        defer { isSending = false }
        do {
            let sessionID: String
            if let pendingCreationSessionID = pendingCreationSessionIDs[.chat] {
                let result = try await remoteService(machineID: machine.id).sendCommand(
                    machineID: machine.id,
                    sessionID: pendingCreationSessionID,
                    type: .userMessage,
                    payload: RemoteAttachmentRules.messagePayload(text: trimmed, attachments: attachments)
                )
                guard result.succeeded else {
                    throw RemoteServiceError.commandRejected(result.errorCode ?? "unknown")
                }
                sessionID = pendingCreationSessionID
            } else {
                sessionID = try await remoteService(machineID: machine.id).createSession(
                    .init(
                        machineID: machine.id,
                        mode: .chat,
                        modelID: selectedModelID,
                        text: trimmed,
                        effort: selectedEffort ?? RemoteEffortRules.effort(
                            capabilities: machine.capabilities,
                            modelID: selectedModelID, provider: selectedModelProvider
                        ).currentValue,
                        attachments: attachments,
                        provider: selectedModelProvider
                    )
                )
            }
            overview = removingAnsweredApprovals(from: try await service.loadOverview())
            guard let session = overview.sessions.first(where: { $0.id == sessionID }) else {
                throw RemoteServiceError.sessionUnavailable
            }
            await selectSession(session)
            pendingCreationSessionIDs[.chat] = nil
            creationDrafts[.chat] = .init()
            setCommandHealth(.responsive, machineID: machine.id)
            lastRemoteDiagnosticReference = nil
            return true
        } catch {
            registerCommandFailure(error, machineID: machine.id)
            errorMessage = commandMessage(for: error)
            return false
        }
    }

    func uploadNewChatAttachment(data: Data, name: String, mimeType: String, options: VideoPreparationOptions = .init()) async -> RemoteAttachmentReference? {
        guard
            mode == .chat,
            let machine = selectedMachine,
            RemoteAttachmentRules.availableAtCreation(capabilities: machine.capabilities, mode: .chat)
        else { return nil }

        do {
            let prepared = try await prepareRemoteInput(data, name: name, mimeType: mimeType, options: options)
            let sessionID: String
            if let pendingCreationSessionID = pendingCreationSessionIDs[.chat] {
                sessionID = pendingCreationSessionID
            } else {
                sessionID = try await remoteService(machineID: machine.id).createSession(
                    .init(
                        machineID: machine.id,
                        mode: .chat,
                        modelID: selectedModelID,
                        text: "",
                        effort: selectedEffort ?? RemoteEffortRules.effort(
                            capabilities: machine.capabilities,
                            modelID: selectedModelID, provider: selectedModelProvider
                        ).currentValue,
                        defersInitialMessage: true,
                        provider: selectedModelProvider
                    )
                )
                pendingCreationSessionIDs[.chat] = sessionID
            }
            let reference = try await remoteService(machineID: machine.id).uploadAttachment(
                data: prepared.data,
                name: name,
                mimeType: prepared.mimeType,
                machineID: machine.id,
                sessionID: sessionID
            )
            if let input = prepared.input { try retainPreparedRemoteInput(input, transferID: reference.transferID) }
            if let preview = prepared.preview { AIMAttachmentPreviewCache.shared.store(data: preview, for: reference.transferID) }
            return reference
        } catch {
            registerCommandFailure(error, machineID: machine.id)
            errorMessage = commandMessage(for: error)
            return nil
        }
    }

    func sendMessage(_ text: String, attachments: [RemoteAttachmentReference] = []) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty), !isSending, !drainingQueue, let session = selectedSession else { return false }
        isSending = true
        setCommandHealth(.checking, machineID: session.machineID)
        errorMessage = nil
        defer { isSending = false }
        do {
            let result = try await remoteService(machineID: session.machineID).sendCommand(
                machineID: session.machineID,
                sessionID: session.id,
                type: .userMessage,
                payload: RemoteAttachmentRules.messagePayload(text: trimmed, attachments: attachments)
            )
            guard result.succeeded else { throw RemoteServiceError.commandRejected(result.errorCode ?? "unknown") }
            try? await Task.sleep(for: .milliseconds(350))
            setCommandHealth(.responsive, machineID: session.machineID)
            lastRemoteDiagnosticReference = nil
            await refreshSelectedSession()
            return true
        } catch {
            registerCommandFailure(error, machineID: session.machineID)
            errorMessage = commandMessage(for: error)
            return false
        }
    }

    func uploadAttachment(data: Data, name: String, mimeType: String, options: VideoPreparationOptions = .init()) async -> RemoteAttachmentReference? {
        guard let session = selectedSession else { return nil }
        do {
            let prepared = try await prepareRemoteInput(data, name: name, mimeType: mimeType, options: options)
            let reference = try await remoteService(machineID: session.machineID).uploadAttachment(
                data: prepared.data,
                name: name,
                mimeType: prepared.mimeType,
                machineID: session.machineID,
                sessionID: session.id
            )
            if let input = prepared.input { try retainPreparedRemoteInput(input, transferID: reference.transferID) }
            if let preview = prepared.preview { AIMAttachmentPreviewCache.shared.store(data: preview, for: reference.transferID) }
            return reference
        } catch {
            errorMessage = commandMessage(for: error)
            return nil
        }
    }

    func requestDetail(id: String) async -> String? {
        guard let value = await requestDetailValue(id: id) else { return nil }
        if let object = value.objectValue {
            return object["content"]?.stringValue
                ?? object["text"]?.stringValue
                ?? object["detail"]?.stringValue
                ?? object["output"]?.stringValue
                ?? value.displayText
        }
        return value.displayText
    }

    func requestDetailValue(id: String, offset: Int = 0) async -> RemoteJSONValue? {
        guard let session = selectedSession else { return nil }
        setCommandHealth(.checking, machineID: session.machineID)
        do {
            let value = try await remoteService(machineID: session.machineID).requestDetail(
                machineID: session.machineID,
                sessionID: session.id,
                detailID: id, offset: offset
            )
            setCommandHealth(.responsive, machineID: session.machineID)
            lastRemoteDiagnosticReference = nil
            return value
        } catch {
            registerCommandFailure(error, machineID: session.machineID)
            errorMessage = commandMessage(for: error)
            return nil
        }
    }

    func respondToApproval(approved: Bool) async -> Bool {
        guard let approval = selectedSession?.pendingApproval else { return false }
        if supportsContinuousGoals, let execution = approval.executionID, let session = approval.sessionID {
            return await performCommand(.continuousGoalApproval, payload: .object([
                "execution_id": .string(execution), "sessionId": .string(session),
                "messageId": .string(approval.messageID), "approved": .bool(approved)]))
        }
        return await performCommand(
            .approvalResponse,
            payload: .object([
                "approved": .bool(approved),
                "messageId": .string(approval.messageID),
            ])
        )
    }

    func respondToVisualApproval(_ approval: RemotePendingApproval, provider: String?, modelID: String?, remember: Bool, approved: Bool) async -> Bool {
        guard let session = selectedSession, let current = session.pendingApproval, current.messageID == approval.messageID, current.kind == "visual", approval.kind == "visual" else { return false }
        var fields: [String: RemoteJSONValue] = ["messageId": .string(approval.messageID), "approved": .bool(approved), "remember": .bool(remember)]
        if approved {
            guard let provider, let modelID, current.questions?.contains(where: { $0.objectValue?["provider"]?.stringValue == provider && $0.objectValue?["model_id"]?.stringValue == modelID }) == true else { return false }
            fields["visual_provider"] = .string(provider); fields["visual_model"] = .string(modelID)
        }
        return await performCommand(.approvalResponse, payload: .object(fields))
    }

    func respondToQuestion(answers: String) async -> Bool {
        let trimmed = answers.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let approval = selectedSession?.pendingApproval else { return false }
        if supportsContinuousGoals, let execution = approval.executionID {
            return await performCommand(.continuousGoalQuestion, payload: .object([
                "execution_id": .string(execution), "messageId": .string(approval.messageID), "answers": .string(trimmed)]))
        }
        return await performCommand(
            .approvalResponse,
            payload: .object([
                "answers": .string(trimmed),
                "messageId": .string(approval.messageID),
            ])
        )
    }

    func selectModel(_ model: RemoteModelAnnouncement) {
        selectedModelID = model.id
        selectedModelProvider = model.provider
        selectedEffort = model.currentEffort
    }

    private func supportsExplicitModelRoute(_ modelID: String, machine: RemoteMachine?) -> Bool {
        let routes = machine?.capabilities?.models.filter { $0.id == modelID } ?? []
        guard routes.count > 1, machine?.capabilities?.features["modelRouting"] != true else { return true }
        errorMessage = "Update the selected Mac before choosing between providers for this model."
        return false
    }

    func setModel(_ modelID: String, effort: String? = nil, provider: String? = nil) async -> Bool {
        guard supportsExplicitModelRoute(modelID, machine: overview.machines.first(where: { $0.id == selectedSession?.machineID })) else { return false }
        var payload: [String: RemoteJSONValue] = ["model_id": .string(modelID)]
        if let provider { payload["provider"] = .string(provider) }
        if let effort, !effort.isEmpty { payload["effort"] = .string(effort) }
        return await performCommand(.setModel, payload: .object(payload))
    }

    func setModelAdded(model: RemoteModelAnnouncement, added: Bool) async -> Bool {
        await performCommand(.setModelAdded, payload: .object([
            "model_id": .string(model.id), "provider": .string(model.provider), "added": .bool(added)
        ]))
    }

    func setApprovalMode(_ mode: String) async -> Bool {
        await performCommand(.setApprovalMode, payload: .object(["mode": .string(mode)]))
    }

    func sendGoal(
        _ text: String,
        maximumTurns: Int,
        attachments: [RemoteAttachmentReference] = []
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, selectedSession?.mode != .chat else { return false }
        var payload = RemoteAttachmentRules.messagePayload(text: trimmed, attachments: attachments).objectValue ?? [:]
        if supportsContinuousGoals {
            payload["goal"] = RemoteContinuousGoalConfiguration(maximumTurns: maximumTurns == 0 ? nil : maximumTurns).json
            return await performCommand(.startContinuousGoal, payload: .object(payload))
        }
        payload["goal"] = .object([
            "max_turns": .number(Double(min(50, max(1, maximumTurns)))),
        ])
        return await performCommand(
            .userMessage,
            payload: .object(payload)
        )
    }

    var offersExperimentalContinuity: Bool {
        let machineID = selectedSession?.machineID ?? selectedMachine?.id
        return overview.machines.first { $0.id == machineID }?.capabilities?.supports(RemoteCapabilities.Feature.experimentalContinuity) == true
    }
    var supportsContinuousGoals: Bool {
        let machineID = selectedSession?.machineID ?? selectedMachine?.id
        return RemoteContinuityRules.supported(capabilities: overview.machines.first { $0.id == machineID }?.capabilities, allowingExperimental: experimentalContinuityEnabled)
    }
    func refreshContinuousGoal() async -> Bool { await continuousCommand(.continuousGoalStatus) }
    /// A status poll must not lock the command composer or replace an error
    /// from an explicit user action. The relay remains the access authority.
    func refreshContinuousGoalInBackground(sessionID: String) async {
        guard !Task.isCancelled, !refreshingContinuityStatus, !isSending,
              supportsContinuousGoals, let session = selectedSession, session.id == sessionID,
              session.mode != .chat else { return }
        if let state = continuitySnapshots[sessionID]?.state,
           ["cancelled", "accepted", "verified", "failed"].contains(state) { return }
        refreshingContinuityStatus = true
        defer { refreshingContinuityStatus = false }
        var fields: [String: RemoteJSONValue] = ["version": .number(1)]
        if let snapshot = continuitySnapshots[sessionID] { fields["execution_id"] = .string(snapshot.executionID) }
        do {
            let result = try await remoteService(machineID: session.machineID).sendCommand(machineID: session.machineID, sessionID: sessionID,
                type: .continuousGoalStatus, payload: .object(fields))
            guard !Task.isCancelled, selectedSessionID == sessionID, result.succeeded else { return }
            try saveContinuityReceipt(result, sessionID: sessionID)
        } catch { /* Keep the last readable state until connectivity returns. */ }
    }
    func pauseContinuousGoal() async -> Bool { await continuousCommand(.pauseContinuousGoal) }
    func resumeContinuousGoal() async -> Bool { await continuousCommand(.resumeContinuousGoal) }
    func cancelContinuousGoal() async -> Bool { await continuousCommand(.cancelContinuousGoal) }
    func acceptContinuousGoal() async -> Bool { await continuousCommand(.acceptContinuousGoal) }
    func correctContinuousGoal(_ text: String) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return await continuousCommand(.correctContinuousGoal, fields: ["text": .string(text)])
    }
    private func continuousCommand(_ type: RemoteCommandType, fields: [String: RemoteJSONValue] = [:]) async -> Bool {
        guard supportsContinuousGoals, let session = selectedSession, session.mode != .chat else { return false }
        var payload = fields
        payload["version"] = .number(1)
        if let snapshot = continuitySnapshots[session.id] { payload["execution_id"] = .string(snapshot.executionID) }
        return await performCommand(type, payload: .object(payload))
    }
    private func saveContinuityReceipt(_ response: RemoteCommandResult, sessionID: String) throws {
        guard let value = response.result, let snapshot = RemoteContinuitySnapshot(json: value) else { return }
        if let previous = continuitySnapshots[sessionID], previous.executionID == snapshot.executionID, previous.revision > snapshot.revision { return }
        continuitySnapshots[sessionID] = snapshot
        if let commandID = response.commandID { continuityCommandIDs[sessionID] = commandID }
        try saveContinuityReceipts()
    }
    private func saveContinuityReceipts() throws {
        guard continuityStorageAvailable else { throw CocoaError(.fileReadCorruptFile) }
        guard let queueURL else { return }
        let url = queueURL.deletingPathExtension().appendingPathExtension("continuity.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let receipt = ContinuityClientReceipts(snapshots: continuitySnapshots, commandIDs: continuityCommandIDs,
            admittedCreations: admittedContinuousCreations, workerWorkspaces: workerWorkspaces, workerPlacements: workerPlacements)
        try JSONEncoder().encode(receipt).write(to: url, options: [.atomic, .completeFileProtection])
    }

    func stopGeneration() async -> Bool {
        await performCommand(.stopGeneration, payload: .object([:]))
    }

    func resumeTurn() async -> Bool {
        await performCommand(.resumeTurn, payload: .object([:]))
    }

    func requestDiff() async throws -> RemoteDiffResult {
        guard let session = selectedSession else { throw RemoteServiceError.sessionUnavailable }
        return try await remoteService(machineID: session.machineID).requestDiff(machineID: session.machineID, sessionID: session.id)
    }

    func runTerminalCommand(_ command: String) async throws -> RemoteTerminalResult {
        guard let session = selectedSession else { throw RemoteServiceError.sessionUnavailable }
        return try await remoteService(machineID: session.machineID).runTerminalCommand(command, machineID: session.machineID, sessionID: session.id)
    }

    func stopTerminalCommand() async throws {
        guard let session = selectedSession else { throw RemoteServiceError.sessionUnavailable }
        try await remoteService(machineID: session.machineID).stopTerminalCommand(machineID: session.machineID, sessionID: session.id)
    }

    func startPreview(script: String? = nil) async throws -> RemotePreviewResult {
        guard let session = selectedSession else { throw RemoteServiceError.sessionUnavailable }
        return try await remoteService(machineID: session.machineID).startPreview(script: script, machineID: session.machineID, sessionID: session.id)
    }

    func performBrowserAction(_ name: String, arguments: [String: String]) async throws -> RemotePreviewResult {
        guard let session = selectedSession, session.mode != .chat else { throw RemoteServiceError.sessionUnavailable }
        let value = try await remoteService(machineID: session.machineID).sendCommand(machineID: session.machineID, sessionID: session.id, type: .startPreview,
            payload: .object(["browser": .object(["version": .number(1), "name": .string(name),
                "arguments": .object(arguments.mapValues(RemoteJSONValue.string))])]))
        guard value.succeeded else { throw RemoteServiceError.commandRejected(value.errorCode ?? "navigateur_indisponible") }
        return RemotePreviewResult(json: value.result ?? .null)
    }

    func stopPreview() async throws {
        guard let session = selectedSession else { throw RemoteServiceError.sessionUnavailable }
        try await remoteService(machineID: session.machineID).stopPreview(machineID: session.machineID, sessionID: session.id)
    }

    private func preservingActiveAssistantText(in snapshot: [RemoteMessage], session: RemoteSession) -> [RemoteMessage] {
        guard selectedSessionID == session.id, ["running", "waiting_approval"].contains(selectedSession?.status ?? "") else { return snapshot }
        let previous = Dictionary(messages.filter { $0.sessionID == session.id }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let latestID = snapshot.last(where: { $0.role == .assistant })?.id
        return snapshot.map { incoming in
            guard incoming.id == latestID, incoming.role == .assistant, incoming.readState == .readable,
                  let old = previous[incoming.id], old.readState == .readable,
                  !old.content.isEmpty, old.content.hasPrefix(incoming.content), old.content.count > incoming.content.count else { return incoming }
            return RemoteMessage(id: incoming.id, sessionID: incoming.sessionID, sequence: incoming.sequence,
                role: incoming.role, content: old.content, reasoning: incoming.reasoning, timeline: incoming.timeline,
                toolCalls: incoming.toolCalls, model: incoming.model, runStats: incoming.runStats, readState: incoming.readState)
        }
    }

    func refreshSelectedSession() async {
        guard !observationPaused, let session = selectedSession, !isRemoteSuspended(machineID: session.machineID) else { return }
        messageReadGeneration &+= 1
        let readGeneration = messageReadGeneration, context = remoteSecurityGeneration
        defer { if readGeneration == messageReadGeneration { isLoadingConversation = false } }
        do {
            let refreshed = try await remoteService(machineID: session.machineID).loadMessages(sessionID: session.id, machineID: session.machineID)
            guard readGeneration == messageReadGeneration, context == remoteSecurityGeneration, securityContextIsCurrent(), !observationPaused, selectedSessionID == session.id, !isRemoteSuspended(machineID: session.machineID) else { return }
            // Preserve earlier history pages while replacing the live window.
            let windowIDs = Set(refreshed.map(\.id))
            messages = (messages.filter { !windowIDs.contains($0.id) } + preservingActiveAssistantText(in: refreshed, session: session)).sorted { $0.sequence < $1.sequence }
        } catch {
            // A transient refresh failure keeps the last readable conversation on screen.
        }
    }

    func observeRemoteChanges() async {
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                if observationPaused && !Task.isCancelled {
                    await withCheckedContinuation { continuation in
                        if Task.isCancelled || !observationPaused { continuation.resume() }
                        else { observationResumeWaiter = continuation }
                    }
                }
                guard !Task.isCancelled else { return }
                // Suspending a Mac drops its active subscription, retaining account overview updates.
                let watchedSessionID = selectedSession.flatMap { isRemoteSuspended(machineID: $0.machineID) || liveTurn($0).map(cancelledObservationTurns.contains) == true ? nil : $0.id }
                let watchedTurn = liveTurn(selectedSession)
                let follower = Task { [weak self] in
                    guard let self else { return }
                    let stream = await service.events(for: watchedSessionID)
                    for await event in stream {
                        guard !Task.isCancelled else { return }
                        await handleRemoteEvent(event)
                    }
                }
                remoteEventTask = follower
                await follower.value
                guard !Task.isCancelled else { return }
                if follower.isCancelled { continue }
                if let watchedTurn, watchedTurn == liveTurn(selectedSession) { recordObservationInterruption(for: selectedSession, expectedTurn: watchedTurn) }
                else { interruptedTurn = nil; interruptionStarted = nil; observationAttempts = 0; persistInterruption() }
                observationNotice = nil
                await load()
                if watchedSessionID != nil { await refreshSelectedSession() }
                let delay = min(pow(2.0, Double(max(0, min(5, observationAttempts - 1)))), 30)
                try? await Task.sleep(for: .seconds(delay))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.remoteEventTask?.cancel()
                self?.observationResumeWaiter?.resume(); self?.observationResumeWaiter = nil
            }
        }
    }

    func handleRemoteEvent(_ event: RemoteEvent) async {
        guard !observationPaused else { return }
        switch event {
        case .overviewChanged:
            await load()
            if selectedSessionID != nil { await refreshSelectedSession() }
        case let .messagesChanged(sessionID):
            guard sessionID == selectedSessionID else { return }
            await refreshSelectedSession()
            interruptedTurn = nil; interruptionStarted = nil; observationNotice = nil; observationAttempts = 0; persistInterruption()
        }
    }

    func closeSession() {
        selectedSessionID = nil
        messages = []
    }

    func pair(code: String, name: String) async -> Bool {
        await pair(code: code, name: name, allowsAuthenticationRecovery: true)
    }

    private func pair(code: String, name: String, allowsAuthenticationRecovery: Bool) async -> Bool {
        await installRemoteAccessPolicy()
        guard !isPairing else { return false }
        invalidateRemoteSecurityContext()
        let machinesBeforePairing = Set(overview.machines.map(\.id))
        let targetBeforePairing = selectedMachineID
        isPairing = true
        errorMessage = nil
        pairingDiagnosticCode = nil
        var succeeded = false
        do {
            let result = try await service.pairDevice(code: code, name: name)
            succeeded = result.succeeded
            if result.succeeded {
                // The one-time code is consumed by the successful RPC. From
                // this point on, refreshing the mirror and receiving the E2E
                // key envelope are asynchronous follow-up work, not a reason
                // to report that pairing failed.
                overview = .init(
                    connectionState: .paired,
                    machines: overview.machines,
                    sessions: overview.sessions
                )
                hasLoaded = true
                inlineErrorMessage = nil

                for delay in [Duration.zero, .milliseconds(350), .milliseconds(900)] {
                    if delay != .zero { try? await Task.sleep(for: delay) }
                    do {
                        overview = removingAnsweredApprovals(from: try await service.loadOverview())
                        break
                    } catch {
                        // Keep the confirmed pairing and retry briefly. Normal
                        // polling and Realtime key events continue afterwards.
                    }
                }
            } else {
                errorMessage = pairingMessage(for: result.errorCode)
                pairingDiagnosticCode = RemotePairingFailure(
                    stage: .response,
                    code: result.errorCode ?? "UNKNOWN"
                ).reference
            }
        } catch RemoteServiceError.invalidPairingCode {
            errorMessage = String(localized: "main.pair.invalid")
        } catch let RemoteServiceError.pairingFailed(failure) {
            if failure.stage == .authentication, allowsAuthenticationRecovery {
                isPairing = false
                if await recoverAuthentication() {
                    return await pair(code: code, name: name, allowsAuthenticationRecovery: false)
                }
            }
            pairingDiagnosticCode = failure.reference
            errorMessage = String(localized: "main.pair.failed")
        } catch {
            pairingDiagnosticCode = RemotePairingFailure(stage: .response, code: "UNKNOWN").reference
            errorMessage = String(localized: "main.pair.failed")
        }
        if succeeded {
            selectedMachineID = targetBeforePairing
            let added = overview.machines.first { !machinesBeforePairing.contains($0.id) }
            pairingSuccessMessage = added.map { "\($0.name) — " + ($0.readState.blocksReading ? String(localized: "remote.pair.keys_pending") : String(localized: "settings.connection.success")) } ?? String(localized: "remote.pair.keys_pending")
        }
        isPairing = false
        return succeeded
    }

    func clearError() {
        errorMessage = nil
        pairingDiagnosticCode = nil
        inlineErrorMessage = nil
        lastRemoteDiagnosticReference = nil
    }

    func diagnosticReportFile() async -> URL? {
        let source = await service.diagnosticReport()
        let selection = selectedMachineID.map { id in
            RemoteDiagnosticEntry(commandIdentifier: "", machineIdentifier: RemoteDiagnosticPrivacy.identifier(id.lowercased()),
                type: "selected_machine", stage: .published, status: "selected", durationMilliseconds: 0)
        }
        let report = RemoteDiagnosticReport(formatVersion: 2, appVersion: source.appVersion,
            entries: source.entries + (selection.map { [$0] } ?? []), links: source.links,
            installationIdentifier: source.installationIdentifier, buildVersion: source.buildVersion, relayIdentifier: source.relayIdentifier)
        guard let data = try? report.encodedData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aim-remote-diagnostic-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    var macSettingsAvailability: RemoteMacSettingsAvailability {
        let authorized = remoteDeviceAuthorized
        if let selectedMachineID, isRemoteSuspended(machineID: selectedMachineID) { return .offline }
        return .resolve(connection: overview.connectionState, machine: selectedMachine, authorized: authorized)
    }

    func macSettings(_ value: RemoteMacSettings? = nil, machineID expectedMachineID: String? = nil) async throws -> RemoteMacSettings {
        let generation = remoteSecurityGeneration
        guard securityCurrent(generation), let machine = selectedMachine,
              expectedMachineID == nil || expectedMachineID == machine.id else { throw CancellationError() }
        guard macSettingsAvailability == .ready else { throw RemoteMacSettingsError.unavailable(macSettingsAvailability) }
        do {
            let result = try await remoteService(machineID: machine.id).sendCommand(machineID: machine.id, sessionID: "", type: value == nil ? .getMacSettings : .setMacSettings, payload: value?.json ?? .object([:]))
            guard securityCurrent(generation), selectedMachine?.id == machine.id else { throw CancellationError() }
            guard result.succeeded else { throw RemoteSecurityServiceError.server(code: result.errorCode ?? "settings_unavailable") }
            guard let json = result.result else { throw RemoteMacSettingsError.invalidResponse }
            return try RemoteMacSettings(json: json)
        } catch is CancellationError { throw CancellationError() }
        catch { throw RemoteMacSettingsError.classify(error) }
    }

    func skillCommand(name: String? = nil) async throws -> RemoteJSONValue {
        let generation = remoteSecurityGeneration
        guard securityCurrent(generation), let machine = selectedMachine else { throw CancellationError() }
        guard macSettingsAvailability == .ready else { throw RemoteMacSettingsError.unavailable(macSettingsAvailability) }
        let payload = try NativeSkillImportContract.request(name: name)
        let result = try await remoteService(machineID: machine.id).sendCommand(machineID: machine.id, sessionID: "", type: .getMacSettings, payload: payload)
        guard securityCurrent(generation), selectedMachine?.id == machine.id else { throw CancellationError() }
        guard result.succeeded, let value = result.result else { throw RemoteSecurityServiceError.server(code: result.errorCode ?? "skills_unavailable") }
        return value
    }

    func refreshMacConnectors() async {
        if macConnectorMachineID != selectedMachineID { macConnectors = []; macConnectorMachineID = selectedMachineID }
        let generation = remoteSecurityGeneration
        guard securityCurrent(generation), let machine = selectedMachine, macSettingsAvailability == .ready else { return }
        do {
            let result = try await remoteService(machineID: machine.id).sendCommand(machineID: machine.id, sessionID: "", type: .getMacSettings, payload: .object(["section": .string("connectors")]))
            guard securityCurrent(generation), selectedMachine?.id == machine.id, result.succeeded, let value = result.result else { return }
            macConnectors = try RemoteConnectorDirectory(json: value).connectors
        } catch { /* Keep display-only metadata for this Mac while offline. */ }
    }

    func remoteDownload(_ fields: [String: RemoteJSONValue], mutate: Bool = false, machineID: String) async throws -> RemoteJSONValue {
        let generation = remoteSecurityGeneration
        guard securityCurrent(generation), selectedMachine?.id == machineID,
              !isRemoteSuspended(machineID: machineID), selectedMachine?.isOnline() == true,
              selectedMachine?.capabilities?.features["remoteDownloads"] == true else { throw RemoteServiceError.commandRejected("selected_mac_unavailable") }
        var payload = fields; payload["section"] = .string("downloads"); payload["version"] = .number(1)
        let result = try await remoteService(machineID: machineID).sendCommand(machineID: machineID, sessionID: "", type: mutate ? .setMacSettings : .getMacSettings, payload: .object(payload))
        guard securityCurrent(generation), selectedMachine?.id == machineID else { throw CancellationError() }
        guard result.succeeded, let value = result.result else { throw RemoteServiceError.commandRejected(result.errorCode ?? "download_failed") }
        return value
    }

    func installSkill(_ skill: NativeSkill) async throws {
        let payload = try NativeSkillImportContract.installRequest(skill)
        let generation = remoteSecurityGeneration
        guard securityCurrent(generation), let machine = selectedMachine else { throw CancellationError() }
        guard macSettingsAvailability == .ready else { throw RemoteMacSettingsError.unavailable(macSettingsAvailability) }
        let result = try await remoteService(machineID: machine.id).sendCommand(machineID: machine.id, sessionID: "", type: .setMacSettings, payload: payload)
        guard securityCurrent(generation), selectedMachine?.id == machine.id else { throw CancellationError() }
        guard result.succeeded else { throw RemoteSecurityServiceError.server(code: result.errorCode ?? "skill_install_failed") }
    }

    func setSecurityContextValidator(_ validator: @escaping @MainActor () -> Bool) {
        securityContextIsCurrent = validator
    }
    func remotePINIsLocked(at date: Date = .now) -> Bool { remotePINLockedUntil.map { $0 > date } ?? false }

    /// Invalidate pending responses when this account's view exits or pairing changes.
    func invalidateRemoteSecurityContext() {
        remoteSecurityGeneration = UUID()
        directSessionAuthorized = false
        remoteMessageCache.removeAll()
        remoteEventTask?.cancel()
        macConnectors = []; macConnectorMachineID = nil
        commandHealthGeneration = UUID()
        commandHealthByMachineID.removeAll(); commandHealthUpdatedAtByMachineID.removeAll(); commandHealthRevisionByMachineID.removeAll()
        remoteUnlockState = nil; isRemoteUnlocked = false; isLoadingRemoteSecurity = false
        remoteProtectionPolicy = nil; remotePolicyResolved = false; remotePolicyLoadFailed = false; remoteUnlockExpiresAt = nil
        remotePINLockedUntil = nil; remotePINAttempts = nil
        remoteBiometricsConfigured = false; remoteSecurityNeedsRepair = false
        remoteSecurityError = nil; remoteSecurityDiagnosticCode = nil
    }
    private func securityCurrent(_ generation: UUID) -> Bool {
        generation == remoteSecurityGeneration && securityContextIsCurrent() && !Task.isCancelled
    }
    private func beginSecurityOperation() -> UUID? {
        guard !isLoadingRemoteSecurity, securityContextIsCurrent(), !Task.isCancelled else { return nil }
        isLoadingRemoteSecurity = true; remoteSecurityError = nil; remoteSecurityDiagnosticCode = nil
        return remoteSecurityGeneration
    }
    private func endSecurityOperation(_ generation: UUID) {
        if generation == remoteSecurityGeneration { isLoadingRemoteSecurity = false }
    }
    private func applySecurityFailure(code: String?) {
        let safe = (code ?? "unknown").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }
        remoteSecurityDiagnosticCode = String(safe.prefix(80))
        remoteSecurityNeedsRepair = ["pairing_too_old", "device_not_paired"].contains(code ?? "")
        remoteSecurityError = securityMessage(for: code)
    }
    private func applySecurityFailure(_ error: any Error) {
        switch error {
        case let RemoteSecurityServiceError.server(code), let RemoteSecurityServiceError.transport(code): applySecurityFailure(code: code)
        case RemoteSecurityServiceError.authenticationRequired: applySecurityFailure(code: "not_authenticated")
        case RemoteSecurityServiceError.deviceNotPaired, RemoteServiceError.deviceNotPaired: applySecurityFailure(code: "device_not_paired")
        case RemoteSecurityServiceError.invalidResponse: applySecurityFailure(code: "invalid_response")
        case RemoteSecurityServiceError.contextChanged: applySecurityFailure(code: "context_changed")
        case let error as URLError: applySecurityFailure(code: "network_" + String(error.code.rawValue))
        default: applySecurityFailure(code: "unknown")
        }
    }
    private func refreshSecurity(_ generation: UUID) async {
        if let directSessionProbe {
            do {
                let authorized = try await directSessionProbe()
                guard securityCurrent(generation) else { return }
                guard authorized else { throw DirectRemoteError.unauthorized }
                directSessionAuthorized = true; isRemoteUnlocked = true
                // This is a freshness bound for presentation, not a cloud grant.
                remoteUnlockExpiresAt = Date().addingTimeInterval(45)
                remotePolicyResolved = true; remotePolicyLoadFailed = false
                remoteSecurityError = nil; remoteSecurityDiagnosticCode = nil
            } catch {
                guard securityCurrent(generation) else { return }
                directSessionAuthorized = false; isRemoteUnlocked = false; remoteUnlockExpiresAt = nil
                remotePolicyLoadFailed = true; remoteSecurityDiagnosticCode = "direct_unavailable"
                remoteSecurityError = "This Mac is unavailable. Reconnect in Computer connection."
            }
            return
        }
        do {
            var deviceState = try await service.deviceAuthorizationState()
            guard securityCurrent(generation) else { return }
            if let version = deviceState?.version, version > 2 { throw RemoteSecurityServiceError.server(code: "client_update_required") }
            if deviceState?.version != 2 {
                // This RPC is account-idempotent and validates a live paired device
                // plus a recent sign-in or an existing grant. No PIN is requested.
                deviceState = try await service.migrateDeviceAuthorization()
                guard securityCurrent(generation) else { return }
            }
            guard let deviceState, deviceState.version == 2 else {
                throw RemoteSecurityServiceError.server(code: "device_authorization_unavailable")
            }
            deviceAuthorizationState = deviceState
            let token = try await service.authorizeDevice()
            guard securityCurrent(generation) else { return }
            guard !token.isExpired else { throw RemoteSecurityServiceError.server(code: "authorization_expired") }
            remoteUnlockExpiresAt = token.expiresAt; isRemoteUnlocked = true
            remoteUnlockState = .init(succeeded: true, isEnabled: false)
            remoteProtectionPolicy = nil; remotePolicyResolved = true; remotePolicyLoadFailed = false
            remoteBiometricsConfigured = false
            try? biometricSecretStore.removeBiometricPIN()
            remoteSecurityError = nil; remoteSecurityDiagnosticCode = nil

        } catch {
            guard securityCurrent(generation) else { return }
            isRemoteUnlocked = false; remoteUnlockExpiresAt = nil
            remoteUnlockState = nil; remotePolicyLoadFailed = true; applySecurityFailure(error)
        }
    }
    func loadRemoteSecurity() async {
        guard let generation = beginSecurityOperation() else { return }
        defer { endSecurityOperation(generation) }
        remoteUnlockState = nil
        await refreshSecurity(generation)
        if securityCurrent(generation), !remoteSecurityHasPIN { remoteBiometricsConfigured = false }
    }

    func migrateDeviceAuthorization() async throws -> RemoteDeviceAuthorizationState {
        guard let generation = beginSecurityOperation() else { throw RemoteSecurityServiceError.contextChanged }
        defer { endSecurityOperation(generation) }
        let migrated = try await service.migrateDeviceAuthorization()
        guard securityCurrent(generation) else { throw RemoteSecurityServiceError.contextChanged }
        deviceAuthorizationState = migrated
        let token = try await service.authorizeDevice()
        guard securityCurrent(generation) else { throw RemoteSecurityServiceError.contextChanged }
        // The server cutover is committed and this paired device received a v2 grant.
        try biometricSecretStore.removeBiometricPIN()
        remoteBiometricsConfigured = false; remoteUnlockExpiresAt = token.expiresAt; isRemoteUnlocked = true
        remoteUnlockState = .init(succeeded: true, isEnabled: false)
        remoteProtectionPolicy = nil; remotePolicyResolved = true; remotePolicyLoadFailed = false
        return migrated
    }

    func configureRemoteSecurity(pin: String, enableBiometrics: Bool) async -> Bool {
        remoteSecurityDiagnosticCode = "legacy_security_retired"
        remoteSecurityError = "App protection is managed with Face ID in Settings. Remote uses this paired device’s authorization."
        return false
    }

    func enableRemoteBiometrics(pin: String) async -> Bool {
        remoteSecurityDiagnosticCode = "legacy_security_retired"
        remoteSecurityError = "App protection is managed with Face ID in Settings. Remote uses this paired device’s authorization."
        return false
    }
    func deferRemoteBiometrics() {
        // This is a local preference, never a change to account PIN/protection.
        remoteBiometricsConfigured = false
    }
    func disableRemoteBiometrics() {
        try? biometricSecretStore.removeBiometricPIN()
        remoteBiometricsConfigured = false; remoteSecurityError = nil; remoteSecurityDiagnosticCode = nil
    }
    func clearRemoteSecurityError() {
        remoteSecurityError = nil; remoteSecurityDiagnosticCode = nil
    }
    func unlockRemote(pin: String) async -> Bool {
        remoteSecurityDiagnosticCode = "legacy_security_retired"
        remoteSecurityError = "App protection is managed with Face ID in Settings. Remote uses this paired device’s authorization."
        return false
    }
    func unlockRemoteWithBiometrics() async -> Bool {
        remoteSecurityDiagnosticCode = "legacy_security_retired"
        remoteSecurityError = "App protection is managed with Face ID in Settings. Remote uses this paired device’s authorization."
        return false
    }
    func setRemoteSecurityEnabled(_ enabled: Bool) async -> Bool {
        remoteSecurityDiagnosticCode = "legacy_security_retired"
        remoteSecurityError = "App protection is managed with Face ID in Settings. Remote uses this paired device’s authorization."
        return false
    }
    func lockRemote() async {
        remoteSecurityGeneration = UUID(); directSessionAuthorized = false; isRemoteUnlocked = false; isLoadingRemoteSecurity = false
        remoteMessageCache.removeAll()
        await service.lockRemote()
    }
    func resetRemoteSecurity() async -> Bool {
        remoteSecurityDiagnosticCode = "legacy_security_retired"
        remoteSecurityError = "App protection is managed with Face ID in Settings. Remote uses this paired device’s authorization."
        return false
    }
    private func securityMessage(for code: String?) -> String {
        switch code {
        case "client_update_required", "server_update_required": "Update AIM on the iPhone and Mac to authorize this paired device."
        case "device_authorization_unavailable": "Remote device authorization is unavailable. Retry after checking the connection."
        case "authorization_expired": "Remote device authorization expired. Reconnect to renew it."
        case "pin_invalide": String(localized: "settings.security.pin_invalid")
        case "wrong_pin", "invalid_pin": String(localized: "settings.security.wrong_pin")
        case "pin_bloque", "locked": String(localized: "settings.security.pin_locked")
        case "pairing_too_old": String(localized: "settings.security.repair_required")
        case "no_pin": String(localized: "settings.security.no_pin")
        case "deverrouillage_requis", "unlock_required": String(localized: "remote.error.unlock_required")
        case "device_not_paired": String(localized: "remote.error.not_paired")
        case "fresh_sign_in_required", "not_authenticated", "edge_http_401": String(localized: "settings.security.sign_in_again")
        case "edge_http_404", "function_unavailable": String(localized: "settings.security.service_missing")
        case "origine_refusee", "edge_http_403": String(localized: "settings.security.origin_refused")
        case "erreur_serveur", "edge_http_500": String(localized: "settings.security.server_error")
        case "policy_conflict": String(localized: "settings.security.policy_conflict")
        case "policy_unavailable": String(localized: "settings.security.policy_unavailable")
        case "invalid_policy": String(localized: "settings.security.invalid_policy")
        case "action_inconnue": String(localized: "settings.security.action_unknown")
        case "invalid_response": String(localized: "settings.security.invalid_response")
        case "context_changed": String(localized: "settings.security.context_changed")
        case "state_unknown": String(localized: "settings.security.state_unknown")
        default: String(localized: "settings.security.unavailable")
        }
    }
    private func securityState(_ state: RemoteUnlockState?, matchesEnabled enabled: Bool, requiresPIN: Bool = false) -> Bool {
        guard let state, state.succeeded, state.isEnabled == enabled else { return false }
        return !requiresPIN || state.hasPIN
    }

    private func pairingMessage(for code: String?) -> String {
        switch code {
        case "invalid_code", "code_not_found", "code_expired", "invalid_or_expired_code":
            String(localized: "main.pair.invalid")
        default:
            String(localized: "main.pair.failed")
        }
    }

    private func serverCapacityCode(for error: Error) -> String? {
        let code: String?
        if case let RemoteServiceError.commandFailure(failure) = error { code = failure.serverCode?.lowercased() }
        else if case let RemoteServiceError.commandRejected(reason) = error { code = reason.lowercased() }
        else { code = nil }
        guard let code, ["rate_limited", "queue_capacity_reached"].contains(code) else { return nil }
        return code
    }

    private func commandMessage(for error: Error) -> String {
        switch serverCapacityCode(for: error) {
        case "rate_limited": return String(localized: "remote.error.server_rate_limited")
        case "queue_capacity_reached": return String(localized: "remote.error.server_queue_full")
        default: break
        }
        let approvalCode: String?
        if case let RemoteServiceError.commandFailure(failure) = error { approvalCode = failure.serverCode?.lowercased() }
        else if case let RemoteServiceError.commandRejected(reason) = error { approvalCode = reason.lowercased() }
        else { approvalCode = nil }
        if approvalCode == "aucune_approbation_en_attente" || approvalCode == "approbation_expiree" {
            return "The Mac could not find this pending approval. Refresh the conversation and check the request on the Mac."
        }
        return switch error {
        case DirectRemoteError.outcomeUnknown:
            "The Mac may have already performed this action. Check its conversation or workspace before trying another action."
        case DirectRemoteError.revoked:
            "This iPhone’s access was revoked. Generate a new pairing invitation on the Mac."
        case DirectRemoteError.unauthorized:
            "Check this iPhone’s permissions in AIM → Settings → Remote on the Mac. Smart/Auto also require Control and Approve; choose Review to keep action approvals."
        case DirectRemoteError.unavailable:
            "The Mac is unavailable or could not confirm this action. Check Computer connection; a retry keeps the same operation identity."
        case RemoteServiceError.commandRejected(let reason) where reason == "remote_access_suspended":
            String(localized: "remote.connection.suspended")
        case RemoteServiceError.deviceNotPaired:
            String(localized: "remote.error.not_paired")
        case RemoteServiceError.encryptionKeyUnavailable:
            String(localized: "remote.error.key_unavailable")
        case RemoteServiceError.sessionUnavailable:
            String(localized: "remote.error.session_unavailable")
        case let RemoteServiceError.commandFailure(failure):
            switch failure.code {
            case .computerOffline:
                String(localized: "remote.error.computer_offline")
            case .bridgeUnresponsive:
                String(localized: "remote.error.bridge_unresponsive")
            case .incompatibleVersion:
                String(localized: "remote.error.incompatible_version")
            case .encryptionKeyPending:
                String(localized: "remote.error.key_unavailable")
            case .unreadablePayload:
                String(localized: "remote.error.unreadable_payload")
            case .unlockRequired:
                String(localized: "remote.error.unlock_required")
            case .lateSynchronization:
                String(localized: "remote.error.session_unavailable")
            case .deviceNotPaired:
                String(localized: "remote.error.not_paired")
            case .unsupportedCommand:
                String(localized: "remote.error.unsupported_command")
            case .authenticationRequired:
                String(localized: "remote.error.authentication_required")
            case .networkUnavailable:
                String(localized: "remote.error.network_unavailable")
            case .commandRefused, .invalidRequest, .unknown:
                String(localized: "remote.error.command_refused")
            }
        default:
            String(localized: "remote.error.command_failed")
        }
    }

    private func registerCommandFailure(_ error: Error, machineID: String) {
        if serverCapacityCode(for: error) != nil {
            // The server answered before admission; this says nothing about Mac health.
            setCommandHealth(.unknown, machineID: machineID)
            if case let RemoteServiceError.commandFailure(failure) = error { lastRemoteDiagnosticReference = failure.diagnosticReference }
            else { lastRemoteDiagnosticReference = nil }
            return
        }
        // These application replies prove the Mac answered; they do not mean the bridge is offline.
        if case let RemoteServiceError.commandRejected(reason) = error,
           ["aucune_approbation_en_attente", "approbation_expiree"].contains(reason) {
            setCommandHealth(.responsive, machineID: machineID)
            lastRemoteDiagnosticReference = nil
            return
        }
        guard case let RemoteServiceError.commandFailure(failure) = error else { return }
        lastRemoteDiagnosticReference = failure.diagnosticReference
        let health: RemoteCommandHealth = switch failure.code {
        case .bridgeUnresponsive: .unresponsive
        case .incompatibleVersion: .incompatible
        case .unsupportedCommand:
            [.failed, .completed, .acknowledged, .decrypting, .published].contains(failure.stage) ? .responsive : .unknown
        case .computerOffline: .unresponsive
        case .encryptionKeyPending, .authenticationRequired, .deviceNotPaired, .unlockRequired, .networkUnavailable: .unknown
        default:
            [.failed, .completed, .acknowledged, .decrypting, .published].contains(failure.stage) ? .responsive : .unknown
        }
        setCommandHealth(health, machineID: machineID)
    }

    private func commandErrorCode(_ error: Error) -> RemoteCommandErrorCode? {
        guard case let RemoteServiceError.commandFailure(failure) = error else { return nil }
        return failure.code
    }

    private func folderCacheKey(machineID: String, path: String?) -> String {
        machineID + "|" + (path ?? "<roots>")
    }

    private func restoreFolderSnapshot(machineID: String?, path: String?) {
        guard let machineID, let snapshot = folderSnapshots[folderCacheKey(machineID: machineID, path: path)] else {
            remoteFolders = []
            folderSnapshot = nil
            return
        }
        remoteFolders = snapshot.folders
        currentFolderPath = snapshot.path
        folderSnapshot = .init(
            machineID: snapshot.machineID,
            path: snapshot.path,
            folders: snapshot.folders,
            loadedAt: snapshot.loadedAt,
            isFromCache: true,
            errorCode: snapshot.errorCode
        )
    }

    private func performCommand(_ type: RemoteCommandType, payload: RemoteJSONValue) async -> Bool {
        guard !isSending, let session = selectedSession else { return false }
        let responseContext = remoteSecurityGeneration
        isSending = true
        setCommandHealth(.checking, machineID: session.machineID)
        errorMessage = nil
        defer { isSending = false }
        do {
            let result = try await remoteService(machineID: session.machineID).sendCommand(
                machineID: session.machineID,
                sessionID: session.id,
                type: type,
                payload: payload
            )
            guard result.succeeded else { throw RemoteServiceError.commandRejected(result.errorCode ?? "unknown") }
            guard securityContextIsCurrent(), remoteSecurityGeneration == responseContext else { return false }
            // Only the terminal success of this exact response consumes the card. A late mirror
            // cannot resurrect it, while a new message ID remains actionable.
            if [.approvalResponse, .continuousGoalApproval, .continuousGoalQuestion].contains(type),
               let message = payload.objectValue?["messageId"]?.stringValue {
                let answered = AnsweredApproval(account: mediaAccountID, machine: session.machineID,
                    session: session.id, message: message)
                if answeredApprovals.insert(answered).inserted { answeredApprovalOrder.append(answered) }
                if answeredApprovalOrder.count > 256 {
                    for removed in answeredApprovalOrder.prefix(answeredApprovalOrder.count - 256) { answeredApprovals.remove(removed) }
                    answeredApprovalOrder.removeFirst(answeredApprovalOrder.count - 256)
                }
                overview = removingAnsweredApprovals(from: overview)
            }
            if RemoteContinuityAction(rawValue: type.rawValue) != nil {
                try saveContinuityReceipt(result, sessionID: session.id)
            }
            try? await Task.sleep(for: .milliseconds(300))
            setCommandHealth(.responsive, machineID: session.machineID)
            lastRemoteDiagnosticReference = nil
            overview = removingAnsweredApprovals(from: try await service.loadOverview())
            await refreshSelectedSession()
            return true
        } catch {
            registerCommandFailure(error, machineID: session.machineID)
            errorMessage = commandMessage(for: error)
            return false
        }
    }
}
