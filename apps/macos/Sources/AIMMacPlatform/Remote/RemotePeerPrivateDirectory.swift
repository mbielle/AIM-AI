import AIMCore
import Darwin
import Foundation

/// Idempotent private child creation, with native no-follow checks even when
/// mkdir reports EEXIST. An existing file or symlink is never treated as a directory.
public enum RemotePeerPrivateDirectory {
    public static func ensureChild(parent: URL, name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw RemotePeerError.invalidConfiguration
        }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw RemotePeerError.invalidConfiguration }
        defer { close(parentFD) }
        try verify(parentFD)
        if mkdirat(parentFD, name, mode_t(0o700)) != 0, errno != EEXIST { throw RemotePeerError.invalidConfiguration }
        let childFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard childFD >= 0 else { throw RemotePeerError.invalidConfiguration }
        defer { close(childFD) }
        try verify(childFD)
        return parent.appendingPathComponent(name, isDirectory: true)
    }
    private static func verify(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw RemotePeerError.invalidConfiguration }
    }
}
