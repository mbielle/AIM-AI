import AIMCore
import Foundation

/// A creator/model identity is distinct from the service transporting its requests.
public enum ModelRouting {
    /// One way to reach a model: a provider and that provider's own model id.
    public struct Route: Hashable, Sendable {
        public let provider: ChatProvider
        public let model: ChatModel
        public init(provider: ChatProvider, model: ChatModel) { self.provider = provider; self.model = model }
    }

    /// One model, whatever the number of connections that serve it.
    public struct Entry: Identifiable, Sendable {
        /// The route used when this model is chosen.
        public let model: ChatModel
        public let provider: ChatProvider
        /// Every connection that serves it, direct providers first, OpenRouter last.
        public let routes: [Route]
        public var id: String { canonicalIdentity(model.id, provider: provider) }
        public var creator: String { ModelIdentity.creator(for: model, via: provider) }

        public init(model: ChatModel, provider: ChatProvider, routes: [Route]? = nil) {
            self.model = model
            self.provider = provider
            self.routes = routes ?? [Route(provider: provider, model: model)]
        }

        public func using(_ provider: ChatProvider) -> Entry {
            guard let route = routes.first(where: { $0.provider == provider }) else { return self }
            return Entry(model: route.model, provider: route.provider, routes: routes)
        }
    }

    public static func identity(_ id: String, provider: ChatProvider) -> String {
        ModelCatalogDetails.identity(id, provider: provider)
    }

    /// Only explicitly listed equivalents share a card. Snapshots and variants stay distinct.
    public static func canonicalIdentity(_ id: String, provider: ChatProvider) -> String {
        CanonicalModelRouting.identity(id, provider: provider.rawValue)
    }

    /// One entry per model. `preferred` names the route a person chose for a model; by
    /// default a direct provider wins over OpenRouter.
    public static func entries(_ catalogs: [ChatProvider: [ChatModel]],
                               preferred: (String) -> ChatProvider? = { _ in nil }) -> [Entry] {
        var routes: [String: [Route]] = [:]
        // A ChatGPT plan (included usage) comes first, OpenRouter (resold usage) last.
        func rank(_ provider: ChatProvider) -> Int { provider == .chatgpt ? 0 : (provider == .openRouter ? 2 : 1) }
        let providers = catalogs.keys.sorted { lhs, rhs in
            rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs) : lhs.rawValue < rhs.rawValue
        }
        for provider in providers {
            for model in catalogs[provider, default: []] {
                let key = canonicalIdentity(model.id, provider: provider)
                var list = routes[key, default: []]
                // Keep the first id per provider (an undated id sorts before its snapshots).
                if !list.contains(where: { $0.provider == provider }) { list.append(Route(provider: provider, model: model)) }
                else if let index = list.firstIndex(where: { $0.provider == provider }),
                        model.id.count < list[index].model.id.count { list[index] = Route(provider: provider, model: model) }
                routes[key] = list
            }
        }
        return routes.map { key, list in
            let chosen = preferred(key).flatMap { wanted in list.first { $0.provider == wanted } } ?? list[0]
            return Entry(model: chosen.model, provider: chosen.provider, routes: list)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    public static func resolve(modelID: String, provider: ChatProvider, catalogs: [ChatProvider: [ChatModel]]) -> Entry? {
        let key = canonicalIdentity(modelID, provider: provider)
        return entries(catalogs).first { $0.id == key }
    }

    /// HTTP refusal before any output is safe to retry; ambiguous network failures are not.
    public static func canFallback(_ error: Error, emittedOutput: Bool) -> Bool {
        guard !emittedOutput, let service = error as? ChatServiceError, case .http(let status) = service else { return false }
        return [401, 402, 404, 429].contains(status)
    }
}

/// Optional same-provider backup model per provider, used once by a tool run
/// when its model is unavailable or keeps refusing (UserDefaults; no secret).
public enum ModelFallbackPreferences {
    static func key(_ provider: ChatProvider) -> String { "AIMFallbackModel.\(provider.rawValue)" }

    public static func fallback(for provider: ChatProvider) -> String? {
        UserDefaults.standard.string(forKey: key(provider)).flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    public static func setFallback(_ modelID: String?, for provider: ChatProvider) {
        UserDefaults.standard.set(modelID?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key(provider))
    }
}
