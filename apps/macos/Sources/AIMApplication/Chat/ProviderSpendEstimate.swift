import AIMCore
import Foundation

/// Catalog-based personal-budget estimates, never a verified provider maximum or invoice.
/// Public reference prices may differ from a direct provider's bill. Missing prices stay unknown.
struct ProviderSpendEstimate: Sendable {
    let input: Decimal
    let output: Decimal

    init?(pricing: ChatModel.Pricing?) {
        func rate(_ raw: String?) -> Decimal? {
            guard let raw, let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
                  !value.isNaN, value >= 0, value <= 1 else { return nil }
            return value
        }
        guard let input = rate(pricing?.prompt), let output = rate(pricing?.completion) else { return nil }
        self.input = input; self.output = output
    }

    static func resolve(provider: ChatProvider, modelID: String, cache: ModelCatalogCache = .shared) async -> Self? {
        guard provider != .local, provider != .chatgpt else { return nil }
        let models = await cache.cached(provider) ?? []
        let references = await cache.cached(.openRouter) ?? []
        let model = models.first { $0.id == modelID } ?? ChatModel(id: modelID, name: modelID)
        return Self(pricing: ModelCatalogDetails.enriched(model, provider: provider, catalog: references).pricing)
    }

    func reservation(body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let generation = json["generationConfig"] as? [String: Any]
        let limit = json["max_tokens"] as? Int ?? json["max_output_tokens"] as? Int
            ?? json["max_completion_tokens"] as? Int ?? generation?["maxOutputTokens"] as? Int
        guard let limit, limit > 0 else { return nil }
        // Includes schemas/system text and a margin for provider framing. Multimodal and web
        // overhead are not promised as bounded by this text estimate.
        let prompt = (body.count + 2) / 3 + 256
        return text(input * Decimal(prompt) + output * Decimal(limit))
    }

    func completed(usage: TokenUsage) -> String? {
        guard let prompt = usage.inputTokens, let completion = usage.outputTokens,
              prompt >= 0, completion >= 0 else { return nil }
        // Cache discounts are deliberately not assumed. Cache writes and hosted tools may add fees.
        return text(input * Decimal(prompt) + output * Decimal(completion))
    }
    private func text(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
}
