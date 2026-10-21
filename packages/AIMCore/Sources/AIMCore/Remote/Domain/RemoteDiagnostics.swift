import CryptoKit
import Foundation

public enum RemoteCommandStage: String, Codable, CaseIterable, Sendable {
    case authentication
    case rpc
    case queued
    case acknowledged
    case completed
    case failed
    case decrypting
    case published
}

public enum RemoteCommandErrorCode: String, Codable, CaseIterable, Sendable {
    case computerOffline = "computer_offline"
    case bridgeUnresponsive = "bridge_unresponsive"
    case incompatibleVersion = "incompatible_version"
    case encryptionKeyPending = "encryption_key_pending"
    case unreadablePayload = "unreadable_payload"
    case commandRefused = "command_refused"
    case unlockRequired = "unlock_required"
    case lateSynchronization = "late_synchronization"
    case deviceNotPaired = "device_not_paired"
    case unsupportedCommand = "unsupported_command"
    case authenticationRequired = "authentication_required"
    case networkUnavailable = "network_unavailable"
    case invalidRequest = "invalid_request"
    case unknown

    public static func classify(_ rawValue: String?) -> Self {
        let value = (rawValue ?? "unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "computer_offline", "machine_offline", "ordinateur_hors_ligne", "unknown_machine":
            return .computerOffline
        case "timeout", "bridge_timeout", "bridge_unresponsive", "commande_expiree", "command_expired":
            return .bridgeUnresponsive
        case "incompatible_version", "version_incompatible", "protocol_version":
            return .incompatibleVersion
        case "cle_en_attente", "cle_a_reappairer", "key_pending", "key_unavailable":
            return .encryptionKeyPending
        case "charge_illisible", "payload_unreadable", "decrypt_failed", "decryption_failed":
            return .unreadablePayload
        case "commande_refusee", "command_refused", "forbidden":
            return .commandRefused
        case "unlock_required", "deverrouillage_requis":
            return .unlockRequired
        case "late_synchronization", "mirror_timeout", "publication_timeout":
            return .lateSynchronization
        case "device_not_paired":
            return .deviceNotPaired
        case "commande_non_prise_en_charge", "unsupported_command", "unknown_command":
            return .unsupportedCommand
        case "not_authenticated", "session_not_found", "jwt_expired":
            return .authenticationRequired
        case "network", "network_unavailable", "reseau":
            return .networkUnavailable
        case "invalid_request", "invalid_payload", "bad_request":
            return .invalidRequest
        case "unknown", "":
            return .unknown
        default:
            return .commandRefused
        }
    }
}

public struct RemoteCommandFailure: Error, Equatable, Sendable {
    public let code: RemoteCommandErrorCode
    public let stage: RemoteCommandStage
    public let serverCode: String?
    public let diagnosticReference: String

    public init(
        code: RemoteCommandErrorCode,
        stage: RemoteCommandStage,
        serverCode: String? = nil,
        diagnosticReference: String
    ) {
        self.code = code
        self.stage = stage
        self.serverCode = Self.safeCode(serverCode)
        self.diagnosticReference = diagnosticReference
    }

    private static func safeCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let safe = value
            .uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return safe.isEmpty ? nil : String(safe.prefix(48))
    }
}

public struct RemoteCommandReceipt: Codable, Equatable, Sendable {
    public let identifier: String
    public let type: String
    public let stage: RemoteCommandStage
    public let status: String
    public let durationMilliseconds: Int
    public let errorCode: RemoteCommandErrorCode?
    public let diagnosticReference: String

    public init(
        identifier: String,
        type: String,
        stage: RemoteCommandStage,
        status: String,
        durationMilliseconds: Int,
        errorCode: RemoteCommandErrorCode? = nil,
        diagnosticReference: String
    ) {
        self.identifier = identifier
        self.type = type
        self.stage = stage
        self.status = status
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.errorCode = errorCode
        self.diagnosticReference = diagnosticReference
    }
}

public struct RemoteDiagnosticEntry: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let commandIdentifier: String
    public let machineIdentifier: String
    public let type: String
    public let stage: RemoteCommandStage
    public let status: String
    public let durationMilliseconds: Int
    public let errorCode: RemoteCommandErrorCode?
    public let serverCode: String?
    public let pathBasename: String?

    public init(
        timestamp: Date = Date(),
        commandIdentifier: String,
        machineIdentifier: String,
        type: String,
        stage: RemoteCommandStage,
        status: String,
        durationMilliseconds: Int,
        errorCode: RemoteCommandErrorCode? = nil,
        serverCode: String? = nil,
        pathBasename: String? = nil
    ) {
        self.timestamp = timestamp
        self.commandIdentifier = commandIdentifier
        self.machineIdentifier = machineIdentifier
        self.type = String(type.prefix(64))
        self.stage = stage
        self.status = String(status.prefix(32))
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.errorCode = errorCode
        self.serverCode = RemoteCommandFailure(
            code: errorCode ?? .unknown,
            stage: stage,
            serverCode: serverCode,
            diagnosticReference: ""
        ).serverCode
        self.pathBasename = pathBasename.map { String(URL(fileURLWithPath: $0).lastPathComponent.prefix(80)) }
    }
}

public struct RemoteDiagnosticReport: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let entries: [RemoteDiagnosticEntry]
    public let links: [RemoteLinkDiagnostic]?
    public let installationIdentifier: String?
    public let buildVersion: String?
    public let relayIdentifier: String?

    public init(
        formatVersion: Int = 1,
        generatedAt: Date = Date(),
        appVersion: String,
        entries: [RemoteDiagnosticEntry],
        links: [RemoteLinkDiagnostic]? = nil,
        installationIdentifier: String? = nil, buildVersion: String? = nil, relayIdentifier: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.entries = entries
        self.links = links
        self.installationIdentifier = installationIdentifier
        self.buildVersion = buildVersion
        self.relayIdentifier = relayIdentifier
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

public enum RemoteDiagnosticPrivacy {
    public static func identifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func reference(commandID: String, code: RemoteCommandErrorCode? = nil) -> String {
        let suffix = code?.rawValue.uppercased().replacingOccurrences(of: "_", with: "-") ?? "OK"
        return "REMOTE-\(identifier(commandID).uppercased())-\(suffix)"
    }
}

public enum RemoteCommandHealth: String, Codable, Equatable, Sendable {
    case unknown
    case checking
    case responsive
    case unresponsive
    case incompatible
}
