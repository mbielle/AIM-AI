import AIMCore
import Foundation

/// Same saved identities as the Mac picker, with no catalog pagination quota.
public enum RemoteModelCatalogMetadata {
    private static let key = "aim.models.added"
    public static func additions(defaults: UserDefaults = .standard) -> [String] {
        let data = Data((defaults.string(forKey: key) ?? "[]").utf8)
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    public static func announcements(_ catalog: [ChatModel], provider: ChatProvider,
                                     favorites: [FavoriteModel], additions: [String], reference: [ChatModel] = [], available: Bool = true) -> [RemoteModelAnnouncement] {
        let pins = Set(favorites.map { ModelRouting.canonicalIdentity($0.modelID, provider: $0.provider) })
        let added = Set(additions.compactMap(identity))
        let index = ModelDetailsLookup.index(reference)
        let presentIDs = Set(catalog.map(\.id))
        let saved = Set(additions).union(favorites.map { $0.provider.rawValue + ":" + $0.modelID })
        let missing = saved.compactMap { value -> ChatModel? in
            guard let colon = value.firstIndex(of: ":"), String(value[..<colon]) == provider.rawValue else { return nil }
            let id = String(value[value.index(after: colon)...])
            guard !presentIDs.contains(id) else { return nil }
            return reference.first { $0.id == id } ?? ChatModel(id: id, name: favorites.first { $0.provider == provider && $0.modelID == id }?.name ?? id)
        }.sorted { $0.id < $1.id }
        return (catalog + missing).map { model in
            let id = ModelRouting.canonicalIdentity(model.id, provider: provider)
            let detail = ModelDetailsLookup.enriched(model, provider: provider, index: index)
            return RemoteModelAnnouncement(id: model.id, name: model.name, provider: provider.rawValue,
                capabilities: detail.capabilities.map(\.rawValue).sorted(),
                isAdded: added.contains(id), isPinned: pins.contains(id), detail: detail,
                isReferencePricing: provider != .openRouter && model.pricing == nil && detail.pricing != nil,
                isAvailable: available && presentIDs.contains(model.id), isFeatured: false)
        }
    }
    public static func replaceAdditions(_ values: [String], defaults: UserDefaults = .standard) throws {
        var seen = Set<String>()
        let validated = values.filter { value in
            guard let colon = value.firstIndex(of: ":"), let provider = ChatProvider(rawValue: String(value[..<colon])),
                  (try? FavoriteModel(provider: provider, modelID: String(value[value.index(after: colon)...]), name: value)) != nil else { return false }
            return seen.insert(value).inserted
        }
        defaults.set(String(decoding: try JSONEncoder().encode(validated), as: UTF8.self), forKey: key)
    }
    public static func setAdded(modelID: String, provider: ChatProvider, added: Bool,
                                defaults: UserDefaults = .standard) throws {
        // Reuse the identifier validation already applied by the model picker.
        _ = try FavoriteModel(provider: provider, modelID: modelID, name: modelID)
        let selected = ModelRouting.canonicalIdentity(modelID, provider: provider)
        var values = additions(defaults: defaults)
        values.removeAll { identity($0) == selected }
        if added { values.append(provider.rawValue + ":" + modelID) }
        defaults.set(String(decoding: try JSONEncoder().encode(values), as: UTF8.self), forKey: key)
    }
    private static func identity(_ value: String) -> String? {
        guard let colon = value.firstIndex(of: ":"), let provider = ChatProvider(rawValue: String(value[..<colon])) else { return nil }
        return ModelRouting.canonicalIdentity(String(value[value.index(after: colon)...]), provider: provider)
    }
}
