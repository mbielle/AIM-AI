import AIMCore
import Foundation

/// A user-triggered, billable smoke test of the same text transport used by Chat.
/// It never writes a conversation or sends local files, project context or memory.
public struct ProviderInferenceProbe: Sendable {
    private let service: ProviderChatService

    public init(service: ProviderChatService = ProviderChatService()) {
        self.service = service
    }

    public func run(provider: ChatProvider, modelID: String, apiKey: String) async throws -> String {
        let conversationID = UUID()
        let prompt = ConversationMessage(conversationID: conversationID, role: .user,
                                         content: "Reply with the single word READY.", sequence: 0)
        var preview = ""
        for try await fragment in service.stream(provider: provider, modelID: modelID,
                                                 messages: [prompt], apiKey: apiKey,
                                                 mode: .chat, useWebSearch: false,
                                                 billingFeature: "qualification") {
            try Task.checkCancellation()
            if preview.count < 600 { preview += fragment.prefix(600 - preview.count) }
        }
        guard !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatServiceError.emptyResponse
        }
        return preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
