import AIMApplication
import AIMCore
import AIMAgentKit
import Foundation

/// recommend_subagent_models: connected routes (a key, a plan or an installed local model)
/// from the cached catalogs, completed with OpenRouter's public facts, chosen without any model
/// call; then ranked by Jev only when the person saved a TypeSafe key.
enum SubagentRecommendation {
    static func make(secureStore: any SecureStoring, jev: JevDecisionClient = JevDecisionClient()) -> @Sendable (SubagentModelRequest) async -> String {
        { request in
            let catalogs = await connectedCatalogs(secureStore: secureStore)
            var candidates = SubagentModelAdvisor.candidates(catalogs, request: request)
            var ranking = "chosen by price and task size, no model call"
            if candidates.count > 1, let data = try? secureStore.readData(forKey: JevDecisionClient.keychainKey),
               let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                do { candidates = try await jev.rank(candidates, task: request, key: key); ranking = "ranked by Jev" }
                catch { ranking = "chosen by price and task size; Jev did not answer" }
            }
            return SubagentModelAdvisor.render(candidates, rankedBy: ranking)
        }
    }

    /// Cached catalogs of the routes this person can use (a key, a plan or an installed local model).
    static func connectedCatalogs(secureStore: any SecureStoring) async -> [ChatProvider: [ChatModel]] {
        let reference = ModelCatalogDetails.index(await ModelCatalogCache.shared.cached(.openRouter) ?? [])
        var catalogs: [ChatProvider: [ChatModel]] = [:]
        for provider in ChatProvider.allCases where provider.supportsWorkspaceTools {
            guard let models = await ModelCatalogCache.shared.cached(provider), !models.isEmpty else { continue }
            if provider != .local {
                guard let key = try? await RuntimeProviderCredentials.reader(provider: provider, store: secureStore)(), !key.isEmpty else { continue }
            }
            catalogs[provider] = models.map { ModelCatalogDetails.enriched($0, provider: provider, index: reference) }
        }
        return catalogs
    }
}

extension AgentSubagentPool {
    /// The delegation tools a parent agent is offered, all executed by `pool`. Every name must be
    /// in `supportedTools`, or the dispatcher refuses to start the run.
    nonisolated static func parentTools(_ pool: AgentSubagentPool, writes: Bool) -> [RegisteredTool] {
        var tools: [RegisteredTool] = []
        if writes {
            tools += [
                RegisteredTool(name: "review_subagent_changes", risk: .readOnly,
                    requiredArguments: ["job_id"], executor: pool),
                RegisteredTool(name: "merge_subagent_changes", risk: .localMutation,
                    requiredArguments: ["job_id"], executor: pool),
                RegisteredTool(name: "discard_subagent_changes", risk: .localMutation,
                    requiredArguments: ["job_id"], executor: pool)
            ]
        }
        tools += [
            RegisteredTool(name: "delegate_task", risk: .delegation,
                requiredArguments: ["title", "prompt"],
                optionalArguments: Set(["machine_id", "provider", "model", "effort", "profile", "depends_on", "result_keys"] + (writes ? ["mode"] : [])),
                argumentKinds: ["depends_on": .array, "result_keys": .array], executor: pool),
            RegisteredTool(name: "message_subagent", risk: .readOnly,
                requiredArguments: ["job_id", "text"], approvalExempt: true, executor: pool),
            RegisteredTool(name: "recommend_subagent_models", risk: .readOnly,
                requiredArguments: ["task"], optionalArguments: ["size", "needs"],
                argumentKinds: ["needs": .array], approvalExempt: true, executor: pool),
            RegisteredTool(name: "await_subagents", risk: .readOnly,
                optionalArguments: ["offset", "limit", "timeout_seconds"],
                argumentKinds: ["offset": .integer, "limit": .integer,
                                "timeout_seconds": .integer],
                approvalExempt: true, executor: pool),
            RegisteredTool(name: "list_subagents", risk: .readOnly,
                optionalArguments: ["offset", "limit"],
                argumentKinds: ["offset": .integer, "limit": .integer],
                approvalExempt: true, executor: pool),
            RegisteredTool(name: "cancel_subagent", risk: .delegation,
                requiredArguments: ["job_id"], executor: pool),
            RegisteredTool(name: "retry_subagent", risk: .delegation,
                requiredArguments: ["job_id"], executor: pool)
        ]
        return tools
    }
}
