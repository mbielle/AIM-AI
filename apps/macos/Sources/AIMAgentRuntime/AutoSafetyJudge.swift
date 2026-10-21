import AIMApplication
import AIMCore
import AIMAgentKit
import Foundation

/// Auto's second opinion for doubtful commands: Jev when the person saved a TypeSafe key,
/// otherwise the cheapest connected model at low effort, charged to the same spending limit.
/// Any failure returns nil, and the person is asked.
struct RuntimeAutoSafetyJudge: AutoSafetyJudging {
    let secureStore: any SecureStoring
    let meter: BillableRequestMeter
    let conversationID: UUID
    var timeout: Duration = .seconds(25)

    func judge(command: String, workspace: String?, doubt: String) async -> AutoSafetyJudgement? {
        await withTaskGroup(of: AutoSafetyJudgement?.self) { group in
            group.addTask { await answer(command: command, workspace: workspace, doubt: doubt) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func answer(command: String, workspace: String?, doubt: String) async -> AutoSafetyJudgement? {
        guard !RuntimePrivacyPolicy.isEnabled else { return nil }
        if let key = jevKey(), let value = try? await jev(command: command, workspace: workspace, doubt: doubt, key: key) { return value }
        return try? await model(command: command, workspace: workspace, doubt: doubt)
    }

    private func jevKey() -> String? {
        guard let data = try? secureStore.readData(forKey: JevDecisionClient.keychainKey),
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    private static func situation(command: String, workspace: String?, doubt: String) -> String {
        """
        An AI coding agent wants to run a shell command on the person's Mac in "Auto" mode, where safe commands run without asking.
        Working folder chosen by the person: \(workspace ?? "none")
        Command: \(String(command.prefix(4_000)))
        Local rules were unsure because: \(doubt)
        """
    }

    // MARK: Jev

    static func jevRequest(command: String, workspace: String?, doubt: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: JevDecisionClient.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": "jev-latest", "state": situation(command: command, workspace: workspace, doubt: doubt), "questions": [
            "verdict": ["type": "choice", "instructions": "Can this command run without asking the person?",
                        "criteria": ["safe": "Harmless: reads, builds, tests or changes files only inside the working folder, and is easy to undo",
                                     "risky": "Could delete or overwrite data, leak secrets or files, act on other machines or accounts, or be hard to undo"]]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func jevJudgement(_ data: Data, doubt: String) throws -> AutoSafetyJudgement {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = (root["answers"] as? [String: Any])?["verdict"] as? [String: Any],
              let probabilities = verdict["probabilities"] as? [String: Double], let safe = probabilities["safe"] else { throw ChatServiceError.invalidResponse }
        return AutoSafetyJudgement(safe: safe >= 0.5, confidence: safe, reason: doubt, judge: "Jev")
    }

    private func jev(command: String, workspace: String?, doubt: String, key: String) async throws -> AutoSafetyJudgement {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 15
        let session = AIMManagedNetworkSession.make(configuration: configuration)
        let (data, response) = try await session.data(for: Self.jevRequest(command: command, workspace: workspace, doubt: doubt, key: key))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatServiceError.invalidResponse }
        return try Self.jevJudgement(data, doubt: doubt)
    }

    // MARK: Small model

    private func model(command: String, workspace: String?, doubt: String) async throws -> AutoSafetyJudgement {
        let catalogs = await SubagentRecommendation.connectedCatalogs(secureStore: secureStore)
        let candidates = SubagentModelAdvisor.candidates(catalogs, request: .init(task: "Judge whether a shell command is safe", size: .small), limit: 8)
        // Free routes are rate-limited and often unavailable: prefer the cheapest priced one.
        guard let choice = candidates.first(where: { ($0.inputPerMillion ?? 0) > 0 }) ?? candidates.first else { throw ModelToolError.invalidConfiguration }
        let key = choice.provider == .local ? "" : try await RuntimeProviderCredentials.reader(provider: choice.provider, store: secureStore)()
        let prompt = Self.situation(command: command, workspace: workspace, doubt: doubt) + """

        Answer with JSON only: {"safe": true or false, "confidence": number from 0 to 1, "reason": "one short sentence for the person"}.
        "safe" means it can run without asking: it only reads, builds, tests or changes files inside the working folder and is easy to undo.
        """
        let conversation = try ProviderToolConversation(provider: choice.provider, modelID: choice.model.id,
            messages: [ConversationMessage(conversationID: conversationID, role: .user, content: prompt, sequence: 0)],
            apiKey: key, tools: [], openAIReasoningEffort: OpenAIReasoningEffort.applies(to: choice.provider) ? .low : nil,
            meter: meter, billingFeature: "safety_check")
        let turn = try await conversation.next(outputs: [])
        return try Self.modelJudgement(turn.text, judge: choice.model.name.isEmpty ? choice.model.id : choice.model.name)
    }

    static func modelJudgement(_ text: String, judge: String) throws -> AutoSafetyJudgement {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let safe = object["safe"] as? Bool else { throw ChatServiceError.invalidResponse }
        let confidence = min(1, max(0, (object["confidence"] as? Double) ?? (object["confidence"] as? Int).map(Double.init) ?? 0))
        let reason = ((object["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AutoSafetyJudgement(safe: safe, confidence: confidence, reason: String(reason.prefix(300)), judge: judge)
    }
}
