import Foundation

/// A persistent local storage owner. This is deliberately not an authenticated
/// user and must never be sent as proof of ownership to a cloud service.
public struct LocalProfile: Codable, Equatable, Sendable {
    public let id: UUID

    public init(id: UUID) { self.id = id }

    /// A corrupt or inaccessible identity must not silently create a new owner
    /// and make existing conversations appear lost. Call on the app's serial
    /// startup path, with its installation-specific secure-store service.
    public static func loadOrCreate(store: any SecureStoring) throws -> LocalProfile {
        let key = "local-profile.v1"
        if let data = try store.readData(forKey: key) {
            return try JSONDecoder().decode(LocalProfile.self, from: data)
        }
        let profile = LocalProfile(id: UUID())
        try store.store(JSONEncoder().encode(profile), forKey: key)
        return profile
    }
}

/// Storage identity and cloud authentication are different capabilities.
/// Local data is never adopted or uploaded merely because someone signs in.
public enum AppIdentity: Equatable, Sendable {
    case local(LocalProfile)
    case account(AuthenticatedUser)

    public var storageID: UUID {
        switch self {
        case .local(let profile): profile.id
        case .account(let user): user.id
        }
    }

    public var authenticatedUser: AuthenticatedUser? {
        guard case .account(let user) = self else { return nil }
        return user
    }

    public var isLocal: Bool { authenticatedUser == nil }
}
