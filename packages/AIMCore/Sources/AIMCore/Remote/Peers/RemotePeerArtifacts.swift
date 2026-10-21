import CryptoKit
import Foundation

public struct RemotePeerArtifactFile: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String
    public let chunks: [String]
    public init(path: String, size: Int64, sha256: String, chunks: [String]) {
        self.path = path; self.size = size; self.sha256 = sha256; self.chunks = chunks
    }
}
public struct RemotePeerArtifactManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let transferID: UUID
    public let grantID: UUID
    public let childExecutionID: UUID
    public let files: [RemotePeerArtifactFile]
    public init(transferID: UUID, grantID: UUID, childExecutionID: UUID, files: [RemotePeerArtifactFile]) {
        version = 1; self.transferID = transferID; self.grantID = grantID; self.childExecutionID = childExecutionID; self.files = files
    }
    public func validate(grant: RemotePeerGrant) throws {
        guard version == 1, grantID == grant.id, childExecutionID == grant.childExecutionID,
              files.count <= 2048, Set(files.map(\.path)).count == files.count else { throw RemotePeerError.invalidEnvelope }
        var total: Int64 = 0
        for file in files {
            try Self.validatePath(file.path)
            guard file.size >= 0, file.size <= 128 * 1024 * 1024, Self.validHash(file.sha256),
                  file.chunks.count == Int((file.size + 65535) / 65536), file.chunks.allSatisfy(Self.validHash) else {
                throw RemotePeerError.invalidEnvelope
            }
            total += file.size; guard total <= 512 * 1024 * 1024 else { throw RemotePeerError.invalidEnvelope }
        }
        // A file cannot also be the parent directory of another file.
        let paths = Set(files.map(\.path))
        for path in paths {
            var parts = path.split(separator: "/"); parts.removeLast()
            while !parts.isEmpty {
                guard !paths.contains(parts.joined(separator: "/")) else { throw RemotePeerError.invalidEnvelope }; parts.removeLast()
            }
        }
    }
    public static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw RemotePeerError.invalidEnvelope
        }
    }
    public static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
public struct RemotePeerArtifactChunk: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let fileIndex: Int
    public let chunkIndex: Int
    public let data: Data
    public init(transferID: UUID, fileIndex: Int, chunkIndex: Int, data: Data) {
        self.transferID = transferID; self.fileIndex = fileIndex; self.chunkIndex = chunkIndex; self.data = data
    }
}
public struct RemotePeerArtifactCommit: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let manifestSHA256: String
    public init(transferID: UUID, manifestSHA256: String) { self.transferID = transferID; self.manifestSHA256 = manifestSHA256 }
}

public enum RemotePeerCommandIdentity {
    public static func derive(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
