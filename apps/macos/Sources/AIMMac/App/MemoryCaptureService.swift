import AIMApplication
import AIMAgentRuntime
import AIMCore
import Foundation

/// Runs after a successful user turn. A capture is a normal provider request
/// billed to the user's own key, not an AIM quota or an invisible cloud sync.
struct MemoryCaptureService: Sendable {
    let repository: any MemoryRepository
    let secureStore: any SecureStoring
    let chatService: ProviderChatService
    let expectedOwner: AccountMemoryOwner?

    init(repository: any MemoryRepository, secureStore: any SecureStoring,
         chatService: ProviderChatService = ProviderChatService(), expectedOwner: AccountMemoryOwner? = nil) {
        self.repository = repository
        self.secureStore = secureStore
        self.chatService = chatService
        self.expectedOwner = expectedOwner
    }

    func proposals(userText: String, assistantText: String? = nil, sourceMessageID: UUID, conversation: Conversation) async throws -> [MemoryItem] {
        guard let messages = MemoryExtraction.requestMessages(userText: userText, assistantText: assistantText, conversationID: conversation.id),
              let provider = conversation.provider, let conversationModel = conversation.modelID, !conversationModel.isEmpty else { return [] }
        let key: String
        if provider == .chatgpt {
            key = try await RuntimeProviderCredentials.reader(provider: provider, store: secureStore)()
        } else {
            guard let data = try secureStore.readData(forKey: provider.rawValue),
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { return [] }
            key = value
        }
        let modelID = MemoryExtraction.captureModel(provider: provider, conversationModel: conversationModel,
            available: await ModelCatalogCache.shared.cached(provider)?.map(\.id))
        var response = ""
        for try await part in chatService.stream(provider: provider, modelID: modelID, messages: messages,
                                                  apiKey: key, mode: .chat, useWebSearch: false,
                                                  billingFeature: "memory") {
            try Task.checkCancellation()
            response += part
            guard response.utf8.count <= 16_384 else { return [] }
        }
        return MemoryExtraction.parse(response, source: userText, projectID: conversation.projectID,
                                      sourceMessageID: sourceMessageID)
    }

    func saveNew(_ proposals: [MemoryItem], explicitRequest: Bool = false) async throws -> Int {
        if let account = repository as? AccountMemoryRepository {
            return try await account.saveCaptured(proposals, expectedOwner: expectedOwner, explicit: explicitRequest)
        }
        let existing = try await repository.list(status: nil)
        var bySubject = Dictionary(existing.map { (subjectKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var saved = 0
        for item in proposals {
            try Task.checkCancellation()
            let key = subjectKey(item)
            // "Retiens que…": the person's own new statement, saved as reviewed. It replaces an
            // earlier memory with the same subject, even one they reviewed or archived.
            var item = item
            if explicitRequest { item.status = .verified; item.confidence = 1 }
            if var previous = bySubject[key] {
                // Otherwise the user owns verified and archived memories: an automatic
                // extraction cannot undo their correction or archive decision.
                guard explicitRequest || (previous.status == .provisional && previous.kind != .correction) else { continue }
                guard item.updatedAt >= previous.updatedAt else { continue }
                guard previous.content != item.content || previous.status != item.status else { continue }
                previous.kind = item.kind
                previous.content = item.content
                previous.evidenceQuote = item.evidenceQuote
                previous.sourceMessageID = item.sourceMessageID
                previous.confidence = item.confidence
                previous.status = item.status
                previous.updatedAt = item.updatedAt
                try await repository.save(previous)
                bySubject[key] = previous
            } else {
                try await repository.save(item)
                bySubject[key] = item
            }
            saved += 1
        }
        return saved
    }

    private func subjectKey(_ item: MemoryItem) -> String {
        "\(item.scope)|\(item.scopeKey)|\(item.subjectKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}
