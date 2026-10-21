import CryptoKit
import Darwin
import Foundation

struct MissionFileInspection: Sendable {
    let sha256: String
    let byteCount: Int64
    let observedAt: Date
}

/// Opens every component relative to the workspace with O_NOFOLLOW. The
/// returned digest describes the bytes actually read from one regular file,
/// rather than trusting a path supplied by the model or an earlier tool result.
enum MissionFileInspector {
    static func inspect(workspacePath: String, check: MissionFileCheck) throws -> MissionFileInspection {
        guard check.isValid, workspacePath.hasPrefix("/"), !workspacePath.contains("\0") else {
            throw AgentMissionError.invalidInput
        }
        let root = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().standardizedFileURL
        guard root.path == workspacePath else { throw AgentMissionError.invalidInput }
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentMissionError.criterionNotMet }
        defer { Darwin.close(descriptor) }
        let components = check.relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC |
                (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = Darwin.openat(descriptor, component, flags)
            guard next >= 0 else { throw AgentMissionError.criterionNotMet }
            Darwin.close(descriptor)
            descriptor = next
        }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw AgentMissionError.criterionNotMet
        }
        let needle = check.requiredText.map { Data($0.utf8) }
        var found = needle == nil
        var trailing = Data()
        var hasher = SHA256()
        var count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let amount = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if amount < 0 && errno == EINTR { continue }
            guard amount >= 0 else { throw AgentMissionError.criterionNotMet }
            if amount == 0 { break }
            let chunk = Data(buffer.prefix(amount))
            hasher.update(data: chunk)
            let (next, overflow) = count.addingReportingOverflow(Int64(amount))
            guard !overflow else { throw AgentMissionError.invalidInput }
            count = next
            if let needle, !found {
                let combined = trailing + chunk
                found = combined.range(of: needle) != nil
                trailing = Data(combined.suffix(max(0, needle.count - 1)))
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              count == after.st_size, found else { throw AgentMissionError.criterionNotMet }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return MissionFileInspection(sha256: digest, byteCount: count, observedAt: .now)
    }
}
