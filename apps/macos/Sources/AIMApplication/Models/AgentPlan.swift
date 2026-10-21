import Foundation

public enum AgentPlanStepStatus: String, Codable, Equatable, Sendable {
    case todo, doing, done
}

public struct AgentPlanStep: Codable, Equatable, Sendable {
    public var title: String
    public var status: AgentPlanStepStatus
    /// How the agent will know this step is finished (a check, an output, a file).
    public var doneWhen: String?
    public init(title: String, status: AgentPlanStepStatus, doneWhen: String? = nil) {
        self.title = title; self.status = status; self.doneWhen = doneWhen
    }

    enum CodingKeys: String, CodingKey {
        case title, status
        case doneWhen = "done_when"
    }
}

public struct AgentPlan: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var steps: [AgentPlanStep]
    public var updatedAt: Date
    public init(conversationID: UUID, steps: [AgentPlanStep], updatedAt: Date = .now) {
        self.conversationID = conversationID; self.steps = steps; self.updatedAt = updatedAt
    }
}
