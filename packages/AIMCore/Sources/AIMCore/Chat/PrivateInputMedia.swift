import Foundation

/// Local-only originals. Only prepared snapshots are included in account documents.
public enum PrivateInputMedia {
    public static func directory(root: URL, accountID: UUID?, attachmentID: UUID) -> URL {
        root.appendingPathComponent("InputOriginals", isDirectory: true)
            .appendingPathComponent(accountID?.uuidString.lowercased() ?? "local", isDirectory: true)
            .appendingPathComponent(attachmentID.uuidString.lowercased(), isDirectory: true)
    }
    @discardableResult public static func retain(_ source: URL, root: URL, accountID: UUID?, attachmentID: UUID) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 250_000_000 else { throw NativeDocumentError.limit }
        let directory = directory(root: root, accountID: accountID, attachmentID: attachmentID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = directory.appendingPathComponent(source.lastPathComponent)
        if !FileManager.default.fileExists(atPath: output.path) { try FileManager.default.copyItem(at: source, to: output) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return output
    }
    public static func original(root: URL, accountID: UUID?, attachmentID: UUID) -> URL? {
        let directory = directory(root: root, accountID: accountID, attachmentID: attachmentID)
        return try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
    }
}
