import AIMCore
import AIMDataChannel
import Foundation

/// Real ICE/DTLS/SCTP transport. A signalling socket opening never reports connected.
public final class LibDataChannel: DirectRemoteDataChannel, @unchecked Sendable {
    public let events: AsyncStream<DirectRemoteNativeEvent>
    private let context: Context
    private let privacyLease: AIMNetworkPrivacyLease
    private var privacyTask: Task<Void,Never>?
    private let pointer: UnsafeMutableRawPointer
    private let lock = NSRecursiveLock()
    private var peer: Int32 = -1
    private var closed = false

    public init(iceServers: [DirectRemoteICEServer] = [], relayOnly: Bool = false) throws {
        privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("Direct WebRTC transport")
        rtcInitLogger(RTC_LOG_ERROR, nil)
        let stream = AsyncStream<DirectRemoteNativeEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = stream.stream; context = Context(stream.continuation)
        let urls = try iceServers.map { try $0.nativeURL() }
        pointer = Unmanaged.passRetained(context).toOpaque()
        guard urls.count <= 8, !relayOnly || !urls.isEmpty else {
            Unmanaged<Context>.fromOpaque(pointer).release(); throw DirectRemoteError.invalidConfiguration
        }
        let allocated = urls.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var pointers = allocated.map { UnsafePointer<CChar>($0) }
        var config = rtcConfiguration()
        config.disableAutoNegotiation = true
        config.maxMessageSize = 262144
        config.iceTransportPolicy = relayOnly ? RTC_TRANSPORT_POLICY_RELAY : RTC_TRANSPORT_POLICY_ALL
        peer = pointers.withUnsafeMutableBufferPointer { buffer in
            config.iceServers = buffer.baseAddress
            config.iceServersCount = Int32(buffer.count)
            return rtcCreatePeerConnection(&config)
        }
        guard peer >= 0 else { Unmanaged<Context>.fromOpaque(pointer).release(); throw DirectRemoteError.unavailable("native_create") }
        rtcSetUserPointer(peer, pointer)
        rtcSetLocalDescriptionCallback(peer, { _, sdp, type, p in
            guard let p, let sdp, let type else { return }
            Unmanaged<Context>.fromOpaque(p).takeUnretainedValue().yield(.description(sdp: String(cString: sdp), type: String(cString: type)))
        })
        rtcSetLocalCandidateCallback(peer, { _, candidate, mid, p in
            guard let p, let candidate, let mid else { return }
            Unmanaged<Context>.fromOpaque(p).takeUnretainedValue().yield(.candidate(value: String(cString: candidate), mid: String(cString: mid)))
        })
        rtcSetStateChangeCallback(peer, { _, state, p in
            guard let p else { return }; let c = Unmanaged<Context>.fromOpaque(p).takeUnretainedValue()
            switch state {
            case RTC_CONNECTING: c.yield(.state(.checkingICE))
            case RTC_DISCONNECTED: c.yield(.state(.reconnecting))
            case RTC_FAILED: c.yield(.state(.failed("ice_failed")))
            case RTC_CLOSED: c.yield(.state(.disconnected))
            default: break
            }
        })
        rtcSetGatheringStateChangeCallback(peer, { _, state, p in
            guard state == RTC_GATHERING_INPROGRESS, let p else { return }; Unmanaged<Context>.fromOpaque(p).takeUnretainedValue().yield(.state(.gatheringICE))
        })
        rtcSetDataChannelCallback(peer, { pc, channel, p in
            guard let p else { return }; let c = Unmanaged<Context>.fromOpaque(p).takeUnretainedValue(); c.install(channel: channel, peer: pc)
        })
        context.peer = peer
        let privacyChanges = AIMNetworkPrivacyPolicy.changes()
        privacyTask = Task { [weak self] in
            for await enabled in privacyChanges { if enabled { self?.close(); return } }
        }
        do { try AIMNetworkPrivacyPolicy.requireNetwork() } catch { close(); throw error }
    }
    public func createOffer() throws {
        lock.lock(); defer { lock.unlock() }; try checkOpen()
        let channel = rtcCreateDataChannel(peer, "aim-direct-v1")
        guard channel >= 0 else { throw DirectRemoteError.unavailable("native_channel") }
        context.install(channel: channel, peer: peer)
        let result = rtcSetLocalDescription(peer, "offer")
        guard result >= 0 else { throw DirectRemoteError.unavailable("native_offer_\(result)") }
    }
    public func acceptDescription(sdp: String, type: String) throws {
        lock.lock(); defer { lock.unlock() }; try checkOpen()
        guard sdp.utf8.count <= 65536, ["offer", "answer"].contains(type), rtcSetRemoteDescription(peer, sdp, type) >= 0 else { throw DirectRemoteError.invalidPacket }
        if type == "offer", rtcSetLocalDescription(peer, "answer") < 0 { throw DirectRemoteError.unavailable("native_answer") }
    }
    public func acceptCandidate(value: String, mid: String) throws {
        lock.lock(); defer { lock.unlock() }; try checkOpen()
        guard value.utf8.count <= 4096, mid.utf8.count <= 64, rtcAddRemoteCandidate(peer, value, mid) >= 0 else { throw DirectRemoteError.invalidPacket }
    }
    public func send(_ bytes: Data) throws {
        lock.lock(); defer { lock.unlock() }; try checkOpen()
        let channel = context.channelID
        guard bytes.count <= 120000, channel >= 0, rtcIsOpen(channel), rtcGetBufferedAmount(channel) < 1048576 else { throw DirectRemoteError.unavailable("native_not_ready") }
        let result = bytes.withUnsafeBytes { rtcSendMessage(channel, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) }
        guard result >= 0 else { throw DirectRemoteError.unavailable("native_send") }
    }
    public func close() {
        lock.lock(); defer { lock.unlock() }; guard !closed else { return }; closed = true
        // Native deletion waits for in-flight callbacks before releasing their retained context.
        let channel = context.beginClose()
        if channel >= 0 { rtcDeleteDataChannel(channel) }
        if peer >= 0 { rtcClosePeerConnection(peer); rtcDeletePeerConnection(peer); peer = -1 }
        context.finish(); Unmanaged<Context>.fromOpaque(pointer).release()
        privacyTask?.cancel(); privacyTask = nil; privacyLease.finish()
    }
    deinit { close() }
    private func checkOpen() throws { try AIMNetworkPrivacyPolicy.requireNetwork(); guard !closed, peer >= 0 else { throw DirectRemoteError.unavailable("native_closed") } }
}

private final class Context: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<DirectRemoteNativeEvent>.Continuation
    private var channel: Int32 = -1
    private var closing = false
    var peer: Int32 = -1
    init(_ continuation: AsyncStream<DirectRemoteNativeEvent>.Continuation) { self.continuation = continuation }
    var channelID: Int32 { lock.lock(); defer { lock.unlock() }; return channel }
    func yield(_ event: DirectRemoteNativeEvent) {
        if case .dropped = continuation.yield(event) {
            // Losing a protocol event is an explicit failure; never silently accept truncated replies.
            continuation.yield(.state(.failed("native_event_overflow"))); continuation.finish()
        }
    }
    func finish() { continuation.finish() }
    func beginClose() -> Int32 { lock.lock(); defer { lock.unlock() }; closing = true; return channel }
    func install(channel: Int32, peer: Int32) {
        lock.lock()
        guard !closing, self.channel == -1 || self.channel == channel else { lock.unlock(); rtcDeleteDataChannel(channel); return }
        self.channel = channel; self.peer = peer; lock.unlock()
        rtcSetOpenCallback(channel, { _, p in
            guard let p else { return }; let c = Unmanaged<Context>.fromOpaque(p).takeUnretainedValue()
            var local = [CChar](repeating: 0, count: 4096), remote = local
            guard rtcGetSelectedCandidatePair(c.peer, &local, Int32(local.count), &remote, Int32(remote.count)) >= 0 else {
                c.yield(.state(.failed("candidate_pair_unavailable"))); return
            }
            let candidates = String(decoding: local.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + String(decoding: remote.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let localValue = String(decoding: local.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let remoteValue = String(decoding: remote.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let path: DirectRemoteTransportPath = candidates.contains("typ relay") ? .turn : (isLocalCandidate(localValue) && isLocalCandidate(remoteValue) ? .lan : .peerToPeer)
            c.yield(.state(.connected(path)))
        })
        rtcSetMessageCallback(channel, { _, bytes, size, p in
            guard let p, let bytes, size >= 0, size <= 120000 else { return }
            Unmanaged<Context>.fromOpaque(p).takeUnretainedValue().yield(.data(Data(bytes: bytes, count: Int(size))))
        })
        rtcSetClosedCallback(channel, { _, p in
            guard let p else { return }; Unmanaged<Context>.fromOpaque(p).takeUnretainedValue().yield(.state(.disconnected))
        })
        rtcSetErrorCallback(channel, { _, _, p in
            guard let p else { return }; Unmanaged<Context>.fromOpaque(p).takeUnretainedValue().yield(.state(.failed("data_channel_error")))
        })
    }
}

private func isLocalCandidate(_ candidate: String) -> Bool {
    let fields = candidate.split(separator: " ")
    guard fields.count > 7, fields[7] == "host" else { return false }
    let host = String(fields[4]).lowercased()
    if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") { return true }
    let parts = host.split(separator: ".")
    return parts.count == 4 && parts[0] == "172" && Int(parts[1]).map { (16...31).contains($0) } == true
}
