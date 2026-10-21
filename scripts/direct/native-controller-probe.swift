// Synthetic two-process qualification only. Never links an AppModel or user data.
import AIMCore
import CryptoKit
import Foundation
import Darwin
import Network

final class ProbeFileStore: SecureStoring, @unchecked Sendable {
    let root: URL; let lock = NSLock()
    init(_ root: URL) throws {
        self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func url(_ key: String) -> URL { root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()) }
    func store(_ data: Data, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }; try data.write(to: url(key), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(key).path)
    }
    func readData(forKey key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; guard FileManager.default.fileExists(atPath: url(key).path) else { return nil }; return try Data(contentsOf: url(key)) }
    func removeData(forKey key: String) throws { lock.lock(); defer { lock.unlock() }; if FileManager.default.fileExists(atPath: url(key).path) { try FileManager.default.removeItem(at: url(key)) } }
}
actor SyntheticJobs: DirectRemoteRequestHandling {
    var effectCount = 0
    var completed = false
    func execute(operation: String, payload: RemoteJSONValue, commandID: UUID, pair: DirectRemotePair) async throws -> RemoteJSONValue {
        guard pair.permissions.contains(.read) else { throw DirectRemoteError.unauthorized }
        if operation == "createSession" {
            guard pair.permissions.contains(.chat) else { throw DirectRemoteError.unauthorized }
            effectCount += 1
            Task { try? await Task.sleep(for: .seconds(3)); self.completed = true }
            return .object(["job_id": .string(commandID.uuidString), "accepted": .bool(true)])
        }
        if operation == "command" {
            guard payload.objectValue?["type"]?.stringValue == "run_command", pair.permissions.contains(.terminal) else { throw DirectRemoteError.unauthorized }
            effectCount += 1
            return .object(["accepted": .bool(true)])
        }
        return .object(["effectCount": .number(Double(effectCount)), "completed": .bool(completed),
            "grantRevision": .number(Double(pair.revision)), "echo": payload])
    }
}
enum ProbeDiagnostics {
    static let start = Date()
    static func mark(_ phase: String) {
        FileHandle.standardError.write(Data("QA milestone=\(phase) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1000))\n".utf8))
    }
    // Passive bounded observation of this run's exact synthetic service only.
    // The product controller still resolves/connects its original Bonjour endpoint.
    static func observeBonjour(_ service: String) -> NWBrowser {
        let browser = NWBrowser(for: .bonjour(type: "_aimdirect._tcp", domain: "local."), using: .tcp)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready: mark("bonjour-browser-ready")
            case .waiting(let error), .failed(let error):
                let code: Int
                switch error { case .dns(let value): code = Int(value); case .posix(let value): code = Int(value.rawValue); default: code = 0 }
                FileHandle.standardError.write(Data("QA milestone=bonjour-browser-blocked code=\(code)\n".utf8))
            default: break
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            if results.contains(where: { result in
                if case .service(let name, let type, _, _) = result.endpoint { return name == service && type.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "_aimdirect._tcp" }
                return false
            }) { mark("bonjour-exact-service-observed") }
        }
        browser.start(queue: DispatchQueue(label: "aim.qa.bonjour-observation"))
        return browser
    }
    static func failure(_ error: Error) {
        let kind: String
        switch error {
        case DirectRemoteError.invalidConfiguration: kind = "invalidConfiguration"
        case DirectRemoteError.expiredInvitation: kind = "expiredInvitation"
        case DirectRemoteError.unauthorized: kind = "unauthorized"
        case DirectRemoteError.revoked: kind = "revoked"
        case DirectRemoteError.invalidPacket: kind = "invalidPacket"
        case DirectRemoteError.conflictingCommand: kind = "conflictingCommand"
        case DirectRemoteError.outcomeUnknown: kind = "outcomeUnknown"
        case DirectRemoteError.unavailable(let reason):
            let allowed = ["lan_timeout", "lan_cancelled", "native_create", "native_channel", "native_not_ready", "native_closed", "direct_session_unavailable", "mac_unreachable_on_local_network", "foreground_required", "connection_cancelled", "probe_not_connected"]
            kind = "unavailable:" + (allowed.contains(reason) ? reason : "other")
        case let timeout as DirectRemoteLANConnectionTimeout:
            kind = "lan_timeout:waiting_" + timeout.waitingKind + ":" + (timeout.waitingCode.map(String.init) ?? "none")
        case let network as NWError:
            switch network {
            case .dns(let code): kind = "network_dns:\(code)"
            case .posix(let code): kind = "network_posix:\(code.rawValue)"
            case .tls(let code): kind = "network_tls:\(code)"
            default: kind = "network_other"
            }
        case is CancellationError: kind = "cancelled"
        default: kind = String(reflecting: type(of: error))
        }
        // No localizedDescription/userInfo/associated strings: these can carry
        // addresses, payloads or invitation material. Type and numeric code only.
        FileHandle.standardError.write(Data("QA failure type=\(kind) code=\((error as NSError).code)\n".utf8))
    }
}
// Retains only the exact synthetic endpoint. No address/service text is logged.
final class ProbeLANBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var found: NWEndpoint?
    let browser: NWBrowser
    init(service: String) {
        browser = NWBrowser(for: .bonjour(type: "_aimdirect._tcp", domain: "local."), using: .tcp)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready: ProbeDiagnostics.mark("lan-browser-ready")
            case .waiting(let error), .failed(let error): ProbeDiagnostics.failure(error)
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let endpoint = results.first(where: {
                if case .service(let name, let type, let domain, _) = $0.endpoint {
                    return name == service && type.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "_aimdirect._tcp" && domain == "local."
                }
                return false
            })?.endpoint else { return }
            self.lock.lock(); self.found = endpoint; self.lock.unlock()
            ProbeDiagnostics.mark("lan-exact-service-observed")
        }
        browser.start(queue: DispatchQueue(label: "aim.qa.lan-browser"))
    }
    func endpoint() -> NWEndpoint? { lock.lock(); defer { lock.unlock() }; return found }
    deinit { browser.cancel() }
}
@main struct Probe {
    static func main() async {
        let args = CommandLine.arguments
        let usage = "AIM Direct qualification tool. Run scripts/direct/qualify-controller.py with --probe PATH; this is not an interactive AIM application.\n"
        if args.count == 2, ["--help", "-h"].contains(args[1]) {
            FileHandle.standardOutput.write(Data(usage.utf8)); return
        }
        let modes = ["host", "privacy", "phone-first", "phone-reconnect", "phone-lifecycle", "phone-recovery", "phone-permission-edit", "lan-host", "lan-client"]
        guard (3...5).contains(args.count), modes.contains(args[1]), args[2].hasPrefix("/"),
              args.count < 5 || args[4] == "--relay",
              args.count < 4 || URL(string: args[3])?.host != nil else {
            FileHandle.standardError.write(Data(usage.utf8))
            _exit(EX_USAGE)
        }
        do { try await run() }
        catch {
            ProbeDiagnostics.failure(error)
            // A failed synthetic scenario must not enter swift_errorInMain and
            // trigger macOS Crash Reporter/Reopen. Do not print keys, QR or payloads.
            FileHandle.standardError.write(Data("AIM Direct qualification failed. Inspect the private harness logs; no app data was used.\n".utf8))
            // Match simulated phone termination below: do not race process-static
            // native teardown against asynchronous Swift transport deinitializers.
            _exit(EXIT_FAILURE)
        }
    }
    static let launchedAt = Date().timeIntervalSince1970
    private static func writeReceipt(_ checks: [String: RemoteJSONValue], mode: String, root: URL) throws {
        let env = ProcessInfo.processInfo.environment
        guard let run = env["AIM_QA_RUN_ID"], run.count == 32,
              let scenario = env["AIM_QA_DIRECT_SCENARIO"], ["lifecycle", "permissions", "reconnect"].contains(scenario),
              let source = env["AIM_QA_SOURCE_SHA256"], source.count == 64,
              let binary = env["AIM_QA_BINARY_SHA256"], binary.count == 64,
              let namespace = Bundle.main.bundleIdentifier else { throw DirectRemoteError.invalidConfiguration }
        var value = checks
        value.merge(["schema": .number(2), "mode": .string(mode), "scenario": .string(scenario),
            "runID": .string(run), "sourceSHA256": .string(source), "binarySHA256": .string(binary),
            "namespace": .string(namespace), "status": .string("passed"), "pid": .number(Double(getpid())),
            "startedAt": .number(launchedAt), "finishedAt": .number(Date().timeIntervalSince1970)], uniquingKeysWith: { _, new in new })
        try DirectRemoteCoding.encode(value).write(to: root.appendingPathComponent(mode + "-receipt.json"), options: .atomic)
    }
    private static func run() async throws {
        ProbeDiagnostics.mark("scenario-start")
        let args = CommandLine.arguments
        guard AIMInstallationContext.isQualification else { throw DirectRemoteError.unavailable("qualification_bundle_required") }
        let mode = args[1], root = URL(fileURLWithPath: args[2], isDirectory: true)
        if mode == "lan-host" || mode == "lan-client" {
            guard args.count == 3 else { throw DirectRemoteError.invalidConfiguration }
            try await runLAN(mode: mode, root: root); return
        }
        let secrets = try ProbeFileStore(root.appendingPathComponent((mode == "host" || mode == "privacy") ? "host-secrets" : "phone-secrets"))
        let profile = try LocalProfile.loadOrCreate(store: secrets)
        let identity = try DirectRemoteIdentity.loadOrCreate(profile: profile, role: (mode == "host" || mode == "privacy") ? .mac : .phone, name: "Synthetic " + mode, store: secrets)
        let controller = try DirectRemoteController(identity: identity, store: secrets,
            endpoint: (mode == "host" || mode == "privacy") ? SyntheticJobs() : nil, journalDirectory: root.appendingPathComponent("jobs"), routePreference: args.count > 3 ? .coordinatorOnly : .automatic, relayOnly: args.contains("--relay"))
        if mode == "privacy" {
            ProbeDiagnostics.mark("listener-start")
            try await controller.startHost()
            do { try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle(); throw DirectRemoteError.unavailable("listener_lease_missing") }
            catch is AIMNetworkPrivacyError { }
            let preparation = AIMNetworkPrivacyPreparation(ownerGeneration: nil)
            try AIMNetworkPrivacyAdmission.begin(preparation)
            var quiesced = false
            for _ in 0..<150 {
                if (try? AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()) != nil { quiesced = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard quiesced else { throw AIMNetworkPrivacyTransactionError.transportStillActive }
            try await AIMManagedNetworkSession.quiesceDisallowedTasks()
            try AIMNetworkPrivacyAdmission.acknowledgeApplication(preparation)
            try AIMNetworkPrivacyAdmission.commit(preparation, ownerReceipt: nil)
            guard AIMNetworkPrivacyPolicy.isEnabled else { throw DirectRemoteError.invalidConfiguration }
            do { try await controller.startHost(); throw DirectRemoteError.unavailable("private_listener_allowed") } catch is AIMNetworkPrivacyError { }
            do { _ = try LibDataChannel(); throw DirectRemoteError.unavailable("private_datachannel_allowed") } catch is AIMNetworkPrivacyError { }
            try Data("{\"privacyFenceClosedNativeListener\":true,\"listenerCancellationAcknowledged\":true,\"privateModeCommitted\":true,\"newNativeTransportDenied\":true,\"physicalDevicesQualified\":false}".utf8).write(to: root.appendingPathComponent("privacy-receipt.json"))
            print("NATIVE PRIVACY QUALIFICATION PASS")
            try AIMNetworkPrivacyPolicy.setEnabled(false)
        } else if mode == "host" {
            let observer = Task {
                for await event in controller.events {
                    if case .claim(let client) = event {
                        // Deliberate simulated physical confirmation in this test executable only.
                        try await controller.confirm(deviceID: client.id, permissions: [.read, .chat])
                    }
                }
            }
            let coordinator = args.count > 3 ? URL(string: args[3]) : nil
            ProbeDiagnostics.mark("invitation-create")
            let invite = try await controller.createInvite(coordinatorURL: coordinator)
            try Data(invite.qrURL().absoluteString.utf8).write(to: root.appendingPathComponent("invite.private"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("invite.private").path)
            for _ in 0..<1800 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) { break }
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("permission-edit-request").path),
                   !FileManager.default.fileExists(atPath: root.appendingPathComponent("permission-edit-done").path) {
                    guard let original = try await controller.records().first,
                          original.pair.revision == 1, original.pair.permissions == [.read, .chat] else { throw DirectRemoteError.invalidConfiguration }
                    try await controller.updatePermissions(pairID: original.pair.id, permissions: [.read])
                    guard let edited = try await controller.records().first,
                          edited.pair.revision == 2, edited.pair.permissions == [.read] else { throw DirectRemoteError.invalidConfiguration }
                    try Data("revision-2".utf8).write(to: root.appendingPathComponent("permission-edit-done"), options: .atomic)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            observer.cancel(); try await controller.stopHost()
        } else {
            let records = try await controller.records()
            var browser: NWBrowser?
            defer { browser?.cancel() }
            if args.count == 3 {
                let service: String
                if mode == "phone-first" || mode == "phone-permission-edit" {
                    let text = try String(contentsOf: root.appendingPathComponent("invite.private"), encoding: .utf8)
                    guard let url = URL(string: text) else { throw DirectRemoteError.invalidConfiguration }
                    service = try DirectRemoteInvite.decodeQR(url).lanService
                } else { service = records.first?.location.lanService ?? "" }
                if !service.isEmpty && ProcessInfo.processInfo.environment["AIM_QA_LAN_OBSERVER"] != "0" { browser = ProbeDiagnostics.observeBonjour(service) }
            }
            if mode == "phone-first" || mode == "phone-permission-edit" {
                let text = try String(contentsOf: root.appendingPathComponent("invite.private"), encoding: .utf8)
                ProbeDiagnostics.mark("pair-start")
                _ = try await controller.pair(inviteURL: URL(string: text)!)
            } else {
                guard let record = records.first else { throw DirectRemoteError.unauthorized }
                ProbeDiagnostics.mark("connect-start")
                try await controller.connect(pairID: record.pair.id)
            }
            ProbeDiagnostics.mark("bonjour-connect-returned")
            var connected = false
            for _ in 0..<250 {
                if case .connected = await controller.connectionState() { connected = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard connected else { print("STATE", await controller.connectionState()); throw DirectRemoteError.unavailable("probe_not_connected") }
            if mode == "phone-permission-edit" {
                try await qualifyPermissionEdit(controller: controller, root: root, requireRelay: args.contains("--relay"))
                print("SYNTHETIC CONTROLLER PERMISSION EDIT PASS")
                _exit(0)
            }
            if mode == "phone-lifecycle" {
                // Cross foreground resume with asynchronous native shutdown.
                async let suspension: Void = controller.setForeground(false)
                try await Task.sleep(for: .milliseconds(5))
                await controller.setForeground(true)
                await suspension
                var resumed = false
                for _ in 0..<350 {
                    if case .connected = await controller.connectionState() { resumed = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard resumed else { throw DirectRemoteError.unavailable("foreground_resume_failed") }
                await controller.disconnect()
                try await Task.sleep(for: .seconds(4))
                guard case .disconnected = await controller.connectionState() else { throw DirectRemoteError.unavailable("explicit_disconnect_reconnected") }
                guard let record = records.first else { throw DirectRemoteError.unauthorized }
            ProbeDiagnostics.mark("connect-start")
                try await controller.connect(pairID: record.pair.id)
                resumed = false
                for _ in 0..<350 {
                    if case .connected = await controller.connectionState() { resumed = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard resumed else { throw DirectRemoteError.unavailable("explicit_reconnect_failed") }
            }
            if mode == "phone-recovery" {
                try Data("ready".utf8).write(to: root.appendingPathComponent("recovery-ready"))
                var observedDrop = false
                for _ in 0..<1200 {
                    if case .connected = await controller.connectionState() { }
                    else { observedDrop = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard observedDrop else { throw DirectRemoteError.unavailable("relay_loss_not_detected") }
                try Data("dropped".utf8).write(to: root.appendingPathComponent("recovery-dropped"))
                var recovered = false
                for _ in 0..<1500 {
                    if case .connected(.turn) = await controller.connectionState() { recovered = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard recovered else { throw DirectRemoteError.unavailable("relay_recovery_failed") }
            }
            let transportState = await controller.connectionState()
            let path: String
            if case .connected(let selectedPath) = transportState { path = selectedPath.rawValue } else { throw DirectRemoteError.unavailable("not_connected") }
            if args.contains("--relay"), path != "turn" { throw DirectRemoteError.unavailable("forced_relay_not_observed") }
            let rpc = try await controller.selectedSession(), id: UUID
            let idFile = root.appendingPathComponent("command-id")
            if mode == "phone-first" { id = UUID(); try Data(id.uuidString.utf8).write(to: idFile) }
            else { id = UUID(uuidString: try String(contentsOf: idFile, encoding: .utf8))! }
            let accepted = try await rpc.request(operation: "createSession", payload: .object(["text": .string("synthetic job")]), id: id)
            guard accepted.objectValue?["accepted"]?.boolValue == true else { throw DirectRemoteError.invalidPacket }
            let reply = try await rpc.request(operation: "overview", payload: .string(String(repeating: "synthetic", count: 30000)), id: UUID())
            let fields = reply.objectValue
            guard fields?["effectCount"]?.numberValue == 1,
                  fields?["echo"]?.stringValue?.count == 270000 else { throw DirectRemoteError.invalidPacket }
            if mode != "phone-first", fields?["completed"]?.boolValue != true { throw DirectRemoteError.unavailable("job_did_not_continue") }
            let receipt: [String:RemoteJSONValue] = ["realNativeDataChannel": .bool(true), "encryptedRPC": .bool(true), "transportPath": .string(path),
                "receivedEchoBytes": .number(270000), "nativeEffectCount": .number(1), "completedAfterPhoneExit": .bool(fields?["completed"]?.boolValue == true),
                "physicalDevicesQualified": .bool(false), "appIntegrationQualified": .bool(false),
                "automaticRecoveryAfterRelayRestart": .bool(mode == "phone-recovery"),
                "crossedForegroundResume": .bool(mode == "phone-lifecycle"), "explicitDisconnectStayedDisconnected": .bool(mode == "phone-lifecycle")]
            try writeReceipt(receipt, mode: mode, root: root)
            print("SYNTHETIC CONTROLLER", mode, "PASS", await controller.connectionState())
            // Simulate OS termination of the phone process. Avoid racing C++
            // process-static teardown against Swift async deinitializers.
            _exit(0)
        }
    }
    private static func runLAN(mode: String, root: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AIM_QA_LAN_DIAGNOSTICS"] == "1",
              let run = env["AIM_QA_RUN_ID"], run.count == 32,
              let source = env["AIM_QA_SOURCE_SHA256"], source.count == 64,
              let binary = env["AIM_QA_BINARY_SHA256"], binary.count == 64,
              let namespace = Bundle.main.bundleIdentifier else { throw DirectRemoteError.invalidConfiguration }
        let service = try String(contentsOf: root.appendingPathComponent("service.private"), encoding: .utf8)
        guard service == "aim-qa-" + run else { throw DirectRemoteError.invalidConfiguration }
        if mode == "lan-host" {
            if env["AIM_QA_LAN_CASE"] == "late" { try await Task.sleep(for: .milliseconds(1500)) }
            let listener = try DirectRemoteLANListener(serviceName: service)
            let echo = Task {
                for await link in listener.connections {
                    for await message in link.messages {
                        guard message.type == "qa-ping" else { throw DirectRemoteError.invalidPacket }
                        try await link.send(.init(type: "qa-pong")); link.close(); break
                    }
                }
            }
            defer { echo.cancel(); listener.close() }
            for _ in 0..<1200 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            listener.close(); try await listener.waitUntilClosed()
            ProbeDiagnostics.mark("lan-host-closed"); return
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            ProbeDiagnostics.mark("lan-total-deadline"); _exit(EXIT_FAILURE)
        }
        defer { watchdog.cancel() }
        var browser: ProbeLANBrowser?
        if env["AIM_QA_LAN_OBSERVER"] != "0" { browser = ProbeLANBrowser(service: service) }
        defer { browser?.browser.cancel() }
        let discovered = env["AIM_QA_LAN_ENDPOINT"] == "discovered"
        var endpoint: NWEndpoint?
        if discovered {
            while endpoint == nil { endpoint = browser?.endpoint(); if endpoint == nil { try await Task.sleep(for: .milliseconds(10)) } }
        }
        ProbeDiagnostics.mark(discovered ? "lan-connect-discovered" : "lan-connect-reconstructed")
        let selectedEndpoint = endpoint
        let attempt = Task {
            if env["AIM_QA_LAN_CASE"] == "cancel-before" {
                ProbeDiagnostics.mark("lan-cancel-requested")
                withUnsafeCurrentTask { $0?.cancel() }
            }
            if let selectedEndpoint { return try await DirectRemoteLANLink.connect(endpoint: selectedEndpoint) }
            return try await DirectRemoteLANDiscovery.connect(serviceName: service)
        }
        let cancellation: Task<Void, Never>?
        if env["AIM_QA_LAN_CASE"] == "cancel" {
            cancellation = Task {
                try? await Task.sleep(for: .milliseconds(200))
                ProbeDiagnostics.mark("lan-cancel-requested"); attempt.cancel()
            }
        } else { cancellation = nil }
        defer { cancellation?.cancel() }
        let link: DirectRemoteLANLink
        do { link = try await attempt.value }
        catch is CancellationError where ["cancel", "cancel-before"].contains(env["AIM_QA_LAN_CASE"] ?? "") {
            // The caller's task remains alive to verify actual Network.framework
            // cancellation acknowledgement, not merely continuation completion.
            for _ in 0..<50 {
                if (try? AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()) != nil {
                    ProbeDiagnostics.mark("lan-cancellation-quiesced"); throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw AIMNetworkPrivacyTransactionError.transportStillActive
        }
        defer { link.close() }
        guard !["cancel", "cancel-before"].contains(env["AIM_QA_LAN_CASE"] ?? "") else { throw DirectRemoteError.unavailable("cancelled_attempt_connected") }
        try await link.send(.init(type: "qa-ping"))
        var echoed = false
        for await message in link.messages { echoed = message.type == "qa-pong"; break }
        guard echoed else { throw DirectRemoteError.invalidPacket }
        link.close(); try await link.waitUntilClosed()
        let value: [String: RemoteJSONValue] = ["schema": .number(1), "status": .string("observed"),
            "outcome": .string("connected"), "exactSyntheticEcho": .bool(true),
            "runID": .string(run), "sourceSHA256": .string(source), "binarySHA256": .string(binary),
            "namespace": .string(namespace), "pid": .number(Double(getpid())),
            "startedAt": .number(launchedAt), "finishedAt": .number(Date().timeIntervalSince1970),
            "fullControllerQualified": .bool(false), "physicalDevicesQualified": .bool(false)]
        try DirectRemoteCoding.encode(value).write(to: root.appendingPathComponent("lan-observation.json"), options: .atomic)
        ProbeDiagnostics.mark("lan-echo-and-close-complete")
    }
    private static func qualifyPermissionEdit(controller: DirectRemoteController, root: URL, requireRelay: Bool) async throws {
        guard let original = try await controller.records().first,
              original.pair.revision == 1, original.pair.permissions == [.read, .chat] else { throw DirectRemoteError.invalidConfiguration }
        let firstRPC = try await controller.selectedSession(), commandID = UUID()
        let jobPayload = RemoteJSONValue.object(["text": .string("synthetic permission job")])
        let accepted = try await firstRPC.request(operation: "createSession", payload: jobPayload, id: commandID)
        guard accepted.objectValue?["accepted"]?.boolValue == true else { throw DirectRemoteError.invalidPacket }
        try Data("edit".utf8).write(to: root.appendingPathComponent("permission-edit-request"), options: .atomic)
        var reconnected = false
        for _ in 0..<450 {
            if let current = try await controller.records().first,
               current.pair.revision == 2, case .connected = await controller.connectionState() {
                reconnected = true; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard reconnected, FileManager.default.fileExists(atPath: root.appendingPathComponent("permission-edit-done").path),
              let revised = try await controller.records().first,
              revised.pair.permissions == [.read], revised.pair.id == original.pair.id,
              revised.pair.host == original.pair.host, revised.pair.client == original.pair.client,
              revised.pair.version == original.pair.version, revised.pair.confirmedAt == original.pair.confirmedAt,
              revised.location == original.location,
              try controller.identity.sessionKey(pair: revised.pair) == controller.identity.sessionKey(pair: original.pair) else {
            throw DirectRemoteError.unavailable("permission_reconnect_did_not_preserve_pair")
        }
        let rpc = try await controller.selectedSession()
        let overview = try await rpc.request(operation: "overview", payload: .object([:]), id: UUID())
        guard overview.objectValue?["grantRevision"]?.numberValue == 2,
              overview.objectValue?["effectCount"]?.numberValue == 1 else { throw DirectRemoteError.invalidPacket }
        // Existing command IDs must remain deduplicated without exposing an old
        // privileged result after access to that command was removed.
        for id in [commandID, UUID()] {
            do {
                _ = try await rpc.request(operation: "createSession", payload: jobPayload, id: id)
                throw DirectRemoteError.unavailable("removed_chat_permission_was_allowed")
            } catch DirectRemoteError.unauthorized { }
        }
        do {
            _ = try await rpc.request(operation: "command", payload: .object(["type": .string("run_command"), "payload": .object([:])]), id: UUID())
            throw DirectRemoteError.unavailable("ungranted_terminal_permission_was_allowed")
        } catch DirectRemoteError.unauthorized { }
        let finalOverview = try await rpc.request(operation: "overview", payload: .object([:]), id: UUID())
        guard finalOverview.objectValue?["effectCount"]?.numberValue == 1,
              case .connected(let path) = await controller.connectionState(),
              !requireRelay || path == .turn else { throw DirectRemoteError.invalidPacket }
        let receipt: [String: RemoteJSONValue] = ["realNativeDataChannel": .bool(true), "encryptedRPC": .bool(true),
            "transportPath": .string(path.rawValue), "initialRevision": .number(1), "updatedRevision": .number(2),
            "pairedOnce": .bool(true), "automaticReconnectWithoutRepairing": .bool(true), "preservedPairIdentityLocationAndKey": .bool(true),
            "readOnlyOverviewSucceeded": .bool(true), "removedChatEffectDenied": .bool(true),
            "priorPrivilegedReplyDenied": .bool(true), "ungrantedTerminalDenied": .bool(true), "nativeEffectCount": .number(1),
            "physicalDevicesQualified": .bool(false), "appIntegrationQualified": .bool(false)]
        try writeReceipt(receipt, mode: "phone-permission-edit", root: root)
    }
}
