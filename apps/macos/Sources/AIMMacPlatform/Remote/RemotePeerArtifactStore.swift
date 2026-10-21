import AIMCore
import CryptoKit
import Darwin
import Foundation

/// Transfers publish into a new private directory only, never overwrite a live
/// workspace. Applying a writer's patch is a separate origin review operation.
public actor RemotePeerArtifactStore {
    private let directory: URL
    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else {
            throw RemotePeerError.invalidConfiguration
        }
    }
    public func receive(manifest: RemotePeerArtifactManifest, grant: RemotePeerGrant) throws {
        try manifest.validate(grant: grant)
        let base = try transferDirectory(manifest.transferID)
        let url = base.appendingPathComponent("manifest.json")
        let bytes = try RemotePeerCoding.encode(manifest)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(url) == bytes else { throw RemotePeerError.conflictingCommand }; return
        }
        try write(bytes, url: url)
    }
    public func receive(chunk: RemotePeerArtifactChunk, grant: RemotePeerGrant) throws {
        let base = try transferDirectory(chunk.transferID)
        let manifest = try RemotePeerCoding.decode(RemotePeerArtifactManifest.self, read(base.appendingPathComponent("manifest.json")))
        try manifest.validate(grant: grant)
        guard manifest.files.indices.contains(chunk.fileIndex), manifest.files[chunk.fileIndex].chunks.indices.contains(chunk.chunkIndex) else {
            throw RemotePeerError.invalidEnvelope
        }
        let file = manifest.files[chunk.fileIndex]
        let expected = min(Int64(65536), file.size - Int64(chunk.chunkIndex) * 65536)
        guard Int64(chunk.data.count) == expected, RemotePeerArtifactManifest.hash(chunk.data) == file.chunks[chunk.chunkIndex] else {
            throw RemotePeerError.invalidEnvelope
        }
        let url = base.appendingPathComponent("block-\(chunk.fileIndex)-\(chunk.chunkIndex)")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(url) == chunk.data else { throw RemotePeerError.conflictingCommand }; return
        }
        try write(chunk.data, url: url)
    }
    public func commit(_ commit: RemotePeerArtifactCommit, grant: RemotePeerGrant) throws -> URL {
        let base = try transferDirectory(commit.transferID)
        let manifestData = try read(base.appendingPathComponent("manifest.json"))
        let manifest = try RemotePeerCoding.decode(RemotePeerArtifactManifest.self, manifestData)
        try manifest.validate(grant: grant)
        guard RemotePeerArtifactManifest.hash(manifestData) == commit.manifestSHA256 else { throw RemotePeerError.invalidEnvelope }
        let complete = base.appendingPathComponent("complete", isDirectory: true)
        let published = base.appendingPathComponent("published.json")
        if FileManager.default.fileExists(atPath: published.path) {
            guard try read(published) == manifestData else { throw RemotePeerError.conflictingCommand }
            try verifyPublished(manifest, directory: complete); return complete
        }
        // A partial build is recreated from immutable verified blocks. No effects
        // outside this private transfer directory have occurred yet.
        let building = base.appendingPathComponent("building", isDirectory: true)
        if FileManager.default.fileExists(atPath: building.path) {
            guard try building.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw RemotePeerError.invalidEnvelope }
            try FileManager.default.removeItem(at: building)
        }
        try FileManager.default.createDirectory(at: building, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let rootFD = open(building.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(rootFD) }
        for (index, file) in manifest.files.enumerated() {
            var hasher = SHA256(); var total: Int64 = 0
            let fd = try createFile(file.path, rootFD: rootFD); defer { close(fd) }
            for chunkIndex in file.chunks.indices {
                let data = try read(base.appendingPathComponent("block-\(index)-\(chunkIndex)"))
                guard RemotePeerArtifactManifest.hash(data) == file.chunks[chunkIndex] else { throw RemotePeerError.invalidEnvelope }
                hasher.update(data: data); total += Int64(data.count); try writeFD(data, fd: fd)
            }
            guard total == file.size, hasher.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256,
                  fsync(fd) == 0, fchmod(fd, 0o400) == 0 else { throw RemotePeerError.invalidEnvelope }
        }
        if FileManager.default.fileExists(atPath: complete.path) {
            // Crash after publish rename but before receipt: verify exact files.
            try verifyPublished(manifest, directory: complete); try FileManager.default.removeItem(at: building)
        } else { try FileManager.default.moveItem(at: building, to: complete) }
        try write(manifestData, url: published); return complete
    }
    /// Explicit file list only, traversed using openat(O_NOFOLLOW) anchored to the
    /// selected workspace descriptor. No archive/symlink/hardlink imports.
    public func prepare(transferID: UUID, grant: RemotePeerGrant, root: URL, paths: [String]) throws -> RemotePeerArtifactManifest {
        guard paths.count <= 2048, Set(paths).count == paths.count, root.path == root.resolvingSymlinksInPath().path else {
            throw RemotePeerError.invalidEnvelope
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(rootFD) }
        let base = try transferDirectory(transferID)
        var files: [RemotePeerArtifactFile] = []
        var total: Int64 = 0
        for (index, path) in paths.enumerated() {
            try RemotePeerArtifactManifest.validatePath(path)
            let fd = try openFile(path, rootFD: rootFD); defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                                      info.st_size >= 0, info.st_size <= 128 * 1024 * 1024 else { throw RemotePeerError.invalidEnvelope }
            total += info.st_size; guard total <= 512 * 1024 * 1024 else { throw RemotePeerError.invalidEnvelope }
            var hasher = SHA256(); var hashes: [String] = []; var readSize: Int64 = 0
            while readSize < info.st_size {
                var buffer = [UInt8](repeating: 0, count: Int(min(Int64(65536), info.st_size - readSize)))
                var offset = 0
                while offset < buffer.count {
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset),  $0.count - offset) }
                    guard n > 0 else { throw RemotePeerError.invalidEnvelope }; offset += n
                }
                let data = Data(buffer); hasher.update(data: data); hashes.append(RemotePeerArtifactManifest.hash(data))
                try write(data, url: base.appendingPathComponent("block-\(index)-\(hashes.count - 1)")); readSize += Int64(data.count)
            }
            var after = stat(); guard fstat(fd, &after) == 0, after.st_size == info.st_size,
                after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw RemotePeerError.invalidEnvelope
            }
            files.append(.init(path: path, size: info.st_size, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), chunks: hashes))
        }
        let manifest = RemotePeerArtifactManifest(transferID: transferID, grantID: grant.id, childExecutionID: grant.childExecutionID, files: files)
        try receive(manifest: manifest, grant: grant); return manifest
    }
    public func manifest(transferID: UUID, grant: RemotePeerGrant) throws -> RemotePeerArtifactManifest {
        let base = try transferDirectory(transferID)
        let value = try RemotePeerCoding.decode(RemotePeerArtifactManifest.self, read(base.appendingPathComponent("manifest.json")))
        try value.validate(grant: grant); return value
    }
    public func chunk(transferID: UUID, fileIndex: Int, chunkIndex: Int, grant: RemotePeerGrant) throws -> RemotePeerArtifactChunk {
        let base = try transferDirectory(transferID)
        let manifest = try RemotePeerCoding.decode(RemotePeerArtifactManifest.self, read(base.appendingPathComponent("manifest.json")))
        try manifest.validate(grant: grant)
        guard manifest.files.indices.contains(fileIndex), manifest.files[fileIndex].chunks.indices.contains(chunkIndex) else { throw RemotePeerError.invalidEnvelope }
        return .init(transferID: transferID, fileIndex: fileIndex, chunkIndex: chunkIndex,
                     data: try read(base.appendingPathComponent("block-\(fileIndex)-\(chunkIndex)")))
    }
    private func transferDirectory(_ id: UUID) throws -> URL {
        try RemotePeerPrivateDirectory.ensureChild(parent: directory, name: id.uuidString.lowercased())
    }
    private func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                                  info.st_size >= 0, info.st_size <= 262144 else { throw RemotePeerError.invalidEnvelope }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            guard n >= 0 else { throw RemotePeerError.invalidEnvelope }; if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
            guard data.count <= 262144 else { throw RemotePeerError.invalidEnvelope }
        }
        return data
    }
    private func write(_ data: Data, url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(url) == data else { throw RemotePeerError.conflictingCommand }; return
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".writing-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try writeFD(data, fd: fd); guard fsync(fd) == 0 else { throw RemotePeerError.invalidEnvelope }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RemotePeerError.conflictingCommand }
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    private func writeFD(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw RemotePeerError.invalidEnvelope }; offset += n
            }
        }
    }
    private func openFile(_ path: String, rootFD: Int32) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        var parent = dup(rootFD); guard parent >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw RemotePeerError.invalidEnvelope }; close(parent); parent = next
        }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RemotePeerError.invalidEnvelope }; return fd
    }
    private func createFile(_ path: String, rootFD: Int32) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        var parent = dup(rootFD); guard parent >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(parent) }
        for part in parts.dropLast() {
            if mkdirat(parent, part, 0o700) != 0 && errno != EEXIST { throw RemotePeerError.invalidEnvelope }
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw RemotePeerError.invalidEnvelope }; close(parent); parent = next
        }
        let fd = openat(parent, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemotePeerError.invalidEnvelope }; return fd
    }
    private func verifyPublished(_ manifest: RemotePeerArtifactManifest, directory root: URL) throws {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(rootFD) }
        for file in manifest.files {
            let fd = try openFile(file.path, rootFD: rootFD); defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == file.size else { throw RemotePeerError.invalidEnvelope }
            var hasher = SHA256(); var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                guard count >= 0 else { throw RemotePeerError.invalidEnvelope }; if count == 0 { break }
                hasher.update(data: Data(buffer.prefix(count)))
            }
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw RemotePeerError.invalidEnvelope }
        }
    }
}
