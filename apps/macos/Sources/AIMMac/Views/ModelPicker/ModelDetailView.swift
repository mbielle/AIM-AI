import AIMCore
import AIMApplication
import AppKit
import SwiftUI

/// Everything known about one model, inside the picker (back returns to the list).
struct ModelDetailView: View {
    let entry: ModelRouting.Entry
    let details: ChatModel
    /// Names of the models included in the connected ChatGPT plan.
    var planModels: [String] = []
    let inSelection: Bool
    let added: Bool
    let toggleAdded: () -> Void
    let use: () -> Void
    let chooseRoute: (ChatProvider) -> Void
    /// The model's id on OpenRouter, when it is listed there (hosts, uptime).
    let openRouterID: String?
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    @State private var expanded = false
    @State private var section = Section.overview
    @State private var endpoints: [OpenRouterEndpoint] = []
    @State private var loadingEndpoints = false
    @State private var uptimeHistory: [ModelStatsStore.UptimeSample] = []
    @State private var speedHistory: [ModelStatsStore.SpeedSample] = []

    private var pinned: Bool { model.isFavoriteModel(entry.model.id, provider: entry.provider) }

    enum Section: String, CaseIterable { case overview = "Overview", providers = "Providers", uptime = "Uptime", performance = "Performance" }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                ModelCreatorLogo(creator: entry.creator, size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(ModelIdentity.displayName(entry.model, via: entry.provider)).font(.system(size: 22, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(ModelIdentity.creatorName(entry.creator)).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(entry.model.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.model.id, forType: .string)
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)).frame(width: 22, height: 22)
                        }
                        .buttonStyle(.aimHover(radius: 6)).aimTooltip(copied ? "Copied" : "Copy model ID")
                    }
                    .font(.system(size: 12.5))
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    if inSelection {
                        Button { Task { await model.toggleFavoriteModel(entry.model, provider: entry.provider) } } label: {
                            Label(pinned ? "Pinned" : "Pin", systemImage: pinned ? "pin.fill" : "pin")
                        }.buttonStyle(.settings)
                    }
                    if !inSelection || added {
                        Button(action: toggleAdded) {
                            Label(added ? "Remove" : "Add to my models", systemImage: added ? "minus" : "plus")
                        }.buttonStyle(.settings)
                    }
                    if details.isChatModel {
                        Button("Use this model", action: use).buttonStyle(.settingsPrimary)
                            .disabled(!model.connectedProviders.contains(entry.provider))
                            .help(model.connectedProviders.contains(entry.provider) ? "Use the selected provider" : "Connect this provider in Settings → Providers")
                    } else if AIMApplication.MediaModel.from(details) != nil {
                        Button("Create with this model") { model.openMediaCreator(preset: entry.model.id) }.buttonStyle(.settingsPrimary)
                    } else {
                        Button("Use this model", action: use).buttonStyle(.settingsPrimary).disabled(true)
                            .help("\(details.kindLabel ?? "This") model does not answer in text, so it cannot run a chat.")
                    }
                }
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Section.allCases, id: \.self) { item in
                        Button { section = item } label: {
                            Label(item.rawValue, systemImage: icon(item)).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                                .foregroundStyle(section == item ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 32)
                                .background(section == item ? AIMTheme.hover(scheme) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 150)
                VStack(alignment: .leading, spacing: 22) {
                    switch section {
                    case .overview: overview
                    case .providers: ModelHostsSection(endpoints: endpoints, loading: loadingEndpoints, available: openRouterID != nil)
                    case .uptime: ModelUptimeSection(endpoints: endpoints, history: uptimeHistory, available: openRouterID != nil)
                    case .performance: ModelSpeedSection(samples: speedHistory)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
        .frame(maxWidth: .infinity)
        .task(id: entry.id) { await loadStats() }
        #if DEBUG
        .onChange(of: model.debugOpenMenu) { _, value in
            if let value, value.hasPrefix("section-"), let match = Section.allCases.first(where: { "section-" + $0.rawValue.lowercased() == value }) {
                section = match
            }
        }
        #endif
    }

    @ViewBuilder private var overview: some View {
            if let summary = details.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary).font(.system(size: 13.5)).lineSpacing(3).foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(expanded ? nil : 5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if summary.count > 420 {
                        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AIMTheme.toggleOn)
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10, alignment: .top)], spacing: 10) {
                tile("Modalities") { modalities }
                if let input = details.pricing?.inputPerMillion, let output = details.pricing?.outputPerMillion {
                    tile("In / out price") {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(ModelFacts.price(input)) / \(ModelFacts.price(output))").font(.system(size: 15, weight: .medium))
                            Text("per 1M").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                if let cache = details.pricing?.cacheReadPerMillion {
                    tile("Cache read") { value(ModelFacts.price(cache) + " / 1M") }
                }
                if let context = details.contextLength ?? details.topProvider?.contextLength {
                    tile("Context") { value(ModelFacts.tokens(context) + " tokens") }
                }
                if let output = details.maxOutputTokens ?? details.topProvider?.maxCompletionTokens {
                    tile("Max output") { value(ModelFacts.tokens(output) + " tokens") }
                }
                if let created = details.created {
                    tile("Released") { value(Date(timeIntervalSince1970: created).formatted(date: .abbreviated, time: .omitted)) }
                }
                if let cutoff = details.knowledgeCutoff, !cutoff.isEmpty {
                    tile("Knowledge cutoff") { value(cutoff) }
                }
            }

            if entry.provider == .anthropic {
                AnthropicOutputSettingsView(modelID: entry.model.id, maximum: details.maxOutputTokens)
            }
            if !details.capabilities.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Capabilities").font(.system(size: 14, weight: .semibold))
                    FlowRow(spacing: 8) {
                        ForEach(CapabilityIcons.order.filter(details.capabilities.contains), id: \.self) { capability in
                            Label(CapabilityIcons.title(capability), systemImage: CapabilityIcons.icon(capability))
                                .font(.system(size: 12.5)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Provider").font(.system(size: 14, weight: .semibold))
                Text(entry.routes.count > 1 ? "Choose how AIM reaches this model. AIM remembers your choice."
                     : "The known route for this model.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                SettingsCard {
                    ForEach(entry.routes, id: \.provider) { route in
                        Button { chooseRoute(route.provider) } label: {
                            SettingsRow(title: Self.routeTitle(route.provider), description: routeFacts(route),
                                        leading: { ProviderLogo(provider: route.provider, size: 22).frame(width: 28) }) {
                                Image(systemName: route.provider == entry.provider ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(route.provider == entry.provider ? AIMTheme.toggleOn : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // A single route is information, not a dimmed control.
                        .allowsHitTesting(entry.routes.count > 1)
                        .accessibilityAddTraits(route.provider == entry.provider ? .isSelected : [])
                    }
                    // Connected to a ChatGPT plan that does not include this OpenAI model: say so.
                    if entry.creator == "openai", model.connectedProviders.contains(.chatgpt),
                       !entry.routes.contains(where: { $0.provider == .chatgpt }) {
                        SettingsRow(title: "ChatGPT plan · not included",
                                    description: planModels.isEmpty ? "Your ChatGPT plan does not offer this model."
                                        : "Your plan offers \(planModels.joined(separator: ", ")). This model is billed through an API route.",
                                    leading: { ProviderLogo(provider: .chatgpt, size: 22).frame(width: 28).opacity(0.45) }) { EmptyView() }
                            .opacity(0.7)
                    }
                    if AIMApplication.MediaModel.from(details)?.bflEndpoint != nil {
                        SettingsRow(title: "Black Forest Labs (official)",
                                    description: model.hasFluxKey ? "Direct to api.bfl.ai with your Black Forest Labs key. Chosen in Create."
                                                                  : "Add a Black Forest Labs key in Settings → Providers to use it directly.",
                                    leading: { ModelCreatorLogo(creator: "black-forest-labs", size: 22).frame(width: 28) }) { EmptyView() }
                    }
                }
                if entry.provider != .openRouter, entry.provider != .chatgpt, details.pricing != nil {
                    Text("Prices and limits come from OpenRouter's public catalog; your provider may bill slightly differently.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
    }

    private func routeFacts(_ route: ModelRouting.Route) -> String {
        let state = model.connectedProviders.contains(route.provider) ? "Connected" : "Connect in Settings → Providers"
        let price: String
        if route.provider == .chatgpt { price = "Included usage · plan limits apply" }
        else if let input = route.model.pricing?.inputPerMillion, let output = route.model.pricing?.outputPerMillion {
            price = "\(ModelFacts.price(input)) / \(ModelFacts.price(output)) per 1M tokens"
        } else { price = "Price not supplied" }
        let capabilities = CapabilityIcons.order.filter(route.model.capabilities.contains).map(CapabilityIcons.title).joined(separator: ", ")
        return [state, price, capabilities.isEmpty ? "Capabilities not supplied" : capabilities].joined(separator: " · ")
    }

    static func routeTitle(_ provider: ChatProvider) -> String {
        switch provider {
        case .openRouter: "OpenRouter"
        case .chatgpt: "ChatGPT plan"
        default: "\(provider.name) (official)"
        }
    }

    static func routeDescription(_ provider: ChatProvider) -> String {
        switch provider {
        case .openRouter: "Routed by OpenRouter to the best available host. Billed to your OpenRouter credits."
        case .chatgpt: "Included in your ChatGPT plan · no API billing. Plan usage limits apply."
        default: "Direct to \(provider.host) with your \(provider.name) key."
        }
    }

    private func icon(_ section: Section) -> String {
        switch section {
        case .overview: "square.text.square"
        case .providers: "server.rack"
        case .uptime: "waveform.path.ecg"
        case .performance: "bolt"
        }
    }

    private func loadStats() async {
        let key = ModelRouting.canonicalIdentity(entry.model.id, provider: entry.provider)
        speedHistory = await ModelStatsStore.shared.speed(model: key)
        guard let openRouterID else { return }
        loadingEndpoints = true
        defer { loadingEndpoints = false }
        if let hosts = try? await OpenRouterEndpoints.fetch(modelID: openRouterID) {
            endpoints = hosts
            await ModelStatsStore.shared.recordUptime(model: key, endpoints: hosts)
        }
        uptimeHistory = await ModelStatsStore.shared.uptime(model: key)
    }


    private var modalities: some View {
        let inputs = details.architecture?.inputModalities ?? details.inputModalities ?? ["text"]
        let outputs = details.architecture?.outputModalities ?? ["text"]
        // Wraps inside its tile instead of spilling over the next one.
        return FlowRow(spacing: 5) {
            ForEach(inputs, id: \.self) { modalityIcon($0) }
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary).frame(height: 22)
            ForEach(outputs, id: \.self) { modalityIcon($0) }
        }
    }

    private func modalityIcon(_ kind: String) -> some View {
        let icon = switch kind {
        case "image": "photo"
        case "file": "doc"
        case "audio": "waveform"
        case "video": "film"
        default: "textformat"
        }
        return Image(systemName: icon).font(.system(size: 12)).frame(width: 24, height: 22)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .help(kind.capitalized)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .medium))
    }

    private func tile<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).kerning(0.3)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(12)
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }
}

/// Wraps its children onto as many lines as needed.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
