import Foundation
import LocalAuthentication
import Observation

@MainActor public protocol AppLockAuthenticating {
    func authenticate(reason: String) async throws
}

@MainActor public final class SystemAppLockAuthenticator: AppLockAuthenticating {
    public init() {}
    public func authenticate(reason: String) async throws {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? AppLockError.unavailable
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { throw AppLockError.cancelled }
    }
}
public enum AppLockError: LocalizedError {
    case unavailable, cancelled, storage
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Set up Face ID or a device passcode in system settings."
        case .cancelled: "Authentication was cancelled."
        case .storage: "The security setting could not be saved."
        }
    }
}

/// Device-only, account-scoped lock. Protected UI is removed by the host, not blurred.
@available(macOS 14.0, iOS 17.0, *)
@MainActor @Observable public final class AppLockService {
    public private(set) var isRequired: Bool
    public private(set) var isLocked: Bool
    public private(set) var isAuthenticating = false
    public private(set) var isConcealed = false
    public private(set) var errorMessage: String?
    private let authenticator: any AppLockAuthenticating
    private let secureStore: any SecureStoring
    private let preferenceKey: String
    private var hiddenAt: Date?
    private var generation = 0
    public init(accountID: UUID, authenticator: any AppLockAuthenticating = SystemAppLockAuthenticator(),
                secureStore: any SecureStoring = KeychainSecureStore(service: "com.aimai.app-lock")) {
        self.authenticator = authenticator; self.secureStore = secureStore
        preferenceKey = "require-system-auth.\(accountID.uuidString.lowercased())"
        do {
            let data = try secureStore.readData(forKey: preferenceKey)
            let required = data.map { $0 != Data([0]) } ?? false
            isRequired = required; isLocked = required
        } catch {
            // A temporarily inaccessible Keychain must never disable an existing lock.
            isRequired = true; isLocked = true; errorMessage = AppLockError.storage.localizedDescription
        }
    }
    public func setRequired(_ value: Bool) async {
        guard !isAuthenticating, value != isRequired else { return }
        let current = generation
        isAuthenticating = true; errorMessage = nil
        defer { isAuthenticating = false }
        do {
            try await authenticator.authenticate(reason: value ? "Enable Face ID protection for AIM" : "Disable Face ID protection for AIM")
            guard current == generation else { return }
            try secureStore.store(Data([value ? 1 : 0]), forKey: preferenceKey)
            isRequired = value; isLocked = false; isConcealed = false
        } catch { errorMessage = error.localizedDescription }
    }
    public func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        let current = generation
        isAuthenticating = true; errorMessage = nil
        defer { isAuthenticating = false }
        do {
            try await authenticator.authenticate(reason: "Unlock AIM")
            guard current == generation else { return }
            isLocked = false; isConcealed = false
        } catch { errorMessage = error.localizedDescription }
    }
    public func lock() { generation += 1; if isRequired { isLocked = true }; errorMessage = nil }
    public func becameInactive() { if isRequired { isConcealed = true } }
    public func enteredBackground(at date: Date = .now) {
        // System authentication causes inactive, not background. A real background exit
        // must count even while an authentication request is pending.
        hiddenAt = date
        if isRequired { isConcealed = true }
    }
    public func becameActive(at date: Date = .now) {
        if isRequired, let hiddenAt, date.timeIntervalSince(hiddenAt) >= 60 { lock() }
        hiddenAt = nil; isConcealed = false
    }
    /// Only called after a successful server migration. Keys/pairings are untouched.
    public func preserveLegacyProtection(_ protected: Bool) throws {
        guard try secureStore.readData(forKey: preferenceKey) == nil else { return }
        try secureStore.store(Data([protected ? 1 : 0]), forKey: preferenceKey)
        isRequired = protected; isLocked = protected
    }
}
