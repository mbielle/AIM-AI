import AIMCore
import Foundation
import Network

public struct DirectRemoteControlMessage: Codable, Sendable {
    public var code: String?
    public var type: String
    public var room: String?
    public var identity: DirectRemotePublicIdentity?
    public var nonce: String?
    public var signature: Data?
    public var claim: Data?
    public var confirmation: Data?
    public var payload: Data?
    public var servers: [DirectRemoteICEServer]?
    public init(type: String, room: UUID? = nil, identity: DirectRemotePublicIdentity? = nil,
                nonce: String? = nil, signature: Data? = nil, claim: Data? = nil,
                confirmation: Data? = nil, payload: Data? = nil) {
        self.type = type; self.room = room?.uuidString; self.identity = identity; self.nonce = nonce
        self.signature = signature; self.claim = claim; self.confirmation = confirmation; self.payload = payload
    }
}
public protocol DirectRemoteControlLink: Sendable {
    var messages: AsyncStream<DirectRemoteControlMessage> { get }
    func send(_ message: DirectRemoteControlMessage) async throws
    func close()
    func waitUntilClosed() async throws
}
public extension DirectRemoteControlLink { func waitUntilClosed() async throws {} }
/// Safe diagnostic facts only: no endpoint, service name or invitation.
public struct DirectRemoteLANConnectionTimeout: Error, Sendable {
    public let waitingKind: String
    public let waitingCode: Int?
}
// Log/variant bodies are compiled only into the standalone synthetic QA helper.
// App targets retain the original TCP parameters and emit no QA diagnostics.
private enum LANDiagnostics {
    static func mark(_ phase: String) {
        #if AIM_QA_LAN_DIAGNOSTICS
        guard AIMInstallationContext.isQualification,
              ProcessInfo.processInfo.environment["AIM_QA_LAN_DIAGNOSTICS"] == "1" else { return }
        let uptimeMs = Int(ProcessInfo.processInfo.systemUptime * 1000)
        FileHandle.standardError.write(Data("QA lan=\(phase) uptimeMs=\(uptimeMs)\n".utf8))
        #endif
    }
    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        #if AIM_QA_LAN_DIAGNOSTICS
        if AIMInstallationContext.isQualification,
           ProcessInfo.processInfo.environment["AIM_QA_LAN_DIAGNOSTICS"] == "1",
           ProcessInfo.processInfo.environment["AIM_QA_LAN_PARAMETERS"] == "peer-to-peer" {
            parameters.includePeerToPeer = true
        }
        #endif
        mark("client-parameters peerToPeer=\(parameters.includePeerToPeer)")
        return parameters
    }
    static func state(_ state: NWConnection.State) {
        switch state {
        case .setup: mark("connection-setup")
        case .preparing: mark("connection-preparing")
        case .ready: mark("connection-ready")
        case .waiting: mark("connection-waiting")
        case .failed: mark("connection-failed")
        case .cancelled: mark("connection-cancelled")
        @unknown default: mark("connection-unknown")
        }
    }
}
public final class DirectRemoteLANLink: DirectRemoteControlLink, @unchecked Sendable {
    public let messages: AsyncStream<DirectRemoteControlMessage>
    private let continuation: AsyncStream<DirectRemoteControlMessage>.Continuation
    private let connection: NWConnection
    private let privacy: DirectNativePrivacyLease
    private var privacyTask: Task<Void,Never>?
    private let queue = DispatchQueue(label: "aim.remote-direct.lan")
    private let lock = NSLock()
    private var closed = false
    init(connection: NWConnection) throws {
        privacy = try DirectNativePrivacyLease("Direct local signalling connection")
        self.connection = connection
        let stream = AsyncStream<DirectRemoteControlMessage>.makeStream(bufferingPolicy: .bufferingNewest(128))
        messages = stream.stream; continuation = stream.continuation
    }
    public static func connect(endpoint: NWEndpoint) async throws -> DirectRemoteLANLink {
        try Task.checkCancellation()
        if case .service(_, _, _, let interface) = endpoint {
            LANDiagnostics.mark("service-endpoint interface=\(interface == nil ? "none" : "specified")")
        }
        let link = try DirectRemoteLANLink(connection: NWConnection(to: endpoint, using: LANDiagnostics.parameters()))
        try await link.start(); return link
    }
    func start() async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let privacyChanges = AIMNetworkPrivacyPolicy.changes()
        privacyTask = Task { [weak self] in for await enabled in privacyChanges { if enabled { self?.close(); return } } }
        let gate = ConnectionGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                // Cancellation can arrive before the continuation is installed.
                // The gate retains that result and resumes this waiter exactly once.
                gate.install(c)
                connection.stateUpdateHandler = { [weak self, privacy] state in
                    LANDiagnostics.state(state)
                    switch state {
                    case .ready: if gate.finish(nil) { self?.readHeader() }
                    case .failed(let error): _ = gate.finish(error); privacy.finish(); self?.close()
                    case .waiting(let error): gate.waiting(error)
                    case .cancelled: _ = gate.finish(DirectRemoteError.unavailable("lan_cancelled")); privacy.finish()
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    if gate.timeout() { LANDiagnostics.mark("connection-deadline"); self?.close() }
                }
            }
        } onCancel: {
            _ = gate.finish(CancellationError())
            self.close()
        }
        // A ready callback and task cancellation may race. Do not hand the
        // caller a link which the cancellation handler has just closed.
        if Task.isCancelled { close(); throw CancellationError() }
    }
    public func send(_ message: DirectRemoteControlMessage) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let bytes = try DirectRemoteCoding.encode(message)
        guard bytes.count <= 262144 else { throw DirectRemoteError.invalidPacket }
        var size = UInt32(bytes.count).bigEndian
        let frame = withUnsafeBytes(of: &size) { Data($0) } + bytes
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self, let data, data.count == 4, !complete, error == nil else { self?.close(); return }
            let count = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count > 0, count <= 262144 else { self.close(); return }
            self.connection.receive(minimumIncompleteLength: Int(count), maximumLength: Int(count)) { [weak self] data, _, complete, error in
                guard let self, let data, data.count == count, error == nil,
                      let message = try? DirectRemoteCoding.decode(DirectRemoteControlMessage.self, data) else { self?.close(); return }
                if case .dropped = self.continuation.yield(message) { self.close(); return }
                if complete { self.close() } else { self.readHeader() }
            }
        }
    }
    public func close() {
        lock.lock(); defer { lock.unlock() }; guard !closed else { return }; closed = true
        connection.cancel(); continuation.finish(); privacyTask?.cancel(); privacyTask = nil
    }
    public func waitUntilClosed() async throws { try await privacy.waitUntilFinished() }
    deinit { close() }
}
private final class ConnectionGate: @unchecked Sendable {
    let lock = NSLock(); var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false
    private var terminalError: (any Error)?
    private var waitingKind = "none"
    private var waitingCode: Int?
    func install(_ c: CheckedContinuation<Void, any Error>) {
        lock.lock()
        if finished {
            let error = terminalError; lock.unlock()
            if let error { c.resume(throwing: error) } else { c.resume() }
        } else { continuation = c; lock.unlock() }
    }
    func waiting(_ error: NWError) {
        lock.lock(); defer { lock.unlock() }
        switch error {
        case .posix(let code): waitingKind = "posix"; waitingCode = Int(code.rawValue)
        case .dns(let code): waitingKind = "dns"; waitingCode = Int(code)
        case .tls(let code): waitingKind = "tls"; waitingCode = Int(code)
        case .wifiAware: waitingKind = "wifiAware"; waitingCode = nil
        @unknown default: waitingKind = "unknown"; waitingCode = nil
        }
    }
    func timeout() -> Bool {
        lock.lock()
        let error = DirectRemoteLANConnectionTimeout(waitingKind: waitingKind, waitingCode: waitingCode)
        lock.unlock()
        return finish(error)
    }
    func finish(_ error: (any Error)?) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true; terminalError = error
        let c = continuation; continuation = nil; lock.unlock()
        if let c { if let error { c.resume(throwing: error) } else { c.resume() } }
        return true
    }
}
public final class DirectRemoteLANListener: @unchecked Sendable {
    public let connections: AsyncStream<DirectRemoteLANLink>
    private let continuation: AsyncStream<DirectRemoteLANLink>.Continuation
    private let listener: NWListener
    private let privacy: DirectNativePrivacyLease
    private var privacyTask: Task<Void,Never>?
    public init(serviceName: String, port: UInt16 = 0) throws {
        privacy = try DirectNativePrivacyLease("Direct local signalling listener")
        guard serviceName.utf8.count <= 63 else { throw DirectRemoteError.invalidConfiguration }
        let stream = AsyncStream<DirectRemoteLANLink>.makeStream(bufferingPolicy: .bufferingNewest(8))
        connections = stream.stream; continuation = stream.continuation
        let params = NWParameters.tcp; params.includePeerToPeer = true
        LANDiagnostics.mark("listener-parameters peerToPeer=\(params.includePeerToPeer)")
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: serviceName, type: "_aimdirect._tcp")
        listener.newConnectionHandler = { [continuation] connection in
            guard let link = try? DirectRemoteLANLink(connection: connection) else { connection.cancel(); return }
            Task { do { try await link.start(); if case .dropped = continuation.yield(link) { link.close() } } catch { link.close() } }
        }
        listener.stateUpdateHandler = { [continuation, privacy] state in
            switch state {
            case .ready: LANDiagnostics.mark("listener-ready")
            case .failed: LANDiagnostics.mark("listener-failed")
            case .cancelled: LANDiagnostics.mark("listener-cancelled")
            default: break
            }
            switch state { case .failed, .cancelled: privacy.finish(); continuation.finish(); default: break }
        }
        listener.start(queue: DispatchQueue(label: "aim.remote-direct.listen"))
        let privacyChanges = AIMNetworkPrivacyPolicy.changes()
        privacyTask = Task { [weak self] in for await enabled in privacyChanges { if enabled { self?.close(); return } } }
        if AIMNetworkPrivacyPolicy.isEnabled { close(); throw AIMNetworkPrivacyError.networkDisabled }
    }
    public func close() { listener.cancel(); continuation.finish(); privacyTask?.cancel(); privacyTask = nil }
    public func waitUntilClosed() async throws { try await privacy.waitUntilFinished() }
    deinit { close() }
}
public enum DirectRemoteLANDiscovery {
    public static func connect(serviceName: String) async throws -> DirectRemoteLANLink {
        // DNS-SD service endpoints resolve through Network.framework without an AIM server.
        try await DirectRemoteLANLink.connect(endpoint: .service(name: serviceName, type: "_aimdirect._tcp", domain: "local.", interface: nil))
    }
}
public final class DirectRemoteWebSocketLink: DirectRemoteControlLink, @unchecked Sendable {
    public let messages: AsyncStream<DirectRemoteControlMessage>
    private let continuation: AsyncStream<DirectRemoteControlMessage>.Continuation
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var reading: Task<Void,Never>?
    public init(url: URL) throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard url.user == nil, url.password == nil, url.fragment == nil, url.host != nil, url.scheme == "wss" || (url.scheme == "ws" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")) else { throw DirectRemoteError.invalidConfiguration }
        let stream = AsyncStream<DirectRemoteControlMessage>.makeStream(bufferingPolicy: .bufferingNewest(128))
        messages = stream.stream; continuation = stream.continuation
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil; config.urlCache = nil
        session = AIMManagedNetworkSession.make(configuration: config); task = session.webSocketTask(with: url); task.maximumMessageSize = 262144
        task.resume()
        reading = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let value = try await task.receive(), bytes: Data
                    switch value { case .data(let data): bytes = data; case .string(let text): bytes = Data(text.utf8); @unknown default: throw DirectRemoteError.invalidPacket }
                    let message = try DirectRemoteCoding.decode(DirectRemoteControlMessage.self, bytes)
                    if case .dropped = continuation.yield(message) { throw DirectRemoteError.unavailable("signalling_overflow") }
                }
            } catch { continuation.finish() }
        }
    }
    public func send(_ message: DirectRemoteControlMessage) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let bytes = try DirectRemoteCoding.encode(message)
        guard bytes.count <= 262144, let string = String(data: bytes, encoding: .utf8) else { throw DirectRemoteError.invalidPacket }
        try await task.send(.string(string))
    }
    public func close() { reading?.cancel(); task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel(); continuation.finish() }
}
public final class DirectRemoteSignalLink: DirectRemoteSignalling, @unchecked Sendable {
    public let signals: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let link: any DirectRemoteControlLink
    private let room: UUID
    public init(link: any DirectRemoteControlLink, room: UUID) {
        self.link = link; self.room = room
        let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(128))
        signals = stream.stream; continuation = stream.continuation
    }
    public func receive(_ data: Data) { if case .dropped = continuation.yield(data) { continuation.finish() } }
    public func send(_ encryptedSignal: Data) async throws { try await link.send(.init(type: "signal", room: room, payload: encryptedSignal)) }
    public func close() async { continuation.finish() }
}

private final class DirectNativePrivacyLease: @unchecked Sendable {
    private let lease: AIMNetworkPrivacyLease
    private let lock = NSLock()
    private var finished = false
    init(_ name: String) throws { lease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation(name) }
    func finish() { lock.lock(); defer { lock.unlock() }; guard !finished else { return }; finished = true; lease.finish() }
    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func waitUntilFinished() async throws {
        for _ in 0..<150 { if isFinished { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw AIMNetworkPrivacyTransactionError.transportStillActive
    }
}
