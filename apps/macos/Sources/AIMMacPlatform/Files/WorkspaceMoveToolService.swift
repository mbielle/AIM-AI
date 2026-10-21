import AIMAgentKit
import AIMApplication
import Darwin
import Foundation

/// Moves one regular file between existing workspace directories after an
/// exact-action approval. macOS performs a no-replace rename; an unsupported
/// volume or cross-volume move fails closed rather than copying or overwriting.
public struct WorkspaceMoveToolService: ToolExecutor, MissionIntentProviding {
    public let supportedTools: Set<String> = ["move_file"]

    public init() {}

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard request.name == "move_file", let workspace = request.workspacePath,
                  let source = request.arguments["source"],
                  let destination = request.arguments["destination"] else { throw MoveError.invalidPath }
            let sourceParts = try Self.components(source)
            let destinationParts = try Self.components(destination)
            guard sourceParts != destinationParts else { throw MoveError.samePath }
            let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard root.path == workspace else { throw MoveError.invalidWorkspace }
            let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw MoveError.invalidWorkspace }
            defer { Darwin.close(rootFD) }

            let sourceParent = try Self.parentDescriptor(rootFD: rootFD, components: sourceParts)
            defer { Darwin.close(sourceParent) }
            let sourceFD = Darwin.openat(sourceParent, sourceParts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw MoveError.invalidSource }
            defer { Darwin.close(sourceFD) }
            var opened = stat()
            guard Darwin.fstat(sourceFD, &opened) == 0,
                  opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw MoveError.invalidSource }

            let destinationParent = try Self.parentDescriptor(rootFD: rootFD, components: destinationParts)
            defer { Darwin.close(destinationParent) }
            var current = stat()
            guard Darwin.fstatat(sourceParent, sourceParts.last!, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
                throw MoveError.sourceChanged
            }
            try Task.checkCancellation()
            guard Darwin.renameatx_np(sourceParent, sourceParts.last!, destinationParent,
                                      destinationParts.last!, UInt32(RENAME_EXCL)) == 0 else {
                switch errno {
                case EEXIST: throw MoveError.alreadyExists
                case EXDEV: throw MoveError.differentVolume
                case ENOENT: throw MoveError.sourceChanged
                default: throw MoveError.cannotMove
                }
            }
            var moved = stat()
            guard Darwin.fstatat(destinationParent, destinationParts.last!, &moved, AT_SYMLINK_NOFOLLOW) == 0,
                  moved.st_dev == opened.st_dev, moved.st_ino == opened.st_ino else {
                throw MoveError.movedButChanged
            }
            return ToolResult(requestID: request.id,
                content: "Moved \(source) to \(destination) without overwriting. The source path is now absent. This action is not automatically undone.")
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    public func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        guard request.name == "move_file" else { return nil }
        guard let workspace = request.workspacePath,
              let source = request.arguments["source"],
              let destination = request.arguments["destination"] else { throw MoveError.invalidPath }
        let sourceParts = try Self.components(source)
        let destinationParts = try Self.components(destination)
        guard sourceParts != destinationParts else { throw MoveError.samePath }
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.path == workspace else { throw MoveError.invalidWorkspace }
        let sourceURL = sourceParts.reduce(root) { $0.appendingPathComponent($1) }
            .resolvingSymlinksInPath().standardizedFileURL
        let destinationURL = destinationParts.reduce(root) { $0.appendingPathComponent($1) }
            .resolvingSymlinksInPath().standardizedFileURL
        guard sourceURL.path.hasPrefix(root.path + "/"),
              destinationURL.path.hasPrefix(root.path + "/") else { throw MoveError.invalidPath }
        return try MissionToolIntent(needs: [
            MissionPermissionNeed(operation: .edit,
                target: try MissionResource(kind: .directory, identifier: sourceURL.path)),
            MissionPermissionNeed(operation: .edit,
                target: try MissionResource(kind: .directory, identifier: destinationURL.path))
        ])
    }

    private static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains("\0"), !path.contains("\\") else { throw MoveError.invalidPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw MoveError.invalidPath }
        return parts
    }

    private static func parentDescriptor(rootFD: Int32, components: [String]) throws -> Int32 {
        var descriptor = Darwin.dup(rootFD)
        guard descriptor >= 0 else { throw MoveError.invalidWorkspace }
        for component in components.dropLast() {
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { throw MoveError.invalidParent }
            descriptor = next
        }
        return descriptor
    }

    private enum MoveError: LocalizedError {
        case invalidWorkspace, invalidPath, samePath, invalidParent, invalidSource
        case sourceChanged, alreadyExists, differentVolume, cannotMove, movedButChanged

        var errorDescription: String? {
            switch self {
            case .invalidWorkspace: "The selected workspace is unavailable."
            case .invalidPath: "Use relative source and destination paths inside the workspace without . or .. components."
            case .samePath: "Source and destination must be different paths."
            case .invalidParent: "Both parent directories must already exist and cannot be symbolic links."
            case .invalidSource: "The source must be an existing readable regular file, not a symbolic link or directory."
            case .sourceChanged: "The source changed or disappeared before the move. No file was moved by this action."
            case .alreadyExists: "A file or directory already exists at the destination. Nothing was overwritten."
            case .differentVolume: "The destination is on another volume. No copy fallback was attempted."
            case .cannotMove: "The file could not be moved. Inspect both paths before retrying."
            case .movedButChanged: "The move occurred, but the destination changed immediately afterward. Inspect both paths before retrying."
            }
        }
    }
}
