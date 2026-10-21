import AIMCore
import Foundation

/// Local execution is available with a persistent profile. Account access remains
/// a separate condition for cloud synchronization and Remote.
package enum AccountAccess: Equatable {
    case granted(AuthenticatedUser?, offline: Bool)
    case restoring
    case signInRequired
    case notConfigured

    package var isGranted: Bool { if case .granted = self { true } else { false } }
}

package enum AccountAccessPolicy {
    /// How long a Mac that cannot reach the account server keeps working after the
    /// account was last confirmed online.
    static let offlineGrace: TimeInterval = 7 * 24 * 3600

    package static func access(identity: AppIdentity?, offline: Bool) -> AccountAccess {
        guard let identity else { return .notConfigured }
        return .granted(identity.authenticatedUser, offline: offline)
    }

    static func offlineUser(_ record: VerifiedAccount?, now: Date) -> AuthenticatedUser? {
        guard let record, now >= record.verifiedAt, now.timeIntervalSince(record.verifiedAt) < offlineGrace else { return nil }
        return AuthenticatedUser(id: record.id, email: record.email, fullName: record.fullName)
    }
}

/// The last account the server confirmed on this Mac, kept in the Keychain for the offline grace.
struct VerifiedAccount: Codable, Equatable {
    let id: UUID
    let email: String?
    let fullName: String?
    let verifiedAt: Date

    static let storageKey = "aim.mac.last-verified-account"

    static func read(from store: (any SecureStoring)?) -> VerifiedAccount? {
        guard let data = try? store?.readData(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(VerifiedAccount.self, from: data)
    }

    static func write(_ user: AuthenticatedUser, at date: Date, to store: (any SecureStoring)?) {
        let record = VerifiedAccount(id: user.id, email: user.email, fullName: user.fullName, verifiedAt: date)
        guard let store, let data = try? JSONEncoder().encode(record) else { return }
        try? store.store(data, forKey: storageKey)
    }

    static func remove(from store: (any SecureStoring)?) {
        try? store?.removeData(forKey: storageKey)
    }
}
