import Foundation

public actor InMemoryConversationRepository: ConversationRepository {
    private var conversations: [UUID: Conversation] = [:]
    private var storedMessages: [UUID: [ConversationMessage]] = [:]

    public init(seed: [Conversation] = []) {
        conversations = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    public func list(includeArchived: Bool) -> [Conversation] {
        conversations.values
            .filter { includeArchived || !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func conversation(id: UUID) -> Conversation? { conversations[id] }

    public func save(_ conversation: Conversation) { conversations[conversation.id] = conversation }

    public func delete(id: UUID) {
        conversations.removeValue(forKey: id)
        storedMessages.removeValue(forKey: id)
    }

    public func messages(conversationID: UUID) -> [ConversationMessage] {
        (storedMessages[conversationID] ?? []).sorted { $0.sequence < $1.sequence }
    }

    public func append(_ message: ConversationMessage) {
        storedMessages[message.conversationID, default: []].append(message)
    }

    public func branch(conversationID: UUID, at messageID: UUID, includingMessage: Bool) async throws -> Conversation {
        guard let source = conversations[conversationID] else { throw ConversationBranchError.missingMessage }
        let branch = try ConversationBranch(source: source, messages: messages(conversationID: conversationID), at: messageID, includingMessage: includingMessage)
        conversations[branch.conversation.id] = branch.conversation
        storedMessages[branch.conversation.id] = branch.messages
        return branch.conversation
    }

    public func search(_ query: String, limit: Int) -> [Conversation] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(list(includeArchived: false).prefix(max(0, limit)))
        }
        return conversations.values
            .filter { !$0.isArchived && $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }
}

public actor UserDefaultsSettingsRepository: SettingsRepository {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = "aim.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key), let decoded = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    public func save(_ settings: AppSettings) throws {
        defaults.set(try encoder.encode(settings), forKey: key)
    }
}
