import Foundation

public enum ProviderHistory {
    /// A cancelled or failed fragment stays visible locally but must not be
    /// presented to a later model as an authoritative completed reply.
    public static func completedContext(_ messages: [ConversationMessage]) -> [ConversationMessage] {
        messages.filter { $0.role != .assistant || $0.completionStatus == nil }
    }
}
