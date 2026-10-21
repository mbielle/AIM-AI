import AIMCore
import Foundation

/// The phone and Mac share the exact extraction prompt, validation and sensitive-data filter.
public enum MemoryExtraction {
    public static func requestMessages(userText: String, assistantText: String? = nil, conversationID: UUID) -> [ConversationMessage]? {
        AccountMemoryCapture.messages(userText: userText, assistantText: assistantText)?.enumerated().map { index, message in
            .init(conversationID: conversationID, role: .user, content: message.text, sequence: index)
        }
    }
    /// A light model of the same provider reads each exchange for memory, when the catalog offers one;
    /// otherwise the conversation's own model does.
    public static func captureModel(provider: ChatProvider, conversationModel: String, available: [String]?) -> String {
        let preferred: [String]
        switch provider {
        case .openRouter: preferred = ["anthropic/claude-haiku-5.5", "anthropic/claude-haiku-4.5", "google/gemini-2.5-flash", "openai/gpt-5-mini"]
        case .anthropic: preferred = ["claude-haiku-5-5", "claude-haiku-4-5"]
        case .openAI: preferred = ["gpt-5-mini", "gpt-4.1-mini"]
        default: preferred = []
        }
        guard let available else { return conversationModel }
        return preferred.first(where: available.contains) ?? conversationModel
    }
    /// Secrets, credentials, payment, health and contact details never enter memory.
    public static func containsSensitiveMaterial(_ text: String) -> Bool {
        AccountMemoryCapture.containsSensitiveMaterial(text)
    }
    public static func requestsRemembering(_ userText: String) -> Bool {
        AccountMemoryCapture.requestsRemembering(userText)
    }
    public static func parse(_ output: String, source: String, projectID: UUID?, sourceMessageID: UUID? = nil) -> [MemoryItem] {
        AccountMemoryCapture.parse(output, source: source, projectID: projectID, sourceMessageID: sourceMessageID).map {
            .init(id: $0.id, kind: MemoryKind(rawValue: $0.kind ?? "fact") ?? .fact,
                  scope: $0.scope ?? "global", scopeKey: $0.scopeKey ?? "self",
                  subjectKey: $0.subject, content: $0.content, evidenceQuote: $0.evidence,
                  sourceMessageID: sourceMessageID, status: .provisional, confidence: $0.confidence ?? 0.8,
                  createdAt: $0.createdAt ?? .now, updatedAt: $0.updatedAt ?? .now)
        }
    }
}
