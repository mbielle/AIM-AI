import Foundation

public extension RemoteCapabilities.Feature {
    static let continuity = "continuity_v1"
    static let experimentalContinuity = "continuity_experimental_v1"
    static let continuityAvailable = "continuity_available_v1"
}

/// Versioned alongside the existing Remote envelope. No implicit turn, time or spend ceiling.
public struct RemoteContinuousGoalConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let maximumTurns: Int?
    public let maximumSpendUSD: String?
    public init(maximumTurns: Int? = nil, maximumSpendUSD: String? = nil) {
        version = 1; self.maximumTurns = maximumTurns; self.maximumSpendUSD = maximumSpendUSD
    }
    public var isValid: Bool {
        guard maximumTurns == nil || maximumTurns! > 0 else { return false }
        if let maximumSpendUSD {
            guard let amount = Decimal(string: maximumSpendUSD, locale: Locale(identifier: "en_US_POSIX")),
                  !amount.isNaN, amount > 0 else { return false }
        }
        return true
    }
    public var json: RemoteJSONValue {
        var value: [String: RemoteJSONValue] = ["version": .number(1), "continuous": .bool(true)]
        if let maximumTurns { value["max_turns"] = .number(Double(maximumTurns)) }
        if let maximumSpendUSD { value["max_spend_usd"] = .string(maximumSpendUSD) }
        return .object(value)
    }
}

public enum RemoteContinuityAction: String, Codable, CaseIterable, Sendable {
    case start = "goal_start", status = "goal_status", pause = "goal_pause", resume = "goal_resume"
    case cancel = "goal_cancel", correct = "goal_correct", accept = "goal_accept"
    case approval = "goal_approval_response", question = "goal_question_response"
}
public enum RemoteContinuityRules {
    public static func supported(capabilities: RemoteCapabilities?, allowingExperimental: Bool = false) -> Bool {
        capabilities?.supports(RemoteCapabilities.Feature.continuity) == true
            || (allowingExperimental && capabilities?.supports(RemoteCapabilities.Feature.experimentalContinuity) == true)
    }
    public static func goalPayload(text: String, maximumTurns: Int?, capabilities: RemoteCapabilities?) -> RemoteJSONValue? {
        guard supported(capabilities: capabilities), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let configuration = RemoteContinuousGoalConfiguration(maximumTurns: maximumTurns)
        guard configuration.isValid else { return nil }
        return .object(["text": .string(text), "goal": configuration.json])
    }
}

public struct RemoteContinuitySnapshot: Codable, Equatable, Sendable {
    public let executionID: String
    public let conversationID: String
    public let state: String
    public let revision: Int64
    public let waitingReason: String?
    public let result: String?
    public let countedUSD: String?
    public let unknownSpendAttempts: Int?
    public init?(json: RemoteJSONValue) {
        guard let value = json.objectValue, value["version"]?.numberValue == 1,
              let executionID = value["execution_id"]?.stringValue, UUID(uuidString: executionID) != nil,
              let conversationID = value["conversation_id"]?.stringValue, UUID(uuidString: conversationID) != nil,
              let state = value["state"]?.stringValue, let revisionText = value["revision"]?.stringValue,
              let revision = Int64(revisionText), revision >= 0 else { return nil }
        self.executionID = executionID; self.conversationID = conversationID; self.state = state; self.revision = revision
        waitingReason = value["waiting_reason"]?.stringValue; result = value["result"]?.stringValue
        countedUSD = value["counted_usd"]?.stringValue
        unknownSpendAttempts = value["unknown_spend_attempts"]?.numberValue.flatMap {
            $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? Int($0) : nil
        }
    }
}
