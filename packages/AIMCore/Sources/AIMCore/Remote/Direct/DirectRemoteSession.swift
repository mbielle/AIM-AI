import Foundation

public protocol DirectRemoteRPCTransport: Sendable {
    var events: AsyncStream<RemoteEvent> { get }
    func subscribeEvents() async -> AsyncStream<RemoteEvent>
    func connectionState() async -> DirectRemoteConnectionState
    func request(operation: String, payload: RemoteJSONValue, id: UUID) async throws -> RemoteJSONValue
}
public extension DirectRemoteRPCTransport { func subscribeEvents() async -> AsyncStream<RemoteEvent> { events } }
public protocol DirectRemoteRequestHandling: Sendable {
    /// Implementations retain existing native permission/approval/provider-budget checks.
    func execute(operation: String, payload: RemoteJSONValue, commandID: UUID, pair: DirectRemotePair) async throws -> RemoteJSONValue
}
public struct DirectRemoteSignal: Codable, Sendable {
    public let description: String?
    public let type: String?
    public let candidate: String?
    public let mid: String?
    public init(description: String? = nil, type: String? = nil, candidate: String? = nil, mid: String? = nil) {
        self.description = description; self.type = type; self.candidate = candidate; self.mid = mid
    }
}
public protocol DirectRemoteSignalling: Sendable {
    var signals: AsyncStream<Data> { get }
    func send(_ encryptedSignal: Data) async throws
    func close() async
}
private struct DirectRemoteRPCFrame: Codable, Sendable {
    let rpcID: UUID
    let operation: String?
    let payload: RemoteJSONValue?
    let failure: String?
}
private struct DirectRemoteChunk: Codable, Sendable { let id: UUID; let index: Int; let count: Int; let bytes: Data }
private struct DirectRemoteAssembly: Sendable { let kind: DirectRemotePacket.Kind; let created: Date; let count: Int; var chunks: [Int:Data] }
private struct DirectRemoteReplayState: Codable { var highest: UInt64; var window: Set<UInt64> }
/// Authenticated, encrypted RPC over an actual DataChannel. Durable effects belong
/// to the host journal; disconnecting this actor never cancels native jobs.
public actor DirectRemoteSession: DirectRemoteRPCTransport {
    public nonisolated let stateEvents: AsyncStream<DirectRemoteConnectionState>
    private let stateContinuation: AsyncStream<DirectRemoteConnectionState>.Continuation
    public nonisolated let events: AsyncStream<RemoteEvent>
    private let eventContinuation: AsyncStream<RemoteEvent>.Continuation
    private let identity: DirectRemoteIdentity
    private var pair: DirectRemotePair
    private let channel: any DirectRemoteDataChannel
    private let signalling: any DirectRemoteSignalling
    private let store: any SecureStoring
    private let sequence: DirectRemoteSequenceStore
    private let endpoint: (any DirectRemoteRequestHandling)?
    private var state: DirectRemoteConnectionState = .disconnected
    private var tasks: [Task<Void,Never>] = []
    private var subscribers: [UUID: AsyncStream<RemoteEvent>.Continuation] = [:]
    private var pending: [UUID: CheckedContinuation<RemoteJSONValue, any Error>] = [:]
    private var candidateBuffer: [DirectRemoteSignal] = []
    private var receivedDescription = false
    private var assemblies: [UUID: DirectRemoteAssembly] = [:]
    public init(identity: DirectRemoteIdentity, pair: DirectRemotePair, channel: any DirectRemoteDataChannel,
                signalling: any DirectRemoteSignalling, store: any SecureStoring,
                endpoint: (any DirectRemoteRequestHandling)? = nil, sequenceStore: DirectRemoteSequenceStore? = nil) throws {
        _ = try pair.other(than: identity.publicIdentity)
        self.identity = identity; self.pair = pair; self.channel = channel; self.signalling = signalling
        self.store = store; self.endpoint = endpoint
        sequence = sequenceStore ?? .init(profile: LocalProfile(id: identity.publicIdentity.localProfileID), deviceID: identity.publicIdentity.id, store: store)
        let stream = AsyncStream<RemoteEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        events = stream.stream; eventContinuation = stream.continuation
        let states = AsyncStream<DirectRemoteConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        stateEvents = states.stream; stateContinuation = states.continuation
    }
    public func subscribeEvents() async -> AsyncStream<RemoteEvent> {
        let id = UUID(), stream = AsyncStream<RemoteEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        subscribers[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream.stream
    }
    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
    private func emit(_ event: RemoteEvent) {
        eventContinuation.yield(event); subscribers.values.forEach { $0.yield(event) }
    }
    deinit {
        tasks.forEach { $0.cancel() }; channel.close()
        let signalling = self.signalling
        Task { await signalling.close() }
        eventContinuation.finish(); stateContinuation.finish(); subscribers.values.forEach { $0.finish() }
        pending.values.forEach { $0.resume(throwing: DirectRemoteError.unavailable("session_closed")) }
    }
    public func connectionState() -> DirectRemoteConnectionState { state }
    public func start(offerer: Bool) throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard tasks.isEmpty else { return }; state = .signalling
        tasks = [Task { [weak self, channel] in
            for await event in channel.events { await self?.receiveNative(event) }
        }, Task { [weak self, signalling] in
            for await signal in signalling.signals { await self?.receiveSignal(signal) }
        }]
        if offerer { try channel.createOffer() }
    }
    public func close() async {
        tasks.forEach { $0.cancel() }; tasks = []; channel.close(); await signalling.close()
        state = .disconnected; stateContinuation.yield(state)
        let old = pending; pending = [:]; old.values.forEach { $0.resume(throwing: DirectRemoteError.unavailable("disconnected")) }
    }
    public func revoke() async { pair.revoked = true; await close(); state = .revoked }
    public func request(operation: String, payload: RemoteJSONValue, id: UUID = UUID()) async throws -> RemoteJSONValue {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard case .connected = state, pending.count < 32, pending[id] == nil else { throw DirectRemoteError.unavailable("not_connected") }
        let timeout: Duration
        let commandType = payload.objectValue?["type"]?.stringValue
        switch (operation, commandType) {
        case ("command", "run_command"): timeout = .seconds(135)
        case ("command", "start_preview"): timeout = .seconds(90)
        case ("history", _), ("command", "request_history"): timeout = .seconds(90)
        default: timeout = .seconds(30)
        }
        let bytes = try DirectRemoteCoding.encode(DirectRemoteRPCFrame(rpcID: id, operation: operation, payload: payload, failure: nil))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                guard let self else { return }
                do { try await self.send(bytes, id: id, kind: .request) }
                catch { await self.fail(id: id, error: error) }
                try? await Task.sleep(for: timeout)
                await self.fail(id: id, error: DirectRemoteError.unavailable("reply_timeout_retry_same_command_id"))
            }
        }
    }
    public func publishOverviewChanged() async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard identity.publicIdentity.role == .mac, case .connected = state else { throw DirectRemoteError.unauthorized }
        let frame = DirectRemoteRPCFrame(rpcID: UUID(), operation: nil, payload: nil, failure: nil)
        try await send(DirectRemoteCoding.encode(frame), id: frame.rpcID, kind: .event)
    }
    private func fail(id: UUID, error: any Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }
    private func packet(_ bytes: Data, id: UUID, kind: DirectRemotePacket.Kind) async throws -> Data {
        let next = try await sequence.next(pairID: pair.id)
        return try DirectRemoteCoding.encode(DirectRemoteCipher.seal(bytes, identity: identity, pair: pair, id: id, sequence: next, kind: kind))
    }
    private func send(_ bytes: Data, id: UUID, kind: DirectRemotePacket.Kind) async throws {
        guard bytes.count <= 4194304 else { throw DirectRemoteError.unavailable("reply_too_large_paginate") }
        let size = 32768, count = max(1, (bytes.count + 32767) / size), transferID = UUID()
        for index in 0..<count {
            let start = min(bytes.count, index * size), end = min(bytes.count, start + size)
            let chunk = DirectRemoteChunk(id: transferID, index: index, count: count, bytes: bytes.subdata(in: start..<end))
            let encoded = try DirectRemoteCoding.encode(chunk)
            try channel.send(await packet(encoded, id: UUID(), kind: kind))
        }
    }
    private func receiveNative(_ event: DirectRemoteNativeEvent) async {
        do {
            switch event {
            case .description(let sdp, let type):
                let signal = DirectRemoteSignal(description: sdp, type: type)
                try await signalling.send(packet(DirectRemoteCoding.encode(signal), id: UUID(), kind: .signal))
            case .candidate(let value, let mid):
                try await signalling.send(packet(DirectRemoteCoding.encode(DirectRemoteSignal(candidate: value, mid: mid)), id: UUID(), kind: .signal))
            case .state(let value): state = value; stateContinuation.yield(value); emit(.overviewChanged)
            case .data(let bytes): try await receive(bytes)
            }
        } catch { state = .failed("direct_protocol_error"); stateContinuation.yield(state); emit(.overviewChanged) }
    }
    private func receiveSignal(_ bytes: Data) async {
        do {
            let packet = try DirectRemoteCoding.decode(DirectRemotePacket.self, bytes)
            guard packet.kind == .signal else { throw DirectRemoteError.invalidPacket }
            let signal = try DirectRemoteCoding.decode(DirectRemoteSignal.self, open(packet))
            if let sdp = signal.description, let type = signal.type {
                try channel.acceptDescription(sdp: sdp, type: type); receivedDescription = true
                for candidate in candidateBuffer { try channel.acceptCandidate(value: candidate.candidate!, mid: candidate.mid!) }; candidateBuffer = []
            } else if let candidate = signal.candidate, let mid = signal.mid {
                if receivedDescription { try channel.acceptCandidate(value: candidate, mid: mid) }
                else { guard candidateBuffer.count < 64 else { throw DirectRemoteError.invalidPacket }; candidateBuffer.append(signal) }
            } else { throw DirectRemoteError.invalidPacket }
        } catch { state = .failed("direct_signalling_error"); stateContinuation.yield(state) }
    }
    private func open(_ packet: DirectRemotePacket) throws -> Data {
        let bytes = try DirectRemoteCipher.open(packet, identity: identity, pair: pair)
        let key = "remote-direct.received.v2.\(identity.publicIdentity.id).\(pair.id)." + (packet.kind == .signal ? "signal" : "channel")
        var replay = try store.readData(forKey: key).map { try DirectRemoteCoding.decode(DirectRemoteReplayState.self, $0) }
            ?? DirectRemoteReplayState(highest: 0, window: [])
        guard !replay.window.contains(packet.sequence), packet.sequence > replay.highest.saturatingSubtract(256) else { throw DirectRemoteError.invalidPacket }
        replay.highest = max(replay.highest, packet.sequence); replay.window.insert(packet.sequence)
        replay.window = replay.window.filter { $0 > replay.highest.saturatingSubtract(256) }
        try store.store(DirectRemoteCoding.encode(replay), forKey: key)
        return bytes
    }
    private func receive(_ bytes: Data) async throws {
        let packet = try DirectRemoteCoding.decode(DirectRemotePacket.self, bytes)
        guard packet.kind == .request || packet.kind == .reply || packet.kind == .event else { throw DirectRemoteError.invalidPacket }
        let chunk = try DirectRemoteCoding.decode(DirectRemoteChunk.self, open(packet))
        guard chunk.count > 0, chunk.count <= 128, chunk.index >= 0, chunk.index < chunk.count, chunk.bytes.count <= 32768 else { throw DirectRemoteError.invalidPacket }
        assemblies = assemblies.filter { Date().timeIntervalSince($0.value.created) < 30 }
        guard assemblies[chunk.id] != nil || assemblies.count < 8 else { throw DirectRemoteError.invalidPacket }
        var assembly = assemblies[chunk.id] ?? .init(kind: packet.kind, created: .now, count: chunk.count, chunks: [:])
        guard assembly.count == chunk.count, assembly.kind == packet.kind, assembly.chunks[chunk.index] == nil else { throw DirectRemoteError.invalidPacket }
        assembly.chunks[chunk.index] = chunk.bytes; assemblies[chunk.id] = assembly
        guard assembly.chunks.count == assembly.count else { return }
        assemblies[chunk.id] = nil
        var combined = Data(); for index in 0..<assembly.count { combined.append(assembly.chunks[index]!) }
        guard combined.count <= 4194304 else { throw DirectRemoteError.invalidPacket }
        let frame = try DirectRemoteCoding.decode(DirectRemoteRPCFrame.self, combined)
        if packet.kind == .reply {
            if let failure = frame.failure {
                let error: DirectRemoteError
                switch failure { case "outcome_unknown": error = .outcomeUnknown; case "conflicting_command": error = .conflictingCommand
                case "revoked": error = .revoked; case "unauthorized": error = .unauthorized; default: error = .unavailable(failure) }
                fail(id: frame.rpcID, error: error)
            }
            else { pending.removeValue(forKey: frame.rpcID)?.resume(returning: frame.payload ?? .null) }
        } else if packet.kind == .event { emit(.overviewChanged) }
        else {
            guard let operation = frame.operation, let payload = frame.payload, let endpoint else { throw DirectRemoteError.unauthorized }
            // Detached request work remains owned by the Mac, rather than the
            // channel's lifecycle. The endpoint journals before executing effects.
            let requestPair = pair
            Task { [weak self] in
                let reply: DirectRemoteRPCFrame
                do { reply = .init(rpcID: frame.rpcID, operation: nil, payload: try await endpoint.execute(operation: operation, payload: payload, commandID: frame.rpcID, pair: requestPair), failure: nil) }
                catch {
                    let failure: String
                    switch error as? DirectRemoteError { case .outcomeUnknown: failure = "outcome_unknown"; case .conflictingCommand: failure = "conflicting_command"
                    case .revoked: failure = "revoked"; case .unauthorized: failure = "unauthorized"; default: failure = "host_refused_or_unavailable" }
                    reply = .init(rpcID: frame.rpcID, operation: nil, payload: nil, failure: failure)
                }
                if let self, let bytes = try? DirectRemoteCoding.encode(reply) { try? await self.send(bytes, id: frame.rpcID, kind: .reply) }
            }
        }
    }
}
private extension UInt64 { func saturatingSubtract(_ n: UInt64) -> UInt64 { self > n ? self - n : 0 } }
