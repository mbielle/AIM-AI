import AIMApplication
import Foundation

/// Finance v1 is an addition to AIM stdio v2, never an upstream wire protocol.
public struct ExternalFinanceGrant: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let runID: UUID
    public let accountID: UUID
    public let executionID: UUID
    public let ownerGeneration: UUID
    public let conversationID: UUID
    public let engineIdentity: String
    public let engineVersion: String
    public let executableSHA256: String
    public let provider: String
    public let modelID: String
    public let allowedFeatures: [String]
    public let expiresAt: Date
    public init(id: UUID, runID: UUID, accountID: UUID, executionID: UUID, ownerGeneration: UUID,
                conversationID: UUID, engineIdentity: String, engineVersion: String, executableSHA256: String,
                provider: String, modelID: String, allowedFeatures: [String], expiresAt: Date) {
        version = 1; self.id = id; self.runID = runID; self.accountID = accountID; self.executionID = executionID
        self.ownerGeneration = ownerGeneration; self.conversationID = conversationID; self.engineIdentity = engineIdentity
        self.engineVersion = engineVersion; self.executableSHA256 = executableSHA256; self.provider = provider
        self.modelID = modelID; self.allowedFeatures = allowedFeatures.sorted(); self.expiresAt = expiresAt
    }
}
public struct ExternalFinanceRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case admit, sent, notSent, unknown, reconcile, snapshot }
    public var version: Int
    /// Stable across transport retransmission. A new provider attempt gets a new attemptID.
    public var requestID: UUID
    public var grantID: UUID
    public var action: Action
    public var attemptID: UUID?
    public var provider: String?
    public var modelID: String?
    public var feature: String?
    public var maximumUSD: String?
    public var actualUSD: String?
    /// Evidence for the host verifier; an amount or stdout metric alone is insufficient.
    public var providerReceipt: Data?
    public var receiptSourceID: String?
    public init(requestID: UUID, grantID: UUID, action: Action, attemptID: UUID? = nil,
                provider: String? = nil, modelID: String? = nil, feature: String? = nil, maximumUSD: String? = nil,
                actualUSD: String? = nil, providerReceipt: Data? = nil, receiptSourceID: String? = nil) {
        version = 1; self.requestID = requestID; self.grantID = grantID; self.action = action
        self.attemptID = attemptID; self.provider = provider; self.modelID = modelID; self.feature = feature
        self.maximumUSD = maximumUSD; self.actualUSD = actualUSD; self.providerReceipt = providerReceipt
        self.receiptSourceID = receiptSourceID
    }
}
public struct ExternalFinanceResponse: Codable, Sendable {
    public enum Disposition: String, Codable, Sendable { case accepted, denied, outcomeUnknown }
    public let version: Int
    public let requestID: UUID
    public let grantID: UUID
    public let action: ExternalFinanceRequest.Action
    public let disposition: Disposition
    public let attempt: SpendAttempt?
    public let snapshot: SpendSnapshot?
    public let diagnostic: String?
    public init(request: ExternalFinanceRequest, disposition: Disposition, attempt: SpendAttempt? = nil,
                snapshot: SpendSnapshot? = nil, diagnostic: String? = nil) {
        version = 1; requestID = request.requestID; grantID = request.grantID; action = request.action
        self.disposition = disposition; self.attempt = attempt; self.snapshot = snapshot; self.diagnostic = diagnostic
    }
}

/// Supplied by the host, never instantiated from a stdout grant or engine config.
public struct ExternalFinanceSession: Sendable {
    public let grant: ExternalFinanceGrant
    private let receive: @Sendable (ExternalFinanceRequest) async throws -> ExternalFinanceResponse
    private let finish: @Sendable () async throws -> Void
    public init(grant: ExternalFinanceGrant,
                receive: @escaping @Sendable (ExternalFinanceRequest) async throws -> ExternalFinanceResponse,
                finish: @escaping @Sendable () async throws -> Void) {
        self.grant = grant; self.receive = receive; self.finish = finish
    }
    public func handle(_ request: ExternalFinanceRequest) async throws -> ExternalFinanceResponse { try await receive(request) }
    /// Closing resolves reserved attempts as unsent and leaves sent attempts unknown.
    public func close() async throws { try await finish() }
}
public typealias ExternalFinanceResolver = @Sendable (AgentRequest, UUID, ExternalEngineConfiguration) async throws -> ExternalFinanceSession
