import AIMCore
import Foundation

/// Resolves the exact model, including sub-agent/fallback/compaction requests.
/// Reading a model descriptor does not generate tokens. Never replace a missing
/// required capacity by an AIM-wide 4096/8192-token default.
enum ProviderModelOutput {
    static func resolve(provider: ChatProvider, modelID: String, userLimit: Int?, thinkingBudget: Int?,
                        apiKey: String, session: URLSession, cache: ModelCatalogCache = .shared) async throws -> Int? {
        if provider != .anthropic {
            return try ModelOutputPolicy.resolve(provider: provider, modelID: modelID, userLimit: userLimit)
        }
        let cached = await cache.cached(provider) ?? []
        var maximum = cached.first(where: { $0.id == modelID })?.maxOutputTokens
        if maximum == nil && userLimit == nil {
            guard !modelID.isEmpty, modelID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
                throw ModelOutputPolicyError.modelCapacityUnknown
            }
            try RuntimePrivacyPolicy.requireNetwork()
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models/" + modelID)!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = row["id"] as? String, id == modelID,
                  let value = row["max_tokens"] as? Int, value > 0 else {
                throw ModelOutputPolicyError.modelCapacityUnknown
            }
            maximum = value
            let prior = cached.first(where: { $0.id == id })
            var model = ChatModel(id: id, name: prior?.name ?? row["display_name"] as? String ?? id,
                contextLength: prior?.contextLength ?? row["max_input_tokens"] as? Int,
                inputModalities: prior?.inputModalities, created: prior?.created, maxOutputTokens: value)
            model.pricing = prior?.pricing
            model.architecture = prior?.architecture
            model.supportedParameters = prior?.supportedParameters
            try await cache.save(cached.filter { $0.id != id } + [model], for: provider)
        }
        return try ModelOutputPolicy.resolve(provider: provider, modelID: modelID, catalogMaximum: maximum,
            userLimit: userLimit, thinkingBudget: thinkingBudget)
    }
}
