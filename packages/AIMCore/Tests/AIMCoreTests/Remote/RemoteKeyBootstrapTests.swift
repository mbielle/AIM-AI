import Foundation
import Supabase
import XCTest
@testable import AIMCore

private final class BootstrapStorage: AuthLocalStorage, SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
    func store(_ data: Data, forKey key: String) throws { try store(key: key, value: data) }
    func readData(forKey key: String) throws -> Data? { try retrieve(key: key) }
    func removeData(forKey key: String) throws { try remove(key: key) }
}

private final class BootstrapRelay: @unchecked Sendable {
    enum Mode { case refused, terminalError, missing, unreadable, opened, pending }
    private let lock = NSLock()
    let mode: Mode
    let deviceID: String
    let publicKey: String
    let envelope: RemoteKeyEnvelope
    let capabilities: String
    let machineID = "00000000-0000-0000-0000-000000000001"
    var policyBody: String?
    var policyStatus = 200
    private var requested = false
    private var sends = 0
    private var types: [String] = []
    private var unlockTokens: [String] = []
    private var reads = 0
    private var keyReads = 0
    init(mode: Mode, identity: RemotePreparedIdentity) throws {
        self.mode = mode; deviceID = identity.deviceID; publicKey = identity.publicKey
        let key = Data(repeating: 7, count: 32)
        envelope = try RemoteCrypto.wrapMirrorKey(key,
            devicePublicKeyBase64: mode == .unreadable ? RemoteDevicePrivateKey().publicKeyBase64 : publicKey,
            machineID: machineID, deviceID: deviceID, version: 1)
        let json = String(decoding: try JSONEncoder().encode(RemoteCapabilities(models: [.init(id: "fixture", name: "Fixture", provider: "fixture")])), as: UTF8.self)
        capabilities = try RemoteCrypto.encryptField(json, key: key, version: 1,
            context: .init(table: "remote_machines", column: "capabilities", rowID: machineID))
    }
    var requestCount: Int { lock.withLock { sends } }
    var commandTypes: [String] { lock.withLock { types } }
    var transmittedUnlockTokens: [String] { lock.withLock { unlockTokens } }
    var keyReadCount: Int { lock.withLock { keyReads } }
    func response(_ request: URLRequest) throws -> Data {
        try lock.withLock {
            let path = request.url!.path
            if path.hasSuffix("remote_security_policy") || path.hasSuffix("remote_set_security_policy"), let policyBody { return Data(policyBody.utf8) }
            let singular = request.value(forHTTPHeaderField: "Accept")?.contains("object") == true
            var value: Any
            if path.hasSuffix("remote_devices") {
                let row: [String: Any] = ["id": deviceID, "public_key": publicKey]
                if singular { value = row } else { value = [row] }
            } else if path.hasSuffix("remote_machines") {
                let row: [String: Any] = ["id": machineID, "name": "Fixture Mac", "last_seen_at": ISO8601DateFormatter().string(from: Date()), "key_version": 1, "capabilities": capabilities]
                if singular { value = row } else { value = [row] }
            } else if path.hasSuffix("remote_sessions") {
                // Many old sessions on the same host must share one envelope read per overview.
                value = (0..<30).map { i -> [String: Any] in
                    ["id": "session-\(i)", "machine_id": machineID, "mode": "chat", "title": "e1.1.invalid", "status": "idle",
                     "message_count": 0, "updated_at": "2026-10-05T12:00:00Z", "silence": false, "interrupted": false]
                }
            } else if path.hasSuffix("remote_device_keys") {
                keyReads += 1
                if requested && [.opened, .unreadable].contains(mode) {
                    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))
                    value = [["key_version": 1, "envelope": object]]
                } else { value = [] as [Any] }
            } else if path.hasSuffix("remote_send_command") {
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 2048)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }; body = data
                }
                let params = try JSONSerialization.jsonObject(with: body ?? Data()) as! [String: Any]
                types.append(params["p_type"] as? String ?? "missing")
                if let token = params["p_unlock_token"] as? String { unlockTokens.append(token) }
                requested = true; sends += 1
                if mode == .refused { value = ["ok": false, "error": "device_not_paired"] as [String: Any] } else { value = ["ok": true] }
            } else if path.hasSuffix("remote_commands") {
                reads += 1
                let row: [String: Any] = mode == .terminalError ? ["status": "error", "error": "key_publication_incomplete"]
                    : mode == .pending ? ["status": "pending"] : ["status": reads == 1 ? "ack" : "done"]
                if singular { value = row } else { value = [row] }
            } else { throw URLError(.unsupportedURL) }
            return try JSONSerialization.data(withJSONObject: value)
        }
    }
}

private final class BootstrapURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var relays: [String: BootstrapRelay] = [:]
    static func register(_ relay: BootstrapRelay, host: String) { lock.withLock { relays[host] = relay } }
    static func remove(_ host: String) { lock.withLock { relays[host] = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host, let relay = Self.lock.withLock({ Self.relays[host] }) else { throw URLError(.unsupportedURL) }
            let data = try relay.response(request)
            let response = HTTPURLResponse(url: url, statusCode: url.path.contains("security_policy") ? relay.policyStatus : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RemoteKeyBootstrapTests: XCTestCase {
    private func scenario(_ mode: BootstrapRelay.Mode) async throws -> (SupabaseRemoteService, BootstrapRelay, String) {
        let storage = BootstrapStorage()
        let identities = RemoteDeviceIdentityStore(secureStore: storage)
        let identity = try identities.preparePairing(); try identities.commit(identity)
        let relay = try BootstrapRelay(mode: mode, identity: identity)
        let host = UUID().uuidString.lowercased() + ".invalid"
        BootstrapURLProtocol.register(relay, host: host)
        let authKey = "fixture-session"
        let user = User(id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date())
        let session = Session(accessToken: "fixture-token", tokenType: "bearer", expiresIn: 3600,
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, refreshToken: "fixture-refresh", user: user)
        try storage.store(key: authKey, value: JSONEncoder().encode(session))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BootstrapURLProtocol.self]
        let client = SupabaseClient(supabaseURL: URL(string: "https://" + host)!, supabaseKey: "fixture-public",
            options: .init(auth: .init(storage: storage, storageKey: authKey, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        return (SupabaseRemoteService(client: client, secureStore: storage), relay, host)
    }

    func testSuspendedOverviewNeverRequestsKeysAndReactivationUsesSamePairing() async throws {
        let (service, relay, host) = try await scenario(.opened); defer { BootstrapURLProtocol.remove(host) }
        let policy = RemoteLocalAccessPolicy(suspendedMachineIDs: [relay.machineID])
        await service.setLocalAccessPolicy(policy)
        let overview = try await service.loadOverview()
        XCTAssertEqual(overview.machines.count, 1)
        XCTAssertEqual(overview.sessions.count, 30)
        XCTAssertEqual(relay.requestCount, 0)
        policy.setEnabled(true, machineID: relay.machineID)
        try await service.checkBridge(machineID: relay.machineID)
        XCTAssertEqual(relay.requestCount, 1)
        XCTAssertEqual(relay.commandTypes, ["request_keys"])
    }

    func testSharedSuspensionGateStopsBridgeBeforeTransmission() async throws {
        let (service, relay, host) = try await scenario(.opened); defer { BootstrapURLProtocol.remove(host) }
        let policy = RemoteLocalAccessPolicy()
        await service.setLocalAccessPolicy(policy)
        policy.setEnabled(false, machineID: relay.machineID)
        do { try await service.checkBridge(machineID: relay.machineID); XCTFail("Suspended Mac must receive no probe") }
        catch RemoteServiceError.commandRejected(let reason) { XCTAssertEqual(reason, "remote_access_suspended") }
        XCTAssertEqual(relay.requestCount, 0)
    }

    func testPolicyRPCOnlyFallsBackForTheExactMissingContract() async throws {
        let (service, relay, host) = try await scenario(.opened); defer { BootstrapURLProtocol.remove(host) }
        relay.policyStatus = 404
        relay.policyBody = #"{"code":"PGRST202","message":"Could not find public.remote_security_policy","details":null,"hint":null}"#
        let missing = try await service.remoteProtectionPolicy(); XCTAssertNil(missing)
        relay.policyStatus = 503
        relay.policyBody = #"{"code":"PGRST000","message":"Private detail","details":null,"hint":null}"#
        do { _ = try await service.remoteProtectionPolicy(); XCTFail("Network failure cannot downgrade policy") }
        catch { XCTAssertEqual(error as? RemoteSecurityServiceError, .transport(code: "schema_PGRST000")) }
    }
    func testPolicyRPCValidatesRevisionAndReturnedModesBeforeAcceptingSave() async throws {
        let (service, relay, host) = try await scenario(.opened); defer { BootstrapURLProtocol.remove(host) }
        relay.policyBody = #"{"ok":true,"policy":{"version":1,"revision":2,"protected_modes":["chat"],"unlock_authorized":false}}"#
        let policy = try await service.remoteProtectionPolicy(); XCTAssertEqual(policy?.protectedModes, [.chat])
        do { _ = try await service.setRemoteProtectionPolicy([], expectedRevision: 1); XCTFail("Wrong returned modes must fail") }
        catch { XCTAssertEqual(error as? RemoteSecurityServiceError, .invalidResponse) }
        relay.policyBody = #"{"ok":true,"policy":{"version":1,"revision":1,"protected_modes":[],"unlock_authorized":true}}"#
        do { _ = try await service.setRemoteProtectionPolicy([], expectedRevision: 1); XCTFail("Unchanged revision must fail") }
        catch { XCTAssertEqual(error as? RemoteSecurityServiceError, .invalidResponse) }
        relay.policyBody = #"{"ok":true,"policy":{"version":1,"revision":2,"protected_modes":[],"unlock_authorized":true}}"#
        let saved = try await service.setRemoteProtectionPolicy([], expectedRevision: 1)
        XCTAssertEqual(saved.preset, .none); XCTAssertEqual(saved.revision, 2)
    }

    func testBridgeCheckNeedsNoUnlockTokenOrFolderAccessAndCoalesces() async throws {
        let (service, relay, host) = try await scenario(.opened); defer { BootstrapURLProtocol.remove(host) }
        async let first: Void = service.checkBridge(machineID: relay.machineID)
        async let second: Void = service.checkBridge(machineID: relay.machineID)
        _ = try await (first, second)
        try await service.checkBridge(machineID: relay.machineID)
        XCTAssertEqual(relay.requestCount, 1)
        XCTAssertEqual(relay.commandTypes, ["request_keys"])
        XCTAssertTrue(relay.transmittedUnlockTokens.isEmpty)
        let report = await service.diagnosticReport()
        XCTAssertTrue(report.entries.contains { $0.type == "request_keys" && $0.status == "envelope_opened" })
    }

    func testBridgeCheckRejectsDoneWithoutReadableKey() async throws {
        for mode in [BootstrapRelay.Mode.missing, .unreadable, .terminalError] {
            let (service, relay, host) = try await scenario(mode); defer { BootstrapURLProtocol.remove(host) }
            do { try await service.checkBridge(machineID: relay.machineID); XCTFail("No valid reply/key") }
            catch let RemoteServiceError.commandFailure(failure) {
                XCTAssertEqual(failure.code, mode == .missing ? .encryptionKeyPending : mode == .unreadable ? .unreadablePayload : .commandRefused)
            }
            XCTAssertEqual(relay.commandTypes, ["request_keys"])
        }
    }

    func testAdmissionAndTerminalPublicationRefusalBecomeDifferentFailures() async throws {
        for mode in [BootstrapRelay.Mode.refused, .terminalError] {
            let (service, relay, host) = try await scenario(mode); defer { BootstrapURLProtocol.remove(host) }
            _ = try await service.loadOverview()
            for _ in 0..<30 {
                if await service.diagnosticReport().entries.contains(where: { $0.type == "request_keys" && ($0.stage == .failed || $0.stage == .rpc) }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let overview = try await service.loadOverview()
            XCTAssertEqual(overview.machines.first?.keyRequestFailure?.code, mode == .refused ? .deviceNotPaired : .commandRefused)
            XCTAssertEqual(relay.requestCount, 1)
            XCTAssertLessThanOrEqual(relay.keyReadCount, 2, "30 sessions must not cause 30 envelope reads")
            let report = await service.diagnosticReport()
            XCTAssertLessThan(report.entries.count, 15, "missing historical keys must not evict command diagnostics")
        }
    }

    func testPendingKeyRequestTimesOutAndConcurrentOverviewReadsDoNotDuplicateIt() async throws {
        let (service, relay, host) = try await scenario(.pending); defer { BootstrapURLProtocol.remove(host) }
        async let first = service.loadOverview()
        async let second = service.loadOverview()
        _ = try await (first, second)
        XCTAssertEqual(relay.requestCount, 1)
        for _ in 0..<100 {
            if await service.diagnosticReport().entries.contains(where: { $0.type == "request_keys" && $0.errorCode == .bridgeUnresponsive }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let overview = try await service.loadOverview()
        XCTAssertEqual(overview.machines.first?.keyRequestFailure?.code, .bridgeUnresponsive)
        XCTAssertEqual(relay.requestCount, 1)
    }

    func testInvalidatedSecurityGenerationDiscardsPendingBootstrapResult() async throws {
        let (service, _, host) = try await scenario(.pending); defer { BootstrapURLProtocol.remove(host) }
        _ = try await service.loadOverview()
        await service.lockRemote()
        try await Task.sleep(for: .milliseconds(400))
        let report = await service.diagnosticReport()
        XCTAssertFalse(report.entries.contains { $0.type == "request_keys" && [.failed, .completed, .decrypting].contains($0.stage) })
    }

    func testDoneRequiresOpeningTheCurrentEnvelope() async throws {
        for mode in [BootstrapRelay.Mode.missing, .unreadable, .opened] {
            let (service, _, host) = try await scenario(mode); defer { BootstrapURLProtocol.remove(host) }
            _ = try await service.loadOverview()
            var report = await service.diagnosticReport()
            for _ in 0..<60 {
                report = await service.diagnosticReport()
                if report.entries.contains(where: { $0.type == "request_keys" && $0.stage == .decrypting }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let overview = try await service.loadOverview()
            let machine = try XCTUnwrap(overview.machines.first)
            if mode == .opened {
                XCTAssertNil(machine.keyRequestFailure); XCTAssertEqual(machine.readState, .readable)
                XCTAssertNotNil(machine.capabilities)
                XCTAssertTrue(report.entries.contains { $0.status == "envelope_opened" })
            } else {
                XCTAssertEqual(machine.keyRequestFailure?.code, mode == .missing ? .encryptionKeyPending : .unreadablePayload)
                XCTAssertNil(machine.capabilities)
            }
        }
    }
}
