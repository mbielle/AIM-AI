import AIMCore
import AIMMacPlatform
import Darwin
import Foundation

/// UI and helper must hold the same process-independent lock before the first
/// secure-store read. Never replace an unreadable profile or treat it as auth.
package enum MacLocalProfileStore {
    private static let processLock = NSLock()

    package static func loadOrCreate(store: any SecureStoring, lockURL: URL? = nil) throws -> LocalProfile {
        try processLock.withLock {
            let url = try lockURL ?? ApplicationPaths().applicationSupport.appending(path: "local-profile.lock")
            let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw RuntimeLeaseError.unavailable }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & S_IFMT == S_IFREG else { throw RuntimeLeaseError.unsafeFile }
            guard flock(fd, LOCK_EX) == 0 else { throw RuntimeLeaseError.unavailable }
            defer { flock(fd, LOCK_UN) }
            guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { throw RuntimeLeaseError.unavailable }
            return try LocalProfile.loadOrCreate(store: store)
        }
    }
}
