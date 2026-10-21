import Foundation

public struct ToolReview: Codable, Sendable, Equatable {
    public let path: String
    public let before: String
    public let after: String
    public let beforeExists: Bool
    public let afterExists: Bool
    public init(path: String, before: String, after: String, beforeExists: Bool = true, afterExists: Bool = true) {
        self.path = path; self.before = before; self.after = after
        self.beforeExists = beforeExists; self.afterExists = afterExists
    }
}

/// Host-owned review content, never accepted from model-supplied approval text.
public protocol ToolReviewProviding: ToolExecutor {
    func review(_ request: ToolRequest) async throws -> ToolReview?
}
