import Foundation

/// Safe diagnostics: never carries PINs, tokens, device secrets or HTTP bodies.
public enum RemoteSecurityServiceError: Error, Equatable, Sendable {
    case server(code: String)
    case authenticationRequired
    case deviceNotPaired
    case transport(code: String)
    case invalidResponse
    case contextChanged
}

public struct RemoteUnlockState: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public let passkeyCount: Int
    public let hasPIN: Bool
    public let lockedUntil: Date?
    public let isEnabled: Bool
    public let errorCode: String?

    public init(
        succeeded: Bool,
        passkeyCount: Int = 0,
        hasPIN: Bool = false,
        lockedUntil: Date? = nil,
        isEnabled: Bool = true,
        errorCode: String? = nil
    ) {
        self.succeeded = succeeded
        self.passkeyCount = passkeyCount
        self.hasPIN = hasPIN
        self.lockedUntil = lockedUntil
        self.isEnabled = isEnabled
        self.errorCode = errorCode
    }

    enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case passkeyCount = "passkeys"
        case hasPIN = "pin"
        case lockedUntil = "locked_until"
        case isEnabled = "enabled"
        case errorCode = "error"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        succeeded = try container.decodeIfPresent(Bool.self, forKey: .succeeded) ?? false
        passkeyCount = try container.decodeIfPresent(Int.self, forKey: .passkeyCount) ?? 0
        hasPIN = try container.decodeIfPresent(Bool.self, forKey: .hasPIN) ?? false
        if let value = try container.decodeIfPresent(String.self, forKey: .lockedUntil) {
            lockedUntil = ISO8601DateFormatter().date(from: value)
        } else {
            lockedUntil = nil
        }
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

public enum RemoteBiometricPreference: String, Codable, Equatable, Sendable {
    case undecided
    case enabled
    case later
}

public struct RemoteSecurityResult: Equatable, Sendable {
    public let succeeded: Bool
    public let token: RemoteUnlockToken?
    public let isEnabled: Bool?
    public let lockedUntil: Date?
    public let attempts: Int?
    public let errorCode: String?

    public init(
        succeeded: Bool,
        token: RemoteUnlockToken? = nil,
        isEnabled: Bool? = nil,
        lockedUntil: Date? = nil,
        attempts: Int? = nil,
        errorCode: String? = nil
    ) {
        self.succeeded = succeeded
        self.token = token
        self.isEnabled = isEnabled
        self.lockedUntil = lockedUntil
        self.attempts = attempts
        self.errorCode = errorCode
    }
}

public protocol RemoteSecurityServicing: Sendable {
    func deviceAuthorizationState() async throws -> RemoteDeviceAuthorizationState?
    func migrateDeviceAuthorization() async throws -> RemoteDeviceAuthorizationState
    func authorizeDevice() async throws -> RemoteUnlockToken
    func remoteProtectionPolicy() async throws -> RemoteProtectionPolicy?
    func setRemoteProtectionPolicy(_ modes: [RemoteMode], expectedRevision: Int) async throws -> RemoteProtectionPolicy
    func remoteUnlockState() async throws -> RemoteUnlockState
    func setRemoteUnlockEnabled(_ enabled: Bool) async throws -> RemoteSecurityResult
    func setRemotePIN(_ pin: String) async throws -> RemoteSecurityResult
    func verifyRemotePIN(_ pin: String) async throws -> RemoteSecurityResult
    func lockRemote() async
    func resetRemoteSecurity() async throws -> RemoteSecurityResult
}

public extension RemoteSecurityServicing {
    func deviceAuthorizationState() async throws -> RemoteDeviceAuthorizationState? { nil }
    func migrateDeviceAuthorization() async throws -> RemoteDeviceAuthorizationState { throw RemoteSecurityServiceError.server(code: "server_update_required") }
    func authorizeDevice() async throws -> RemoteUnlockToken { throw RemoteSecurityServiceError.server(code: "server_update_required") }
    func remoteProtectionPolicy() async throws -> RemoteProtectionPolicy? { nil }
    func setRemoteProtectionPolicy(_ modes: [RemoteMode], expectedRevision: Int) async throws -> RemoteProtectionPolicy {
        throw RemoteSecurityServiceError.server(code: "policy_unavailable")
    }

    func remoteUnlockState() async throws -> RemoteUnlockState {
        .init(succeeded: false, errorCode: "unavailable")
    }

    func setRemoteUnlockEnabled(_ enabled: Bool) async throws -> RemoteSecurityResult {
        .init(succeeded: false, errorCode: "unavailable")
    }

    func setRemotePIN(_ pin: String) async throws -> RemoteSecurityResult {
        .init(succeeded: false, errorCode: "unavailable")
    }

    func verifyRemotePIN(_ pin: String) async throws -> RemoteSecurityResult {
        .init(succeeded: false, errorCode: "unavailable")
    }

    func lockRemote() async {}

    func resetRemoteSecurity() async throws -> RemoteSecurityResult {
        .init(succeeded: false, errorCode: "unavailable")
    }
}

public protocol BiometricSecretStoring: Sendable {
    func storeBiometricPIN(_ pin: String) throws
    func biometricPIN(reason: String) async throws -> String
    func removeBiometricPIN() throws
}

public struct RemoteDeviceAuthorizationState: Codable, Equatable, Sendable {
    public let version: Int
    public let legacyProtected: Bool
    public init(version: Int, legacyProtected: Bool) { self.version = version; self.legacyProtected = legacyProtected }
    enum CodingKeys: String, CodingKey { case version; case legacyProtected = "legacy_protected" }
}
