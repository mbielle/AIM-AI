import CryptoKit
import Foundation

public enum RemoteCryptoError: Error, Equatable, Sendable {
    case invalidKeyLength
    case invalidNonce
    case invalidPublicKey
    case invalidEncryptedFormat
    case unknownKeyVersion(Int)
    case authenticationFailed
    case unsupportedEnvelope
    case invalidMirrorKey
    case invalidUTF8
}

public struct RemoteFieldContext: Equatable, Sendable {
    public let table: String
    public let column: String
    public let rowID: String

    public init(table: String, column: String, rowID: String) {
        self.table = table
        self.column = column
        self.rowID = rowID
    }

    public var associatedDataString: String {
        "aim-remote/v1|\(table).\(column)|\(rowID)"
    }

    var associatedData: Data {
        Data(associatedDataString.utf8)
    }
}

public struct RemoteCommandIdentity: Equatable, Sendable {
    public enum Column: String, Sendable {
        case payload
        case result
    }

    public let id: String
    public let type: String
    public let sessionID: String?
    public let machineID: String

    public init(id: String, type: String, sessionID: String?, machineID: String) {
        self.id = id
        self.type = type
        self.sessionID = sessionID
        self.machineID = machineID
    }

    public func context(for column: Column) -> RemoteFieldContext {
        RemoteFieldContext(
            table: "remote_commands",
            column: column.rawValue,
            rowID: "\(id)|\(type)|\(sessionID ?? "")|\(machineID)"
        )
    }
}

public struct RemoteKeyEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let keyVersion: Int
    public let ephemeralPublicKey: String
    public let nonce: String
    public let ciphertext: String

    public init(
        version: Int,
        keyVersion: Int,
        ephemeralPublicKey: String,
        nonce: String,
        ciphertext: String
    ) {
        self.version = version
        self.keyVersion = keyVersion
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case keyVersion = "kv"
        case ephemeralPublicKey = "epk"
        case nonce = "iv"
        case ciphertext = "ct"
    }
}

public struct RemoteDevicePrivateKey: @unchecked Sendable {
    let key: P256.KeyAgreement.PrivateKey

    public init() {
        key = P256.KeyAgreement.PrivateKey()
    }

    public init(rawRepresentation: Data) throws {
        do {
            key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw RemoteCryptoError.invalidPublicKey
        }
    }

    public var publicKeyBase64: String {
        key.publicKey.x963Representation.base64EncodedString()
    }

    var rawRepresentation: Data {
        key.rawRepresentation
    }
}

public enum RemoteCrypto {
    public static let encryptedPrefix = "e1."

    public static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(encryptedPrefix)
    }

    public static func keyVersion(of value: String) -> Int? {
        let components = value.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard
            components.count == 3,
            components[0] == "e1",
            !components[1].isEmpty,
            components[1].allSatisfy(\.isNumber),
            let version = Int(components[1])
        else {
            return nil
        }
        return version
    }

    public static func encryptField(
        _ plaintext: String,
        key: Data,
        version: Int,
        context: RemoteFieldContext,
        nonce: Data? = nil
    ) throws -> String {
        guard version >= 1 else { throw RemoteCryptoError.invalidEncryptedFormat }
        let sealed = try seal(
            Data(plaintext.utf8),
            key: key,
            nonce: nonce ?? randomBytes(count: 12),
            authenticatedData: context.associatedData
        )
        return "\(encryptedPrefix)\(version).\(sealed.base64EncodedString())"
    }

    public static func decryptField(
        _ value: String,
        keys: [Int: Data],
        context: RemoteFieldContext
    ) throws -> String {
        let components = value.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard
            components.count == 3,
            components[0] == "e1",
            !components[1].isEmpty,
            components[1].allSatisfy(\.isNumber),
            let version = Int(components[1])
        else {
            throw RemoteCryptoError.invalidEncryptedFormat
        }
        guard let key = keys[version] else {
            throw RemoteCryptoError.unknownKeyVersion(version)
        }
        guard let combined = Data(base64Encoded: String(components[2])), combined.count >= 28 else {
            throw RemoteCryptoError.invalidEncryptedFormat
        }
        let plaintext = try open(combined, key: key, authenticatedData: context.associatedData)
        guard let result = String(data: plaintext, encoding: .utf8) else {
            throw RemoteCryptoError.invalidUTF8
        }
        return result
    }

    public static func wrapMirrorKey(
        _ mirrorKey: Data,
        devicePublicKeyBase64: String,
        machineID: String,
        deviceID: String,
        version: Int,
        ephemeralPrivateKey: Data? = nil,
        nonce: Data? = nil
    ) throws -> RemoteKeyEnvelope {
        guard mirrorKey.count == 32 else { throw RemoteCryptoError.invalidMirrorKey }
        guard version >= 1 else { throw RemoteCryptoError.invalidEncryptedFormat }
        let devicePublicKey = try publicKey(from: devicePublicKeyBase64)
        let ephemeral: P256.KeyAgreement.PrivateKey
        do {
            if let ephemeralPrivateKey {
                ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: ephemeralPrivateKey)
            } else {
                ephemeral = P256.KeyAgreement.PrivateKey()
            }
        } catch {
            throw RemoteCryptoError.invalidPublicKey
        }

        let ephemeralPublic = ephemeral.publicKey.x963Representation
        let devicePublic = devicePublicKey.x963Representation
        let keyEncryptionKey = try envelopeKey(
            privateKey: ephemeral,
            otherPublicKey: devicePublicKey,
            ephemeralPublicKey: ephemeralPublic,
            devicePublicKey: devicePublic,
            machineID: machineID,
            deviceID: deviceID,
            version: version
        )
        let nonceData = nonce ?? randomBytes(count: 12)
        let ciphertext = try seal(mirrorKey, symmetricKey: keyEncryptionKey, nonce: nonceData)

        return RemoteKeyEnvelope(
            version: 1,
            keyVersion: version,
            ephemeralPublicKey: ephemeralPublic.base64EncodedString(),
            nonce: nonceData.base64EncodedString(),
            ciphertext: Data(ciphertext.dropFirst(12)).base64EncodedString()
        )
    }

    public static func openEnvelope(
        _ envelope: RemoteKeyEnvelope,
        devicePrivateKey: RemoteDevicePrivateKey,
        machineID: String,
        deviceID: String
    ) throws -> Data {
        guard envelope.version == 1 else { throw RemoteCryptoError.unsupportedEnvelope }
        guard
            envelope.keyVersion >= 1,
            let ephemeralPublicData = Data(base64Encoded: envelope.ephemeralPublicKey),
            let nonce = Data(base64Encoded: envelope.nonce),
            let ciphertext = Data(base64Encoded: envelope.ciphertext),
            nonce.count == 12,
            ciphertext.count >= 16
        else {
            throw RemoteCryptoError.invalidEncryptedFormat
        }
        let ephemeralPublicKey = try publicKey(from: envelope.ephemeralPublicKey)
        let devicePublicData = devicePrivateKey.key.publicKey.x963Representation
        let keyEncryptionKey = try envelopeKey(
            privateKey: devicePrivateKey.key,
            otherPublicKey: ephemeralPublicKey,
            ephemeralPublicKey: ephemeralPublicData,
            devicePublicKey: devicePublicData,
            machineID: machineID,
            deviceID: deviceID,
            version: envelope.keyVersion
        )
        let mirrorKey = try open(nonce + ciphertext, symmetricKey: keyEncryptionKey)
        guard mirrorKey.count == 32 else { throw RemoteCryptoError.invalidMirrorKey }
        return mirrorKey
    }

    static func seal(
        _ plaintext: Data,
        key: Data,
        nonce: Data,
        authenticatedData: Data = Data()
    ) throws -> Data {
        try seal(
            plaintext,
            symmetricKey: try symmetricKey(from: key),
            nonce: nonce,
            authenticatedData: authenticatedData
        )
    }

    static func open(
        _ combined: Data,
        key: Data,
        authenticatedData: Data = Data()
    ) throws -> Data {
        try open(combined, symmetricKey: try symmetricKey(from: key), authenticatedData: authenticatedData)
    }

    private static func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw RemoteCryptoError.invalidKeyLength }
        return SymmetricKey(data: data)
    }

    private static func seal(
        _ plaintext: Data,
        symmetricKey: SymmetricKey,
        nonce: Data,
        authenticatedData: Data = Data()
    ) throws -> Data {
        guard nonce.count == 12 else { throw RemoteCryptoError.invalidNonce }
        do {
            let sealed = try AES.GCM.seal(
                plaintext,
                using: symmetricKey,
                nonce: AES.GCM.Nonce(data: nonce),
                authenticating: authenticatedData
            )
            guard let combined = sealed.combined else { throw RemoteCryptoError.authenticationFailed }
            return combined
        } catch let error as RemoteCryptoError {
            throw error
        } catch {
            throw RemoteCryptoError.authenticationFailed
        }
    }

    private static func open(
        _ combined: Data,
        symmetricKey: SymmetricKey,
        authenticatedData: Data = Data()
    ) throws -> Data {
        guard combined.count >= 28 else { throw RemoteCryptoError.invalidEncryptedFormat }
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: combined),
                using: symmetricKey,
                authenticating: authenticatedData
            )
        } catch {
            throw RemoteCryptoError.authenticationFailed
        }
    }

    private static func publicKey(from base64: String) throws -> P256.KeyAgreement.PublicKey {
        guard let data = Data(base64Encoded: base64), data.count == 65, data.first == 0x04 else {
            throw RemoteCryptoError.invalidPublicKey
        }
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: data)
        } catch {
            throw RemoteCryptoError.invalidPublicKey
        }
    }

    private static func envelopeKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        otherPublicKey: P256.KeyAgreement.PublicKey,
        ephemeralPublicKey: Data,
        devicePublicKey: Data,
        machineID: String,
        deviceID: String,
        version: Int
    ) throws -> SymmetricKey {
        do {
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
            return sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: ephemeralPublicKey + devicePublicKey,
                sharedInfo: Data("aim-remote/v1/enveloppe|\(machineID)|\(deviceID)|\(version)".utf8),
                outputByteCount: 32
            )
        } catch {
            throw RemoteCryptoError.authenticationFailed
        }
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
