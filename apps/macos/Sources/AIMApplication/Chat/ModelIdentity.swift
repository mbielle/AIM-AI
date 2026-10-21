import AIMCore
import Foundation

public enum ModelIdentity {
    public static func creator(for model: ChatModel, via route: ChatProvider) -> String {
        ModelCatalogDetails.creator(for: model, via: route)
    }

    public static func normalizedCreator(_ value: String) -> String {
        ModelCatalogDetails.normalizedCreator(value)
    }

    public static func creatorName(_ slug: String) -> String {
        switch normalizedCreator(slug) {
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "google": "Google"
        case "deepseek": "DeepSeek"
        case "x-ai", "xai": "xAI"
        case "perplexity": "Perplexity"
        case "meta-llama": "Meta"
        case "mistralai": "Mistral"
        case "moonshotai": "Moonshot"
        case "qwen": "Qwen"
        case "z-ai": "Z.ai"
        case "aion-labs": "Aion Labs"
        case "amazon": "Amazon"
        case "arcee-ai": "Arcee AI"
        case "baidu": "Baidu"
        case "bytedance", "bytedance-seed": "ByteDance"
        case "cognitivecomputations": "Cognitive Computations"
        case "cohere": "Cohere"
        case "ibm-granite": "IBM"
        case "inclusionai": "inclusionAI"
        case "kwaipilot": "Kwaipilot"
        case "liquid": "Liquid AI"
        case "meituan": "Meituan"
        case "microsoft": "Microsoft"
        case "minimax": "MiniMax"
        case "nousresearch": "Nous Research"
        case "nvidia": "NVIDIA"
        case "rekaai": "Reka"
        case "stepfun": "StepFun"
        case "tencent": "Tencent"
        case "xiaomi": "Xiaomi"
        case "ai21": "AI21"
        case "allenai": "Ai2"
        case "thinkingmachines": "Thinking Machines"
        default: slug.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    public static func displayName(_ model: ChatModel, via route: ChatProvider) -> String {
        let creator = creatorName(creator(for: model, via: route))
        for prefix in [creator + ": ", creator + " ", "MoonshotAI: ", "OpenAI: ", "Anthropic: ", "xAI: "] {
            if model.name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil {
                return String(model.name.dropFirst(prefix.count))
            }
        }
        // OpenRouter names read "Maker: Model"; the maker is already shown by the logo and group.
        if let colon = model.name.range(of: ": "), model.name.distance(from: model.name.startIndex, to: colon.lowerBound) <= 32 {
            return String(model.name[colon.upperBound...])
        }
        let name = model.name.contains("/") ? String(model.name.split(separator: "/").last ?? Substring(model.name)) : model.name
        if name.hasPrefix("gpt-") { return name.replacingOccurrences(of: "gpt-", with: "GPT-") }
        return name
    }
}
