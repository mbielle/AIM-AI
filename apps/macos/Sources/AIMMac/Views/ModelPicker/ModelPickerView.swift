import AIMCore
import AIMApplication
import AIMMacPlatform
import AppKit
import SwiftUI

/// Choose, browse and add models. Online models come from the connected providers;
/// local ones from the servers on this Mac and Hugging Face. Everything (including a
/// model's full description) stays inside this one panel.
struct ModelPickerView: View {
    enum Tab { case mine, add }
    enum Place: Hashable { case online, local }

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var tab = Tab.mine
    @State private var place = Place.online
    @State private var query = ""
    @State private var providerFilter: ChatProvider?
    @State private var store = ModelPickerStore()
    @State private var errors: [ChatProvider: String] = [:]
    @State private var refreshing = false
    @State private var catalogLoadID = UUID()
    @State private var added: [String] = []
    @State private var debouncedQuery = ""
    @State private var detailEntryID: String?
    @State private var localDetail: String?
    @State private var showFilter = false
    @FocusState private var searchFocused: Bool
    @AppStorage("aim.models.added") private var addedJSON = "[]"

    static let headerHeight: CGFloat = 66
    static let footerHeight: CGFloat = 68

    private var surface: Color { scheme == .dark ? AIMTheme.sidebar(scheme) : .white }

    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            header
            VStack { Spacer(); footer }
        }
        .task {
            added = (try? JSONDecoder().decode([String].self, from: Data(addedJSON.utf8))) ?? []
            await loadCatalogs(force: false)
            await loadReference()
        }
        .onAppear {
            searchFocused = true; syncStore()
            // Opened from "Model settings" (effort menu, Settings): straight to that page.
            if let pending = model.pendingLocalModelSettings {
                model.pendingLocalModelSettings = nil
                place = .local; tab = .mine
                Task { @MainActor in localDetail = pending }
            }
        }
        .onChange(of: tab) { _, _ in query = ""; debouncedQuery = ""; detailEntryID = nil; localDetail = nil; syncStore() }
        .onChange(of: place) { _, _ in query = ""; debouncedQuery = ""; detailEntryID = nil; localDetail = nil }
        .onChange(of: providerFilter) { _, _ in syncStore() }
        .onChange(of: added) { _, _ in syncStore() }
        .onChange(of: addedJSON) { _, value in
            added = (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
            syncStore()
        }
        .onChange(of: model.settings.favoriteModels) { _, _ in syncStore() }
        .onChange(of: model.connectedProviders) { _, _ in
            syncStore()
            Task { await loadCatalogs(force: false) }
        }
        .task(id: query) {
            // Search runs once typing pauses, not on every keystroke.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            debouncedQuery = query
            syncStore()
        }
        #if DEBUG
        .onChange(of: model.debugOpenMenu) { _, value in
            switch value {
            case "picker-add": tab = .add
            case "picker-detail": detailEntryID = store.sections.first?.items.first?.id
            case "picker-local": tab = .add; place = .local
            case "picker-scroll-bottom": query = "flux"
            default: break
            }
        }
        #endif
    }

    // MARK: Layout

    @ViewBuilder private var content: some View {
        if let id = detailEntryID, let entry = store.entriesByID[id] {
            let item = store.sections.lazy.flatMap(\.items).first { $0.id == id }
            ScrollView {
                ModelDetailView(entry: entry, details: store.details(entry), planModels: (store.catalogs[.chatgpt] ?? []).map(\.name),
                                inSelection: item?.inSelection ?? false, added: item?.added ?? false,
                                toggleAdded: { toggleAdded(entry) }, use: { select(entry) },
                                chooseRoute: { store.setPreferredRoute($0, for: entry.id) },
                                openRouterID: entry.routes.first { $0.provider == .openRouter }?.model.id
                                    ?? ModelDetailsLookup.reference(for: entry.model, provider: entry.provider, in: store.reference)?.id)
                    .padding(.horizontal, 28).padding(.top, Self.headerHeight).padding(.bottom, Self.footerHeight + 8)
            }
            .scrollIndicators(.automatic)
        } else if place == .local {
            LocalModelBrowser(tab: tab, query: query, detail: $localDetail) { tab = $0 }
                .padding(.top, 0)
        } else {
            onlineGrid
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if detailEntryID != nil || localDetail != nil {
                Button { detailEntryID = nil; localDetail = nil } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).frame(height: 32)
                }
                .buttonStyle(.aimHover(radius: 8))
                .keyboardShortcut(.cancelAction)
                Spacer()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
                    TextField(searchPrompt, text: $query).textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
                        .focusEffectDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(searchFocused ? AIMTheme.inputBorder(scheme) : AIMTheme.cardBorder(scheme)))
                if place == .online {
                    Button { showFilter.toggle() } label: {
                        Image(systemName: providerFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 14)).frame(width: 34, height: 34)
                    }
                    .buttonStyle(.aimHover(radius: 9, active: showFilter))
                    .aimTooltip("Filter by connection")
                    .aimMenu(isPresented: $showFilter, alignment: .trailing) {
                        AIMMenuSection("Connections")
                        AIMMenuItem("All connections", checked: providerFilter == nil) { providerFilter = nil }
                        ForEach(ChatProvider.allCases.filter { $0 != .local && model.connectedProviders.contains($0) }) { provider in
                            AIMMenuItem(provider.name, checked: providerFilter == provider) { providerFilter = provider }
                        }
                    }
                    Button { Task { await loadCatalogs(force: true); await loadReference(force: true) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13)).frame(width: 34, height: 34)
                            .rotationEffect(.degrees(refreshing ? 360 : 0))
                            .animation(refreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: refreshing)
                    }
                    .buttonStyle(.aimHover(radius: 9)).disabled(refreshing).aimTooltip("Refresh catalogs")
                }
            }
            Button { model.showModelPicker = false } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).frame(width: 34, height: 34)
            }
            .buttonStyle(.aimHover(radius: 9))
            .keyboardShortcut(detailEntryID == nil && localDetail == nil ? .cancelAction : nil)
            .aimTooltip("Close", shortcut: "esc")
        }
        .padding(.horizontal, 18).frame(height: Self.headerHeight)
        .background(alignment: .top) {
            // Cards fade out under the bar instead of being cut.
            LinearGradient(stops: [.init(color: surface, location: 0), .init(color: surface, location: 0.62),
                                   .init(color: surface.opacity(0.0), location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.headerHeight + 18)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        ZStack {
            AIMSegmentedControl(selection: $place, options: [(Place.online, "Online"), (.local, "Local")], compact: true,
                                identifierPrefix: "model-place-")
            HStack {
                Button { tab = tab == .mine ? .add : .mine } label: {
                    Label(tab == .mine ? "Add models" : "My models", systemImage: tab == .mine ? "plus" : "arrow.left")
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 13).frame(height: 32)
                        .background(Color.primary.opacity(scheme == .dark ? 0.09 : 0.05), in: Capsule())
                }
                .buttonStyle(.aimHover(radius: 16))
                if refreshing && place == .online {
                    ProgressView().controlSize(.small).help("Updating catalogs in the background")
                }
                Spacer()
                Button {
                    model.showModelPicker = false
                    model.settingsSection = place == .online ? .providers : .localModels
                } label: {
                    Label(place == .online ? "Providers" : "Local settings", systemImage: place == .online ? "key" : "desktopcomputer")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).frame(height: 32)
                        .overlay(Capsule().strokeBorder(AIMTheme.cardBorder(scheme)))
                }
                .buttonStyle(.aimHover(radius: 16))
                .aimTooltip(place == .online ? "Connect providers and API keys" : "Downloaded models and the built-in engine")
            }
        }
        .padding(.horizontal, 18).frame(height: Self.footerHeight)
        .background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: surface.opacity(0), location: 0), .init(color: surface, location: 0.4),
                                   .init(color: surface, location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.footerHeight + 26)
                .allowsHitTesting(false)
        }
    }

    private var searchPrompt: String {
        switch (place, tab) {
        case (.online, .mine): "Search your models"
        case (.online, .add): "Search every model from your connections"
        case (.local, .mine): "Search models on this Mac"
        case (.local, .add): "Search Hugging Face"
        }
    }

    // MARK: Online grid

    private var onlineGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(store.sections) { section in sectionView(section) }
                ForEach(ChatProvider.allCases.filter { errors[$0] != nil }) { provider in
                    SettingsNotice("\(provider.name): \(errors[provider] ?? "")", tone: .warning)
                }
                if store.isEmpty && !refreshing { emptyState }
            }
            .padding(.horizontal, 22).padding(.top, Self.headerHeight + 4).padding(.bottom, Self.footerHeight + 16)
        }
    }

    private func sectionView(_ section: ModelPickerStore.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let creator = section.creator { ModelCreatorLogo(creator: creator, size: 16) }
                else {
                    Image(systemName: section.id == ModelPickerStore.mediaSectionID ? "photo.on.rectangle.angled" : "pin.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(section.title).font(.system(size: 14, weight: .semibold))
                Text("\(section.items.count)").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 228), spacing: 10)], spacing: 10) {
                ForEach(section.items) { item in card(item) }
            }
        }
    }

    private func card(_ item: ModelPickerStore.Item) -> some View {
        let entry = item.entry
        let selected = entry.routes.contains { $0.provider == model.selectedProvider && $0.model.id == model.selectedModelID }
        return ModelCard(name: item.name, creator: entry.creator, meta: item.meta, capabilities: item.capabilities, selected: selected,
                         mode: tab == .mine ? .select(pinned: item.pinned) : .add(added: item.inSelection, locked: item.pinned),
                         primary: {
                             if tab == .mine && item.isChat { select(entry) }
                             else if tab == .mine { model.openMediaCreator(preset: entry.model.id) }
                             else { detailEntryID = entry.id }
                         },
                         info: { detailEntryID = entry.id },
                         pin: { Task { await model.toggleFavoriteModel(entry.model, provider: entry.provider) } },
                         toggleAdded: { toggleAdded(entry) })
            .equatable()
    }

    private var hasOnlineProvider: Bool { model.connectedProviders.contains { $0 != .local } }

    private var emptyState: some View {
        let firstSelection = tab == .mine && !store.hasSavedModels && debouncedQuery.isEmpty && providerFilter == nil
        return VStack(spacing: 14) {
            Image(systemName: !hasOnlineProvider ? "key" : firstSelection ? "square.stack.3d.up" : "magnifyingglass")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(!hasOnlineProvider ? "Connect your first provider" : firstSelection ? "Build your model library" : "No matching models")
                .font(.system(size: 18, weight: .semibold))
            Text(!hasOnlineProvider
                 ? "Connect a provider to choose the models you want to use."
                 : firstSelection ? "Choose models from your connected providers. Only models you add or pin appear here."
                 : "Try another search or browse the full catalog.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 350)
            if !hasOnlineProvider {
                Button("Connect a provider") { model.showModelPicker = false; model.settingsSection = .providers }
                    .buttonStyle(.settingsPrimary).accessibilityIdentifier("model-library-connect-provider")
            } else if tab == .mine {
                Button("Choose models") { tab = .add }.buttonStyle(.settingsPrimary)
                    .accessibilityIdentifier("model-library-choose-models")
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
        .accessibilityElement(children: .contain).accessibilityIdentifier("model-library-empty")
    }

    // MARK: Data

    private func syncStore() {
        store.update(query: debouncedQuery, tab: tab, providerFilter: providerFilter, connected: model.connectedProviders,
                     favorites: model.settings.favoriteModels ?? [], added: added, accountID: model.account.accessUser?.id, target: "mac:local")
    }

    private var catalogs: [ChatProvider: [ChatModel]] { store.catalogs }

    private func toggleAdded(_ entry: ModelRouting.Entry) {
        Task { await model.toggleAddedModel(entry.model, provider: entry.provider) }
    }

    private func select(_ entry: ModelRouting.Entry) {
        let scope = model.account.credentialScope.snapshot()
        let inLibrary = store.sections.flatMap(\.items).first { $0.id == entry.id }?.inSelection == true
        Task {
            do {
                // "Use model" is also an explicit library choice, unlike browsing.
                if !inLibrary { try await model.setAddedModel(modelID: entry.model.id, provider: entry.provider, added: true) }
                guard model.account.credentialScope.snapshot() == scope else { return }
                model.selectProvider(entry.provider)
                guard model.selectedProvider == entry.provider else { return }
                model.availableModels = catalogs[entry.provider] ?? []
                model.selectModel(entry.model.id)
            } catch { model.alertMessage = error.localizedDescription }
        }
    }

    private func loadCatalogs(force: Bool) async {
        let requestID = UUID()
        catalogLoadID = requestID
        let scope = model.account.credentialScope.snapshot()
        let providers = ChatProvider.allCases.filter { model.connectedProviders.contains($0) && $0 != .local }
        for provider in ChatProvider.allCases where provider != .local {
            if providers.contains(provider), let cached = await ModelCatalogCache.shared.cached(provider) {
                guard catalogLoadID == requestID, model.account.credentialScope.snapshot() == scope, !Task.isCancelled else { return }
                store.catalogs[provider] = cached
            } else { store.catalogs[provider] = nil }
        }
        refreshing = true
        defer { if catalogLoadID == requestID { refreshing = false } }
        for provider in providers {
            // A cache written before reasoning levels and the full catalog were kept is refreshed now.
            let outdated = provider == .openRouter && !(store.catalogs[provider]?.contains { $0.reasoning != nil } ?? false)
            if !force, !outdated, await ModelCatalogCache.shared.isFresh(provider) { continue }
            do {
                let items = try await model.catalog(for: provider)
                guard catalogLoadID == requestID, model.account.credentialScope.snapshot() == scope, !Task.isCancelled else { return }
                guard model.connectedProviders.contains(provider) else { continue }
                store.catalogs[provider] = items
                errors[provider] = nil
                try? await ModelCatalogCache.shared.save(items, for: provider)
            } catch {
                guard catalogLoadID == requestID, model.account.credentialScope.snapshot() == scope, !Task.isCancelled else { return }
                if model.connectedProviders.contains(provider), store.catalogs[provider] == nil { errors[provider] = "catalog unavailable. Check this connection in Settings → Providers." }
            }
        }
    }

    /// OpenRouter's public catalog (no key) supplies prices, context and descriptions.
    private func loadReference(force: Bool = false) async {
        guard hasOnlineProvider else { return }
        if let cached = await ModelCatalogCache.shared.cached(.openRouter), cached.contains(where: { $0.reasoning != nil || $0.pricing != nil }) {
            store.reference = ModelDetailsLookup.index(cached)
            model.modelReference = store.reference
            if model.connectedProviders.contains(.openRouter) { store.catalogs[.openRouter] = cached }
            if !force, await ModelCatalogCache.shared.isFresh(.openRouter) { return }
        }
        guard let items = try? await ProviderChatService().models(provider: .openRouter, apiKey: nil) else { return }
        store.reference = ModelDetailsLookup.index(items)
        model.modelReference = store.reference
        try? await ModelCatalogCache.shared.save(items, for: .openRouter)
        if model.connectedProviders.contains(.openRouter) { store.catalogs[.openRouter] = items }
    }
}

/// Short, scannable facts about a model.
enum ModelFacts {
    static func price(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 0.1 { return "$" + value.formatted(.number.precision(.fractionLength(0...3))) }
        return "$" + value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return (Double(count) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    static func cardLine(_ model: ChatModel, via provider: ChatProvider, showRoute: Bool) -> String {
        var parts: [String] = []
        if provider == .chatgpt {
            // Included usage, not per-token billing.
            parts.append("Included in your plan")
        } else if let input = model.pricing?.inputPerMillion, let output = model.pricing?.outputPerMillion {
            parts.append(input == 0 && output == 0 ? "Free" : "\(price(input)) / \(price(output))")
        }
        if let context = model.contextLength ?? model.topProvider?.contextLength { parts.append(tokens(context)) }
        if showRoute || parts.isEmpty { parts.append("via " + provider.name) }
        return parts.joined(separator: " · ")
    }
}
