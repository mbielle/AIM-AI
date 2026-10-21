import AIMAgentKit
import AIMCore
import AIMApplication
import Foundation

package struct ContinuityInteractions: Codable, Sendable {
    package var approvals: [PendingToolApproval]
    package var questions: [AgentQuestion]
}
package struct AgentHostCommand: Codable, Sendable {
    package enum Action: String, Codable, Sendable { case remote, privacy, peers, virtualMachine, ambientAudio, channels, admit, list, snapshot, events, eventCursor, pause, resume, cancel, correct, accept, interactions, approve, answer, stop, logout, fireSchedule, processes, acknowledgeProcess, cancelChild }
    package var action: Action
    package var commandID: UUID
    package var executionID: UUID?
    package var accountID: UUID?
    package var request: AgentRequest?
    package var after: Int64?
    package var text: String?
    package var interactionID: String?
    package var sessionID: UUID?
    package var decision: ApprovalDecision?
    package var sourceMessageID: UUID?
    package var scheduledTaskID: UUID?
    package var processID: UUID?
    package var payload: Data?
    package init(action: Action, commandID: UUID = UUID(), executionID: UUID? = nil,
                 accountID: UUID? = nil, request: AgentRequest? = nil, after: Int64? = nil,
                 text: String? = nil, interactionID: String? = nil, sessionID: UUID? = nil, decision: ApprovalDecision? = nil, sourceMessageID: UUID? = nil, scheduledTaskID: UUID? = nil, processID: UUID? = nil, payload: Data? = nil) {
        self.action = action; self.commandID = commandID; self.executionID = executionID
        self.accountID = accountID; self.request = request; self.after = after
        self.text = text; self.interactionID = interactionID; self.sessionID = sessionID; self.decision = decision
        self.sourceMessageID = sourceMessageID
        self.scheduledTaskID = scheduledTaskID
        self.processID = processID
        self.payload = payload
    }
}
package protocol AgentHostClient: Sendable {
    func send(_ command: AgentHostCommand) async throws -> Data
}
package struct EmbeddedAgentHostClient: AgentHostClient {
    let coordinator: RunCoordinator
    var onStop: (@Sendable () async throws -> Void)? = nil
    var onLogout: (@Sendable () async -> Void)? = nil
    var onSchedule: (@Sendable (UUID, UUID) async throws -> Void)? = nil
    var onChannels: (@Sendable (AgentHostCommand) async throws -> Data)? = nil
    var onAmbientAudio: (@Sendable (AgentHostCommand) async throws -> Data)? = nil
    var onVirtualMachine: (@Sendable (AgentHostCommand) async throws -> Data)? = nil
    var onPrivacy: (@Sendable (AgentHostCommand) async throws -> Data)? = nil
    var onPeers: (@Sendable (AgentHostCommand) async throws -> Data)? = nil
    var onRemote: (@Sendable (AgentHostCommand) async throws -> Data)? = nil
    package func send(_ command: AgentHostCommand) async throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        switch command.action {
        case .remote:
            guard let onRemote else { throw AgentHostTransportError.disconnected }
            return try await onRemote(command)
        case .privacy:
            guard let onPrivacy else { throw AgentHostTransportError.disconnected }
            return try await onPrivacy(command)
        case .peers:
            guard let onPeers else { throw AgentHostTransportError.disconnected }
            return try await onPeers(command)
        case .virtualMachine:
            guard let onVirtualMachine else { throw AgentHostTransportError.disconnected }
            return try await onVirtualMachine(command)
        case .ambientAudio:
            guard let onAmbientAudio else { throw AgentHostTransportError.disconnected }
            return try await onAmbientAudio(command)
        case .channels:
            guard let onChannels else { throw AgentHostTransportError.disconnected }
            return try await onChannels(command)
        case .admit:
            guard let request = command.request else { throw ExecutionStoreError.invalidTransition }
            return try await encoder.encode(coordinator.admit(commandID: command.commandID, accountID: command.accountID, request: request))
        case .stop:
            guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
            guard let onStop else { throw AgentHostTransportError.disconnected }
            try await onStop(); return Data("{}".utf8)
        case .logout:
            await onLogout?(); try await coordinator.suspendAllForLogout(); return Data("{}".utf8)
        case .fireSchedule:
            guard let task = command.scheduledTaskID, let onSchedule else { throw ExecutionStoreError.invalidTransition }
            try await onSchedule(task, command.commandID); return Data("{}".utf8)
        case .list: return try await encoder.encode(coordinator.list())
        default:
            guard let id = command.executionID else { throw ExecutionStoreError.notFound }
            switch command.action {
            case .snapshot: return try await encoder.encode(coordinator.snapshot(id))
            case .events: return try await encoder.encode(coordinator.events(id, after: command.after ?? 0))
            case .eventCursor: return try await encoder.encode(coordinator.eventCursor(id))
            case .processes: return try await encoder.encode(coordinator.processes(id))
            case .acknowledgeProcess:
                guard let process = command.processID else { throw ExecutionStoreError.invalidTransition }
                try await coordinator.acknowledgeProcess(id, processID: process)
            case .pause, .resume, .cancel, .accept, .correct:
                return try await encoder.encode(coordinator.control(commandID: command.commandID, id: id, action: command.action.rawValue, text: command.text, sourceMessageID: command.sourceMessageID))
            case .interactions: return try await encoder.encode(coordinator.interactions(id))
            case .cancelChild:
                guard let child = command.sessionID else { throw ExecutionStoreError.invalidTransition }
                try await coordinator.cancelChild(executionID: id, childID: child)
            case .approve:
                guard let raw = command.interactionID, let approval = UUID(uuidString: raw), let session = command.sessionID,
                      let decision = command.decision else { throw ExecutionStoreError.invalidTransition }
                try await coordinator.approve(executionID: id, id: approval, sessionID: session, decision: decision)
            case .answer:
                guard let interaction = command.interactionID, let text = command.text else { throw ExecutionStoreError.invalidTransition }
                try await coordinator.answer(executionID: id, id: interaction, text: text)
            default: throw ExecutionStoreError.invalidTransition
            }
            return try await encoder.encode(coordinator.snapshot(id))
        }
    }
}
