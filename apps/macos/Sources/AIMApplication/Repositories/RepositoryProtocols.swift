import Foundation

public protocol ConversationRepository: Sendable {
    func list(includeArchived: Bool) async throws -> [Conversation]
    func conversation(id: UUID) async throws -> Conversation?
    func save(_ conversation: Conversation) async throws
    func delete(id: UUID) async throws
    func messages(conversationID: UUID) async throws -> [ConversationMessage]
    func message(conversationID: UUID, sequence: Int) async throws -> ConversationMessage?
    func append(_ message: ConversationMessage) async throws
    func appendPair(_ first: ConversationMessage, _ second: ConversationMessage) async throws
    func branch(conversationID: UUID, at messageID: UUID, includingMessage: Bool) async throws -> Conversation
    func search(_ query: String, limit: Int) async throws -> [Conversation]
    func searchHits(_ query: String, limit: Int) async throws -> [ConversationSearchHit]
    func searchHits(_ query: String, projectID: UUID?, limit: Int) async throws -> [ConversationSearchHit]
    /// Conversations containing the query's words (not the exact phrase), in every project,
    /// those of `projectID` first.
    func searchHits(words query: String, preferring projectID: UUID?, limit: Int) async throws -> [ConversationSearchHit]
}

public extension ConversationRepository {
    func message(conversationID: UUID, sequence: Int) async throws -> ConversationMessage? {
        try await messages(conversationID: conversationID).first { $0.sequence == sequence }
    }
    func appendPair(_ first: ConversationMessage, _ second: ConversationMessage) async throws {
        try await append(first)
        try await append(second)
    }
    func searchHits(_ query: String, limit: Int) async throws -> [ConversationSearchHit] {
        try await search(query, limit: limit).map { ConversationSearchHit(conversation: $0) }
    }
    func searchHits(_ query: String, projectID: UUID?, limit: Int) async throws -> [ConversationSearchHit] {
        try await searchHits(query, limit: 100).filter { $0.conversation.projectID == projectID }.prefix(max(0, limit)).map { $0 }
    }
    func branch(conversationID: UUID, at messageID: UUID, includingMessage: Bool) async throws -> Conversation {
        throw ConversationBranchError.unsupported
    }
    func searchHits(words query: String, preferring projectID: UUID?, limit: Int) async throws -> [ConversationSearchHit] {
        try await searchHits(query, limit: limit)
    }
}

public protocol ProjectRepository: Sendable {
    func list() async throws -> [AIMProject]
    func save(_ project: AIMProject) async throws
    func delete(id: UUID) async throws
    func sources(projectID: UUID) async throws -> [ProjectSource]
    func save(source: ProjectSource) async throws
    func deleteSource(id: UUID) async throws
}

public protocol MemoryRepository: Sendable {
    func list(status: MemoryStatus?) async throws -> [MemoryItem]
    func save(_ item: MemoryItem) async throws
    func archive(id: UUID) async throws
    func consolidateDuplicates(keeping: UUID, archiving: [UUID]) async throws
    func delete(id: UUID) async throws
    func search(_ query: String, limit: Int) async throws -> [MemoryItem]
    /// Apply the visibility scope inside the local search, before limiting results.
    func searchScoped(_ query: String, projectID: UUID?, includeGlobal: Bool,
                      limit: Int) async throws -> [MemoryItem]
    /// What a request's context may draw on: the person's profile and the entries matching the
    /// query, within the scope and only while memory is on.
    func contextCandidates(_ query: String, projectID: UUID?, includeGlobal: Bool) async throws -> [MemoryItem]
}

public extension MemoryRepository {
    func contextCandidates(_ query: String, projectID: UUID?, includeGlobal: Bool) async throws -> [MemoryItem] {
        try await searchScoped(query, projectID: projectID, includeGlobal: includeGlobal, limit: 32)
    }
}

public protocol AgentPlanRepository: Sendable {
    func load(conversationID: UUID) async throws -> AgentPlan?
    func save(_ plan: AgentPlan) async throws
}

public protocol SchedulerRepository: Sendable {
    func list() async throws -> [ScheduledTask]
    func due(before date: Date) async throws -> [ScheduledTask]
    func save(_ task: ScheduledTask) async throws
    func delete(id: UUID) async throws
}

public protocol ActivityRepository: Sendable {
    func record(_ entry: ActivityEntry) async throws
    func search(_ query: String, since: Date?, until: Date?, limit: Int) async throws -> [ActivityEntry]
    func purge(olderThan date: Date) async throws -> Int
}

public protocol SettingsRepository: Sendable {
    func load() async throws -> AppSettings
    func save(_ settings: AppSettings) async throws
}

public extension MemoryRepository {
    func consolidateDuplicates(keeping: UUID, archiving: [UUID]) async throws { throw MemoryConsolidationError.unsupportedRepository }
}
public enum MemoryConsolidationError: Error { case unsupportedRepository, staleProposal }
