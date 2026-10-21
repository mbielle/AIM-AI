import Foundation

public enum ChatExecutionTarget: Codable, Hashable, Sendable {
    case thisDevice
    case computer(machineID: String)
}

/// Identity connection is distinct from permission to consume a ChatGPT plan.
/// No commercial approval is inferred from possessing an OAuth token.
public struct ChatGPTIntegration: Codable, Equatable, Sendable {
    public enum PlanAccess: String, Codable, Sendable { case pendingApproval, notGranted, granted }
    public var accountConnected: Bool
    public var planAccess: PlanAccess
    public var integrationApproved: Bool
    public init(accountConnected: Bool = false, planAccess: PlanAccess = .pendingApproval, integrationApproved: Bool = false) {
        self.accountConnected = accountConnected; self.planAccess = planAccess; self.integrationApproved = integrationApproved
    }
    public var mayUsePlan: Bool { accountConnected && integrationApproved && planAccess == .granted }
    public static func isPlanLimit(_ text: String) -> Bool {
        text.contains("subscription_sharing_usage_limit_exceeded") || text.contains("usage_limit_reached")
    }
    public static func isPlanUnavailable(_ text: String) -> Bool { text.contains("subscription_sharing_usage_unavailable") }
}
