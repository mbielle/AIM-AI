import Foundation

/// One model a sub-agent could run on: only routes whose key or plan is connected (or local
/// models already installed) are ever proposed.
public struct SubagentCandidate: Codable, Hashable, Sendable {
    public var provider: ChatProvider
    public var model: ChatModel
    public var suggestedEffort: String?
    public var reason: String
    /// Jev's probability that this is the best choice, when it ranked the list.
    public var probability: Double?

    public var inputPerMillion: Double? { provider == .local ? 0 : model.pricing?.inputPerMillion }
    public var outputPerMillion: Double? { provider == .local ? 0 : model.pricing?.outputPerMillion }
    /// A blended per-million price (output counted four times), for ordering only.
    var weight: Double? { inputPerMillion.flatMap { input in outputPerMillion.map { input + 4 * $0 } } }
}

public struct SubagentModelRequest: Sendable {
    public enum Size: String, Sendable, CaseIterable { case small, medium, large }
    public var task: String
    public var size: Size
    public var needsVision: Bool
    public var needsLongContext: Bool
    public init(task: String, size: Size = .medium, needsVision: Bool = false, needsLongContext: Bool = false) {
        self.task = task; self.size = size; self.needsVision = needsVision; self.needsLongContext = needsLongContext
    }
}

/// Proposes up to four sub-agent models without any model call: models able to use tools,
/// filtered by the task's needs, one route per model identity, spread by price according
/// to the declared size of the task. The parent agent still makes the choice.
public enum SubagentModelAdvisor {
    public static func candidates(_ catalogs: [ChatProvider: [ChatModel]], request: SubagentModelRequest, limit: Int = 4) -> [SubagentCandidate] {
        var byIdentity: [String: SubagentCandidate] = [:]
        for (provider, models) in catalogs {
            // An undisclosed capability is not a refusal: only explicit catalog facts exclude a model.
            for model in models where model.isChatModel && (provider == .local || model.supportedParameters == nil || model.capabilities.contains(.tools)) {
                if request.needsVision, model.supportsImageInput == false { continue }
                if request.needsLongContext, (model.contextLength ?? model.topProvider?.contextLength ?? 0) < 200_000 { continue }
                let candidate = SubagentCandidate(provider: provider, model: model, suggestedEffort: effort(model, size: request.size, provider: provider), reason: "")
                let identity = CanonicalModelRouting.identity(model.id, provider: provider.rawValue)
                if let existing = byIdentity[identity],
                   CanonicalModelRouting.rank(existing.provider.rawValue) <= CanonicalModelRouting.rank(provider.rawValue) { continue }
                byIdentity[identity] = candidate
            }
        }
        // Unknown prices stay proposable but after priced routes, so a cost is never assumed to be zero.
        let ordered = byIdentity.values.sorted { left, right in
            switch (left.weight, right.weight) {
            case let (l?, r?): return l == r ? left.model.id < right.model.id : l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.model.id < right.model.id
            }
        }
        guard !ordered.isEmpty else { return [] }
        let count = min(limit, ordered.count)
        let start: Int
        switch request.size {
        case .small: start = 0
        case .medium: start = max(0, min(ordered.count - count, ordered.count / 2 - count / 2))
        case .large: start = ordered.count - count
        }
        var picked = Array(ordered[start..<(start + count)])
        if request.size == .large { picked.reverse() }
        return picked.map { candidate in
            var value = candidate
            value.reason = reason(candidate, size: request.size)
            return value
        }
    }

    /// The effort to suggest: low for small tasks, medium, then high, among the levels the
    /// catalog lists for this model; nil when the model has no effort setting.
    static func effort(_ model: ChatModel, size: SubagentModelRequest.Size, provider: ChatProvider) -> String? {
        let wanted = ["small": "low", "medium": "medium", "large": "high"][size.rawValue]!
        if let levels = model.reasoning?.supportedEfforts, !levels.isEmpty {
            return levels.contains(wanted) ? wanted : levels.first { ["low", "medium", "high"].contains($0) } ?? levels.first
        }
        return model.capabilities.contains(.reasoning) ? wanted : nil
    }

    private static func reason(_ candidate: SubagentCandidate, size: SubagentModelRequest.Size) -> String {
        if candidate.provider == .local { return "Runs on this Mac at no provider cost; uses its memory and is slower than hosted models." }
        guard candidate.weight != nil else { return "Price not published for this route; the spending limit still applies." }
        switch size {
        case .small: return "Among the cheapest connected models able to use tools."
        case .medium: return "Mid-priced connected model, balancing cost and capability."
        case .large: return "Among the most capable (and expensive) connected models."
        }
    }

    /// The list given to the parent agent, one line per candidate.
    public static func render(_ candidates: [SubagentCandidate], rankedBy: String) -> String {
        guard !candidates.isEmpty else {
            return "No connected model can run a sub-agent with these needs. Delegate without a model to use your own, or ask the person to connect a provider."
        }
        func price(_ value: Double?) -> String { value.map { $0 == 0 ? "$0" : String(format: "$%.2f", $0) } ?? "unknown" }
        let lines = candidates.enumerated().map { index, item in
            var parts = ["\(index + 1). provider=\(item.provider.rawValue) model=\(item.model.id)",
                         "input \(price(item.inputPerMillion))/M, output \(price(item.outputPerMillion))/M"]
            if let context = item.model.contextLength ?? item.model.topProvider?.contextLength { parts.append("context \(context / 1000)k") }
            var capabilities = ["tools"]
            if item.model.supportsImageInput == true { capabilities.append("vision") }
            if item.model.capabilities.contains(.reasoning) { capabilities.append("reasoning") }
            parts.append(capabilities.joined(separator: "+"))
            if let effort = item.suggestedEffort { parts.append("suggested effort=\(effort)") }
            if let probability = item.probability { parts.append(String(format: "fit %.0f%%", probability * 100)) }
            return parts.joined(separator: " · ") + " — " + item.reason
        }
        return "Sub-agent candidates (\(rankedBy)); pass provider, model and effort to delegate_task. An explicit instruction from the person about models always wins.\n" + lines.joined(separator: "\n")
    }
}

/// TypeSafe's Jev decision model, used only to rank the candidates above when the person
/// saved a key. One request per recommendation; the answer is a probability per candidate.
public struct JevDecisionClient: Sendable {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// Where the person's TypeSafe key is kept in AIM's provider keychain.
    public static let keychainKey = "typesafe.jev"
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 15
            self.session = AIMManagedNetworkSession.make(configuration: configuration)
        }
    }

    public static func request(_ candidates: [SubagentCandidate], task: SubagentModelRequest, key: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var criteria: [String: String] = [:]
        for (index, item) in candidates.enumerated() {
            criteria["c\(index + 1)"] = SubagentModelAdvisor.render([item], rankedBy: "").components(separatedBy: "\n").last ?? item.model.id
        }
        let state = "A coding agent must delegate this task to a sub-agent model.\nTask (\(task.size.rawValue)): " + String(task.task.prefix(6_000))
            + (task.needsVision ? "\nThe task needs image input." : "") + (task.needsLongContext ? "\nThe task needs a long context." : "")
        let body: [String: Any] = ["model": "jev-latest", "state": state, "questions": [
            "best": ["type": "choice", "instructions": "Which candidate model completes this task well at the lowest reasonable cost?", "criteria": criteria],
            "effort": ["type": "choice", "instructions": "How much reasoning effort does this task need?",
                       "criteria": ["low": "Simple lookup or mechanical change", "medium": "Ordinary multi-step work", "high": "Hard reasoning, design or debugging"]]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The candidates reordered by Jev's probabilities, with its effort when a candidate offers one.
    public static func ranked(_ candidates: [SubagentCandidate], response data: Data) throws -> [SubagentCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let best = answers["best"] as? [String: Any],
              let probabilities = best["probabilities"] as? [String: Double] else { throw ChatServiceError.invalidResponse }
        let effort = (answers["effort"] as? [String: Any])?["choice"] as? String
        return candidates.enumerated().map { index, item -> SubagentCandidate in
            var value = item
            value.probability = probabilities["c\(index + 1)"] ?? 0
            if let effort, value.suggestedEffort != nil, value.model.reasoning?.supportedEfforts.map({ $0.contains(effort) }) ?? true { value.suggestedEffort = effort }
            return value
        }.sorted { ($0.probability ?? 0) > ($1.probability ?? 0) }
    }

    public func rank(_ candidates: [SubagentCandidate], task: SubagentModelRequest, key: String) async throws -> [SubagentCandidate] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        let (data, response) = try await session.data(for: try Self.request(candidates, task: task, key: key))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatServiceError.invalidResponse }
        return try Self.ranked(candidates, response: data)
    }
}
