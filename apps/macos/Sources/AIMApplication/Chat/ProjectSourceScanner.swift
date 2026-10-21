import Foundation

public struct ProjectSourceScan: Sendable {
    public let chunks: [ProjectSourceChunk]
    public let indexedFiles: Int
    public let skippedFiles: Int
    public let isPartial: Bool
    public let hasReadErrors: Bool

    public init(chunks: [ProjectSourceChunk], indexedFiles: Int, skippedFiles: Int, isPartial: Bool, hasReadErrors: Bool = false) {
        self.chunks = chunks; self.indexedFiles = indexedFiles; self.skippedFiles = skippedFiles
        self.isPartial = isPartial; self.hasReadErrors = hasReadErrors
    }
}

public enum ProjectSourceScannerError: LocalizedError {
    case inaccessible, probeIncomplete
    public var errorDescription: String? {
        switch self {
        case .inaccessible: "The selected folder cannot be read. Choose it again or check its permissions."
        case .probeIncomplete: "The linked folder is too large or slow to verify automatically. Rescan or unlink it before sending."
        }
    }
}

public enum ProjectSourceScanner {
    private static let ignoredDirectories: Set<String> = [
        ".git", ".svn", ".hg", ".build", "build", "dist", "deriveddata", "node_modules", "vendor", "target", "coverage", "pods", ".next", ".venv", "venv", "__pycache__"
    ]
    private static let ignoredExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "pdf", "zip", "gz", "tar", "dmg", "exe", "dll", "dylib", "so", "a", "o", "class", "pyc", "sqlite", "db", "mp3", "mp4", "mov", "wav", "woff", "woff2", "ttf", "otf", "p12", "p8", "pem", "key", "cer", "crt"
    ]
    private static let sensitiveNames: Set<String> = ["id_rsa", "id_ed25519", "credentials", "credentials.json", "secrets.json", "secrets.yml", "secrets.yaml", "service-account.json", "google-services.json", "googleservice-info.plist"]

    /// Metadata-only check before a provider request. Directory modification
    /// dates detect additions/deletions, while file dates detect content edits.
    /// Uncertain checks fail rather than sending an old index as current.
    public static func refreshRequired(_ folder: URL, scannedAt: Date?) throws -> Bool {
        guard let scannedAt else { return true }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let rootValues = try? root.resourceValues(forKeys: keys), rootValues.isDirectory == true else {
            throw ProjectSourceScannerError.inaccessible
        }
        guard let rootModified = rootValues.contentModificationDate else { return true }
        if rootModified > scannedAt { return true }
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return false }) else {
            throw ProjectSourceScannerError.inaccessible
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var visited = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 50_000, ContinuousClock.now < deadline else { throw ProjectSourceScannerError.probeIncomplete }
            let name = url.lastPathComponent.lowercased()
            guard let values = try? url.resourceValues(forKeys: keys) else { throw ProjectSourceScannerError.inaccessible }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true && ignoredDirectories.contains(name) {
                enumerator.skipDescendants(); continue
            }
            guard let modified = values.contentModificationDate else { return true }
            if modified > scannedAt { return true }
        }
        if failed { throw ProjectSourceScannerError.inaccessible }
        return false
    }

    /// A bounded initial snapshot, not a quota on the user's model requests.
    /// The result explicitly reports partial scans; it never silently claims
    /// a complete project index.
    public static func scan(_ folder: URL) throws -> ProjectSourceScan {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        var partial = false
        var readErrors = false
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in partial = true; readErrors = true; return true }) else {
            throw ProjectSourceScannerError.inaccessible
        }
        var chunks: [ProjectSourceChunk] = []
        var indexed = 0
        var skipped = 0
        var totalBytes = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let name = url.lastPathComponent.lowercased()
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
                skipped += 1; partial = true; readErrors = true; continue
            }
            if values.isSymbolicLink == true { skipped += 1; continue }
            if values.isDirectory == true {
                if ignoredDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if name.hasPrefix(".env") || name.contains("secret") || name.contains("private_key") || name.contains("apikey") || name.contains("api_key") || sensitiveNames.contains(name) || ignoredExtensions.contains(url.pathExtension.lowercased()) {
                skipped += 1; continue
            }
            guard indexed < 10_000, totalBytes < 32_000_000 else { partial = true; skipped += 1; break }
            guard let size = values.fileSize, size <= 256_000 else { skipped += 1; partial = true; continue }
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPath.hasPrefix(root.path + "/") else { skipped += 1; partial = true; readErrors = true; continue }
            let data = try? readBoundedFile(url)
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == resolvedPath else {
                skipped += 1; partial = true; readErrors = true; continue
            }
            guard let data, !data.contains(0), let content = String(data: data, encoding: .utf8) else {
                skipped += 1
                if data == nil { partial = true; readErrors = true }
                continue
            }
            let relative = String(resolvedPath.dropFirst(root.path.count + 1))
            guard !relative.isEmpty else { skipped += 1; continue }
            chunks += makeChunks(path: relative, content: content)
            indexed += 1
            totalBytes += data.count
        }
        return ProjectSourceScan(chunks: chunks, indexedFiles: indexed, skippedFiles: skipped,
                                 isPartial: partial, hasReadErrors: readErrors)
    }

    private static func readBoundedFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 256_001) ?? Data()
        guard data.count <= 256_000 else { throw ProjectSourceScannerError.inaccessible }
        return data
    }

    private static func makeChunks(path: String, content: String) -> [ProjectSourceChunk] {
        var output: [ProjectSourceChunk] = []
        var passage = ""
        var firstLine = 1
        // Foundation splits the literal LF bytes; Swift Character can treat
        // CRLF as one grapheme and miss it when splitting on Character("\n").
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            let cleanLine = line.hasSuffix("\r") ? String(line.dropLast()) : line
            let excerpt = String(decoding: cleanLine.utf8.prefix(2_000), as: UTF8.self)
            if passage.utf8.count + excerpt.utf8.count + 1 > 3_000, !passage.isEmpty {
                output.append(ProjectSourceChunk(relativePath: path, startLine: firstLine, content: passage))
                passage = ""; firstLine = index + 1
            }
            if passage.isEmpty { firstLine = index + 1 }
            passage += excerpt + "\n"
        }
        if !passage.isEmpty { output.append(ProjectSourceChunk(relativePath: path, startLine: firstLine, content: passage)) }
        return output
    }
}
