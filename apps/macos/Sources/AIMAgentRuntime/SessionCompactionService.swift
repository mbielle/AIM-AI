import AIMCore
import AIMApplication
import Foundation

/// Maintains a resumable context checkpoint without changing the transcript.
/// Compaction uses the same user-supplied provider key as the actual turn and
/// makes no hosted AIM request. Each generated summary is saved only after a
/// complete provider response, so cancellation never advances the checkpoint.
package struct SessionCompactionService: Sendable {
    let repository: any SessionCompactionRepository
    let chatService: ProviderChatService

    package init(repository: any SessionCompactionRepository, chatService: ProviderChatService = ProviderChatService()) {
        self.repository = repository
        self.chatService = chatService
    }

    package func prepare(_ original: [ConversationMessage], conversationID: UUID, provider: ChatProvider,
                 modelID: String, apiKey: String, contextLength: Int? = nil,
                 reservedRequestBytes: Int = 0, force: Bool = false,
                 summarize: (@Sendable (ConversationMessage) async throws -> String)? = nil,
                 onCompactionStarted: @Sendable () -> Void = {},
                 onCheckpoint: @Sendable (SessionCompaction) -> Void = { _ in }) async throws -> [ConversationMessage] {
        // An oversized fixed prefix cannot be repaired by summarizing old
        // dialogue. Reject before spending the user's provider credits on
        // summaries that could never make this request fit.
        if let contextLength, contextLength >= 4_096,
           reservedRequestBytes > (contextLength > Int.max / 8 ? Int.max : contextLength * 8) {
            throw SessionCompactionError.uncompactableContext
        }
        var checkpoint = try await repository.load(conversationID: conversationID)
        while true {
            try Task.checkCancellation()
            let batch = try SessionCompactionContext.nextBatch(original, checkpoint: checkpoint,
                                                               contextLength: contextLength,
                                                               reservedRequestBytes: reservedRequestBytes, force: force)
            guard let last = batch.last else {
                return try SessionCompactionContext.requestHistory(original, checkpoint: checkpoint)
            }
            let prompt = SessionCompactionContext.summaryInput(batch, previous: checkpoint,
                                                                contextLength: contextLength)
            onCompactionStarted()
            let request = ConversationMessage(conversationID: conversationID, role: .user,
                                              content: prompt, sequence: 0)
            var summary = ""
            if let summarize {
                summary = try await summarize(request)
                guard summary.utf8.count <= SessionCompactionContext.summaryLimitBytes(contextLength: contextLength) else {
                    throw SessionCompactionError.invalidSummary
                }
            } else {
            for try await delta in chatService.stream(provider: provider, modelID: modelID,
                                                      messages: [request], apiKey: apiKey,
                                                      mode: .chat, useWebSearch: false,
                                                      billingFeature: "compaction") {
                try Task.checkCancellation()
                summary += delta
                guard summary.utf8.count <= SessionCompactionContext.summaryLimitBytes(contextLength: contextLength) else {
                    throw SessionCompactionError.invalidSummary
                }
            }
            }
            try Task.checkCancellation()
            let next = try SessionCompaction(conversationID: conversationID, throughMessageID: last.id,
                                             throughSequence: last.sequence, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines))
            try await repository.save(next)
            checkpoint = next
            onCheckpoint(next)
        }
    }
}
