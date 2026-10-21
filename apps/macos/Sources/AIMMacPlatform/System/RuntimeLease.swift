import Darwin
import Foundation

public enum RuntimeLeaseError: Error, Equatable { case alreadyOwned, unsafeFile, unavailable }

/// Kernel-owned lease: automatically released on crash, inherited by no child.
public final class RuntimeLease: @unchecked Sendable {
    public let generation = UUID()
    private let lock = NSLock()
    private var descriptor: Int32

    public init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RuntimeLeaseError.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor); throw RuntimeLeaseError.unsafeFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); throw RuntimeLeaseError.alreadyOwned
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor); throw RuntimeLeaseError.unavailable
        }
    }
    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor); descriptor = -1
        }
    }
    deinit { release() }
}
