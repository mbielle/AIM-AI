import Foundation
import Network

// Compile-only dependency, deliberately unavailable. No Supabase code is linked.
// Calling stock quiesceDisallowedTasks() fails rather than claiming socket closure.
enum AIMNativeRealtime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var invocations = 0
    static var invocationCount: Int { lock.withLock { invocations } }
    static func closeAll() async throws {
        lock.withLock { invocations += 1 }
        throw HarnessError.unavailableRealtime
    }
}
enum HarnessError: Error { case failed(String), unavailableRealtime }
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}
final class ListenerReceipt: @unchecked Sendable {
    private let condition = NSCondition()
    private var ready = false
    private var cancelled = false
    private var failure: String?
    private var connections = 0
    func update(_ state: NWListener.State) {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .ready: ready = true
        case .cancelled: cancelled = true
        case .failed(let error): failure = String(describing: error)
        default: break
        }
        condition.broadcast()
    }
    func connection() { condition.lock(); connections += 1; condition.unlock() }
    func wait(cancel: Bool) throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !(cancel ? cancelled : ready) && failure == nil {
            guard condition.wait(until: deadline) else { throw HarnessError.failed("NWListener callback timeout") }
        }
        if let failure { throw HarnessError.failed("NWListener failed: \(failure)") }
    }
    func count() -> Int { condition.lock(); defer { condition.unlock() }; return connections }
}
@main struct Harness {
    static func check(_ truth: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try truth() else { throw HarnessError.failed(name) }
        print("PASS \(name)")
    }
    static func refuses(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { print("PASS \(name): \(error)"); return }
        throw HarnessError.failed("Unexpected acceptance: \(name)")
    }
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() throws {
        let expected = ProcessInfo.processInfo.environment["AIM_HARNESS_NAMESPACE"] ?? ""
        // MUST precede every privacy policy/defaults/admission access.
        guard expected.range(of: "^com\\.aimai\\.macos\\.qualification\\.[0-9a-f]{32}$", options: .regularExpression) != nil,
              !expected.contains("5af0"), Bundle.main.bundleIdentifier == expected,
              AIMInstallationContext.isQualification,
              AIMInstallationContext.applicationSupportNamespace == expected,
              AIMInstallationContext.preferencesSuite == expected else {
            throw HarnessError.failed("Installation namespace guard refused execution")
        }
        print("GUARD qualification namespace \(expected)")
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw HarnessError.failed("Application Support missing")
        }
        print("STORAGE \(support.appendingPathComponent(expected).path)")
        try check(!AIMNetworkPrivacyPolicy.isEnabled, "fresh namespace admission open")

        let lifetime = try AIMNativeNetworkLifetime("harness synthetic two-token transport")
        let first = lifetime.attach(), second = lifetime.attach()
        let owner = UUID()
        let preparation = AIMNetworkPrivacyPreparation(ownerGeneration: owner)
        try AIMNetworkPrivacyAdmission.begin(preparation)
        try check(AIMNetworkPrivacyAdmission.isClosed, "preparation closes admission")
        try refuses("new opaque start blocked during preparation") { _ = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("forbidden new start") }
        try refuses("network admission blocked during preparation") { try AIMNetworkPrivacyPolicy.requireNetwork() }
        try refuses("active lease blocks application acknowledgement") { try AIMNetworkPrivacyAdmission.acknowledgeApplication(preparation) }
        try refuses("active lease blocks owner acknowledgement") {
            try AIMNetworkPrivacyAdmission.acknowledgeOwner(.init(preparation: preparation, ownerGeneration: owner))
        }
        try refuses("active lease blocks commit flag write even before receipt validation") {
            try AIMNetworkPrivacyPolicy.writeConfiguredEnabled(true)
        }
        try check(!AIMNetworkPrivacyPolicy.isConfiguredEnabled, "refused flag write preserves uncommitted state")
        try refuses("active lease cannot commit without acknowledgements") {
            try AIMNetworkPrivacyAdmission.commit(preparation, ownerReceipt: nil)
        }
        lifetime.cancelUnstarted()
        try refuses("cancelUnstarted does not release attached tokens") { try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle() }
        lifetime.complete(first)
        try refuses("partial token completion preserves lease") { try AIMNetworkPrivacyAdmission.acknowledgeApplication(preparation) }
        lifetime.complete(first)
        try refuses("duplicate token completion preserves remaining lease") { try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle() }
        lifetime.complete(second)
        try AIMNetworkPrivacyPolicy.requireLocalOpaqueIdle()
        try AIMNetworkPrivacyAdmission.acknowledgeApplication(preparation)
        let receipt = AIMNetworkPrivacyReceipt(preparation: preparation, ownerGeneration: owner)
        try AIMNetworkPrivacyAdmission.acknowledgeOwner(receipt)
        try AIMNetworkPrivacyAdmission.commit(preparation, ownerReceipt: receipt)
        try check(try AIMNetworkPrivacyAdmission.isCommitted(preparation), "terminal tokens permit acknowledged commit")
        try refuses("abort after commit refused") { try AIMNetworkPrivacyAdmission.abort(preparation) }

        let base = URL(string: "http://127.0.0.1:64321/v1")!
        try refuses("unowned localhost refused") { try AIMNetworkPrivacyPolicy.requireEndpoint(base) }
        let alive = LockedFlag(true)
        let endpoint = try AIMNetworkPrivacyPolicy.registerManagedLocalEndpoint(base, ownerIsRunning: { alive.get() })
        try AIMNetworkPrivacyPolicy.requireEndpoint(base.appendingPathComponent("models"))
        print("PASS live owned localhost accepts bounded base path (policy only, no connection)")
        try refuses("owned localhost does not authorize sibling path") {
            try AIMNetworkPrivacyPolicy.requireEndpoint(URL(string: "http://127.0.0.1:64321/other")!)
        }
        try refuses("owned localhost does not authorize other port") {
            try AIMNetworkPrivacyPolicy.requireEndpoint(URL(string: "http://127.0.0.1:64322/v1")!)
        }
        alive.set(false)
        try refuses("dead localhost owner refused") { try AIMNetworkPrivacyPolicy.requireEndpoint(base) }
        AIMNetworkPrivacyPolicy.unregisterManagedLocalEndpoint(endpoint)
        try AIMNetworkPrivacyPolicy.setEnabled(false)
        try check(!AIMNetworkPrivacyAdmission.isClosed && !AIMNetworkPrivacyPolicy.isEnabled, "disable reopens admission")
        let reopened = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("reopened synthetic transport")
        reopened.finish()

        // Real native listener lifecycle, bound exclusively to loopback, no client.
        let nativeLifetime = try AIMNativeNetworkLifetime("harness loopback NWListener")
        let token = nativeLifetime.attach()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { nativeLifetime.complete(token); throw error }
        let callbacks = ListenerReceipt()
        listener.newConnectionHandler = { connection in callbacks.connection(); connection.cancel() }
        listener.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed: nativeLifetime.complete(token)
            default: break
            }
            callbacks.update(state)
        }
        listener.start(queue: DispatchQueue(label: "aim.qualification.loopback-listener"))
        try callbacks.wait(cancel: false)
        guard let port = listener.port else { listener.cancel(); throw HarnessError.failed("Loopback listener port missing") }
        print("NATIVE listener ready 127.0.0.1:\(port.rawValue)")
        let nativePreparation = AIMNetworkPrivacyPreparation(ownerGeneration: nil)
        try AIMNetworkPrivacyAdmission.begin(nativePreparation)
        try refuses("ready native listener blocks acknowledgement") { try AIMNetworkPrivacyAdmission.acknowledgeApplication(nativePreparation) }
        listener.cancel()
        try callbacks.wait(cancel: true)
        try AIMNetworkPrivacyAdmission.acknowledgeApplication(nativePreparation)
        try AIMNetworkPrivacyAdmission.commit(nativePreparation, ownerReceipt: nil)
        try check(try AIMNetworkPrivacyAdmission.isCommitted(nativePreparation), "native cancelled callback permits commit")
        try check(callbacks.count() == 0, "loopback listener accepted no clients")
        try AIMNetworkPrivacyPolicy.setEnabled(false)
        try check(!AIMNetworkPrivacyPolicy.isEnabled, "final namespace admission reopened")
        try check(AIMNativeRealtime.invocationCount == 0, "unavailable realtime dependency never invoked")
        print("COMPLETE contract + native loopback callback checks; no Supabase/quiesce/zero-packet claim")
    }
}
