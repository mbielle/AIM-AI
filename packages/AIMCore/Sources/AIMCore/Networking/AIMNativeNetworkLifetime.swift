import Foundation

/// A host callback barrier for Network.framework objects. Cancellation intent,
/// dropping a UI reference, or a JSON receipt does not release its opaque lease.
public final class AIMNativeNetworkLifetime: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var pending: [UUID: AIMNativeNetworkLifetime] = [:]
    private let id = UUID()
    private let lock = NSLock()
    private var tokens: Set<UUID> = []
    private var lease: AIMNetworkPrivacyLease?
    public init(_ operation: String) throws {
        lease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation(operation)
        Self.registryLock.withLock { Self.pending[id] = self }
    }
    public func attach() -> UUID {
        lock.withLock { let token = UUID(); tokens.insert(token); return token }
    }
    /// Only the native object's terminal cancelled/failed state callback.
    public func complete(_ token: UUID) {
        let finished: AIMNetworkPrivacyLease? = lock.withLock {
            guard tokens.remove(token) != nil, tokens.isEmpty else { return nil }
            let value = lease; lease = nil; return value
        }
        guard let finished else { return }
        finished.finish()
        Self.registryLock.withLock { _ = Self.pending.removeValue(forKey: id) }
    }
    /// Construction failed before any listener/socket was started.
    public func cancelUnstarted() {
        let finished: AIMNetworkPrivacyLease? = lock.withLock {
            guard tokens.isEmpty else { return nil }
            let value = lease; lease = nil; return value
        }
        guard let finished else { return }
        finished.finish()
        Self.registryLock.withLock { _ = Self.pending.removeValue(forKey: id) }
    }
}
