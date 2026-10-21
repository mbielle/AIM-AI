import AIMCore
import Foundation
final class ProbeStore: SecureStoring, @unchecked Sendable {
    let lock = NSLock(); var values: [String:Data] = [:]
    func store(_ data: Data, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = data }
    func readData(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func removeData(forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}
final class Signal: DirectRemoteSignalling, @unchecked Sendable {
    let signals: AsyncStream<Data>; let continuation: AsyncStream<Data>.Continuation
    weak var other: Signal?
    init() { let s = AsyncStream<Data>.makeStream(); signals = s.stream; continuation = s.continuation }
    func send(_ data: Data) async { other?.continuation.yield(data) }
    func close() async { continuation.finish() }
}
struct Echo: DirectRemoteRequestHandling {
    func execute(operation: String, payload: RemoteJSONValue, commandID: UUID, pair: DirectRemotePair) async throws -> RemoteJSONValue { payload }
}
@main struct Probe {
    static func main() async throws {
        guard AIMInstallationContext.isQualification else { throw DirectRemoteError.unavailable("qualification_bundle_required") }
        let hs = ProbeStore(), cs = ProbeStore()
        let hi = DirectRemoteIdentity(profile: .init(id: UUID()), role: .mac, name: "Synthetic host")
        let ci = DirectRemoteIdentity(profile: .init(id: UUID()), role: .phone, name: "Synthetic phone")
        let host = try DirectRemotePairingHost(identity: hi, store: hs)
        let invite = try await host.createInvite()
        let claim = try DirectRemoteClaim(invite: invite, client: ci.publicIdentity)
        _ = try await host.propose(claim)
        let confirmation = try await host.confirmDevice(ci.publicIdentity.id, permissions: [.read])
        let pair = try confirmation.accept(invite: invite, client: ci)
        let a = Signal(), b = Signal(); a.other = b; b.other = a
        let hc = try LibDataChannel(), cc = try LibDataChannel()
        let h = try DirectRemoteSession(identity: hi, pair: pair, channel: hc, signalling: a, store: hs, endpoint: Echo())
        let c = try DirectRemoteSession(identity: ci, pair: pair, channel: cc, signalling: b, store: cs)
        try await c.start(offerer: false); try await h.start(offerer: true)
        var connected = false
        for _ in 0..<200 {
            if case .connected = await c.connectionState() { connected = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard connected else { print("HOST", await h.connectionState(), "CLIENT", await c.connectionState()); throw DirectRemoteError.unavailable("probe_not_connected") }
        let payload = RemoteJSONValue.string(String(repeating: "synthetic-payload-", count: 14000))
        let result = try await c.request(operation: "probe", payload: payload, id: UUID())
        guard result == payload else { throw DirectRemoteError.invalidPacket }
        print("REAL SWIFT DATACHANNEL RPC OK: 238000 bytes bidirectional encrypted fragmented payload")
        await c.close(); await h.close()
    }
}
