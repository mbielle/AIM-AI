import AIMCore
import Foundation

public typealias RuntimeManagedNetworkSession = AIMManagedNetworkSession

public enum RuntimePrivacyError: LocalizedError, Sendable {
    case externalAccessDisabled
    public var errorDescription: String? { "Private Agent mode blocks this external request. Choose a local model or explicitly disable this mode before continuing." }
}

/// Re-read at every request/effect boundary, including restored missions and children.
/// Account sign-in and unrelated application services are separate from Agent egress.
public enum RuntimePrivacyPolicy {
    public static let defaultsKey = "AIMPrivateAgentModeEnabled"
    public static let globalDefaultsKey = AIMNetworkPrivacyPolicy.defaultsKey
    public static var isGlobalEnabled: Bool { AIMNetworkPrivacyPolicy.isConfiguredEnabled }
    public static var isApplicationNetworkBlocked: Bool { AIMNetworkPrivacyPolicy.isEnabled }
    public static var isAgentEnabled: Bool {
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.synchronize()
        return defaults.bool(forKey: defaultsKey) == true
    }
    public static var isEnabled: Bool { isAgentEnabled || isApplicationNetworkBlocked }
    public static var changedNotification: Notification.Name { AIMNetworkPrivacyPolicy.changedNotification }
    public static func globalChanges() -> AsyncStream<Bool> { AIMNetworkPrivacyPolicy.changes() }
    public static func setGlobalEnabled(_ enabled: Bool) throws { try AIMNetworkPrivacyPolicy.setEnabled(enabled) }
    public static func requireApplicationNetwork() throws { try AIMNetworkPrivacyPolicy.requireNetwork() }
    public static func requireNetwork() throws {
        if isEnabled { throw RuntimePrivacyError.externalAccessDisabled }
    }
    public static func requireEndpoint(_ url: URL) throws {
        guard isEnabled else { return }
        guard AIMNetworkPrivacyPolicy.isManagedLocalEndpoint(url) else { throw RuntimePrivacyError.externalAccessDisabled }
    }
    public static func registerManagedLocalEndpoint(_ url: URL, ownerIsRunning: @escaping @Sendable () -> Bool) throws -> UUID {
        try AIMNetworkPrivacyPolicy.registerManagedLocalEndpoint(url, ownerIsRunning: ownerIsRunning)
    }
    public static func unregisterManagedLocalEndpoint(_ id: UUID) { AIMNetworkPrivacyPolicy.unregisterManagedLocalEndpoint(id) }
}
