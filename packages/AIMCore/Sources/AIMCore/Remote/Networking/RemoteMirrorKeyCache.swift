import Foundation

/// Reuse only within the account and device identity that opened the envelope.
struct RemoteMirrorKeyContext: Equatable, Sendable {
    let accountID: UUID
    let deviceID: String
    let publicKey: String
    let generation: UUID
}

struct RemoteMirrorKeyCacheEntry: Sendable {
    let context: RemoteMirrorKeyContext
    let keys: [Int: Data]
    let fetchedAt: Date

    func isUsable(context: RemoteMirrorKeyContext, requiredVersion: Int?, now: Date) -> Bool {
        guard self.context == context, !keys.isEmpty,
              now >= fetchedAt, now.timeIntervalSince(fetchedAt) < 5 else { return false }
        return requiredVersion.map { keys[$0] != nil } ?? true
    }
}
