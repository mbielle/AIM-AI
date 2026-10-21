import AIMCore
import AIMApplication
import Foundation

/// One application-wide admission gate, shared by terminal, Git and runtime runners.
/// Callbacks and continuations always run outside the lock.
public final class ProcessSupervisor: @unchecked Sendable {
    public static let shared = ProcessSupervisor()
    private let lock = NSLock()
    private var accepting = true
    private var jobs: [UUID: @Sendable () -> Void] = [:]
    private var privacyLeases: [UUID: AIMNetworkPrivacyLease] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    public init() {}

    public var activeCount: Int { lock.withLock { jobs.count } }
    public var isShuttingDown: Bool { lock.withLock { !accepting } }

    func register(id: UUID, confinedNetworkDenied: Bool = false, cancel: @escaping @Sendable () -> Void) throws {
        if !confinedNetworkDenied { try RuntimePrivacyPolicy.requireApplicationNetwork() }
        let privacyLease = try confinedNetworkDenied ? AIMNetworkPrivacyPolicy.beginConfinedOperation()
            : AIMNetworkPrivacyPolicy.beginOpaqueOperation("native command or external stdio worker")
        try lock.withLock {
            guard accepting else { throw ProcessExecutionError.shuttingDown }
            jobs[id] = cancel
            privacyLeases[id] = privacyLease
        }
    }

    func finish(id: UUID) {
        let waiters = lock.withLock {
            jobs.removeValue(forKey: id)
            privacyLeases.removeValue(forKey: id)
            guard jobs.isEmpty else { return [CheckedContinuation<Void, Never>]() }
            let pending = idleWaiters
            idleWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    public func beginShutdown() {
        let cancellations = lock.withLock {
            accepting = false
            return Array(jobs.values)
        }
        for cancel in cancellations { cancel() }
    }

    public func waitForIdle() async {
        await withCheckedContinuation { continuation in
            let alreadyIdle = lock.withLock {
                guard !jobs.isEmpty else { return true }
                idleWaiters.append(continuation)
                return false
            }
            if alreadyIdle { continuation.resume() }
        }
    }

    public func waitForPrivacyIdle(timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while activeCount > 0 {
            guard ContinuousClock.now < deadline else { throw AIMNetworkPrivacyTransactionError.transportStillActive }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    /// Used only when quitting is cancelled after an unsuccessful save.
    @discardableResult public func resumeAfterCancelledShutdown() -> Bool {
        lock.withLock {
            guard jobs.isEmpty else { return false }
            accepting = true
            return true
        }
    }
}
