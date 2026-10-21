import AIMCore
import Darwin
import Foundation
import Security

package enum AgentHostTransportError: Error, Equatable, LocalizedError {
    case invalidSignature, wrongIdentity, invalidMessage, disconnected, timedOut, notReady, serviceQuiescent
    package var errorDescription: String? {
        switch self {
        case .invalidSignature: "The background helper's signature could not be verified. Reinstall the matching AIM application."
        case .wrongIdentity: "The background helper does not match this AIM application or macOS user."
        case .invalidMessage: "The background service rejected the request. Check the mission state before retrying a change."
        case .disconnected: "The background service connection was lost. A change may already have completed; refresh its state before retrying."
        case .timedOut: "The background service did not reply in time. A change may already have completed; refresh its state before retrying."
        case .notReady: "The background service is still starting or reconnecting. Its registration and checkpoints are retained; wait and refresh to reconnect."
        case .serviceQuiescent: "Background work has stopped and checkpoints are retained. Finish removing the service before starting new work."
        }
    }
}

/// Transport retries are confined to these explicit observational commands.
/// A disconnected mutation has an unknown outcome and is never resent here.
package struct AgentHostReadRetryPolicy: Sendable {
    package var timeout: Duration = .seconds(20)
    package var attemptTimeout: Duration = .seconds(2)
    package var delay: Duration = .milliseconds(250)
    package static func isReadOnly(_ action: AgentHostCommand.Action) -> Bool {
        switch action {
        case .list, .snapshot, .events, .eventCursor, .interactions, .processes: true
        default: false
        }
    }
    package func send(_ command: AgentHostCommand,
        attempt: @Sendable (AgentHostCommand, Duration) async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        guard Self.isReadOnly(command.action) else { return try await attempt(command, timeout) }
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw AgentHostTransportError.notReady }
            do { return try await attempt(command, min(attemptTimeout, remaining)) }
            catch let error as AgentHostTransportError {
                guard [.disconnected, .timedOut, .notReady].contains(error) else { throw error }
                let left = clock.now.duration(to: deadline)
                guard left > .zero else { throw AgentHostTransportError.notReady }
                try await Task.sleep(for: min(delay, left))
            }
        }
    }
}

/// A stop receipt describes quiesced work, while the listener remains alive
/// until SMAppService unregisters it. No new mutation enters during quiescence.
package actor AgentHostServiceClient: AgentHostClient {
    private let client: any AgentHostClient
    private var ready: Bool
    private var stopping = false
    private var quiescent = false
    package init(client: any AgentHostClient, initiallyReady: Bool = true) {
        self.client = client; ready = initiallyReady
    }
    package func markReady() { ready = true }
    package func send(_ command: AgentHostCommand) async throws -> Data {
        guard ready else { throw AgentHostTransportError.notReady }
        if command.action == .stop {
            guard !AIMNetworkPrivacyAdmission.isPreparing else { throw RuntimePrivacyShutdownError.preparationPending }
            if quiescent { return Data("{}".utf8) }
            guard !stopping else { throw AgentHostTransportError.serviceQuiescent }
            stopping = true
            defer { stopping = false }
            let receipt = try await client.send(command)
            quiescent = true
            return receipt
        }
        guard !(stopping || quiescent) || AgentHostReadRetryPolicy.isReadOnly(command.action) else {
            throw AgentHostTransportError.serviceQuiescent
        }
        return try await client.send(command)
    }
}

@objc package protocol AgentHostXPCProtocol {
    func request(_ data: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

/// Production uses team + identifier; ad-hoc qualification pins the exact code hash.
package enum SignedPeerRequirement {
    package static func requirement(bundle: URL, identifier: String) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw AgentHostTransportError.invalidSignature
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any], fields[kSecCodeInfoIdentifier as String] as? String == identifier,
              identifier.range(of: "^[a-zA-Z0-9.-]+$", options: .regularExpression) != nil else {
            throw AgentHostTransportError.wrongIdentity
        }
        if let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
           team.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil {
            return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        guard let hash = fields[kSecCodeInfoUnique as String] as? Data else { throw AgentHostTransportError.invalidSignature }
        return "identifier \"\(identifier)\" and cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
    }
}

package final class AgentHostXPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    package static var serviceName: String { AIMInstallationContext.helperIdentifier }
    private let listener: NSXPCListener
    private let requirement: String
    private let endpoint: AgentHostXPCEndpoint
    private let serviceClient: AgentHostServiceClient
    package init(client: any AgentHostClient, applicationBundle: URL, machServiceName: String = AgentHostXPCServer.serviceName,
                 initiallyReady: Bool = true) throws {
        requirement = try SignedPeerRequirement.requirement(bundle: applicationBundle, identifier: AIMInstallationContext.applicationIdentifier)
        serviceClient = AgentHostServiceClient(client: client, initiallyReady: initiallyReady)
        endpoint = AgentHostXPCEndpoint(client: serviceClient)
        listener = NSXPCListener(machServiceName: machServiceName)
        super.init(); listener.delegate = self
    }
    package func start() { listener.resume() }
    package func markReady() async { await serviceClient.markReady() }
    package func stop() { listener.invalidate() }
    package func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: AgentHostXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}

private final class AgentHostXPCEndpoint: NSObject, AgentHostXPCProtocol, @unchecked Sendable {
    let client: any AgentHostClient
    init(client: any AgentHostClient) { self.client = client }
    func request(_ data: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard data.count <= 2 * 1024 * 1024 else { reply(nil, "invalidMessage"); return }
        Task {
            do {
                let command = try JSONDecoder().decode(AgentHostCommand.self, from: data)
                reply(try await client.send(command), nil)
            } catch { reply(nil, String(describing: error)) }
        }
    }
}

private final class XPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    @discardableResult func complete(_ result: Result<Data, any Error>) -> Bool {
        let value = lock.withLock { let current = continuation; continuation = nil; return current }
        value?.resume(with: result)
        return value != nil
    }
}

/// NSXPC manages peer credentials/transport synchronization internally. Keep
/// its reference boxed when the protocol's Sendable reply crosses executors.
private struct XPCConnectionPeer: @unchecked Sendable { let connection: NSXPCConnection }

package final class XPCBasedAgentHostClient: AgentHostClient, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let requirement: String
    private let machServiceName: String
    package init(helperBundle: URL, machServiceName: String = AgentHostXPCServer.serviceName) throws {
        requirement = try SignedPeerRequirement.requirement(bundle: helperBundle, identifier: AgentHostXPCServer.serviceName)
        self.machServiceName = machServiceName
    }
    deinit { connection?.invalidate() }
    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let created = NSXPCConnection(machServiceName: machServiceName, options: [])
            created.setCodeSigningRequirement(requirement)
            created.remoteObjectInterface = NSXPCInterface(with: AgentHostXPCProtocol.self)
            created.invalidationHandler = { [weak self, weak created] in if let created { self?.discard(created) } }
            created.interruptionHandler = { [weak self, weak created] in if let created { self?.discard(created) } }
            connection = created
            created.resume()
            return created
        }
    }
    private func discard(_ failed: NSXPCConnection) {
        let removed = lock.withLock {
            guard connection === failed else { return false }
            connection = nil; return true
        }
        if removed { failed.invalidate() }
    }
    package func send(_ command: AgentHostCommand) async throws -> Data {
        try await AgentHostReadRetryPolicy().send(command) { command, timeout in
            try await self.sendOnce(command, timeout: timeout)
        }
    }
    private func sendOnce(_ command: AgentHostCommand, timeout: Duration) async throws -> Data {
        let bytes = try JSONEncoder().encode(command)
        let peer = XPCConnectionPeer(connection: currentConnection())
        let connection = peer.connection
        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                self.discard(peer.connection)
                gate.complete(.failure(AgentHostTransportError.disconnected))
            }) as? any AgentHostXPCProtocol else {
                self.discard(peer.connection); gate.complete(.failure(AgentHostTransportError.disconnected)); return
            }
            proxy.request(bytes) { data, error in
                if peer.connection.effectiveUserIdentifier != getuid() { gate.complete(.failure(AgentHostTransportError.wrongIdentity)) }
                else if let data, error == nil { gate.complete(.success(data)) }
                else if error == "notReady" { gate.complete(.failure(AgentHostTransportError.notReady)) }
                else if error == "serviceQuiescent" { gate.complete(.failure(AgentHostTransportError.serviceQuiescent)) }
                else { gate.complete(.failure(AgentHostTransportError.invalidMessage)) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.complete(.failure(AgentHostTransportError.timedOut)) { self.discard(peer.connection) }
            }
        }
    }
}
