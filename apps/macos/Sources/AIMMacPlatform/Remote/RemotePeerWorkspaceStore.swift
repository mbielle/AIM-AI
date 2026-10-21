import AIMCore
import CryptoKit
import Darwin
import Foundation

/// Workspace snapshots stay isolated until the origin's existing review/merge.
/// No archive extraction, git hooks, model commands or remote patch evaluation.
public actor RemotePeerWorkspaceStore {
    private let artifacts: RemotePeerArtifactStore
    private let directory: URL
    public init(artifacts: RemotePeerArtifactStore, directory: URL) throws {
        self.artifacts = artifacts; self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw RemotePeerError.invalidConfiguration }
    }
    public func snapshot(root: URL, transferID: UUID, grant: RemotePeerGrant, paths explicit: [String]? = nil) async throws -> RemotePeerArtifactManifest {
        guard root.path == root.resolvingSymlinksInPath().path else { throw RemotePeerError.invalidConfiguration }
        let paths = try explicit ?? enumerate(root: root)
        guard paths.allSatisfy({ !$0.split(separator: "/").contains(".git") }) else { throw RemotePeerError.invalidEnvelope }
        return try await artifacts.prepare(transferID: transferID, grant: grant, root: root, paths: paths)
    }
    private func enumerate(root: URL) throws -> [String] {
            let traversalErrors = WorkspaceTraversalErrors()
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                options: [], errorHandler: { _, _ in traversalErrors.failed = true; return false }) else { throw RemotePeerError.invalidEnvelope }
            var selected: [String] = []
            for case let file as URL in iterator {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                if relative.split(separator: "/").contains(".git") { iterator.skipDescendants(); continue }
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw RemotePeerError.invalidEnvelope }
                if values.isRegularFile == true { selected.append(relative) }
                guard selected.count <= 2048 else { throw RemotePeerError.invalidEnvelope }
            }
            guard !traversalErrors.failed else { throw RemotePeerError.invalidEnvelope }
            return selected.sorted()
    }
    public func materialize(commit: RemotePeerArtifactCommit, grant: RemotePeerGrant) async throws -> URL {
        let source = try await artifacts.commit(commit, grant: grant)
        let manifest = try await artifacts.manifest(transferID: commit.transferID, grant: grant)
        let base = directory.appendingPathComponent(grant.childExecutionID.uuidString.lowercased(), isDirectory: true)
        let receipt = directory.appendingPathComponent(grant.childExecutionID.uuidString.lowercased() + ".json")
        let expected = try RemotePeerCoding.encode(commit)
        if FileManager.default.fileExists(atPath: receipt.path) {
            guard try Data(contentsOf: receipt) == expected, base.path == base.resolvingSymlinksInPath().path else { throw RemotePeerError.conflictingCommand }
            return base
        }
        // An existing unreceipted workspace is never erased/rebuilt automatically.
        guard !FileManager.default.fileExists(atPath: base.path) else { throw RemotePeerError.outcomeUnknown }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sourceFD = try openRoot(source); defer { close(sourceFD) }
        let destinationFD = try openRoot(base); defer { close(destinationFD) }
        for file in manifest.files { try replace(file, sourceFD: sourceFD, destinationFD: destinationFD, existing: nil) }
        try expected.write(to: receipt, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return base
    }
    /// Final snapshot replaces only files in the disposable origin worktree.
    /// Every path must still match the captured baseline or the exact final file.
    /// Repeating a partially applied snapshot converges to the same bytes.
    public func synchronize(baseline: RemotePeerArtifactManifest, final: RemotePeerArtifactManifest,
        finalDirectory: URL, destination: URL, grant: RemotePeerGrant) throws {
        try baseline.validate(grant: grant); try final.validate(grant: grant)
        guard !final.files.contains(where: { $0.path.split(separator: "/").contains(".git") }) else { throw RemotePeerError.invalidEnvelope }
        let sourceFD = try openRoot(finalDirectory); defer { close(sourceFD) }
        let destinationFD = try openRoot(destination); defer { close(destinationFD) }
        let before = Dictionary(uniqueKeysWithValues: baseline.files.map { ($0.path, $0) })
        let after = Dictionary(uniqueKeysWithValues: final.files.map { ($0.path, $0) })
        // Verify all target preconditions before applying any file.
        for path in Set(before.keys).union(after.keys) {
            let current = try currentHash(path, rootFD: destinationFD)
            guard current == before[path]?.sha256 || current == after[path]?.sha256 else { throw RemotePeerError.conflictingCommand }
        }
        for file in final.files { try replace(file, sourceFD: sourceFD, destinationFD: destinationFD, existing: before[file.path]?.sha256) }
        for file in baseline.files where after[file.path] == nil {
            guard let current = try currentHash(file.path, rootFD: destinationFD) else { continue }
            guard current == file.sha256 else { throw RemotePeerError.conflictingCommand }
            let (parent, name) = try parentFD(file.path, rootFD: destinationFD, create: false); defer { close(parent) }
            guard unlinkat(parent, name, 0) == 0, fsync(parent) == 0 else { throw RemotePeerError.invalidEnvelope }
        }
    }
    private func openRoot(_ url: URL) throws -> Int32 {
        guard url.path == url.resolvingSymlinksInPath().path else { throw RemotePeerError.invalidEnvelope }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RemotePeerError.invalidEnvelope }; return fd
    }
    private func parentFD(_ path: String, rootFD: Int32, create: Bool) throws -> (Int32, String) {
        try RemotePeerArtifactManifest.validatePath(path)
        let parts = path.split(separator: "/").map(String.init)
        var parent = dup(rootFD); guard parent >= 0 else { throw RemotePeerError.invalidEnvelope }
        do {
            for part in parts.dropLast() {
                if create, mkdirat(parent, part, 0o700) != 0, errno != EEXIST { throw RemotePeerError.invalidEnvelope }
                let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw RemotePeerError.invalidEnvelope }; close(parent); parent = next
            }
            return (parent, parts.last!)
        } catch { close(parent); throw error }
    }
    private func currentHash(_ path: String, rootFD: Int32) throws -> String? {
        let parent: Int32; let name: String
        do { (parent, name) = try parentFD(path, rootFD: rootFD, create: false) }
        catch { if errno == ENOENT { return nil }; throw error }
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw RemotePeerError.invalidEnvelope }; defer { close(fd) }
        return try hash(fd)
    }
    private func hash(_ fd: Int32) throws -> String {
        var metadata = stat(); guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                                      metadata.st_nlink == 1, metadata.st_size <= 128 * 1024 * 1024 else { throw RemotePeerError.invalidEnvelope }
        var hasher = SHA256(); var total = 0; var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            guard n >= 0 else { throw RemotePeerError.invalidEnvelope }; if n == 0 { break }
            hasher.update(data: Data(buffer.prefix(n))); total += n; guard total <= 128 * 1024 * 1024 else { throw RemotePeerError.invalidEnvelope }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func replace(_ file: RemotePeerArtifactFile, sourceFD: Int32, destinationFD: Int32, existing: String?) throws {
        let current = try currentHash(file.path, rootFD: destinationFD)
        if current == file.sha256 { return }
        guard current == existing else { throw RemotePeerError.conflictingCommand }
        let (sourceParent, sourceName) = try parentFD(file.path, rootFD: sourceFD, create: false); defer { close(sourceParent) }
        let source = openat(sourceParent, sourceName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(source) }
        guard try hash(source) == file.sha256, lseek(source, 0, SEEK_SET) == 0 else { throw RemotePeerError.invalidEnvelope }
        let (parent, name) = try parentFD(file.path, rootFD: destinationFD, create: true); defer { close(parent) }
        var mode: mode_t = 0o600
        if existing != nil {
            var metadata = stat()
            guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw RemotePeerError.conflictingCommand }
            mode = metadata.st_mode & 0o777 // Preserve origin permissions; remote snapshots cannot chmod.
        }
        let temporary = ".aim-peer-writing-" + UUID().uuidString
        let destination = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw RemotePeerError.invalidEnvelope }; defer { close(destination); _ = unlinkat(parent, temporary, 0) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress!, $0.count) }
            guard n >= 0 else { throw RemotePeerError.invalidEnvelope }; if n == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                var written = 0
                while written < n { let count = Darwin.write(destination, bytes.baseAddress!.advanced(by: written), n - written)
                    guard count > 0 else { throw RemotePeerError.invalidEnvelope }; written += count }
            }
        }
        guard fchmod(destination, mode) == 0, fsync(destination) == 0, lseek(destination, 0, SEEK_SET) == 0, try hash(destination) == file.sha256,
              try currentHash(file.path, rootFD: destinationFD) == existing,
              renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else { throw RemotePeerError.conflictingCommand }
    }
}

private final class WorkspaceTraversalErrors: @unchecked Sendable { var failed = false }
