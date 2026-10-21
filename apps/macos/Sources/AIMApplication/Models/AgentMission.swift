import Foundation

public enum AgentMissionState: String, Codable, CaseIterable, Sendable {
    case preparing
    case executing
    case awaitingUser
    case suspendedHuman
    case suspendedFinancial
    case blocked
    case partial
    case verified
    case failed
    case cancelled

    public var isTerminal: Bool { self == .verified || self == .failed || self == .cancelled }
}

public struct AgentMissionCriterion: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var description: String
    /// Only a host verifier may set this; model prose is never proof.
    public var verifiedAt: Date?
    public var evidenceReference: String?
    /// A concrete host check. Older and qualitative criteria remain unverified
    /// until a suitable verifier exists.
    public var fileCheck: MissionFileCheck?
    /// A command, Web or desktop predicate observed by the host.
    public var hostCheck: MissionHostCheck?

    public init(id: UUID = UUID(), description: String, verifiedAt: Date? = nil,
                evidenceReference: String? = nil, fileCheck: MissionFileCheck? = nil,
                hostCheck: MissionHostCheck? = nil) {
        self.id = id
        self.description = description
        self.verifiedAt = verifiedAt
        self.evidenceReference = evidenceReference
        self.fileCheck = fileCheck
        self.hostCheck = hostCheck
    }
}

/// A success predicate that AIM observes itself. The user approves its exact
/// definition; re-observation right before completion decides success.
public struct MissionHostCheck: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case command, web, desktop }

    public let kind: Kind
    /// command: absolute executable and arguments, run without a shell in the workspace.
    public let executable: String?
    public let arguments: [String]?
    public let expectedExitCode: Int?
    /// web: one HTTP(S) URL fetched without cookies or credentials.
    public let url: String?
    /// desktop: the exact running application and optionally a window title fragment.
    public let bundleID: String?
    public let windowTitleContains: String?
    /// Text that must appear in the command output, page text or app's accessible text.
    public let requiredText: String?
    public let timeoutSeconds: Int?

    public init(kind: Kind, executable: String? = nil, arguments: [String]? = nil, expectedExitCode: Int? = nil,
                url: String? = nil, bundleID: String? = nil, windowTitleContains: String? = nil,
                requiredText: String? = nil, timeoutSeconds: Int? = nil) {
        self.kind = kind; self.executable = executable; self.arguments = arguments
        self.expectedExitCode = expectedExitCode; self.url = url; self.bundleID = bundleID
        self.windowTitleContains = windowTitleContains; self.requiredText = requiredText
        self.timeoutSeconds = timeoutSeconds
    }

    public var isValid: Bool {
        func text(_ value: String?, max: Int) -> Bool {
            value == nil || (!value!.isEmpty && value!.utf8.count <= max && !value!.contains("\0"))
        }
        guard text(requiredText, max: 4_096), text(windowTitleContains, max: 300),
              (timeoutSeconds ?? 60) >= 1, (timeoutSeconds ?? 60) <= 600 else { return false }
        switch kind {
        case .command:
            let arguments = self.arguments ?? []
            guard let executable, executable.hasPrefix("/"), text(executable, max: 1_024),
                  arguments.count <= 64,
                  arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }),
                  (expectedExitCode ?? 0) >= 0, (expectedExitCode ?? 0) <= 255 else { return false }
            return url == nil && bundleID == nil
        case .web:
            guard let url, url.utf8.count <= 2_048, let components = URLComponents(string: url),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  components.host?.isEmpty == false, components.user == nil, components.password == nil,
                  requiredText != nil else { return false }
            return executable == nil && bundleID == nil
        case .desktop:
            guard let bundleID, text(bundleID, max: 255),
                  bundleID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
                  requiredText != nil else { return false }
            return executable == nil && url == nil
        }
    }

    /// Human-readable definition for the approval and the criteria list.
    public var summary: String {
        switch kind {
        case .command:
            let command = ([executable ?? ""] + (arguments ?? [])).joined(separator: " ")
            return "command `\(command)` exits \(expectedExitCode ?? 0)" +
                (requiredText.map { " and prints “\($0)”" } ?? "")
        case .web:
            return "page \(url ?? "") contains “\(requiredText ?? "")”"
        case .desktop:
            return "\(bundleID ?? "") shows “\(requiredText ?? "")”" +
                (windowTitleContains.map { " in a window titled like “\($0)”" } ?? "")
        }
    }
}

/// One host observation of a `MissionHostCheck`.
public struct MissionCheckObservation: Sendable, Equatable {
    public let satisfied: Bool
    /// Digest of the normalized observation; the raw content is not stored.
    public let digest: String
    public let summary: String
    public let observedAt: Date

    public init(satisfied: Bool, digest: String, summary: String, observedAt: Date = .now) {
        self.satisfied = satisfied; self.digest = digest; self.summary = summary; self.observedAt = observedAt
    }
}

public struct MissionCheckEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let missionID: UUID
    public let criterionID: UUID
    public let kind: MissionHostCheck.Kind
    public let digest: String
    public let summary: String
    public let observedAt: Date
}

/// Implemented by the platform layer (process, network, accessibility).
public protocol MissionHostCheckRunning: Sendable {
    func observe(_ check: MissionHostCheck, workspacePath: String?) async throws -> MissionCheckObservation
}

public struct MissionFileCheck: Codable, Equatable, Sendable {
    public let relativePath: String
    public let requiredText: String?

    public init(relativePath: String, requiredText: String? = nil) {
        self.relativePath = relativePath
        self.requiredText = requiredText
    }

    public var isValid: Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !relativePath.isEmpty && relativePath.utf8.count <= 4_096 &&
            !relativePath.contains("\0") && !relativePath.hasPrefix("/") &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } &&
            (requiredText == nil || (requiredText!.utf8.count >= 1 &&
                requiredText!.utf8.count <= 16_384 && !requiredText!.contains("\0")))
    }
}

public struct MissionFileEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let missionID: UUID
    public let criterionID: UUID
    public let workspacePath: String
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64
    public let observedAt: Date

    public init(id: UUID = UUID(), missionID: UUID, criterionID: UUID,
                workspacePath: String, relativePath: String,
                sha256: String, byteCount: Int64, observedAt: Date = .now) {
        self.id = id; self.missionID = missionID; self.criterionID = criterionID
        self.workspacePath = workspacePath; self.relativePath = relativePath; self.sha256 = sha256
        self.byteCount = byteCount; self.observedAt = observedAt
    }
}

public struct AgentMission: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let objective: String
    public var criteria: [AgentMissionCriterion]
    public var state: AgentMissionState
    public var stateReason: String?
    public var activeRunID: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var revision: Int

    public init(id: UUID = UUID(), conversationID: UUID, objective: String,
                criteria: [AgentMissionCriterion] = [], createdAt: Date = .now) {
        self.id = id
        self.conversationID = conversationID
        self.objective = objective
        self.criteria = criteria
        self.state = .preparing
        self.stateReason = nil
        self.activeRunID = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.revision = 0
    }

    public var isVerified: Bool {
        state == .verified && !criteria.isEmpty && criteria.allSatisfy { $0.verifiedAt != nil && $0.evidenceReference != nil }
    }
}

public struct AgentMissionInput: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let missionID: UUID
    public let content: String
    /// Saved chat message carrying this correction, when one exists.
    public let conversationMessageID: UUID?
    public let createdAt: Date
    public var consumedAt: Date?

    public init(id: UUID = UUID(), missionID: UUID, content: String, conversationMessageID: UUID? = nil, createdAt: Date = .now) {
        self.id = id
        self.missionID = missionID
        self.content = content
        self.conversationMessageID = conversationMessageID
        self.createdAt = createdAt
        self.consumedAt = nil
    }
}

/// A user-supplied observation after an interrupted tool action. It does not
/// turn the missing tool result into a verified success or failure.
public enum ActionEffectAssessment: String, Codable, CaseIterable, Sendable {
    case observed
    case notObserved
}

public struct ActionReconciliation: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(runID)/\(callID)" }
    public let missionID: UUID
    public let runID: String
    public let callID: String
    public let assessment: ActionEffectAssessment
    public let note: String
    public let reviewedAt: Date
}

public enum AgentMissionError: LocalizedError, Sendable {
    case invalidInput, conflict, invalidTransition, missingEvidence, criterionNotMet

    public var errorDescription: String? {
        switch self {
        case .invalidInput: "The mission objective, criterion or state reason is invalid."
        case .conflict: "The mission changed concurrently. Reload it before retrying."
        case .invalidTransition: "The mission cannot make that state transition."
        case .missingEvidence: "Mission success requires a verified receipt for every criterion and no uncertain action."
        case .criterionNotMet: "The current file does not satisfy this mission criterion."
        }
    }
}

public protocol AgentMissionRepository: Sendable {
    func beginOrSteer(conversationID: UUID, message: String) async throws -> AgentMission
    /// Atomically stores a correction in the conversation and the active mission's inbox.
    func enqueueCorrection(conversationID: UUID, message: String) async throws -> ConversationMessage
    func load(id: UUID) async throws -> AgentMission?
    func authorization(missionID: UUID) async throws -> MissionAuthorization?
    /// A nil expectedRevision creates the first scope; a revision replaces it.
    func replaceAuthorization(missionID: UUID, expectedRevision: Int?,
                              rules: [MissionAuthorizationRule]) async throws -> MissionAuthorization
    func revokeAuthorization(missionID: UUID, expectedRevision: Int) async throws -> MissionAuthorization
    func latest(conversationID: UUID) async throws -> AgentMission?
    func pendingInputs(missionID: UUID) async throws -> [AgentMissionInput]
    func consumeInput(id: UUID, missionID: UUID) async throws
    func reconciliations(missionID: UUID) async throws -> [ActionReconciliation]
    func recordReconciliation(missionID: UUID, expectedRevision: Int, callID: String,
                              assessment: ActionEffectAssessment, note: String) async throws -> AgentMission
    func completeReview(missionID: UUID, expectedRevision: Int, note: String) async throws -> AgentMission
    /// Exact action arguments previously left uncertain and reviewed by the user.
    func wasUncertainAction(missionID: UUID, name: String,
                            arguments: [String: ToolJSONValue]) async throws -> Bool
    func setCriteria(missionID: UUID, expectedRevision: Int, criteria: [AgentMissionCriterion]) async throws -> AgentMission
    func appendFileCriterion(missionID: UUID, expectedRevision: Int,
                             description: String, check: MissionFileCheck) async throws -> AgentMission
    func transition(missionID: UUID, expectedRevision: Int, to state: AgentMissionState,
                    reason: String?, activeRunID: String?) async throws -> AgentMission
    func verifyFileCriterion(missionID: UUID, expectedRevision: Int, criterionID: UUID,
                             workspacePath: String, expectedRunID: String?) async throws -> AgentMission
    func fileEvidence(missionID: UUID, criterionID: UUID) async throws -> MissionFileEvidence?
    func appendHostCriterion(missionID: UUID, expectedRevision: Int,
                             description: String, check: MissionHostCheck) async throws -> AgentMission
    /// Stores a satisfied observation as the criterion's current receipt.
    func recordHostCheck(missionID: UUID, expectedRevision: Int, criterionID: UUID,
                         observation: MissionCheckObservation, expectedRunID: String?) async throws -> AgentMission
    func hostEvidence(missionID: UUID, criterionID: UUID) async throws -> MissionCheckEvidence?
    func finalizeRun(missionID: UUID, expectedRevision: Int, runID: String) async throws -> AgentMission
    func recoverInterrupted() async throws -> [AgentMission]
}

/// Only the runtime owning the database generation may project a reconciled
/// checkpoint into the historical mission journal. This never records human approval.
public protocol CheckpointMissionResuming: AgentMissionRepository {
    func restoreExecution(_ checkpoint: ExecutionCheckpoint, executionID: UUID,
                          owner: UUID, conversationID: UUID) async throws -> AgentMission
}
