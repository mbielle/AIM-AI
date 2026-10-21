import AIMCore
import Foundation
import Observation
import UniformTypeIdentifiers

enum AIMProjectDocumentImportError: LocalizedError {
    case unsupported
    var errorDescription: String? { String(localized: "project.files.unsupported") }
}

struct AIMPreparedProjectDocument: Sendable {
    let name: String
    let mimeType: String
    let source: Data
    let text: String

    /// Extract from a bounded, protected stable copy. Never modify the Files provider original.
    static func read(_ url: URL) throws -> Self {
        try Task.checkCancellation()
        guard url.isFileURL, !url.lastPathComponent.isEmpty, url.lastPathComponent.count <= 255 else { throw NativeDocumentError.invalidSelection }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw NativeDocumentError.invalidSelection }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: ProjectSourceStore.maximumSourceBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= ProjectSourceStore.maximumSourceBytes else { throw ProjectSourceError.invalidSource }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-document-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = url.lastPathComponent
        let copy = directory.appendingPathComponent(name)
        try data.write(to: copy, options: [.atomic, .completeFileProtection])
        let snapshot: NativeDocumentSnapshot
        do { snapshot = try NativeDocumentImporter.read(copy, limits: .project) }
        catch NativeDocumentError.invalidSelection { throw AIMProjectDocumentImportError.unsupported }
        guard !snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeDocumentImportError.noText }
        try Task.checkCancellation()
        return .init(name: name, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", source: data, text: snapshot.content)
    }
}

/// Lightweight display record. `text` is a 4-KB preview; readText returns the entire retained text.
struct AIMProjectDocument: Codable, Identifiable, Equatable {
    var id = UUID()
    let projectID: UUID
    let name: String
    let mimeType: String
    let sourceBytes: Int
    let text: String
    var importedAt = Date()
    var useInChat = false
    var hasOriginal = false
    var textBytes = 0
}

/// Device-only, profile-scoped library. New sources are searchable; no source is uploaded here.
/// Legacy inclusion choices survive migration, including deliberately excluded private documents.
@MainActor @Observable final class AIMProjectDocumentLibrary {
    private(set) var documents: [AIMProjectDocument] = []
    private(set) var error: String?
    private(set) var sourceStore: ProjectSourceStore?
    /// The legacy JSON reader bound, retained for compatibility diagnostics (not the new quota).
    static let maximumBytes = ProjectSourceStore.maximumLegacyBytes

    init(directory: URL) {
        do { sourceStore = try ProjectSourceStore(directory: directory); try reload() }
        catch { self.error = error.localizedDescription }
    }
    func files(for projectID: UUID) -> [AIMProjectDocument] { documents.filter { $0.projectID == projectID } }
    @discardableResult func add(_ prepared: AIMPreparedProjectDocument, projectID: UUID) -> Bool {
        mutate {
            guard let sourceStore else { throw ProjectSourceError.unreadable }
            try sourceStore.add(projectID: projectID, name: prepared.name, mimeType: prepared.mimeType, text: prepared.text, original: prepared.source)
        }
    }
    /// Index and write large imports off the main actor. The captured store belongs to this
    /// library's immutable profile; cancellation is forwarded through the commit boundary.
    @discardableResult func addPrepared(_ prepared: AIMPreparedProjectDocument, projectID: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let sourceStore else { error = ProjectSourceError.unreadable.localizedDescription; return false }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try sourceStore.add(projectID: projectID, name: prepared.name, mimeType: prepared.mimeType, text: prepared.text, original: prepared.source)
        }
        do {
            _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            // A committed import remains committed if cancellation arrives just after COMMIT.
            // Refresh even then so the UI cannot hide the retained source or encourage a duplicate.
            let refreshed = Task.detached(priority: .userInitiated) { try sourceStore.records() }
            apply(try await refreshed.value); error = nil; return true
        } catch is CancellationError {
            try? reload(); return false
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func setUse(_ id: UUID, enabled: Bool) -> Bool {
        mutate { guard let sourceStore else { throw ProjectSourceError.unreadable }; try sourceStore.setEnabled(id, enabled: enabled) }
    }
    /// The title and its search index change together; large indexes never block the UI actor.
    @discardableResult func rename(_ id: UUID, projectID: UUID, name: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let sourceStore else { error = ProjectSourceError.unreadable.localizedDescription; return false }
        let worker = Task.detached(priority: .userInitiated) { try sourceStore.rename(id, projectID: projectID, name: name) }
        do {
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            // COMMIT is final even if the originating view disappears immediately afterwards.
            let refreshed = Task.detached(priority: .userInitiated) { try sourceStore.records() }
            apply(try await refreshed.value); error = nil; return true
        } catch is CancellationError { return false }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func delete(_ id: UUID) -> Bool {
        mutate { guard let sourceStore else { throw ProjectSourceError.unreadable }; try sourceStore.remove(id) }
    }
    func readText(_ id: UUID) throws -> String {
        guard let sourceStore else { throw ProjectSourceError.unreadable }; return try sourceStore.readText(id)
    }
    func readOriginal(_ id: UUID) throws -> Data {
        guard let sourceStore else { throw ProjectSourceError.unreadable }; return try sourceStore.readOriginal(id)
    }
    /// Never inject whole project files when there is no query. Kept for old call-site compatibility.
    func attachments(for projectID: UUID?) -> [NativeChatAttachment] { [] }

    func attachments(for projectID: UUID?, query: String) async throws -> [NativeChatAttachment] {
        guard let projectID else { return [] }
        guard let sourceStore else { throw ProjectSourceError.unreadable }
        let worker = Task.detached(priority: .userInitiated) { try sourceStore.search(projectID: projectID, query: query) }
        let excerpts = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        // Group by source so the existing four-document attachment ceiling remains intact.
        var order: [UUID] = [], grouped: [UUID: (String, String)] = [:]
        for excerpt in excerpts {
            if grouped[excerpt.sourceID] == nil { order.append(excerpt.sourceID); grouped[excerpt.sourceID] = (excerpt.name, "") }
            grouped[excerpt.sourceID]!.1 += "[\(excerpt.citation)]\n\(excerpt.text)\n\n"
        }
        return order.compactMap { id in
            guard let value = grouped[id] else { return nil }
            return .init(id: id, name: value.0, kind: .document, mimeType: "text/plain", text: value.1, projectSourceID: id)
        }
    }
    private func reload() throws {
        apply(try sourceStore?.records() ?? [])
    }
    private func apply(_ records: [ProjectSourceRecord]) {
        documents = records.map {
            .init(id: $0.id, projectID: $0.projectID, name: $0.name, mimeType: $0.mimeType, sourceBytes: $0.sourceBytes, text: $0.preview, importedAt: $0.importedAt, useInChat: $0.useInChat, hasOriginal: $0.hasOriginal, textBytes: $0.textBytes)
        }
    }
    private func mutate(_ operation: () throws -> Void) -> Bool {
        do { try Task.checkCancellation(); try operation(); try reload(); error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
