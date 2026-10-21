import CryptoKit
import Darwin
import Foundation

public enum ExecutionArtifactError: Error { case unsafePath, invalidReference, corrupt, unavailable }

/// Content-addressed private data. SQLite carries references, never duplicated screenshot blobs.
public struct ExecutionArtifactStore: Sendable {
    private let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else {
            throw ExecutionArtifactError.unsafePath
        }
        guard chmod(directory.path, 0o700) == 0 else { throw ExecutionArtifactError.unavailable }
    }
    public func put(_ data: Data) throws -> String {
        let reference = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = directory.appending(path: reference)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(reference) == data else { throw ExecutionArtifactError.corrupt }
            return reference
        }
        let temporary = directory.appending(path: ".pending-\(UUID())")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ExecutionArtifactError.unavailable }
        var committed = false
        defer { Darwin.close(fd); if !committed { try? FileManager.default.removeItem(at: temporary) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ExecutionArtifactError.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ExecutionArtifactError.unavailable }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw ExecutionArtifactError.unavailable }
        let dirFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard dirFD >= 0 else { throw ExecutionArtifactError.unavailable }
        defer { Darwin.close(dirFD) }
        guard fsync(dirFD) == 0 else { throw ExecutionArtifactError.unavailable }
        committed = true
        return reference
    }
    public func read(_ reference: String) throws -> Data {
        guard reference.count == 64, reference.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ExecutionArtifactError.invalidReference
        }
        let fd = Darwin.open(directory.appending(path: reference).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ExecutionArtifactError.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= 128 * 1024 * 1024 else {
            throw ExecutionArtifactError.unsafePath
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ExecutionArtifactError.unavailable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 128 * 1024 * 1024 else { throw ExecutionArtifactError.corrupt }
        }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == reference else {
            throw ExecutionArtifactError.corrupt
        }
        return data
    }
}

struct StoredExecutionCheckpoint: Codable {
    var storageVersion = 1
    var checkpoint: ExecutionCheckpoint
    var transcript: String
    var images: [String: String]
    var toolState: [String: String]?
}
