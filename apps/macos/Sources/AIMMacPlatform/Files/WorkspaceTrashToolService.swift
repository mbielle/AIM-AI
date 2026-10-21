import AIMAgentKit
import Darwin
import Foundation

/// Moves one approved workspace file to the macOS Trash. Only regular,
/// single-link files are supported; directories and symlinks fail closed.
public struct WorkspaceTrashToolService: ToolExecutor {
    public let supportedTools: Set<String> = ["trash_file"]
    private let trash: @Sendable (URL) throws -> Void

    public init() {
        trash = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    // A mover scoped to a temporary directory makes destructive behavior
    // testable without filling the user's actual Finder Trash.
    init(trash: @escaping @Sendable (URL) throws -> Void) { self.trash = trash }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard request.name == "trash_file", let workspace = request.workspacePath,
                  let path = request.arguments["path"] else { throw TrashError.invalidPath }
            let parts = try Self.components(path)
            let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard root.path == workspace else { throw TrashError.invalidWorkspace }
            let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw TrashError.invalidWorkspace }
            defer { Darwin.close(rootFD) }
            let parentFD = try Self.parentDescriptor(rootFD: rootFD, components: parts)
            defer { Darwin.close(parentFD) }
            let leaf = parts.last!
            let sourceFD = Darwin.openat(parentFD, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw TrashError.invalidSource }
            defer { Darwin.close(sourceFD) }
            var original = stat()
            guard Darwin.fstat(sourceFD, &original) == 0,
                  original.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  original.st_nlink == 1 else { throw TrashError.invalidSource }
            let target = parts.reduce(root) { $0.appendingPathComponent($1) }

            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var outcome: Result<Void, Error>?
            coordinator.coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { coordinated in
                outcome = Result {
                    guard coordinated.standardizedFileURL == target.standardizedFileURL,
                          Self.matches(path: root.path, descriptor: rootFD),
                          Self.matches(path: target.deletingLastPathComponent().path, descriptor: parentFD),
                          Self.matches(path: target.path, descriptor: sourceFD) else { throw TrashError.sourceChanged }
                    var current = stat()
                    guard Darwin.fstatat(parentFD, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                          current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                          current.st_nlink == 1 else { throw TrashError.sourceChanged }
                    try Task.checkCancellation()
                    try trash(target)
                }
            }
            if let outcome { try outcome.get() }
            else if let coordinationError { throw coordinationError }
            else { throw TrashError.cannotTrash }
            return ToolResult(requestID: request.id,
                              content: "Moved \(path) to the macOS Trash after approval. Restore it in Finder if needed; AIM does not automatically undo this action.")
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    private static func matches(path: String, descriptor: Int32) -> Bool {
        var opened = stat()
        var named = stat()
        return Darwin.fstat(descriptor, &opened) == 0
            && Darwin.lstat(path, &named) == 0
            && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
            && named.st_mode & mode_t(S_IFMT) == opened.st_mode & mode_t(S_IFMT)
    }

    private static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains("\0"), !path.contains("\\") else { throw TrashError.invalidPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw TrashError.invalidPath }
        return parts
    }

    private static func parentDescriptor(rootFD: Int32, components: [String]) throws -> Int32 {
        var descriptor = Darwin.dup(rootFD)
        guard descriptor >= 0 else { throw TrashError.invalidWorkspace }
        for component in components.dropLast() {
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { throw TrashError.invalidParent }
            descriptor = next
        }
        return descriptor
    }

    private enum TrashError: LocalizedError {
        case invalidWorkspace, invalidPath, invalidParent, invalidSource, sourceChanged, cannotTrash

        var errorDescription: String? {
            switch self {
            case .invalidWorkspace: "The selected workspace is unavailable."
            case .invalidPath: "Use a relative file path inside the workspace without . or .. components."
            case .invalidParent: "The parent directory is missing or is a symbolic link."
            case .invalidSource: "Only an existing regular file with one hard link can be moved to Trash. Directories and symbolic links are not supported."
            case .sourceChanged: "The file or its parent changed before the Trash action. Inspect the workspace before retrying."
            case .cannotTrash: "The Trash action could not be confirmed. Inspect the workspace and Finder Trash before retrying."
            }
        }
    }
}
