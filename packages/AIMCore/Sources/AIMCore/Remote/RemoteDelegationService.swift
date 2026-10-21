import Foundation
import Observation

public struct RemoteDelegation: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case waiting, submitting, admitted, uncertain, cancelled }
    public let id: UUID
    public let machineID: String
    public let modelID: String
    public let text: String
    public let workspace: String
    public let maximumSpendUSD: String?
    public let maximumTurns: Int?
    public let createdAt: Date
    public var state: State
    public var conversationID: String?
    public init(id: UUID = UUID(), machineID: String, modelID: String, text: String, workspace: String,
                maximumSpendUSD: String?, maximumTurns: Int?, createdAt: Date = .now) {
        self.id = id; self.machineID = machineID; self.modelID = modelID; self.text = text; self.workspace = workspace
        self.maximumSpendUSD = maximumSpendUSD; self.maximumTurns = maximumTurns; self.createdAt = createdAt; state = .waiting
    }
}

/// Storing a request never schedules execution. Only a fresh, explicit Start calls
/// Remote admission; an uncertain result is reconciled with the same stable ID.
@available(macOS 14.0, iOS 17.0, *)
@MainActor @Observable public final class RemoteDelegationService {
    public private(set) var requests: [RemoteDelegation] = []
    public private(set) var errorMessage: String?
    private let remote: any RemoteServicing
    private let secureStore: any SecureStoring
    private let key: String
    public init(accountID: UUID, remote: any RemoteServicing, secureStore: any SecureStoring = KeychainSecureStore(service: "com.aimai.delegation")) {
        self.remote = remote; self.secureStore = secureStore; key = accountID.uuidString.lowercased()
        do {
            if let data = try secureStore.readData(forKey: key) { requests = try JSONDecoder().decode([RemoteDelegation].self, from: data) }
            for index in requests.indices where requests[index].state == .submitting { requests[index].state = .uncertain }
        } catch { errorMessage = "Saved delegation requests could not be read; existing data has been preserved." }
    }
    @discardableResult public func enqueue(_ request: RemoteDelegation) throws -> UUID {
        guard !requests.contains(where: { $0.id == request.id }), request.state == .waiting else {
            throw RemoteSecurityServiceError.server(code: "duplicate_or_submitted_delegation")
        }
        guard RemoteContinuousGoalConfiguration(maximumTurns: request.maximumTurns, maximumSpendUSD: request.maximumSpendUSD).isValid,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.workspace.hasPrefix("/"),
              !request.modelID.isEmpty, !request.machineID.isEmpty else { throw RemoteSecurityServiceError.invalidResponse }
        requests.append(request)
        do { try persist() } catch { requests.removeLast(); throw error }
        return request.id
    }
    public func cancel(_ id: UUID) throws {
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].state == .waiting else {
            throw RemoteSecurityServiceError.server(code: "already_submitted_requires_remote_stop")
        }
        let old = requests[index]; requests[index].state = .cancelled
        do { try persist() } catch { requests[index] = old; throw error }
    }
    public func start(_ id: UUID, machine: RemoteMachine) async {
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].machineID == machine.id,
              [.waiting, .uncertain].contains(requests[index].state), machine.isOnline(),
              machine.capabilities?.supports(RemoteCapabilities.Feature.continuity) == true,
              machine.capabilities?.models.contains(where: { $0.id == requests[index].modelID }) == true else {
            errorMessage = "Reconnect the assigned Mac and select an available, qualified model before starting."; return
        }
        let request = requests[index]
        requests[index].state = .submitting
        do { try persist() } catch { requests[index].state = request.state; errorMessage = "The request could not be saved; nothing was submitted."; return }
        do {
            let conversation = try await remote.createSession(.init(machineID: request.machineID, mode: .agent, modelID: request.modelID,
                workspace: request.workspace, approvalMode: "always_ask", text: request.text,
                goal: .init(continuous: true, maximumTurns: request.maximumTurns), maximumSpendUSD: request.maximumSpendUSD, delegationID: request.id))
            guard let current = requests.firstIndex(where: { $0.id == id }) else { return }
            requests[current].conversationID = conversation; requests[current].state = .admitted; errorMessage = nil
            try persist()
        } catch {
            // A timeout never authorizes a fresh execution on another Mac.
            if let current = requests.firstIndex(where: { $0.id == id }) { requests[current].state = .uncertain; try? persist() }
            errorMessage = "Admission needs reconciliation. Retry only this saved request; do not submit a replacement."
        }
    }
    private func persist() throws { try secureStore.store(JSONEncoder().encode(requests), forKey: key) }
}
