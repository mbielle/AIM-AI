import Foundation

/// Providers with an OpenAI-compatible API (chat completions, `/models`, Bearer key): one
/// table instead of a special case each. They share the chat-completions path of OpenRouter
/// and DeepSeek for chat, Agent tools, measurements and titles.
public struct CompatibleProviderSpec: Sendable {
    public let name: String
    /// Base URL ending before `/chat/completions` and `/models`.
    public let baseURL: String
    public let keyURL: String
    /// The LobeHub logo name (Resources/ModelLogos/logo-<name>.png), or a GitHub org avatar.
    public let logo: String
    public let supportsTools: Bool
    public let group: Group

    public enum Group: String, Sendable, CaseIterable {
        case fast = "Fast inference", open = "Open models", platforms = "Platforms"
    }
}

public enum CompatibleProviders {
    public static func spec(_ provider: ChatProvider) -> CompatibleProviderSpec? { table[provider] }

    static let table: [ChatProvider: CompatibleProviderSpec] = [
        .mistral: .init(name: "Mistral", baseURL: "https://api.mistral.ai/v1", keyURL: "https://console.mistral.ai/api-keys",
                        logo: "mistral", supportsTools: true, group: .open),
        .groq: .init(name: "Groq", baseURL: "https://api.groq.com/openai/v1", keyURL: "https://console.groq.com/keys",
                     logo: "groq", supportsTools: true, group: .fast),
        .together: .init(name: "Together AI", baseURL: "https://api.together.xyz/v1", keyURL: "https://api.together.ai/settings/api-keys",
                         logo: "together", supportsTools: true, group: .platforms),
        .fireworks: .init(name: "Fireworks", baseURL: "https://api.fireworks.ai/inference/v1", keyURL: "https://fireworks.ai/account/api-keys",
                          logo: "fireworks", supportsTools: true, group: .platforms),
        .cerebras: .init(name: "Cerebras", baseURL: "https://api.cerebras.ai/v1", keyURL: "https://cloud.cerebras.ai/platform",
                         logo: "cerebras", supportsTools: true, group: .fast),
        .moonshot: .init(name: "Moonshot (Kimi)", baseURL: "https://api.moonshot.ai/v1", keyURL: "https://platform.moonshot.ai/console/api-keys",
                         logo: "kimi", supportsTools: true, group: .open),
        .zai: .init(name: "Z.ai (GLM)", baseURL: "https://api.z.ai/api/paas/v4", keyURL: "https://z.ai/manage-apikey/apikey-list",
                    logo: "zai", supportsTools: true, group: .open),
        .qwen: .init(name: "Alibaba Qwen", baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                     keyURL: "https://bailian.console.alibabacloud.com/?apiKey=1", logo: "qwen", supportsTools: true, group: .open),
        .minimax: .init(name: "MiniMax", baseURL: "https://api.minimax.io/v1",
                        keyURL: "https://platform.minimax.io/user-center/basic-information/interface-key", logo: "minimax", supportsTools: true, group: .open),
        .cohere: .init(name: "Cohere", baseURL: "https://api.cohere.ai/compatibility/v1", keyURL: "https://dashboard.cohere.com/api-keys",
                       logo: "cohere", supportsTools: true, group: .open),
        .huggingface: .init(name: "Hugging Face", baseURL: "https://router.huggingface.co/v1", keyURL: "https://huggingface.co/settings/tokens",
                            logo: "huggingface", supportsTools: true, group: .platforms),
        .nvidia: .init(name: "Nvidia NIM", baseURL: "https://integrate.api.nvidia.com/v1", keyURL: "https://build.nvidia.com/settings/api-keys",
                       logo: "nvidia", supportsTools: true, group: .platforms),
        .sambanova: .init(name: "SambaNova", baseURL: "https://api.sambanova.ai/v1", keyURL: "https://cloud.sambanova.ai/apis",
                          logo: "sambanova", supportsTools: true, group: .fast),
        .deepinfra: .init(name: "DeepInfra", baseURL: "https://api.deepinfra.com/v1/openai", keyURL: "https://deepinfra.com/dash/api_keys",
                          logo: "deepinfra", supportsTools: true, group: .platforms),
        .nebius: .init(name: "Nebius", baseURL: "https://api.tokenfactory.nebius.com/v1", keyURL: "https://tokenfactory.nebius.com",
                       logo: "nebius", supportsTools: true, group: .platforms),
        .novita: .init(name: "Novita", baseURL: "https://api.novita.ai/openai", keyURL: "https://novita.ai/settings/key-management",
                       logo: "novita", supportsTools: true, group: .platforms),
        .venice: .init(name: "Venice", baseURL: "https://api.venice.ai/api/v1", keyURL: "https://venice.ai/settings/api",
                       logo: "venice", supportsTools: true, group: .platforms),
    ]

    /// `/models` of a compatible provider: `data[].id` (and `context_length` when given).
    public static func decodeModels(_ data: Data) throws -> [ChatModel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ChatServiceError.invalidResponse }
        guard root["error"] == nil, let items = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) else { throw ChatServiceError.invalidResponse }
        return items.compactMap { item in
            guard let id = (item["id"] as? String) ?? (item["name"] as? String), !id.isEmpty else { return nil }
            let context = (item["context_length"] as? Int) ?? (item["context_window"] as? Int) ?? (item["max_model_len"] as? Int)
            return ChatModel(id: id, name: item["display_name"] as? String ?? id, contextLength: context)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
