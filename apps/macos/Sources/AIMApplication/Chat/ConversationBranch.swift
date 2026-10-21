import Foundation

public enum ConversationBranchError: LocalizedError {
    case missingMessage, unsupported
    public var errorDescription: String? {
        switch self {
        case .missingMessage: "The source conversation or message no longer exists."
        case .unsupported: "This conversation store does not support branching."
        }
    }
}

public struct ConversationBranch: Sendable {
    public let conversation: Conversation
    public let messages: [ConversationMessage]

    public init(source: Conversation, messages: [ConversationMessage], at messageID: UUID, includingMessage: Bool) throws {
        let ordered = messages.filter { $0.conversationID == source.id }.sorted { $0.sequence < $1.sequence }
        guard let index = ordered.firstIndex(where: { $0.id == messageID }) else { throw ConversationBranchError.missingMessage }
        let copy = Conversation(title: String(source.title.prefix(145)) + " · Branch", mode: source.mode,
                                projectID: source.projectID, engineID: source.engineID,
                                provider: source.provider, modelID: source.modelID, workspacePath: source.workspacePath)
        conversation = copy
        self.messages = ordered.prefix(index + (includingMessage ? 1 : 0)).enumerated().map { sequence, message in
            ConversationMessage(conversationID: copy.id, role: message.role, content: message.content,
                                sequence: sequence, createdAt: message.createdAt, attachments: message.attachments, images: message.images,
                                completionStatus: message.completionStatus)
        }
    }
}
