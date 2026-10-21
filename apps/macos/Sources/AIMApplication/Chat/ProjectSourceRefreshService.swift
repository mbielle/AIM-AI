import Foundation

public enum ProjectSourceRefreshError: LocalizedError {
    case linkedFolderUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .linkedFolderUnavailable(name):
            "The linked project folder “\(name)” could not be refreshed. Reconnect, rescan or remove it in Project Files before sending; an outdated snapshot was not sent."
        }
    }
}

/// Refreshes linked local sources before retrieval. It never transmits files;
/// the provider receives only the passages selected by the caller afterwards.
public struct ProjectSourceRefreshService: Sendable {
    private let projects: any ProjectRepository
    private let index: SQLiteProjectSourceIndex

    public init(projects: any ProjectRepository, index: SQLiteProjectSourceIndex) {
        self.projects = projects
        self.index = index
    }

    public func refresh(projectID: UUID) async throws {
        for source in try await projects.sources(projectID: projectID) {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: source.canonicalPath, isDirectory: true)
            do {
                guard url.resolvingSymlinksInPath().standardizedFileURL.path == source.canonicalPath else {
                    throw ProjectSourceScannerError.inaccessible
                }
                let probe = Task.detached(priority: .utility) {
                    try ProjectSourceScanner.refreshRequired(url, scannedAt: source.lastScannedAt)
                }
                let changed = try await withTaskCancellationHandler {
                    try await probe.value
                } onCancel: { probe.cancel() }
                guard changed else { continue }
                let scanStartedAt = Date.now
                let scan = Task.detached(priority: .utility) { try ProjectSourceScanner.scan(url) }
                let snapshot = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: { scan.cancel() }
                try Task.checkCancellation()
                guard !snapshot.hasReadErrors else { throw ProjectSourceScannerError.inaccessible }
                try await index.replace(source: source, chunks: snapshot.chunks, scanStartedAt: scanStartedAt)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProjectSourceRefreshError.linkedFolderUnavailable(source.displayName)
            }
        }
    }
}
