import Foundation
import Darwin

public enum AIMNetworkPrivacyError: LocalizedError, Sendable {
    case networkDisabled
    case opaqueOperationInProgress(String)
    case barrierUnavailable
    public var errorDescription: String? {
        switch self {
        case .barrierUnavailable: "AIM could not establish its shared privacy admission barrier. Application private mode was not changed."
        case .networkDisabled: "Application private mode blocks AIM-managed network access. Local data and credentials are preserved."
        case .opaqueOperationInProgress(let operation): "An AIM-managed operation is still active (\(operation)). Close or cancel it and wait for completion before enabling application private mode; AIM cannot attest cancellation of its opaque network effects."
        }
    }
}
public final class AIMNetworkPrivacyLease: Sendable {
    private let id: UUID
    fileprivate init(_ id: UUID) { self.id = id }
    /// Host completion callback only; cancellation intent does not finish a lease.
    public func finish() { AIMNetworkPrivacyPolicy.releaseOpaqueLease(id) }
    deinit { finish() }
}

/// Application-level policy for AIM-managed transports. It is not an OS firewall.
public enum AIMNetworkPrivacyPolicy {
    private final class Observer: @unchecked Sendable {
        let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
    }
    public static let defaultsKey = "AIMPrivateApplicationModeEnabled"
    public static let changedNotification = Notification.Name("AIMApplicationNetworkPrivacyChangedV1")
    public static var isEnabled: Bool { isConfiguredEnabled || AIMNetworkPrivacyAdmission.isClosed }
    public static var isConfiguredEnabled: Bool {
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.synchronize()
        return defaults.bool(forKey: defaultsKey) == true
    }
    public static func requireNetwork() throws {
        if isEnabled { throw AIMNetworkPrivacyError.networkDisabled }
    }
    public static func requireEndpoint(_ url: URL) throws {
        if isEnabled && !isManagedLocalEndpoint(url) { throw AIMNetworkPrivacyError.networkDisabled }
    }
    private struct LocalEndpoint: Sendable {
        let url: URL
        let ownerIsRunning: @Sendable () -> Bool
    }
    private static let lock = NSLock()
    private static let operationLock = NSLock()
    nonisolated(unsafe) private static var opaqueOperations: [UUID: (description: String, descriptor: Int32)] = [:]
    nonisolated(unsafe) private static var localEndpoints: [UUID: LocalEndpoint] = [:]
    /// Only a host-owned, live bundled model process may register its endpoint.
    /// A configured localhost address or a peer declaration is not authority.
    public static func registerManagedLocalEndpoint(_ url: URL, ownerIsRunning: @escaping @Sendable () -> Bool) throws -> UUID {
        guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil, url.user == nil, url.password == nil else {
            throw AIMNetworkPrivacyError.networkDisabled
        }
        let id = UUID()
        lock.lock(); localEndpoints[id] = LocalEndpoint(url: url, ownerIsRunning: ownerIsRunning); lock.unlock()
        return id
    }
    public static func unregisterManagedLocalEndpoint(_ id: UUID) {
        lock.lock(); localEndpoints.removeValue(forKey: id); lock.unlock()
    }
    public static func isManagedLocalEndpoint(_ url: URL) -> Bool {
        lock.lock(); let endpoints = Array(localEndpoints.values); lock.unlock()
        return endpoints.contains { endpoint in
            let base = endpoint.url
            return url.scheme == base.scheme && url.host == base.host && url.port == base.port
                && url.user == nil && url.password == nil
                && (url.path == "/health" || url.path == base.path || url.path.hasPrefix(base.path + "/"))
                && endpoint.ownerIsRunning()
        }
    }
    /// Serializes an opaque operation start with activation of global privacy.
    public static func beginOpaqueOperation(_ description: String = "AppleScript or hook") throws -> AIMNetworkPrivacyLease {
        operationLock.lock(); defer { operationLock.unlock() }
        let descriptor = try acquireSharedBarrier(exclusive: false)
        do { try requireNetwork() } catch { flock(descriptor, LOCK_UN); close(descriptor); throw error }
        let id = UUID(); opaqueOperations[id] = (String(description.prefix(256)), descriptor)
        return AIMNetworkPrivacyLease(id)
    }
    /// Host OS-confined worker only: no new worker starts during preparation,
    /// but a deny-network Seatbelt worker may run after private commit.
    public static func beginConfinedOperation() throws -> AIMNetworkPrivacyLease {
        operationLock.lock(); defer { operationLock.unlock() }
        let descriptor = try acquireSharedBarrier(exclusive: false)
        guard !AIMNetworkPrivacyAdmission.isPreparing else {
            flock(descriptor, LOCK_UN); close(descriptor)
            throw AIMNetworkPrivacyTransactionError.conflictingTransaction
        }
        let id = UUID(); opaqueOperations[id] = ("OS-confined local worker", descriptor)
        return AIMNetworkPrivacyLease(id)
    }
    fileprivate static func releaseOpaqueLease(_ id: UUID) {
        operationLock.lock()
        if let operation = opaqueOperations.removeValue(forKey: id) {
            flock(operation.descriptor, LOCK_UN); close(operation.descriptor)
        }
        operationLock.unlock()
    }
    public static func requireLocalOpaqueIdle() throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard opaqueOperations.isEmpty else {
            throw AIMNetworkPrivacyError.opaqueOperationInProgress(Set(opaqueOperations.values.map(\.description)).sorted().joined(separator: ", "))
        }
    }
    public static func setEnabled(_ enabled: Bool) throws {
        guard !enabled else { throw AIMNetworkPrivacyTransactionError.transactionRequired }
        try AIMNetworkPrivacyAdmission.disable()
    }
    static func writeConfiguredEnabled(_ enabled: Bool) throws {
        operationLock.lock()
        if enabled && !opaqueOperations.isEmpty {
            let operations = Set(opaqueOperations.values.map(\.description)).sorted().joined(separator: ", ")
            operationLock.unlock(); throw AIMNetworkPrivacyError.opaqueOperationInProgress(operations)
        }
        let descriptor: Int32?
        do { descriptor = enabled ? try acquireSharedBarrier(exclusive: true) : nil } catch { operationLock.unlock(); throw error }
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.set(enabled, forKey: defaultsKey); defaults.synchronize()
        if let descriptor { flock(descriptor, LOCK_UN); close(descriptor) }
        operationLock.unlock()
        if enabled { AIMManagedNetworkSession.cancelDisallowedTasks() }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
    /// The app and runtime helper use the same user Application Support path.
    /// The kernel releases a crashed process's leases; there is no stale JSON lease.
    private static func acquireSharedBarrier(exclusive: Bool) throws -> Int32 {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AIMNetworkPrivacyError.barrierUnavailable
        }
        let folder = support.appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/Privacy", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw AIMNetworkPrivacyError.barrierUnavailable
            }
        } catch { throw AIMNetworkPrivacyError.barrierUnavailable }
        let descriptor = open(folder.appendingPathComponent("opaque-admission-v1.lock").path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AIMNetworkPrivacyError.barrierUnavailable }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(descriptor)
            if busy { throw AIMNetworkPrivacyError.opaqueOperationInProgress("runtime helper or another AIM process") }
            throw AIMNetworkPrivacyError.barrierUnavailable
        }
        return descriptor
    }
    public static func changes() -> AsyncStream<Bool> {
        AIMManagedNetworkSession.installGlobalInterceptor()
        return AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(forName: changedNotification, object: nil, queue: nil) { _ in
                continuation.yield(isEnabled)
            }
            let observer = Observer(token)
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer.token) }
        }
    }
}

private final class AIMNetworkBlockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return AIMNetworkPrivacyPolicy.isEnabled && !AIMNetworkPrivacyPolicy.isManagedLocalEndpoint(url)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: AIMNetworkPrivacyError.networkDisabled) }
    override func stopLoading() {}
}

public enum AIMManagedNetworkSession {
    private final class WeakSession: @unchecked Sendable {
        weak var value: URLSession?
        init(_ value: URLSession) { self.value = value }
    }
    private final class FlushReceipt: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        var isComplete: Bool { lock.withLock { completed } }
        func finish() { lock.withLock { completed = true } }
    }
    private final class TaskListReceipt: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [URLSessionTask]?
        var value: [URLSessionTask]? { lock.withLock { tasks } }
        func finish(_ value: [URLSessionTask]) { lock.withLock { tasks = value } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [WeakSession] = []
    private final class PrivacyMonitor: @unchecked Sendable {
        let timer: DispatchSourceTimer
        private var previous = AIMNetworkPrivacyPolicy.isEnabled
        init() {
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.aimai.network-privacy"))
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let enabled = AIMNetworkPrivacyPolicy.isEnabled
                if self.previous != enabled {
                    self.previous = enabled
                    NotificationCenter.default.post(name: AIMNetworkPrivacyPolicy.changedNotification, object: nil)
                }
                if enabled { AIMManagedNetworkSession.cancelDisallowedTasks() }
            }
            timer.resume()
        }
        deinit { timer.cancel() }
    }
    private static let privacyMonitor = PrivacyMonitor()
    private static let installed = URLProtocol.registerClass(AIMNetworkBlockProtocol.self)
    public static func installGlobalInterceptor() { _ = installed; _ = privacyMonitor }
    public static let shared = make(configuration: .default)
    public static func make(configuration: URLSessionConfiguration, delegate: (any URLSessionDelegate)? = nil,
                            delegateQueue: OperationQueue? = nil) -> URLSession {
        installGlobalInterceptor()
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.protocolClasses = [AIMNetworkBlockProtocol.self] + (copy.protocolClasses ?? []).filter { $0 != AIMNetworkBlockProtocol.self }
        let session = URLSession(configuration: copy, delegate: delegate, delegateQueue: delegateQueue)
        lock.lock(); sessions.removeAll { $0.value == nil }; sessions.append(WeakSession(session)); lock.unlock()
        return session
    }
    static func forgetClosedSession(_ session: URLSession) {
        lock.withLock { sessions.removeAll { $0.value == nil || $0.value === session } }
    }
    public static func quiesceDisallowedTasks(timeout: Duration = .seconds(3)) async throws {
        try await AIMNativeRealtime.closeAll()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let current = lock.withLock { sessions.compactMap(\.value) }
            var pending = false
            for session in current {
                let taskList = TaskListReceipt()
                // Foundation delivers enumeration on the delegate queue too.
                // A stalled queue must not strand privacy preparation beyond its
                // deadline; only the actual callback supplies this receipt.
                session.getAllTasks { taskList.finish($0) }
                while taskList.value == nil {
                    guard ContinuousClock.now < deadline else { throw AIMNetworkPrivacyTransactionError.transportStillActive }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let tasks = taskList.value else { throw AIMNetworkPrivacyTransactionError.transportStillActive }
                for task in tasks where task.state != .completed {
                    if let url = task.currentRequest?.url, AIMNetworkPrivacyPolicy.isManagedLocalEndpoint(url) { continue }
                    task.cancel(); pending = true
                }
            }
            if !pending {
                for session in current {
                    let receipt = FlushReceipt()
                    // Foundation's documented flush completes on the delegate queue,
                    // clears transient caches and requires future requests to use a
                    // new TCP connection. It preserves saved credentials/cookies.
                    session.flush { receipt.finish() }
                    while !receipt.isComplete {
                        guard ContinuousClock.now < deadline else { throw AIMNetworkPrivacyTransactionError.transportStillActive }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
                return
            }
            guard ContinuousClock.now < deadline else { throw AIMNetworkPrivacyTransactionError.transportStillActive }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    public static func cancelDisallowedTasks() {
        lock.lock(); let current = sessions.compactMap(\.value); lock.unlock()
        for session in current {
            session.getAllTasks { tasks in
                for task in tasks {
                    if let url = task.currentRequest?.url, AIMNetworkPrivacyPolicy.isManagedLocalEndpoint(url) { continue }
                    task.cancel()
                }
            }
        }
    }
}
