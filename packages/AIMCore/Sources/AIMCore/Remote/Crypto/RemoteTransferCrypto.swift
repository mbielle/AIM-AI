import CryptoKit
import Foundation

public enum RemoteTransferError: Error, Equatable, Sendable {
    case invalidManifest
    case unreadableManifest
    case unreadableBlock
    case incompleteTransfer
    case invalidSize
    case invalidDigest
    case expiredTransfer
    case invalidBlock
}

public enum RemoteTransferKind: String, Codable, Sendable {
    case detail
    case attachment
}

public struct RemoteTransferManifest: Codable, Equatable, Sendable {
    public let transferID: String
    public let kind: RemoteTransferKind
    public let machineID: String
    public let sessionID: String
    public let messageID: String?
    public let segmentID: String?
    public let filename: String?
    public let mimeType: String
    public let expiresAt: String
    public let truncated: Bool?
    public let originalSize: Int?
    public let version: Int
    public let keyVersion: Int
    public let clearSize: Int
    public let chunkSize: Int
    public let chunkCount: Int
    public let sha256: String
    public let chunkHashes: [String]

    public init(
        transferID: String,
        kind: RemoteTransferKind,
        machineID: String,
        sessionID: String,
        messageID: String? = nil,
        segmentID: String? = nil,
        filename: String? = nil,
        mimeType: String,
        expiresAt: String,
        truncated: Bool? = nil,
        originalSize: Int? = nil,
        version: Int,
        keyVersion: Int,
        clearSize: Int,
        chunkSize: Int,
        chunkCount: Int,
        sha256: String,
        chunkHashes: [String]
    ) {
        self.transferID = transferID
        self.kind = kind
        self.machineID = machineID
        self.sessionID = sessionID
        self.messageID = messageID
        self.segmentID = segmentID
        self.filename = filename
        self.mimeType = mimeType
        self.expiresAt = expiresAt
        self.truncated = truncated
        self.originalSize = originalSize
        self.version = version
        self.keyVersion = keyVersion
        self.clearSize = clearSize
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
        self.sha256 = sha256
        self.chunkHashes = chunkHashes
    }

    private enum CodingKeys: String, CodingKey {
        case transferID = "transferId"
        case kind
        case machineID = "machineId"
        case sessionID = "sessionId"
        case messageID = "messageId"
        case segmentID = "segmentId"
        case filename
        case mimeType = "mime"
        case expiresAt
        case truncated
        case originalSize
        case version = "v"
        case keyVersion
        case clearSize
        case chunkSize
        case chunkCount
        case sha256
        case chunkHashes
    }

    public func canonicalJSONData() -> Data {
        var fields = [
            "\"transferId\":\(Self.quote(transferID))",
            "\"kind\":\(Self.quote(kind.rawValue))",
            "\"machineId\":\(Self.quote(machineID))",
            "\"sessionId\":\(Self.quote(sessionID))",
        ]
        if let messageID { fields.append("\"messageId\":\(Self.quote(messageID))") }
        if let segmentID { fields.append("\"segmentId\":\(Self.quote(segmentID))") }
        if let filename { fields.append("\"filename\":\(Self.quote(filename))") }
        fields.append("\"mime\":\(Self.quote(mimeType))")
        fields.append("\"expiresAt\":\(Self.quote(expiresAt))")
        if let truncated { fields.append("\"truncated\":\(truncated ? "true" : "false")") }
        if let originalSize { fields.append("\"originalSize\":\(originalSize)") }
        fields.append(contentsOf: [
            "\"v\":\(version)",
            "\"keyVersion\":\(keyVersion)",
            "\"clearSize\":\(clearSize)",
            "\"chunkSize\":\(chunkSize)",
            "\"chunkCount\":\(chunkCount)",
            "\"sha256\":\(Self.quote(sha256))",
            "\"chunkHashes\":[\(chunkHashes.map(Self.quote).joined(separator: ","))]",
        ])
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}

public struct RemoteTransferBlock: Equatable, Sendable {
    public let index: Int
    public let encrypted: Data

    public init(index: Int, encrypted: Data) {
        self.index = index
        self.encrypted = encrypted
    }
}

public struct RemoteEncryptedTransfer: Equatable, Sendable {
    public let manifest: RemoteTransferManifest
    public let blocks: [RemoteTransferBlock]

    public init(manifest: RemoteTransferManifest, blocks: [RemoteTransferBlock]) {
        self.manifest = manifest
        self.blocks = blocks
    }
}

public enum RemoteTransferCrypto {
    public static let chunkSize = 1_048_576
    public static let maximumChunkCount = 256

    /// Desktop history/diff/detail payloads use the same authenticated blocks.
    public static func prepareDetail(data: Data, key: Data, keyVersion: Int, transferID: String,
        machineID: String, sessionID: String, now: Date = Date()) throws -> RemoteEncryptedTransfer {
        let prepared = try prepareAttachment(data: data, key: key, keyVersion: keyVersion, transferID: transferID,
            machineID: machineID, sessionID: sessionID, filename: "result.json", mimeType: "application/json", now: now)
        let source = prepared.manifest
        let manifest = RemoteTransferManifest(transferID: source.transferID, kind: .detail,
            machineID: source.machineID, sessionID: source.sessionID, mimeType: source.mimeType,
            expiresAt: source.expiresAt, version: source.version, keyVersion: source.keyVersion,
            clearSize: source.clearSize, chunkSize: source.chunkSize, chunkCount: source.chunkCount,
            sha256: source.sha256, chunkHashes: source.chunkHashes)
        return RemoteEncryptedTransfer(manifest: manifest, blocks: prepared.blocks)
    }

    public static func prepareAttachment(
        data: Data,
        key: Data,
        keyVersion: Int,
        transferID: String,
        machineID: String,
        sessionID: String,
        filename: String,
        mimeType: String,
        now: Date = Date()
    ) throws -> RemoteEncryptedTransfer {
        guard
            !transferID.isEmpty,
            !machineID.isEmpty,
            !sessionID.isEmpty,
            !mimeType.isEmpty,
            keyVersion >= 1
        else { throw RemoteTransferError.invalidManifest }

        let count = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
        guard count <= maximumChunkCount else { throw RemoteTransferError.invalidSize }
        var blocks: [RemoteTransferBlock] = []
        blocks.reserveCapacity(count)
        for index in 0..<count {
            let lower = index * chunkSize
            let upper = min(data.count, lower + chunkSize)
            let clear = data.subdata(in: lower..<upper)
            blocks.append(
                .init(
                    index: index,
                    encrypted: try encryptBlock(
                        clear,
                        key: key,
                        transferID: transferID,
                        index: index,
                        total: count
                    )
                )
            )
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let manifest = RemoteTransferManifest(
            transferID: transferID,
            kind: .attachment,
            machineID: machineID,
            sessionID: sessionID,
            filename: filename,
            mimeType: mimeType,
            expiresAt: formatter.string(from: now.addingTimeInterval(24 * 60 * 60)),
            version: 1,
            keyVersion: keyVersion,
            clearSize: data.count,
            chunkSize: chunkSize,
            chunkCount: count,
            sha256: digest(data),
            chunkHashes: blocks.map { digest($0.encrypted) }
        )
        try validate(manifest)
        return .init(manifest: manifest, blocks: blocks)
    }

    public static func encryptBlock(
        _ plaintext: Data,
        key: Data,
        transferID: String,
        index: Int,
        total: Int,
        nonce: Data? = nil
    ) throws -> Data {
        guard !transferID.isEmpty, index >= 0, total > 0, index < total else {
            throw RemoteTransferError.invalidBlock
        }
        return try RemoteCrypto.seal(
            plaintext,
            key: key,
            nonce: nonce ?? randomBytes(count: 12),
            authenticatedData: associatedData(transferID: transferID, index: index, total: total)
        )
    }

    public static func decryptBlock(
        _ encrypted: Data,
        key: Data,
        transferID: String,
        index: Int,
        total: Int
    ) throws -> Data {
        guard !transferID.isEmpty, index >= 0, total > 0, index < total, encrypted.count >= 28 else {
            throw RemoteTransferError.unreadableBlock
        }
        do {
            return try RemoteCrypto.open(
                encrypted,
                key: key,
                authenticatedData: associatedData(transferID: transferID, index: index, total: total)
            )
        } catch {
            throw RemoteTransferError.unreadableBlock
        }
    }

    public static func sealManifest(
        _ manifest: RemoteTransferManifest,
        key: Data,
        nonce: Data? = nil
    ) throws -> String {
        try validate(manifest)
        guard let json = String(data: manifest.canonicalJSONData(), encoding: .utf8) else {
            throw RemoteTransferError.invalidManifest
        }
        return try RemoteCrypto.encryptField(
            json,
            key: key,
            version: manifest.keyVersion,
            context: manifestContext(transferID: manifest.transferID),
            nonce: nonce
        )
    }

    public static func openManifest(
        _ encrypted: String,
        transferID: String,
        keys: [Int: Data]
    ) throws -> RemoteTransferManifest {
        do {
            let json = try RemoteCrypto.decryptField(
                encrypted,
                keys: keys,
                context: manifestContext(transferID: transferID)
            )
            let manifest = try JSONDecoder().decode(RemoteTransferManifest.self, from: Data(json.utf8))
            try validate(manifest, expectedTransferID: transferID)
            return manifest
        } catch let error as RemoteTransferError {
            throw error
        } catch {
            throw RemoteTransferError.unreadableManifest
        }
    }

    public static func assemble(
        manifest: RemoteTransferManifest,
        blocks: [RemoteTransferBlock],
        key: Data,
        now: Date = Date()
    ) throws -> Data {
        try validate(manifest)
        guard let expiration = parseDate(manifest.expiresAt), now < expiration else {
            throw RemoteTransferError.expiredTransfer
        }
        var byIndex: [Int: Data] = [:]
        for block in blocks {
            guard
                block.index >= 0,
                block.index < manifest.chunkCount,
                byIndex[block.index] == nil
            else {
                throw RemoteTransferError.incompleteTransfer
            }
            byIndex[block.index] = block.encrypted
        }
        guard byIndex.count == manifest.chunkCount else {
            throw RemoteTransferError.incompleteTransfer
        }

        var plaintext = Data()
        for index in 0..<manifest.chunkCount {
            guard let encrypted = byIndex[index] else { throw RemoteTransferError.incompleteTransfer }
            guard digest(encrypted) == manifest.chunkHashes[index] else {
                throw RemoteTransferError.unreadableBlock
            }
            let clear = try decryptBlock(
                encrypted,
                key: key,
                transferID: manifest.transferID,
                index: index,
                total: manifest.chunkCount
            )
            let expectedSize = index == manifest.chunkCount - 1
                ? manifest.clearSize - index * manifest.chunkSize
                : manifest.chunkSize
            guard clear.count == expectedSize else { throw RemoteTransferError.invalidSize }
            plaintext.append(clear)
        }
        guard plaintext.count == manifest.clearSize else { throw RemoteTransferError.invalidSize }
        guard digest(plaintext) == manifest.sha256 else { throw RemoteTransferError.invalidDigest }
        return plaintext
    }

    public static func missingBlocks(total: Int, present: [Int]) -> [Int] {
        guard total > 0 else { return [] }
        let valid = Set(present.filter { $0 >= 0 && $0 < total })
        return (0..<total).filter { !valid.contains($0) }
    }

    public static func storagePath(
        userID: String,
        manifest: RemoteTransferManifest,
        index: Int
    ) throws -> String {
        guard !userID.isEmpty, index >= 0, index < manifest.chunkCount else {
            throw RemoteTransferError.invalidBlock
        }
        return "\(userID)/\(manifest.machineID)/\(manifest.transferID)/\(String(format: "%06d", index)).bin"
    }

    private static func validate(
        _ manifest: RemoteTransferManifest,
        expectedTransferID: String? = nil
    ) throws {
        guard
            manifest.version == 1,
            !manifest.transferID.isEmpty,
            expectedTransferID == nil || manifest.transferID == expectedTransferID,
            !manifest.machineID.isEmpty,
            !manifest.sessionID.isEmpty,
            !manifest.mimeType.isEmpty,
            manifest.keyVersion >= 1,
            manifest.clearSize >= 0,
            manifest.chunkSize >= 1,
            manifest.chunkCount >= 1,
            manifest.chunkCount <= maximumChunkCount,
            manifest.chunkHashes.count == manifest.chunkCount,
            !manifest.sha256.isEmpty,
            parseDate(manifest.expiresAt) != nil,
            manifest.truncated != true || (manifest.originalSize ?? -1) >= manifest.clearSize
        else {
            throw RemoteTransferError.invalidManifest
        }
    }

    private static func associatedData(transferID: String, index: Int, total: Int) -> Data {
        Data("aim-remote/v1|remote_transfers.block|\(transferID)|\(index)|\(total)".utf8)
    }

    private static func manifestContext(transferID: String) -> RemoteFieldContext {
        RemoteFieldContext(table: "remote_transfers", column: "manifest", rowID: transferID)
    }

    private static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
