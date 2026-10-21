import Foundation

public struct NativeDocumentSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let content: String
    public init(name: String, content: String) { id = UUID(); self.name = name; self.content = content }

    public static func read(_ url: URL, maximumBytes: Int = 64_000) throws -> NativeDocumentSnapshot {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw NativeDocumentError.invalidSelection }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = min(max(1, maximumBytes), 8_000_000)
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw NativeDocumentError.limit }
        guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { throw NativeDocumentError.invalidSelection }
        return NativeDocumentSnapshot(name: url.lastPathComponent, content: text)
    }
    public static func validate(_ attachments: [NativeDocumentSnapshot]) throws {
        guard attachments.count <= 4, Set(attachments.map(\.id)).count == attachments.count,
              attachments.reduce(0, { $0 + $1.content.utf8.count }) <= 128_000,
              attachments.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 255 && $0.content.utf8.count <= 64_000 && !$0.content.contains("\0") }) else {
            throw NativeDocumentError.limit
        }
    }
}

public enum NativeDocumentError: LocalizedError {
    case limit, historyLimit, invalidSelection, synchronizationLimit
    public var errorDescription: String? {
        switch self {
        case .synchronizationLimit: "This conversation exceeds the 16 MB account synchronization limit. Its local attachments are preserved."
        case .limit: "Attach up to 4 UTF-8 files: 64 KB each and 128 KB total."
        case .historyLimit: "This conversation exceeds 512 KB of attached text. Start a new conversation with only the files needed."
        case .invalidSelection: "Choose distinct local files. Web links cannot be imported as file attachments."
        }
    }
}
