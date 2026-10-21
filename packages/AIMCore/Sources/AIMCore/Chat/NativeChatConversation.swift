import Foundation

public struct NativeChatTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var usage: TokenUsage
    public var estimatedUSD: Double?
    public var completedAt: Date?
    public init(id: UUID, usage: TokenUsage = .init(), estimatedUSD: Double? = nil, completedAt: Date? = nil) {
        self.id = id; self.usage = usage; self.estimatedUSD = estimatedUSD; self.completedAt = completedAt
    }
}
public struct NativeChatConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var provider: ChatProvider
    public var modelID: String
    public var messages: [NativeChatMessage]
    public var turns: [NativeChatTurn]
    public var projectID: String?
    public var updatedAt: Date
    public var lastTurnStatus: String?
    public var executionDeviceIDs: [String]?
    public var latestResponseVersion: ConversationResponseVersion?
    public init(id: UUID = UUID(), title: String, provider: ChatProvider, modelID: String, messages: [NativeChatMessage] = [],
                turns: [NativeChatTurn] = [], projectID: String? = nil, updatedAt: Date = .now, executionDeviceIDs: [String]? = nil, latestResponseVersion: ConversationResponseVersion? = nil, lastTurnStatus: String? = nil) {
        self.id = id; self.title = title; self.provider = provider; self.modelID = modelID; self.messages = messages
        self.turns = turns; self.projectID = projectID; self.updatedAt = updatedAt
        self.executionDeviceIDs = executionDeviceIDs; self.latestResponseVersion = latestResponseVersion; self.lastTurnStatus = lastTurnStatus
    }
    /// Completed/partial messages are identified by UUID, so repeated synchronization does not count a turn twice.
    public func merging(_ other: Self) -> Self {
        guard id == other.id else { return self }
        var result = updatedAt >= other.updatedAt ? self : other
        var messagesByID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.text.count >= b.text.count ? a : b })
        for message in other.messages {
            if var old = messagesByID[message.id], old.text.count >= message.text.count {
                old.visualReport = old.visualReport ?? message.visualReport
                old.actions = ConversationAction.merge(old.actions, message.actions)
                old.sources = ConversationSource.merge(old.sources, message.sources)
                old.routeAttempts = ConversationRouteAttempt.merge(old.routeAttempts, message.routeAttempts)
                old.timeline = TurnTimeline.merge(old.timeline, message.timeline)
                old.skillActivities = old.skillActivities ?? message.skillActivities
                old.attachments = Self.mergeAttachments(old.attachments, message.attachments)
                if old.webSearchUsage == nil { old.webSearchUsage = message.webSearchUsage }
                if old.webSearchActivities == nil { old.webSearchActivities = message.webSearchActivities }
                messagesByID[message.id] = old
            } else {
                var updated = message
                updated.visualReport = updated.visualReport ?? messagesByID[message.id]?.visualReport
                updated.actions = ConversationAction.merge(updated.actions, messagesByID[message.id]?.actions)
                updated.sources = ConversationSource.merge(updated.sources, messagesByID[message.id]?.sources)
                updated.routeAttempts = ConversationRouteAttempt.merge(messagesByID[message.id]?.routeAttempts, updated.routeAttempts)
                updated.timeline = TurnTimeline.merge(messagesByID[message.id]?.timeline, updated.timeline)
                updated.skillActivities = updated.skillActivities ?? messagesByID[message.id]?.skillActivities
                updated.attachments = Self.mergeAttachments(updated.attachments, messagesByID[message.id]?.attachments)
                if updated.webSearchUsage == nil { updated.webSearchUsage = messagesByID[message.id]?.webSearchUsage }
                if updated.webSearchActivities == nil { updated.webSearchActivities = messagesByID[message.id]?.webSearchActivities }
                messagesByID[message.id] = updated
            }
        }
        result.messages = messagesByID.values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        var turnsByID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { a, b in b.completedAt != nil ? b : a })
        for turn in other.turns { if turnsByID[turn.id]?.completedAt == nil || turn.completedAt != nil { turnsByID[turn.id] = turn } }
        result.turns = turnsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        if executionDeviceIDs != nil || other.executionDeviceIDs != nil {
            result.executionDeviceIDs = Array(Set((executionDeviceIDs ?? []) + (other.executionDeviceIDs ?? []))).sorted()
        }
        result.latestResponseVersion = [latestResponseVersion, other.latestResponseVersion].compactMap { $0 }.max { $0.completedAt == $1.completedAt ? $0.id < $1.id : $0.completedAt < $1.completedAt }
        return result
    }
    private static func mergeAttachments(_ left: [NativeChatAttachment]?, _ right: [NativeChatAttachment]?) -> [NativeChatAttachment]? {
        guard left != nil || right != nil else { return nil }
        var values = left ?? []
        for value in right ?? [] where !values.contains(where: { $0.id == value.id }) { values.append(value) }
        return values
    }

}
