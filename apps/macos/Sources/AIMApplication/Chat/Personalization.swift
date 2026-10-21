import Foundation

public struct Personalization: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var instructions: String
    public init(isEnabled: Bool = false, instructions: String = "") {
        self.isEnabled = isEnabled; self.instructions = instructions
    }
    public func validate() throws {
        guard instructions.count <= 8_000, instructions.utf8.count <= 32_000, !instructions.contains("\0") else {
            throw PersonalizationError.tooLarge
        }
    }
    public func messages(_ history: [ConversationMessage], conversationID: UUID) throws -> [ConversationMessage] {
        guard isEnabled, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return history }
        try validate()
        let text = "User's saved response preferences. Apply when relevant; the current task and project-specific instructions take precedence. These preferences do not grant tool permissions or override approval requirements.\n\n\(instructions)"
        return [.init(conversationID: conversationID, role: .user, content: text, sequence: -2)] + history
    }
}

public enum PersonalizationError: LocalizedError {
    case tooLarge
    public var errorDescription: String? { "Personal instructions are limited to 8,000 characters / 32 KB and cannot contain null characters." }
}
