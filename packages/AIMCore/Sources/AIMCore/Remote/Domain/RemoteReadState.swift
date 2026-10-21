import Foundation

/// A read result, independent of pairing, presence and command responsiveness.
public enum RemoteReadState: String, Codable, Equatable, Sendable {
    case unknown, readable, keyPending, historicalKeyMissing, envelopeUnreadable
    case payloadUnreadable, invalidData, unavailable

    public var blocksReading: Bool { self != .unknown && self != .readable }
}

struct RemoteFieldRead: Sendable {
    let text: String?
    let state: RemoteReadState
    let keyVersion: Int?

    var displayText: String? {
        switch state {
        case .unknown, .readable: text
        case .keyPending: "🔒 En attente de la clé de l’ordinateur…"
        case .historicalKeyMissing: "🔒 Clé historique indisponible sur cet appareil"
        case .envelopeUnreadable: "🔒 Clé reçue mais illisible sur cet appareil"
        case .payloadUnreadable, .invalidData: "🔒 Contenu illisible sur cet appareil"
        case .unavailable: "🔒 Lecture momentanément indisponible"
        }
    }
}

enum RemoteFieldReader {
    static func read(_ value: String?, context: RemoteFieldContext, currentVersion: Int?,
                     keys: [Int: Data], envelopeUnreadable: Bool = false) -> RemoteFieldRead {
        guard let value else { return .init(text: nil, state: .unknown, keyVersion: nil) }
        guard RemoteCrypto.isEncrypted(value) else {
            // Only an explicitly legacy machine may publish plaintext. Missing
            // keys must never make a protected machine's plaintext acceptable.
            return .init(text: currentVersion == nil ? value : nil,
                         state: currentVersion == nil ? .readable : .payloadUnreadable, keyVersion: nil)
        }
        guard let version = RemoteCrypto.keyVersion(of: value) else {
            return .init(text: nil, state: .invalidData, keyVersion: nil)
        }
        guard keys[version] != nil else {
            let state: RemoteReadState = envelopeUnreadable ? .envelopeUnreadable
                : currentVersion.map { version < $0 } == true ? .historicalKeyMissing : .keyPending
            return .init(text: nil, state: state, keyVersion: version)
        }
        do {
            return .init(text: try RemoteCrypto.decryptField(value, keys: keys, context: context),
                         state: .readable, keyVersion: version)
        } catch {
            return .init(text: nil, state: .payloadUnreadable, keyVersion: version)
        }
    }
}

/// Safe correlation metadata. Never contains key material or conversation text.
public struct RemoteLinkDiagnostic: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let accountIdentifier: String
    public let deviceIdentifier: String
    public let machineIdentifier: String
    public let localPublicKeyFingerprint: String?
    public let registeredPublicKeyFingerprint: String?
    public let currentKeyVersion: Int?
    public let envelopeVersions: [Int]
    public let openedVersions: [Int]
    public let unreadableVersions: [Int]
    public let readState: RemoteReadState

    public init(accountID: String, deviceID: String, machineID: String, localPublicKey: String?,
                registeredPublicKey: String?, currentKeyVersion: Int?, envelopeVersions: [Int],
                openedVersions: [Int], unreadableVersions: [Int], readState: RemoteReadState) {
        timestamp = Date()
        accountIdentifier = RemoteDiagnosticPrivacy.identifier(accountID.lowercased())
        deviceIdentifier = RemoteDiagnosticPrivacy.identifier(deviceID.lowercased())
        machineIdentifier = RemoteDiagnosticPrivacy.identifier(machineID.lowercased())
        localPublicKeyFingerprint = localPublicKey.map(RemoteDiagnosticPrivacy.identifier)
        registeredPublicKeyFingerprint = registeredPublicKey.map(RemoteDiagnosticPrivacy.identifier)
        self.currentKeyVersion = currentKeyVersion
        self.envelopeVersions = envelopeVersions.sorted()
        self.openedVersions = openedVersions.sorted()
        self.unreadableVersions = unreadableVersions.sorted()
        self.readState = readState
    }
}
