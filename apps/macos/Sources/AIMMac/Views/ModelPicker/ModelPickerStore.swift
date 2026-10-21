import AIMCore
import AIMApplication
import Foundation
import Observation

/// Everything the model picker shows, computed once per change (catalog, search, tab,
/// pins…) instead of on every frame, so scrolling stays smooth with ~1,000 models.
@MainActor
@Observable
final class ModelPickerStore {
    struct Item: Identifiable, Equatable {
        let entry: ModelRouting.Entry
        let name: String
        let meta: String
        let capabilities: Set<ChatModel.Capability>
        let pinned: Bool
        let added: Bool
        let isChat: Bool
        var id: String { entry.id }
        var inSelection: Bool { added || pinned }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.entry.provider == rhs.entry.provider && lhs.meta == rhs.meta
                && lhs.pinned == rhs.pinned && lhs.added == rhs.added
        }
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let creator: String?
        let items: [Item]
    }

    private(set) var sections: [Section] = []
    private(set) var isEmpty = true
    var hasSavedModels: Bool { !pins.isEmpty || !added.isEmpty }

    private(set) var entriesByID: [String: ModelRouting.Entry] = [:]

    var catalogs: [ChatProvider: [ChatModel]] = [:] { didSet { rebuildEntries() } }
    var reference: [String: ChatModel] = [:] { didSet { rebuildItems() } }

    private var entries: [ModelRouting.Entry] = []
    private var detailsCache: [String: ChatModel] = [:]

    // Inputs mirrored from the view.
    private var query = ""
    private var tab = ModelPickerView.Tab.mine
    private var providerFilter: ChatProvider?
    private var connected: Set<ChatProvider> = []
    private var pins: Set<String> = []
    private var added: Set<String> = []

    var accountID: UUID?
    var target = "mac:local"
    static let routesKey = "aim.models.routes"
    static let mediaSectionID = "media"

    func update(query: String, tab: ModelPickerView.Tab, providerFilter: ChatProvider?, connected: Set<ChatProvider>,
                favorites: [FavoriteModel], added: [String], accountID: UUID? = nil, target: String = "mac:local") {
        let scopeChanged = self.accountID != accountID || self.target != target
        self.accountID = accountID; self.target = target
        let pins = Set(favorites.map { ModelRouting.canonicalIdentity($0.modelID, provider: $0.provider) })
        let additions = Set(added.compactMap { value -> String? in
            guard let colon = value.firstIndex(of: ":"), let provider = ChatProvider(rawValue: String(value[..<colon])) else { return nil }
            return ModelRouting.canonicalIdentity(String(value[value.index(after: colon)...]), provider: provider)
        })
        let connectionsChanged = connected != self.connected
        guard query != self.query || tab != self.tab || providerFilter != self.providerFilter || connectionsChanged
                || pins != self.pins || additions != self.added || scopeChanged else { return }
        self.query = query; self.tab = tab; self.providerFilter = providerFilter
        self.connected = connected; self.pins = pins; self.added = additions
        if connectionsChanged || scopeChanged { rebuildEntries() } else { rebuildItems() }
    }

    func details(_ entry: ModelRouting.Entry) -> ChatModel {
        let key = entry.provider.rawValue + ":" + entry.model.id
        if let cached = detailsCache[key] { return cached }
        let value = ModelDetailsLookup.enriched(entry.model, provider: entry.provider, index: reference)
        detailsCache[key] = value
        return value
    }

    // MARK: Routes

    static func preferredRoutes() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: routesKey) as? [String: String] ?? [:]
    }

    func setPreferredRoute(_ provider: ChatProvider, for entryID: String) {
        if let accountID {
            UserDefaults.standard.set(provider.rawValue, forKey: CanonicalModelRouting.preferenceKey(account: accountID, target: target, model: entryID))
            rebuildEntries(); return
        }
        var routes = Self.preferredRoutes()
        routes[entryID] = provider.rawValue
        UserDefaults.standard.set(routes, forKey: Self.routesKey)
        rebuildEntries()
    }

    // MARK: Building

    private func rebuildEntries() {
        let usable = catalogs.filter { $0.key != .local }
        let routes = Self.preferredRoutes()
        entries = ModelRouting.entries(usable) { canonical in
            if let owner = self.accountID {
                let key = CanonicalModelRouting.preferenceKey(account: owner, target: self.target, model: canonical)
                if let explicit = UserDefaults.standard.string(forKey: key) { return ChatProvider(rawValue: explicit) }
                if let legacy = routes[canonical] { UserDefaults.standard.set(legacy, forKey: key); return ChatProvider(rawValue: legacy) }
                return self.defaultConnectedRoute(canonical, catalogs: usable)
            }
            return routes[canonical].flatMap(ChatProvider.init(rawValue:)) ?? self.defaultConnectedRoute(canonical, catalogs: usable)
        }
        entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        detailsCache = [:]
        rebuildItems()
    }

    private func defaultConnectedRoute(_ canonical: String, catalogs: [ChatProvider: [ChatModel]]) -> ChatProvider? {
        catalogs.keys.sorted {
            let a = CanonicalModelRouting.rank($0.rawValue), b = CanonicalModelRouting.rank($1.rawValue)
            return a == b ? $0.rawValue < $1.rawValue : a < b
        }.first { provider in
            connected.contains(provider) && catalogs[provider, default: []].contains {
                ModelRouting.canonicalIdentity($0.id, provider: provider) == canonical
            }
        }
    }

    private func rebuildItems() {
        let showRoute = connected.filter { $0 != .local }.count > 1 && providerFilter == nil
        let needle = query.trimmingCharacters(in: .whitespaces)
        var pinnedItems: [Item] = []
        var groups: [String: [Item]] = [:]
        for entry in entries {
            if let providerFilter, !entry.routes.contains(where: { $0.provider == providerFilter }) { continue }
            let isPinned = pins.contains(entry.id), isAdded = added.contains(entry.id)
            if tab == .mine && !(isPinned || isAdded) { continue }
            if !needle.isEmpty,
               !(entry.model.name + " " + entry.model.id + " " + ModelIdentity.creatorName(entry.creator)).localizedCaseInsensitiveContains(needle) {
                continue
            }
            let info = details(entry)
            // Media models: per-token chat prices and context do not apply; show how AIM reaches them.
            let meta = info.kindLabel.map { label in
                [label.replacingOccurrences(of: " generation", with: ""),
                 AIMApplication.MediaModel.from(info)?.bflEndpoint != nil ? "BFL key or OpenRouter" : "via \(entry.provider.name)"]
                    .joined(separator: " · ")
            } ?? ModelFacts.cardLine(info, via: entry.provider, showRoute: showRoute)
            let item = Item(entry: entry, name: ModelIdentity.displayName(entry.model, via: entry.provider), meta: meta,
                            capabilities: info.capabilities.intersection([.vision, .tools, .reasoning]),
                            pinned: isPinned, added: isAdded, isChat: info.isChatModel)
            // Image and video models sit under their maker like any model (a click opens Create).
            if tab == .mine && isPinned { pinnedItems.append(item) } else { groups[entry.creator, default: []].append(item) }
        }
        var result: [Section] = []
        if !pinnedItems.isEmpty { result.append(Section(id: "pinned", title: "Pinned", creator: nil, items: pinnedItems)) }
        for creator in groups.keys.sorted(by: { ModelIdentity.creatorName($0) < ModelIdentity.creatorName($1) }) {
            result.append(Section(id: creator, title: ModelIdentity.creatorName(creator), creator: creator, items: groups[creator] ?? []))
        }
        if result != sections { sections = result }
        isEmpty = result.isEmpty
    }
}
