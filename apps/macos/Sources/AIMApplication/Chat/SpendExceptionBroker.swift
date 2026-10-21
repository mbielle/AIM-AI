import Foundation

/// An exception is decided by AIM's UI for one attempt ID. Cancellation or
/// shutdown denies the request before any provider send.
public actor SpendExceptionBroker {
    private struct Pending {
        let request: PendingSpendException
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var pending: [UUID: Pending] = [:]
    private var subscribers: [UUID: AsyncStream<[PendingSpendException]>.Continuation] = [:]
    private var closed = false

    public init() {}

    public func request(_ request: PendingSpendException) async -> Bool {
        guard !closed, !Task.isCancelled, pending.count < 32, pending[request.id] == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !closed, !Task.isCancelled else { continuation.resume(returning: false); return }
                pending[request.id] = Pending(request: request, continuation: continuation)
                publish()
            }
        } onCancel: {
            Task { await self.decide(id: request.id, allow: false) }
        }
    }

    @discardableResult public func decide(id: UUID, allow: Bool) -> Bool {
        guard let item = pending.removeValue(forKey: id) else { return false }
        item.continuation.resume(returning: allow)
        publish()
        return true
    }

    public func updates() -> AsyncStream<[PendingSpendException]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    public func close() {
        closed = true
        for id in Array(pending.keys) { _ = decide(id: id, allow: false) }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    public func snapshot() -> [PendingSpendException] {
        pending.values.map(\.request).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func publish() {
        let current = snapshot()
        for continuation in subscribers.values { continuation.yield(current) }
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}
