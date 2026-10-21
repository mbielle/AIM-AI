import Foundation

public actor AuthenticationCallbackDeduplicator {
    private let capacity: Int
    private var claimedKeys: Set<String> = []
    private var insertionOrder: [String] = []

    public init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    public func claim(_ url: URL) -> Bool {
        let key = Self.key(for: url)
        guard claimedKeys.insert(key).inserted else {
            return false
        }
        insertionOrder.append(key)

        if insertionOrder.count > capacity {
            claimedKeys.remove(insertionOrder.removeFirst())
        }
        return true
    }

    public func release(_ url: URL) {
        let key = Self.key(for: url)
        claimedKeys.remove(key)
        insertionOrder.removeAll { $0 == key }
    }

    private static func key(for url: URL) -> String {
        SecureNonceGenerator.sha256(url.absoluteString)
    }
}
