import AIMApplication
import AIMAgentKit
import CryptoKit
import Foundation
import AIMCore

/// The live router is required even for a restored child. A persisted grant
/// alone cannot authorize spending after pairing, account, or scope changes.
package actor RuntimePeerSpendRegistry {
    package static let shared = RuntimePeerSpendRegistry()
    private var router: RuntimePeerRouter?
    private var generation = UUID()
    package func install(router: RuntimePeerRouter) { self.router = router; generation = UUID() }
    package func clear() { router = nil; generation = UUID() }
    package func meter(signedGrantData: Data) async throws -> NativeDistributedSpendProxy {
        guard signedGrantData.count <= 65_536, let router else { throw SpendAdmissionError.invalidPolicy }
        let signed = try RemotePeerCoding.decode(RemotePeerSignedGrant.self, signedGrantData)
        let expectedGeneration = generation
        guard await router.authorizeGrant(signed), generation == expectedGeneration else { throw SpendAdmissionError.invalidPolicy }
        return NativeDistributedSpendProxy { [self] commandID, data in
            guard await self.isCurrent(expectedGeneration), await router.authorizeGrant(signed),
                  await self.isCurrent(expectedGeneration) else { throw SpendAdmissionError.invalidPolicy }
            return try await router.request(RemotePeerRequest(commandID: commandID, action: .budget, grant: signed, payload: data), timeout: 30)
        }
    }
    private func isCurrent(_ value: UUID) -> Bool { router != nil && generation == value }
}

package struct RuntimePeerSpendRequest: Codable, Sendable {
    package enum Action: String, Codable, Sendable { case admit, sent, notSent, unknown, reconcile, snapshot, requiresBound }
    package var version = 1
    package var action: Action
    package var attemptID: UUID?
    package var provider: String?
    package var modelID: String?
    package var feature: String?
    package var maximumUSD: String?
    package var actualUSD: String?
    package init(action: Action, attemptID: UUID? = nil, provider: String? = nil, modelID: String? = nil,
                 feature: String? = nil, maximumUSD: String? = nil, actualUSD: String? = nil) {
        self.action = action; self.attemptID = attemptID; self.provider = provider; self.modelID = modelID
        self.feature = feature; self.maximumUSD = maximumUSD; self.actualUSD = actualUSD
    }
}
private struct PeerSpendResponse: Codable, Sendable { var version = 1; var payload: Data?; var error: String? }

/// The worker cannot substitute its own ledger when the origin cannot admit a
/// charge. The request UUID is stable across relay retransmissions.
package struct NativeDistributedSpendProxy: GlobalSpendLedger {
    private let transport: @Sendable (UUID, Data) async throws -> Data
    package init(transport: @escaping @Sendable (UUID, Data) async throws -> Data) { self.transport = transport }
    private func send(_ request: RuntimePeerSpendRequest) async throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(request)
        let commandID: UUID
        if let attempt = request.attemptID {
            let hash = Array(SHA256.hash(data: Data((attempt.uuidString + ":" + request.action.rawValue).utf8)))
            commandID = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
        } else { commandID = UUID() }
        let response = try await transport(commandID, bytes)
        guard response.count <= 65_536 else { throw SpendAdmissionError.invalidPolicy }
        let result = try JSONDecoder().decode(PeerSpendResponse.self, from: response)
        guard result.version == 1 else { throw SpendAdmissionError.invalidPolicy }
        if let code = result.error { throw Self.error(code) }
        guard let payload = result.payload else { throw SpendAdmissionError.invalidPolicy }
        return payload
    }
    package func admit(id: UUID, provider: String, modelID: String, feature: String, conversationID: UUID?, maximumUSD: String?, exception: Bool, at date: Date) async throws -> SpendAttempt {
        guard !exception else { throw SpendAdmissionError.exceptionDeclined }
        let value = try JSONDecoder().decode(SpendAttempt.self, from: await send(.init(action: .admit, attemptID: id, provider: provider, modelID: modelID, feature: feature, maximumUSD: maximumUSD)))
        guard value.id == id, value.provider == provider, value.modelID == modelID, value.maximumUSD == maximumUSD, value.state == .reserved else { throw SpendAdmissionError.invalidTransition }
        return value
    }
    package func markSent(id: UUID, at date: Date) async throws { _ = try await send(.init(action: .sent, attemptID: id)) }
    package func markNotSent(id: UUID, at date: Date) async throws { _ = try await send(.init(action: .notSent, attemptID: id)) }
    package func markUnknown(id: UUID) async throws { _ = try await send(.init(action: .unknown, attemptID: id)) }
    package func reconcile(id: UUID, actualUSD: String, at date: Date) async throws { _ = try await send(.init(action: .reconcile, attemptID: id, actualUSD: actualUSD)) }
    package func snapshot(at date: Date) async throws -> SpendSnapshot { try JSONDecoder().decode(SpendSnapshot.self, from: await send(.init(action: .snapshot))) }
    package func requiresVerifiedBound(at date: Date) async throws -> Bool {
        try JSONDecoder().decode(Bool.self, from: await send(.init(action: .requiresBound)))
    }
    private static func error(_ code: String) -> SpendAdmissionError {
        switch code {
        case "invalidAmount": .invalidAmount
        case "unknownBound": .unknownBound
        case "limitReached": .limitReached
        case "duplicateAttempt": .duplicateAttempt
        case "exceptionDeclined": .exceptionDeclined
        case "invalidTransition": .invalidTransition
        default: .invalidPolicy
        }
    }
}

/// An encrypted peer envelope supplies the scope separately from its billing
/// payload. Files journal the reply; SQLite remains authoritative for money.
package actor RuntimePeerSpendBroker {
    private struct Receipt: Codable {
        var version = 1
        var parentID: UUID
        var childID: UUID
        var digest: String
        var response: Data?
    }
    private let ledger: SQLiteGlobalSpendLedger
    private let executions: SQLiteAgentExecutionRepository
    private let owner: UUID
    private let directory: URL
    package init(ledger: SQLiteGlobalSpendLedger, executions: SQLiteAgentExecutionRepository, owner: UUID, directory: URL) throws {
        self.ledger = ledger; self.executions = executions; self.owner = owner; self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw ExecutionStoreError.incompatibleCheckpoint }
    }
    package func handle(_ data: Data, parentExecutionID: UUID, childID: UUID,
                        expectedProvider: String, expectedModelID: String,
                        authorized: @escaping @Sendable () async throws -> Bool) async throws -> Data {
        guard data.count <= 16_384, try await authorized(),
              let parent = try await executions.execution(parentExecutionID), parent.ownerGeneration == owner,
              let account = parent.accountID else { throw ExecutionStoreError.staleOwner }
        let child = try await executions.child(childID)
        guard child.parentExecutionID == parentExecutionID, let placement = child.remoteAssignment,
              placement.provider == expectedProvider, placement.modelID == expectedModelID else { throw SpendAdmissionError.invalidPolicy }
        let request = try JSONDecoder().decode(RuntimePeerSpendRequest.self, from: data)
        guard request.version == 1 else { throw SpendAdmissionError.invalidPolicy }
        if request.action == .admit || request.action == .sent {
            guard [.running, .waitingEvent, .waitingNetwork].contains(child.state), [.running, .waitingEvent, .waitingNetwork].contains(parent.state) else { throw SpendAdmissionError.invalidPolicy }
        }
        let scopedRequest = try JSONDecoder().decode(AgentRequest.self, from: parent.request)
        let scoped = ExecutionScopedSpendLedger(ledger: ledger, executionID: parentExecutionID, owner: owner, capUSD: scopedRequest.continuityMaximumSpendUSD)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if request.action == .snapshot {
            let snapshot = try await scoped.snapshot(at: .now)
            return try encoder.encode(PeerSpendResponse(payload: encoder.encode(snapshot)))
        }
        if request.action == .requiresBound {
            return try encoder.encode(PeerSpendResponse(payload: encoder.encode(await scoped.requiresVerifiedBound(at: .now))))
        }
        guard let attemptID = request.attemptID else { throw SpendAdmissionError.invalidPolicy }
        // Child ID keeps an unrelated peer from mutating another child's cost.
        let identity = parentExecutionID.uuidString + ":" + childID.uuidString + ":" + attemptID.uuidString + ":" + request.action.rawValue
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(key + ".json")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if FileManager.default.fileExists(atPath: file.path) {
            let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 100_000 else { throw SpendAdmissionError.invalidPolicy }
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file))
            guard receipt.version == 1, receipt.parentID == parentExecutionID, receipt.childID == childID, receipt.digest == digest else { throw SpendAdmissionError.duplicateAttempt }
            if let response = receipt.response { return response }
        }
        var receipt = Receipt(parentID: parentExecutionID, childID: childID, digest: digest)
        try save(receipt, to: file)
        let response: PeerSpendResponse
        do {
            guard try await authorized(), (try await executions.execution(parentExecutionID))?.accountID == account else { throw SpendAdmissionError.invalidPolicy }
            let previous = try await ledger.executionAttempt(attemptID, executionID: parentExecutionID, owner: owner)
            if request.action == .admit {
                guard request.provider == expectedProvider, request.modelID == expectedModelID,
                      let feature = request.feature, !feature.isEmpty, feature.utf8.count <= 100,
                      [.running, .waitingEvent, .waitingNetwork].contains(child.state), [.running, .waitingEvent, .waitingNetwork].contains(parent.state) else { throw SpendAdmissionError.invalidPolicy }
                let tag = "peer:" + childID.uuidString + ":" + feature
                guard tag.utf8.count <= 100 else { throw SpendAdmissionError.invalidPolicy }
                let attempt: SpendAttempt
                if let previous {
                    guard previous.provider == expectedProvider, previous.modelID == expectedModelID,
                          previous.feature == tag, previous.maximumUSD == request.maximumUSD,
                          previous.conversationID == parent.conversationID, previous.state == .reserved else { throw SpendAdmissionError.duplicateAttempt }
                    attempt = previous
                } else {
                    attempt = try await scoped.admit(id: attemptID, provider: expectedProvider, modelID: expectedModelID,
                        feature: tag, conversationID: parent.conversationID, maximumUSD: request.maximumUSD, exception: false, at: .now)
                }
                response = PeerSpendResponse(payload: try encoder.encode(attempt))
            } else {
                guard let previous, previous.feature.hasPrefix("peer:" + childID.uuidString + ":") else { throw SpendAdmissionError.invalidPolicy }
                switch request.action {
                case .sent:
                    guard [.running, .waitingEvent, .waitingNetwork].contains(child.state), [.running, .waitingEvent, .waitingNetwork].contains(parent.state) else { throw SpendAdmissionError.invalidPolicy }
                    if previous.state != .sent { try await scoped.markSent(id: attemptID, at: .now) }
                case .notSent:
                    if previous.state != .notSent { try await scoped.markNotSent(id: attemptID, at: .now) }
                case .unknown:
                    if previous.state != .unknown && previous.state != .confirmed { try await scoped.markUnknown(id: attemptID) }
                case .reconcile:
                    guard let cost = request.actualUSD else { throw SpendAdmissionError.invalidAmount }
                    if previous.state == .confirmed {
                        guard previous.actualUSD == cost else { throw SpendAdmissionError.invalidTransition }
                    } else { try await scoped.reconcile(id: attemptID, actualUSD: cost, at: .now) }
                case .admit, .snapshot, .requiresBound: throw SpendAdmissionError.invalidPolicy
                }
                response = PeerSpendResponse(payload: Data("{}".utf8))
            }
        } catch let error as SpendAdmissionError {
            response = PeerSpendResponse(error: String(describing: error))
        }
        let bytes = try encoder.encode(response)
        receipt.response = bytes; try save(receipt, to: file)
        return bytes
    }
    private func save(_ receipt: Receipt, to file: URL) throws {
        try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
