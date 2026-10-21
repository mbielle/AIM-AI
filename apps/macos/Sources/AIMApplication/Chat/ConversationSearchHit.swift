import Foundation

/// A sidebar search result points to a saved message, not just a conversation.
public struct ConversationSearchHit: Identifiable, Sendable {
    public let conversation: Conversation
    public let messageID: UUID?
    public let excerpt: String?
    public var id: UUID { conversation.id }

    public init(conversation: Conversation, messageID: UUID? = nil, excerpt: String? = nil) {
        self.conversation = conversation
        self.messageID = messageID
        self.excerpt = excerpt
    }
}
