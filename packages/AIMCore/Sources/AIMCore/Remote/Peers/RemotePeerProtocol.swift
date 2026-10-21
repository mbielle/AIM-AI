import Foundation

public enum RemotePeerError: Error, Equatable, Sendable {
    case invalidConfiguration, unauthorized, protocolUnavailable, invalidEnvelope, conflictingCommand
    case outcomeUnknown, unavailable(String), rejected(String)
}
public enum RemotePeerAction: String, Codable, Sendable, CaseIterable {
    case start, snapshot, events, pause, resume, cancel, approval, correction, budget, interactions, answer
    case artifactManifest, artifactChunk, artifactCommit
}
public struct RemotePeerPublicIdentity: Codable, Equatable, Sendable {
    public let version: Int
    public let machineID: UUID
    public let agreementKey: Data
    public let signingKey: Data
    public init(machineID: UUID, agreementKey: Data, signingKey: Data) {
        version = 1; self.machineID = machineID; self.agreementKey = agreementKey; self.signingKey = signingKey
    }
}
/// User-authorized immutable delegation. Payload/events cannot expand this scope.
public struct RemotePeerGrant: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let pairID: UUID
    public let accountID: UUID
    public let originMachineID: UUID
    public let workerMachineID: UUID
    public let parentExecutionID: UUID
    public let childExecutionID: UUID
    public let childConversationID: UUID
    public let workspaceID: String
    public let actions: Set<RemotePeerAction>
    public let allowedToolNames: Set<String>
    public let provider: String
    public let modelID: String
    public let writer: Bool
    public let workspaceArtifact: RemotePeerArtifactCommit?
    public let budgetAuthorization: Data
    public let expiresAt: Date
    public init(id: UUID, pairID: UUID, accountID: UUID, originMachineID: UUID, workerMachineID: UUID,
        parentExecutionID: UUID, childExecutionID: UUID, childConversationID: UUID, workspaceID: String,
        actions: Set<RemotePeerAction>, allowedToolNames: Set<String>, provider: String, modelID: String,
        writer: Bool = false, workspaceArtifact: RemotePeerArtifactCommit? = nil, budgetAuthorization: Data, expiresAt: Date) {
        version = 1; self.id = id; self.pairID = pairID; self.accountID = accountID
        self.originMachineID = originMachineID; self.workerMachineID = workerMachineID
        self.parentExecutionID = parentExecutionID; self.childExecutionID = childExecutionID
        self.childConversationID = childConversationID; self.workspaceID = workspaceID; self.actions = actions
        self.allowedToolNames = allowedToolNames; self.provider = provider; self.modelID = modelID
        self.writer = writer; self.workspaceArtifact = workspaceArtifact; self.budgetAuthorization = budgetAuthorization; self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey {
        case version, id, pairID, accountID, originMachineID, workerMachineID, parentExecutionID,
             childExecutionID, childConversationID, workspaceID, actions, allowedToolNames, provider, modelID,
             writer, workspaceArtifact, budgetAuthorization, expiresAt
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version); try container.encode(id, forKey: .id)
        try container.encode(pairID, forKey: .pairID); try container.encode(accountID, forKey: .accountID)
        try container.encode(originMachineID, forKey: .originMachineID); try container.encode(workerMachineID, forKey: .workerMachineID)
        try container.encode(parentExecutionID, forKey: .parentExecutionID); try container.encode(childExecutionID, forKey: .childExecutionID)
        try container.encode(childConversationID, forKey: .childConversationID); try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(actions.sorted { $0.rawValue < $1.rawValue }, forKey: .actions)
        try container.encode(allowedToolNames.sorted(), forKey: .allowedToolNames)
        try container.encode(provider, forKey: .provider); try container.encode(modelID, forKey: .modelID)
        try container.encode(writer, forKey: .writer); try container.encodeIfPresent(workspaceArtifact, forKey: .workspaceArtifact)
        try container.encode(budgetAuthorization, forKey: .budgetAuthorization)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
    public func bindingWorkspace(_ artifact: RemotePeerArtifactCommit) -> RemotePeerGrant {
        RemotePeerGrant(id: id, pairID: pairID, accountID: accountID, originMachineID: originMachineID,
            workerMachineID: workerMachineID, parentExecutionID: parentExecutionID, childExecutionID: childExecutionID,
            childConversationID: childConversationID, workspaceID: workspaceID, actions: actions,
            allowedToolNames: allowedToolNames, provider: provider, modelID: modelID, writer: writer,
            workspaceArtifact: artifact, budgetAuthorization: budgetAuthorization, expiresAt: expiresAt)
    }
    public func validate(at date: Date = .now) throws {
        guard version == 1, originMachineID != workerMachineID, expiresAt > date,
              !workspaceID.isEmpty, workspaceID.utf8.count <= 128, !provider.isEmpty, !modelID.isEmpty,
              allowedToolNames.count <= 256, !budgetAuthorization.isEmpty, budgetAuthorization.count <= 32768,
              !actions.isEmpty, (!writer || workspaceArtifact != nil) else { throw RemotePeerError.unauthorized }
    }
}
public struct RemotePeerSignedGrant: Codable, Equatable, Sendable {
    public let grant: RemotePeerGrant
    public let signature: Data
    public init(grant: RemotePeerGrant, signature: Data) { self.grant = grant; self.signature = signature }
}
public struct RemotePeerRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let commandID: UUID
    public let action: RemotePeerAction
    public let grant: RemotePeerSignedGrant
    public let payload: Data
    public init(commandID: UUID, action: RemotePeerAction, grant: RemotePeerSignedGrant, payload: Data) {
        version = 1; self.commandID = commandID; self.action = action; self.grant = grant; self.payload = payload
    }
}
public struct RemotePeerReply: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case completed, rejected, outcomeUnknown }
    public let commandID: UUID
    public let state: State
    public let payload: Data
    public let diagnostic: String?
    public init(commandID: UUID, state: State, payload: Data = Data(), diagnostic: String? = nil) {
        self.commandID = commandID; self.state = state; self.payload = payload; self.diagnostic = diagnostic
    }
}
public struct RemotePeerPacket: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case request, reply }
    public let version: Int
    public let pairID: UUID
    public let accountID: UUID
    public let from: UUID
    public let to: UUID
    public let commandID: UUID
    public let kind: Kind
    public let ciphertext: Data
    public let signature: Data
    public init(pairID: UUID, accountID: UUID, from: UUID, to: UUID, commandID: UUID, kind: Kind,
                ciphertext: Data, signature: Data) {
        version = 1; self.pairID = pairID; self.accountID = accountID; self.from = from; self.to = to
        self.commandID = commandID; self.kind = kind; self.ciphertext = ciphertext; self.signature = signature
    }
    public var associatedData: Data {
        Data("aim-peer/v1|\(pairID)|\(accountID)|\(from)|\(to)|\(commandID)|\(kind.rawValue)".utf8)
    }
}
public struct RemotePeerPair: Codable, Equatable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let origin: RemotePeerPublicIdentity
    public let worker: RemotePeerPublicIdentity
    public let accepted: Bool
    public let revoked: Bool
    public let expiresAt: Date
    public init(id: UUID, accountID: UUID, origin: RemotePeerPublicIdentity, worker: RemotePeerPublicIdentity,
                accepted: Bool, revoked: Bool, expiresAt: Date) {
        self.id = id; self.accountID = accountID; self.origin = origin; self.worker = worker
        self.accepted = accepted; self.revoked = revoked; self.expiresAt = expiresAt
    }
    public func identity(for machineID: UUID) throws -> RemotePeerPublicIdentity {
        if origin.machineID == machineID { return origin }
        if worker.machineID == machineID { return worker }
        throw RemotePeerError.unauthorized
    }
}
public enum RemotePeerRelayOperation: String, Codable, Sendable {
    case status, register, identities, propose, accept, revoke, pairs, submit, pending, reply, receipt
}
/// Additive authenticated RPC; payload and response are bounded JSON. No unauthenticated local listener.
public protocol RemotePeerRelaying: Sendable {
    func call(_ operation: RemotePeerRelayOperation, machineID: UUID, secret: String, payload: Data) async throws -> Data
}
public protocol RemotePeerTransport: Sendable {
    /// Retrying this exact command retransmits its persisted ciphertext; never chooses another worker.
    func request(_ request: RemotePeerRequest, timeout: TimeInterval) async throws -> Data
}
public enum RemotePeerCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
