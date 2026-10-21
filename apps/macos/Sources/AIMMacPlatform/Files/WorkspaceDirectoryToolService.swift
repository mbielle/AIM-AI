import AIMAgentKit
import AIMApplication
import Darwin
import Foundation

/// Creates exactly one directory after the dispatcher has authorized its relative path.
/// Parent directories must already exist. Descriptor-relative traversal refuses
/// symlinks, so a changed parent cannot redirect the operation outside the root.
public struct WorkspaceDirectoryToolService: ToolExecutor, MissionIntentProviding {
    public let supportedTools: Set<String> = ["create_dir"]

    public init() {}

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard let workspace = request.workspacePath else { throw DirectoryError.invalidWorkspace }
            guard let path = request.arguments["path"] else { throw DirectoryError.invalidPath }
            let components = try Self.components(path)
            let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard root.path == workspace else { throw DirectoryError.invalidWorkspace }
            var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw DirectoryError.invalidWorkspace }
            defer { Darwin.close(descriptor) }
            for component in components.dropLast() {
                let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw DirectoryError.invalidParent }
                Darwin.close(descriptor)
                descriptor = next
            }
            try Task.checkCancellation()
            guard Darwin.mkdirat(descriptor, components.last!, 0o755) == 0 else {
                if errno == EEXIST { throw DirectoryError.alreadyExists }
                throw DirectoryError.cannotCreate
            }
            return ToolResult(requestID: request.id, content: "Created directory \(path). The parent already existed; no other paths were created. This action is not automatically undone.")
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    public func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        guard request.name == "create_dir" else { return nil }
        guard let workspace = request.workspacePath, let path = request.arguments["path"] else {
            throw DirectoryError.invalidPath
        }
        let components = try Self.components(path)
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.path == workspace else { throw DirectoryError.invalidWorkspace }
        let target = components.reduce(root) { $0.appendingPathComponent($1) }
            .resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw DirectoryError.invalidPath }
        return MissionToolIntent(operation: .edit,
            target: try MissionResource(kind: .directory, identifier: target.path))
    }

    private static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"), !path.contains("\0"),
              !path.contains("\\") else { throw DirectoryError.invalidPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw DirectoryError.invalidPath }
        return parts
    }

    private enum DirectoryError: LocalizedError {
        case invalidWorkspace, invalidPath, invalidParent, alreadyExists, cannotCreate
        var errorDescription: String? {
            switch self {
            case .invalidWorkspace: "The selected workspace is unavailable."
            case .invalidPath: "Choose a relative directory path inside the workspace without . or .. components."
            case .invalidParent: "The parent directory must already exist and cannot be a symbolic link."
            case .alreadyExists: "A file or directory already exists at this path. Nothing was changed."
            case .cannotCreate: "The directory could not be created. Nothing else was changed."
            }
        }
    }
}
