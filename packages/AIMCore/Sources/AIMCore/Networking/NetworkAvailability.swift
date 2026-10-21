import Foundation
import Network

/// Wait only before submission. A lost response after submission is uncertain;
/// this service never retries it or repeats a provider charge/tool effect.
public enum NetworkAvailability {
    public static func wait(onWaiting: @escaping @Sendable () -> Void) async throws {
        let monitor = NWPathMonitor(), state = WaitState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation, monitor: monitor)
                monitor.pathUpdateHandler = { path in
                    if path.status == .satisfied { state.finish(nil) }
                    else { state.waiting(onWaiting) }
                }
                monitor.start(queue: DispatchQueue(label: "aim.network-readiness"))
            }
        } onCancel: { state.finish(CancellationError()) }
    }
    public struct UnavailableBeforeSubmission: Error, Sendable { public init() {} }
    /// Read the first system path state. Failure is observed before any provider send.
    public static func check() async throws {
        let monitor = NWPathMonitor(), state = WaitState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation, monitor: monitor)
                monitor.pathUpdateHandler = { path in
                    state.finish(path.status == .satisfied ? nil : UnavailableBeforeSubmission())
                }
                monitor.start(queue: DispatchQueue(label: "aim.network-preflight"))
            }
        } onCancel: { state.finish(CancellationError()) }
    }
    private final class WaitState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var monitor: NWPathMonitor?
        private var finished = false
        private var announced = false
        func install(_ continuation: CheckedContinuation<Void, Error>, monitor: NWPathMonitor) {
            lock.lock()
            if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); monitor.cancel(); return }
            self.continuation = continuation; self.monitor = monitor; lock.unlock()
        }
        func waiting(_ callback: @Sendable () -> Void) {
            lock.lock(); let shouldAnnounce = !finished && !announced; announced = true; lock.unlock()
            if shouldAnnounce { callback() }
        }
        func finish(_ error: Error?) {
            lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
            let continuation = continuation, monitor = monitor; self.continuation = nil; self.monitor = nil; lock.unlock()
            monitor?.cancel()
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        }
    }
}
