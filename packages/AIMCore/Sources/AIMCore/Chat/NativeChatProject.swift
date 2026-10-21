import Foundation

/// Portable project metadata; machine paths, file permissions and source files never sync.
public struct NativeChatProject: Codable, Identifiable, Equatable, Sendable {
    public enum MemoryScope: String, Codable, Sendable { case `default`, projectOnly }
    public var id: UUID
    public var name: String
    public var instructions: String
    public var isPinned: Bool
    public var memoryScope: MemoryScope
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), name: String, instructions: String = "", isPinned: Bool = false, memoryScope: MemoryScope = .default, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id; self.name = name; self.instructions = instructions; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.isPinned = isPinned; self.memoryScope = memoryScope
    }
    private enum CodingKeys: String, CodingKey { case id, name, instructions, isPinned, memoryScope, createdAt, updatedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        instructions = try values.decode(String.self, forKey: .instructions)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        memoryScope = try values.decodeIfPresent(MemoryScope.self, forKey: .memoryScope) ?? .default
    }
}
