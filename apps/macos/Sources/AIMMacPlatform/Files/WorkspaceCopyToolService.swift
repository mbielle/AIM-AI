import AIMAgentKit
import AIMApplication
import Darwin
import Foundation

/// Copies one regular file after the dispatcher approves the exact relative
/// source and destination. Directory traversal is descriptor-relative and
/// refuses symlinks; the destination is created exclusively, never replaced.
public struct WorkspaceCopyToolService: ToolExecutor, MissionIntentProviding {
    public let supportedTools: Set<String> = ["copy_file"]

    public init() {}

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard request.name == "copy_file", let workspace = request.workspacePath,
                  let source = request.arguments["source"],
                  let destination = request.arguments["destination"] else { throw CopyError.invalidPath }
            let sourceParts = try Self.components(source)
            let destinationParts = try Self.components(destination)
            guard sourceParts != destinationParts else { throw CopyError.samePath }
            let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard root.path == workspace else { throw CopyError.invalidWorkspace }
            let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw CopyError.invalidWorkspace }
            defer { Darwin.close(rootFD) }

            let sourceParent = try Self.parentDescriptor(rootFD: rootFD, components: sourceParts)
            defer { Darwin.close(sourceParent) }
            let sourceFD = Darwin.openat(sourceParent, sourceParts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw CopyError.invalidSource }
            defer { Darwin.close(sourceFD) }
            var sourceInfo = stat()
            guard Darwin.fstat(sourceFD, &sourceInfo) == 0,
                  sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw CopyError.invalidSource }

            let destinationParent = try Self.parentDescriptor(rootFD: rootFD, components: destinationParts)
            defer { Darwin.close(destinationParent) }
            try Task.checkCancellation()
            let destinationFD = Darwin.openat(destinationParent, destinationParts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destinationFD >= 0 else {
                if errno == EEXIST { throw CopyError.alreadyExists }
                throw CopyError.cannotCreate
            }
            defer { Darwin.close(destinationFD) }
            var destinationInfo = stat()
            var completed = false
            defer {
                if !completed {
                    var opened = stat()
                    var current = stat()
                    if Darwin.fstat(destinationFD, &opened) == 0,
                       Darwin.fstatat(destinationParent, destinationParts.last!, &current, AT_SYMLINK_NOFOLLOW) == 0,
                       current.st_dev == opened.st_dev, current.st_ino == opened.st_ino {
                        _ = Darwin.unlinkat(destinationParent, destinationParts.last!, 0)
                    }
                }
            }
            guard Darwin.fstat(destinationFD, &destinationInfo) == 0 else { throw CopyError.cannotCreate }

            var total: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CopyError.cannotRead
                }
                if count == 0 { break }
                var offset = 0
                while offset < count {
                    try Task.checkCancellation()
                    let written = buffer.withUnsafeBytes {
                        Darwin.write(destinationFD, $0.baseAddress!.advanced(by: offset), count - offset)
                    }
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw CopyError.cannotWrite
                    }
                    guard written > 0 else { throw CopyError.cannotWrite }
                    offset += written
                }
                total += Int64(count)
            }
            var endingInfo = stat()
            guard Darwin.fstat(sourceFD, &endingInfo) == 0,
                  endingInfo.st_dev == sourceInfo.st_dev,
                  endingInfo.st_ino == sourceInfo.st_ino,
                  endingInfo.st_size == sourceInfo.st_size,
                  endingInfo.st_mtimespec.tv_sec == sourceInfo.st_mtimespec.tv_sec,
                  endingInfo.st_mtimespec.tv_nsec == sourceInfo.st_mtimespec.tv_nsec,
                  total == sourceInfo.st_size else { throw CopyError.sourceChanged }
            guard Darwin.fchmod(destinationFD, sourceInfo.st_mode & 0o777) == 0,
                  Darwin.fsync(destinationFD) == 0 else { throw CopyError.cannotWrite }
            completed = true
            return ToolResult(requestID: request.id, content: "Copied \(source) to \(destination) (\(total) bytes). The source remains unchanged. The destination was new; this action is not automatically undone.")
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    public func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        guard request.name == "copy_file" else { return nil }
        guard let workspace = request.workspacePath,
              let source = request.arguments["source"],
              let destination = request.arguments["destination"] else { throw CopyError.invalidPath }
        let sourceParts = try Self.components(source)
        let destinationParts = try Self.components(destination)
        guard sourceParts != destinationParts else { throw CopyError.samePath }
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.path == workspace else { throw CopyError.invalidWorkspace }
        let sourceURL = sourceParts.reduce(root) { $0.appendingPathComponent($1) }
            .resolvingSymlinksInPath().standardizedFileURL
        let destinationURL = destinationParts.reduce(root) { $0.appendingPathComponent($1) }
            .resolvingSymlinksInPath().standardizedFileURL
        guard sourceURL.path.hasPrefix(root.path + "/"),
              destinationURL.path.hasPrefix(root.path + "/") else { throw CopyError.invalidPath }
        return try MissionToolIntent(needs: [
            MissionPermissionNeed(operation: .observe,
                target: try MissionResource(kind: .directory, identifier: sourceURL.path)),
            MissionPermissionNeed(operation: .edit,
                target: try MissionResource(kind: .directory, identifier: destinationURL.path))
        ])
    }

    private static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains("\0"), !path.contains("\\") else { throw CopyError.invalidPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CopyError.invalidPath }
        return parts
    }

    private static func parentDescriptor(rootFD: Int32, components: [String]) throws -> Int32 {
        var descriptor = Darwin.dup(rootFD)
        guard descriptor >= 0 else { throw CopyError.invalidWorkspace }
        for component in components.dropLast() {
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { throw CopyError.invalidParent }
            descriptor = next
        }
        return descriptor
    }

    private enum CopyError: LocalizedError {
        case invalidWorkspace, invalidPath, samePath, invalidParent, invalidSource
        case alreadyExists, cannotCreate, cannotRead, cannotWrite, sourceChanged

        var errorDescription: String? {
            switch self {
            case .invalidWorkspace: "The selected workspace is unavailable."
            case .invalidPath: "Use relative source and destination paths inside the workspace without . or .. components."
            case .samePath: "Source and destination must be different paths."
            case .invalidParent: "Both parent directories must already exist and cannot be symbolic links."
            case .invalidSource: "The source must be an existing regular file, not a symbolic link or directory."
            case .alreadyExists: "A file or directory already exists at the destination. Nothing was overwritten."
            case .cannotCreate: "The destination could not be created. Nothing was overwritten."
            case .cannotRead: "The source could not be read. An incomplete destination was removed when safe."
            case .cannotWrite: "The destination could not be completed. An incomplete copy was removed when safe."
            case .sourceChanged: "The source changed during copying. An incomplete copy was removed when safe."
            }
        }
    }
}
