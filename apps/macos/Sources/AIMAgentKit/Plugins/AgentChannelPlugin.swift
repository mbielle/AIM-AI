import AIMApplication
import Foundation

/// A host-approved channel snapshot. The extension cannot mint or change it.
public struct AgentChannelGrant: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable { case receiveWake, deliverResult }
    public let apiVersion: Int
    public let id: UUID
    public let accountID: UUID
    public let executionID: UUID
    public let eventKey: String
    public let scopes: Set<Scope>
    public let expiresAt: Date
    public let pluginID: String
    public let pluginVersion: String
    /// Host-approved transport target/settings, never credentials or authority.
    public let configuration: Data
    public init(id: UUID, accountID: UUID, executionID: UUID, eventKey: String, scopes: Set<Scope>,
                expiresAt: Date, pluginID: String, pluginVersion: String, configuration: Data = Data()) {
        apiVersion = 1; self.id = id; self.accountID = accountID; self.executionID = executionID
        self.eventKey = eventKey; self.scopes = scopes; self.expiresAt = expiresAt
        self.pluginID = pluginID; self.pluginVersion = pluginVersion; self.configuration = configuration
    }
}
public struct AgentChannelEvent: Codable, Equatable, Sendable {
    public let id: String
    public let accountID: UUID
    public let executionID: UUID
    public let eventKey: String
    public let occurredAt: Date
    /// Untrusted event data only; the router decides whether an existing wake accepts it.
    public let payload: Data
    public init(id: String, accountID: UUID, executionID: UUID, eventKey: String, occurredAt: Date, payload: Data) {
        self.id = id; self.accountID = accountID; self.executionID = executionID
        self.eventKey = eventKey; self.occurredAt = occurredAt; self.payload = payload
    }
}
public struct AgentChannelDelivery: Codable, Equatable, Sendable {
    public let id: String
    public let digest: String
    public let event: AgentChannelEvent
    public init(id: String, digest: String, event: AgentChannelEvent) {
        self.id = id; self.digest = digest; self.event = event
    }
}
/// Host supplies this only after the event/disposition is durably journalled.
public struct AgentChannelIngressReceipt: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case accepted, rejected }
    public let event: AgentChannelEvent
    public let hostReceiptID: String
    public let digest: String
    public let disposition: Disposition
    public init(event: AgentChannelEvent, hostReceiptID: String, digest: String, disposition: Disposition) {
        self.event = event; self.hostReceiptID = hostReceiptID; self.digest = digest; self.disposition = disposition
    }
}
public struct AgentChannelReceipt: Codable, Equatable, Sendable {
    /// Unknown means an effect may have occurred: host must suspend, never resend automatically.
    public enum State: String, Codable, Sendable { case confirmed, outcomeUnknown }
    public let deliveryID: String
    public let digest: String
    public let state: State
    public let remoteReceiptID: String?
    public init(deliveryID: String, digest: String, state: State, remoteReceiptID: String? = nil) {
        self.deliveryID = deliveryID; self.digest = digest; self.state = state; self.remoteReceiptID = remoteReceiptID
    }
}
public struct AgentChannelPluginConfiguration: Sendable {
    public let grant: AgentChannelGrant
    /// Only the secret already selected by the host grant, re-read after authorization.
    public let credentials: @Sendable () async throws -> Data?
    public init(grant: AgentChannelGrant, credentials: @escaping @Sendable () async throws -> Data? = { nil }) {
        self.grant = grant; self.credentials = credentials
    }
}
/// Linked host code only; a manifest alone cannot receive or deliver anything.
public protocol AgentChannelPlugin: NativeAgentPlugin {
    func makeChannel(configuration: AgentChannelPluginConfiguration) async throws -> any AgentChannelSession
}
public protocol AgentChannelSession: Sendable {
    /// Polls at most twenty events WITHOUT acknowledging or advancing a committed
    /// offset. Unacknowledged events must be redelivered after process restart.
    func poll() async throws -> [AgentChannelEvent]
    /// The sole ingress offset/ack boundary, after a durable host disposition.
    /// Must tolerate the same receipt again after an interrupted acknowledgment.
    func acknowledge(_ receipt: AgentChannelIngressReceipt) async throws
    /// The host persists a sending boundary before calling this method once.
    func deliver(_ delivery: AgentChannelDelivery) async throws -> AgentChannelReceipt
    func close() async
}
public enum AgentChannelPluginError: LocalizedError, Sendable {
    case missing, disabled, incompatibleVersion, unsupportedContract, unauthorized, invalidEvent, invalidReceipt, conflictingSession, operationInProgress
    public var errorDescription: String? {
        switch self {
        case .missing: "The selected channel plugin is unavailable."
        case .disabled: "The selected channel plugin is disabled or its session was stopped."
        case .incompatibleVersion: "The channel grant belongs to a different plugin/API version."
        case .unsupportedContract: "This plugin does not implement the channel factory contract."
        case .unauthorized: "The existing account, mission, event or channel scope is no longer authorized."
        case .invalidEvent: "The channel returned an invalid or out-of-scope event."
        case .invalidReceipt: "The channel delivery receipt does not match the pending effect. Inspect before retrying."
        case .conflictingSession: "This channel grant already has an active or starting session. Close it before changing the transport."
        case .operationInProgress: "The channel already has an ingress operation in progress."
        }
    }
}

/// The callback must re-read the host grant, account, mission and wake conditions.
/// It is supplied by RuntimeChannelRouter, never by the extension.
public typealias AgentChannelAuthorization = @Sendable (AgentChannelGrant, AgentChannelGrant.Scope) async throws -> Bool

actor PinnedAgentChannelSession: AgentChannelSession {
    private let inner: any AgentChannelSession
    private let registry: AgentPluginRegistry
    private let grant: AgentChannelGrant
    private let generation: UInt64
    private let authorize: AgentChannelAuthorization
    private var closed = false
    private var polling = false
    private var pending: [AgentChannelEvent] = []
    private var acknowledging: Set<String> = []
    init(inner: any AgentChannelSession, registry: AgentPluginRegistry, grant: AgentChannelGrant,
         generation: UInt64, authorize: @escaping AgentChannelAuthorization) {
        self.inner = inner; self.registry = registry; self.grant = grant
        self.generation = generation; self.authorize = authorize
    }
    private func check(_ scope: AgentChannelGrant.Scope) async throws {
        guard !closed, grant.expiresAt > .now, grant.scopes.contains(scope),
              try await authorize(grant, scope) else { throw AgentChannelPluginError.unauthorized }
        _ = try await registry.validateChannel(grant: grant, sessionGeneration: generation)
        guard !closed else { throw AgentChannelPluginError.disabled }
        try Task.checkCancellation()
    }
    private func validate(_ event: AgentChannelEvent) throws {
        guard !event.id.isEmpty, event.id.utf8.count <= 200, event.accountID == grant.accountID,
              event.executionID == grant.executionID, event.eventKey == grant.eventKey,
              event.payload.count <= 1_048_576 else { throw AgentChannelPluginError.invalidEvent }
    }
    func poll() async throws -> [AgentChannelEvent] {
        try await check(.receiveWake)
        if !pending.isEmpty { return pending }
        guard !polling else { throw AgentChannelPluginError.operationInProgress }
        polling = true
        defer { polling = false }
        let events = try await inner.poll()
        try await check(.receiveWake)
        guard events.count <= 20, Set(events.map(\.id)).count == events.count else { throw AgentChannelPluginError.invalidEvent }
        for event in events { try validate(event) }
        pending = events
        return events
    }
    func acknowledge(_ receipt: AgentChannelIngressReceipt) async throws {
        try await check(.receiveWake)
        guard pending.first == receipt.event, !receipt.hostReceiptID.isEmpty,
              receipt.hostReceiptID.utf8.count <= 200, receipt.digest.count == 64,
              receipt.digest.allSatisfy({ $0.isASCII && ($0.isNumber || "abcdef".contains($0)) }) else {
            throw AgentChannelPluginError.invalidReceipt
        }
        guard acknowledging.insert(receipt.event.id).inserted else { throw AgentChannelPluginError.operationInProgress }
        defer { acknowledging.remove(receipt.event.id) }
        try await inner.acknowledge(receipt)
        try await check(.receiveWake)
        pending.removeAll { $0 == receipt.event }
    }
    func deliver(_ delivery: AgentChannelDelivery) async throws -> AgentChannelReceipt {
        try await check(.deliverResult); try validate(delivery.event)
        guard !delivery.id.isEmpty, delivery.id.utf8.count <= 200,
              delivery.digest.count == 64, delivery.digest.allSatisfy({ $0.isASCII && ($0.isNumber || "abcdef".contains($0)) }) else {
            throw AgentChannelPluginError.invalidReceipt
        }
        let receipt = try await inner.deliver(delivery)
        try await check(.deliverResult)
        guard receipt.deliveryID == delivery.id, receipt.digest == delivery.digest,
              receipt.remoteReceiptID.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else {
            throw AgentChannelPluginError.invalidReceipt
        }
        return receipt
    }
    func close() async {
        guard !closed else { return }
        closed = true; await inner.close()
    }
}
