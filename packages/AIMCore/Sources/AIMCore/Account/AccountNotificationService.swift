import Foundation
import Supabase

public enum AIMNotificationCategory: String, Codable, CaseIterable, Sendable {
    case response, task, question, approval, failure
    public var title: String {
        switch self { case .response: "Response ready"; case .task: "Task completed"; case .question: "Question for you"; case .approval: "Approval requested"; case .failure: "Intervention needed" }
    }
}
public struct AccountNotificationEvent: Decodable, Sendable {
    public let id: UUID
    public let conversation: UUID
    public let category: AIMNotificationCategory
    public let created_at: String
    public init(id: UUID, conversation: UUID, category: AIMNotificationCategory, createdAt: String) {
        self.id = id; self.conversation = conversation; self.category = category; self.created_at = createdAt
    }
    public var date: Date? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: created_at) ?? ISO8601DateFormatter().date(from: created_at)
    }
}
public struct AccountNotificationCursor: Codable, Equatable, Sendable {
    // Preserve the server's full timestamp precision; never derive this cursor from the device clock.
    public let createdAt: String
    public let eventID: UUID
    public init(createdAt: String, eventID: UUID) { self.createdAt = createdAt; self.eventID = eventID }
    enum CodingKeys: String, CodingKey { case createdAt = "created_at", eventID = "id" }
}
public struct AccountNotificationPage: Decodable, Sendable {
    public let events: [AccountNotificationEvent]
    public let cursor: AccountNotificationCursor?
    public let hasMore: Bool
    public init(events: [AccountNotificationEvent], cursor: AccountNotificationCursor?, hasMore: Bool) {
        self.events = events; self.cursor = cursor; self.hasMore = hasMore
    }
    enum CodingKeys: String, CodingKey { case events, cursor, hasMore = "has_more" }
}
public protocol AccountNotificationServicing: Sendable {
    func register(installation: UUID, token: String, topic: String, environment: String, categories: [AIMNotificationCategory]) async throws
    func presence(installation: UUID, foreground: Bool, conversation: UUID?) async throws
    func unregister(installation: UUID) async throws
    func notify(accountID: UUID, event: UUID, task: UUID, conversation: UUID, category: AIMNotificationCategory) async throws
    func eventPage(after: AccountNotificationCursor?, overlap: Bool) async throws -> AccountNotificationPage
}
public actor AccountNotificationService: AccountNotificationServicing {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }
    public func register(installation: UUID, token: String, topic: String, environment: String, categories: [AIMNotificationCategory]) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do { try await client.rpc("aim_register_push", params: Registration(p_installation: installation, p_token: token, p_topic: topic, p_environment: environment, p_categories: categories.map(\.rawValue))).execute() }
        catch { throw AccountSessionService.failure(error) }
    }
    public func presence(installation: UUID, foreground: Bool, conversation: UUID?) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do { try await client.rpc("aim_push_presence", params: Presence(p_installation: installation, p_foreground: foreground, p_conversation: conversation)).execute() }
        catch { throw AccountSessionService.failure(error) }
    }
    public func unregister(installation: UUID) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        try await client.rpc("aim_unregister_push", params: Unregistration(p_installation: installation)).execute()
    }
    public func notify(accountID: UUID, event: UUID, task: UUID, conversation: UUID, category: AIMNotificationCategory) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let _: RemoteJSONValue = try await client.functions.invoke("aim-push", options: .init(body: Event(account: accountID, event: event, task: task, conversation: conversation, category: category.rawValue)))
    }
    public func events(since: Date?) async throws -> [AccountNotificationEvent] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        return try await client.rpc("aim_push_events_since", params: Cursor(p_after: since.map { ISO8601DateFormatter().string(from: $0) })).execute().value
    }
    public func eventPage(after cursor: AccountNotificationCursor?, overlap: Bool = true) async throws -> AccountNotificationPage {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        do {
            return try await client.rpc("aim_push_event_page", params: PageCursor(p_created_at: cursor?.createdAt, p_event_id: cursor?.eventID, p_overlap: overlap)).execute().value
        } catch { throw AccountSessionService.failure(error) }
    }
    private struct PageCursor: Encodable { let p_created_at: String?; let p_event_id: UUID?; let p_overlap: Bool }
    private struct Registration: Encodable { let p_installation: UUID; let p_token, p_topic, p_environment: String; let p_categories: [String] }
    private struct Presence: Encodable { let p_installation: UUID; let p_foreground: Bool; let p_conversation: UUID? }
    private struct Unregistration: Encodable { let p_installation: UUID }
    private struct Event: Encodable { let account, event, task, conversation: UUID; let category: String }
    private struct Cursor: Encodable { let p_after: String? }
}
