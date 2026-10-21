import AIMCore
import AIMMacPlatform
import CryptoKit
import Foundation

/// Private, bounded staging for data received inside an authenticated direct
/// session. Filenames never determine paths; manifests bind every byte to a
/// device grant and conversation. Nothing is imported until send is accepted.
actor DirectRemoteAttachmentVault {
    private struct Manifest: Codable, Equatable {
        let id: UUID, pairID: UUID, sessionID: UUID
        let name: String, mime: String, digest: String
        let size: Int, created: Date
        var ready: Bool
    }
    private let root: URL
    init(directory: URL) throws {
        guard directory.isFileURL else { throw DirectRemoteError.invalidConfiguration }
        root = directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DirectRemoteError.invalidConfiguration }
    }
    private func file(_ id: UUID, _ suffix: String) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + suffix) }
    private func requireRegular(_ url: URL) throws {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true,
              (value.fileSize ?? Int.max) <= 20 * 1024 * 1024 else { throw DirectRemoteError.invalidPacket }
    }
    private func load(_ id: UUID) throws -> Manifest {
        let url = file(id, ".json"); try requireRegular(url)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 4096 else { throw DirectRemoteError.invalidPacket }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    private func save(_ value: Manifest) throws {
        let url = file(value.id, ".json")
        guard !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false) else { throw DirectRemoteError.invalidPacket }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func purgeExpired(now: Date = .now) throws -> [Manifest] {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard entries.count <= 128 else { throw DirectRemoteError.unavailable("transfer_storage_full") }
        var live: [Manifest] = []
        for url in entries where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let item = try load(id)
            if now.timeIntervalSince(item.created) >= 3600 { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: file(id, ".bin")) }
            else { live.append(item) }
        }
        return live
    }
    func upload(_ object: [String: RemoteJSONValue], pairID: UUID, sessionID: UUID) throws -> RemoteJSONValue {
        guard let id = object["transfer_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let phase = object["phase"]?.stringValue else { throw DirectRemoteError.invalidPacket }
        let existing = try purgeExpired()
        if phase == "begin" {
            guard let name = object["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 512,
                  let mime = object["mime"]?.stringValue, !mime.isEmpty, mime.utf8.count <= 256,
                  let number = object["size"]?.numberValue, number.isFinite, number.rounded() == number,
                  (1...Double(20 * 1024 * 1024)).contains(number),
                  let digest = object["sha256"]?.stringValue, digest.count == 64,
                  digest.allSatisfy({ $0.isASCII && ($0.isHexDigit && !$0.isUppercase) }) else { throw DirectRemoteError.invalidPacket }
            let item = Manifest(id: id, pairID: pairID, sessionID: sessionID, name: RemoteHostAttachments.safeName(name),
                mime: mime, digest: digest, size: Int(number), created: .now, ready: false)
            if let old = existing.first(where: { $0.id == id }) {
                guard old.pairID == pairID, old.sessionID == sessionID, old.size == item.size,
                      old.name == item.name, old.mime == item.mime, old.digest == item.digest else { throw DirectRemoteError.unauthorized }
                return .object(["accepted": .bool(true)])
            }
            guard existing.count < 16, existing.reduce(0, { $0 + $1.size }) + item.size <= 40 * 1024 * 1024,
                  !FileManager.default.fileExists(atPath: file(id, ".bin").path) else { throw DirectRemoteError.unavailable("transfer_storage_full") }
            try Data().write(to: file(id, ".bin"), options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id, ".bin").path)
            try save(item); return .object(["accepted": .bool(true)])
        }
        var item = try load(id)
        guard item.pairID == pairID, item.sessionID == sessionID else { throw DirectRemoteError.unauthorized }
        let url = file(id, ".bin"); try requireRegular(url)
        if phase == "chunk" {
            guard !item.ready, let number = object["offset"]?.numberValue, number.isFinite,
                  number.rounded() == number, number >= 0, number <= Double(item.size),
                  let encoded = object["data"]?.stringValue, encoded.utf8.count <= 349_528,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 256 * 1024,
                  Int(number) + bytes.count <= item.size else { throw DirectRemoteError.invalidPacket }
            let offset = Int(number), length = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if offset < length {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                guard try handle.read(upToCount: bytes.count) == bytes else { throw DirectRemoteError.conflictingCommand }
            } else {
                guard offset == length else { throw DirectRemoteError.invalidPacket }
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: bytes); try handle.synchronize()
            }
            return .object(["accepted": .bool(true)])
        }
        guard phase == "finish" else { throw DirectRemoteError.invalidPacket }
        let bytes = try Data(contentsOf: url)
        guard bytes.count == item.size, Self.digest(bytes) == item.digest else { throw DirectRemoteError.invalidPacket }
        item.ready = true; try save(item); return .object(["ready": .bool(true)])
    }
    func attachments(_ references: RemoteJSONValue?, pairID: UUID, sessionID: UUID) throws -> [RemoteHostAttachment] {
        guard let references else { return [] }
        guard let values = references.arrayValue, values.count <= 4 else { throw DirectRemoteError.invalidPacket }
        var seen = Set<UUID>()
        return try values.map { value in
            guard let id = value.objectValue?["transfer_id"]?.stringValue.flatMap(UUID.init(uuidString:)), seen.insert(id).inserted else { throw DirectRemoteError.invalidPacket }
            let item = try load(id)
            guard item.ready, item.pairID == pairID, item.sessionID == sessionID,
                  Date().timeIntervalSince(item.created) < 3600 else { throw DirectRemoteError.unauthorized }
            let url = file(id, ".bin"); try requireRegular(url); let bytes = try Data(contentsOf: url)
            guard bytes.count == item.size, Self.digest(bytes) == item.digest else { throw DirectRemoteError.invalidPacket }
            return .init(name: item.name, mimeType: item.mime, data: bytes)
        }
    }
    func revoke(pairID: UUID) {
        guard let entries = try? purgeExpired() else { return }
        for entry in entries where entry.pairID == pairID {
            try? FileManager.default.removeItem(at: file(entry.id, ".json")); try? FileManager.default.removeItem(at: file(entry.id, ".bin"))
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
