import Foundation

/// AIM does not invent an output quota. Optional limits belong to the provider
/// unless the person explicitly chooses one. Messages requires a positive
/// max_tokens: use the model's published capacity, never a generic fallback.
public enum ModelOutputPolicy {
    public static func resolve(provider: ChatProvider, modelID: String, catalogMaximum: Int? = nil,
                               userLimit: Int? = nil, thinkingBudget: Int? = nil) throws -> Int? {
        guard !modelID.isEmpty, catalogMaximum.map({ $0 > 0 }) ?? true,
              userLimit.map({ $0 > 0 }) ?? true, thinkingBudget.map({ $0 > 0 }) ?? true else {
            throw ModelOutputPolicyError.invalidLimit
        }
        if let userLimit, let catalogMaximum, userLimit > catalogMaximum {
            throw ModelOutputPolicyError.exceedsModelCapacity
        }
        let result = userLimit ?? (provider == .anthropic ? catalogMaximum : nil)
        if provider == .anthropic, result == nil { throw ModelOutputPolicyError.modelCapacityUnknown }
        if let thinkingBudget, let result, thinkingBudget >= result {
            throw ModelOutputPolicyError.thinkingBudgetExceedsOutput
        }
        return result
    }
}

public enum ModelOutputPolicyError: LocalizedError, Equatable, Sendable {
    case invalidLimit, exceedsModelCapacity, modelCapacityUnknown, thinkingBudgetExceedsOutput
    public var errorDescription: String? {
        switch self {
        case .invalidLimit: "The model output limit must be a positive token count."
        case .exceedsModelCapacity: "The selected output limit exceeds this model's published capacity."
        case .modelCapacityUnknown: "AIM could not verify this model's required output capacity. Refresh the model catalog or choose an explicit output limit."
        case .thinkingBudgetExceedsOutput: "The thinking budget must be smaller than the selected output limit. Change the explicit output limit or reasoning setting."
        }
    }
}
