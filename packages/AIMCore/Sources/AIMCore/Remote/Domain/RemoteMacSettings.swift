import Foundation

public extension RemoteCapabilities.Feature {
    static let macSettings = "mac_settings"
}

public enum RemoteMacSettingsAvailability: String, Equatable, Sendable {
    case ready, selectComputer, pairingRequired, offline, authorizationRequired, synchronizing, updateRequired, keyUnavailable

    public static func resolve(connection: RemoteConnectionState, machine: RemoteMachine?, authorized: Bool, at date: Date = .now) -> Self {
        guard connection == .paired else { return .pairingRequired }
        guard let machine else { return .selectComputer }
        guard machine.isOnline(at: date) else { return .offline }
        guard authorized else { return .authorizationRequired }
        guard !machine.readState.blocksReading else { return .keyUnavailable }
        guard let capabilities = machine.capabilities else { return .synchronizing }
        // An absent announcement is not proof of incompatibility. Older bridges
        // can answer the typed request; only an explicit refusal establishes it.
        return capabilities.features[RemoteCapabilities.Feature.macSettings] == false ? .updateRequired : .ready
    }
}

public enum RemoteMacSettingsError: Error, Equatable, Sendable {
    case unavailable(RemoteMacSettingsAvailability)
    case bridgeUnresponsive, updateRequired, authorizationRequired, invalidResponse, connectionFailed

    public static func classify(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        let code: RemoteCommandErrorCode
        switch error {
        case let RemoteServiceError.commandFailure(failure): code = failure.code
        case let RemoteServiceError.commandRejected(value), let RemoteSecurityServiceError.server(value): code = .classify(value)
        case RemoteSecurityServiceError.deviceNotPaired, RemoteServiceError.deviceNotPaired: return .unavailable(.pairingRequired)
        case RemoteSecurityServiceError.invalidResponse: return .invalidResponse
        case RemoteSecurityServiceError.authenticationRequired: return .authorizationRequired
        default: return .connectionFailed
        }
        switch code {
        case .bridgeUnresponsive: return .bridgeUnresponsive
        case .incompatibleVersion, .unsupportedCommand: return .updateRequired
        case .unlockRequired, .authenticationRequired: return .authorizationRequired
        case .computerOffline: return .unavailable(.offline)
        case .deviceNotPaired: return .unavailable(.pairingRequired)
        case .encryptionKeyPending, .unreadablePayload: return .unavailable(.keyUnavailable)
        default: return .connectionFailed
        }
    }
}

public struct RemoteMacSettings: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public var appearance: Appearance
    public var notifyRemote: Bool
    public var notifyApprovals: Bool
    public var notifyQuestions: Bool
    public init(appearance: Appearance, notifyRemote: Bool, notifyApprovals: Bool, notifyQuestions: Bool) {
        self.appearance = appearance; self.notifyRemote = notifyRemote; self.notifyApprovals = notifyApprovals; self.notifyQuestions = notifyQuestions
    }
    public var json: RemoteJSONValue { .object(["appearance": .string(appearance.rawValue), "notify_remote": .bool(notifyRemote), "notify_approvals": .bool(notifyApprovals), "notify_questions": .bool(notifyQuestions)]) }
    public init(json: RemoteJSONValue) throws {
        guard let object = json.objectValue, let appearance = object["appearance"]?.stringValue.flatMap(Appearance.init(rawValue:)),
              let notifyRemote = object["notify_remote"]?.boolValue, let notifyApprovals = object["notify_approvals"]?.boolValue,
              let notifyQuestions = object["notify_questions"]?.boolValue,
              Set(object.keys) == ["appearance", "notify_remote", "notify_approvals", "notify_questions"] else { throw RemoteSecurityServiceError.invalidResponse }
        self.init(appearance: appearance, notifyRemote: notifyRemote, notifyApprovals: notifyApprovals, notifyQuestions: notifyQuestions)
    }
}
