import AIMCore
import SwiftUI
import UIKit

struct AIMModelPickerItem: Identifiable {
    let modelID: String
    let name: String
    let provider: String
    var groupProvider: String? = nil
    var routes: [AIMModelPickerItem] = []
    var subtitle: String? = nil
    var capabilities: [String] = []
    var isLocal = false
    var isAdded = false
    var isPinned = false
    var isFeatured = false
    var available = true
    var unavailableReason: String? = nil
    var detail: ChatModel? = nil
    var isReferencePricing = false
    var mediaModel: MediaModel? = nil
    var id: String { Self.key(provider: provider, modelID: modelID) }
    var displayProvider: String { groupProvider ?? provider }
    func factsSubtitle(locale: Locale) -> String {
        let french = locale.language.languageCode?.identifier == "fr"
        if let mediaModel {
            if let price = mediaModel.priceUSD, let unit = mediaModel.priceUnit { return price.formatted(.currency(code: "USD").precision(.fractionLength(0...4)).locale(locale)) + " / " + unit }
            return french ? "Tarif non communiqué" : "Price not supplied"
        }
        var facts: [String] = []
        if let pricing = detail?.pricing {
            func amount(_ value: Double?) -> String { value.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0...4)).locale(locale)) } ?? "?" }
            facts.append(amount(pricing.inputPerMillion) + " / " + amount(pricing.outputPerMillion) + (french ? " par 1M tokens" : " per 1M tokens"))
        }
        if let context = detail?.contextLength ?? detail?.topProvider?.contextLength {
            facts.append((french ? "contexte " : "context ") + context.formatted(.number.notation(.compactName).locale(locale)))
        }
        return facts.joined(separator: " · ")
    }
    static func key(provider: String, modelID: String) -> String { provider + ":" + modelID }
}

/// One picker for both execution adapters. Browsing changes only local filter state.
struct AIMUnifiedModelPicker: View {
    let items: [AIMModelPickerItem]
    let selectedKey: String?
    var executionDeviceName: String? = nil
    var loading = false
    var refresh: (() -> Void)? = nil
    var openProviders: (() -> Void)? = nil
    var remoteStore: MainExperienceStore? = nil
    var toggleAdded: ((AIMModelPickerItem) -> Void)? = nil
    var togglePinned: ((AIMModelPickerItem) -> Void)? = nil
    let select: (AIMModelPickerItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var showingDownloads = false
    @State private var query = ""
    @State private var provider: String?
    @State private var showingCatalog = false
    @State private var local = false
    @State private var detailID: String?
    @State private var topControlsHeight: CGFloat = 180
    @State private var bottomControlsHeight: CGFloat = 72
    @State private var searchFocused = false
    @State private var searchFocusRequest = 0

    private var filtered: [AIMModelPickerItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        return items.filter { item in
            seen.insert(item.id).inserted && item.isLocal == local && (showingCatalog || item.isAdded || item.isPinned || item.isFeatured)
                && (provider == nil || item.displayProvider == provider)
                && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
                    || item.provider.localizedCaseInsensitiveContains(search) || item.modelID.localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var pinned: [AIMModelPickerItem] { filtered.filter(\.isPinned) }
    private var providers: [String] { Set(filtered.filter { !$0.isPinned }.map(\.displayProvider)).sorted() }
    private var filterProviders: [String] { Set(items.filter { $0.isLocal == local }.map(\.displayProvider)).sorted() }

    var body: some View {
        ZStack {
            // Keep the editor, controls and scroll state mounted. The opaque
            // detail overlay owns occlusion and touch routing while open.
            picker.accessibilityHidden(detailID != nil)
            if let detailID, let item = items.first(where: { $0.id == detailID }) {
                ZStack {
                    Color(uiColor: .systemGroupedBackground)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                    AIMModelDetailsPage(item: item, back: { self.detailID = nil }, toggleAdded: toggleAdded, select: select)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
        }
        .onChange(of: detailID) { _, id in
            if id != nil { searchFocused = false }
        }
        .onChange(of: items.map(\.id)) { _, identifiers in
            // A removed unavailable favorite may be the only retained catalog reference.
            if let detailID, !identifiers.contains(detailID) { self.detailID = nil }
        }
        .foregroundStyle(.primary).tint(.primary)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-selection-sheet")
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .aimUniversalPanelSurface(background: Color(uiColor: .systemGroupedBackground))
    }

    private var picker: some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                    if !pinned.isEmpty { group(copy("Pinned", "Épinglés"), models: pinned, symbol: "pin.fill") }
                    ForEach(providers, id: \.self) { key in
                        group(providerName(key), models: filtered.filter { !$0.isPinned && $0.displayProvider == key })
                    }
                    if filtered.isEmpty && !loading {
                        VStack(spacing: 12) {
                            Image(systemName: local ? "desktopcomputer" : "sparkle.magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text(emptyTitle).font(.headline)
                            if !showingCatalog {
                                Button(catalogActionTitle, action: browseCatalog)
                                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 12)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                // Insets belong to the content, so rows remain visible behind
                // the floating controls while every row can still be reached.
                .padding(.horizontal, 16)
                .padding(.top, topControlsHeight + 14)
                .padding(.bottom, bottomControlsHeight + 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("model-picker-list")
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                header
                    .background(alignment: .top) {
                        LinearGradient(colors: [Color(uiColor: .systemGroupedBackground), Color(uiColor: .systemGroupedBackground).opacity(0)], startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    }
                searchField
                Picker("Models", selection: $showingCatalog) {
                    Text(copy("Added models", "Modèles ajoutés")).tag(false)
                    Text(copy("Full catalog", "Catalogue complet")).tag(true)
                }
                // UISegmentedControl already owns its selection surface and
                // touch tracking. An enclosing interactive glass surface can
                // consume its first short tap on iOS 26 and later.
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityIdentifier("model-picker-library-filter")
                .padding(.horizontal, 16)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: AIMModelPickerTopHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .overlay(alignment: .bottom) {
            footer.background {
                GeometryReader { proxy in
                    Color.clear.preference(key: AIMModelPickerBottomHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .onPreferenceChange(AIMModelPickerTopHeightKey.self) { topControlsHeight = $0 }
        .onPreferenceChange(AIMModelPickerBottomHeightKey.self) { bottomControlsHeight = $0 }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44).aimGlassCircle()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy("Close", "Fermer"))
            .accessibilityIdentifier("model-picker-close")
            Spacer()
            VStack(spacing: 2) {
                Text(copy("Models", "Modèles")).font(.title3.weight(.semibold))
                if let executionDeviceName {
                    Text(copy("On ", "Sur ") + executionDeviceName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("model-picker-execution-device")
                }
            }
            Spacer()
            Menu {
                if let refresh { Button(copy("Refresh catalog", "Actualiser le catalogue"), action: refresh) }
                Button(copy("All providers", "Tous les fournisseurs")) { provider = nil }
                ForEach(filterProviders, id: \.self) { key in
                    Button { provider = key } label: {
                        if provider == key { Label(providerName(key), systemImage: "checkmark") }
                        else { Text(providerName(key)) }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44).aimGlassCircle()
            }.accessibilityLabel(copy("Filter providers", "Filtrer les fournisseurs"))
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            AIMModelSearchField(
                text: $query,
                focused: $searchFocused,
                focusRequest: searchFocusRequest,
                placeholder: copy("Search models", "Rechercher des modèles")
            )
        }
        .font(.body).padding(.horizontal, 16).frame(minHeight: 52)
        .aimGlassCapsule()
        .contentShape(Capsule())
        .onTapGesture(perform: focusSearch)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-search-control")
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func group(_ name: String, models: [AIMModelPickerItem], symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol) }
                Text(name)
                Text("\(models.count)").foregroundStyle(.tertiary)
            }.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            VStack(spacing: 0) {
                ForEach(models) { item in
                    row(item)
                    if item.id != models.last?.id { Divider().padding(.leading, 66) }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func row(_ item: AIMModelPickerItem) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                    AIMModelLogo(modelID: item.modelID, provider: item.displayProvider, displayName: item.name, size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(item.factsSubtitle(locale: locale).isEmpty ? copy("Price and context not supplied", "Prix et contexte non communiqués") : item.factsSubtitle(locale: locale))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        AIMModelCapabilityIcons(capabilities: item.capabilities)
                        if let subtitle = item.available ? (item.isLocal ? item.subtitle : nil) : item.unavailableReason {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if !showingCatalog, selectedKey == item.id { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)) }
                }
                .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .aimSwipeSafeTap {
                    if showingCatalog || !item.available { detailID = item.id }
                    else { select(item) }
                }
            .opacity(item.available ? 1 : 0.65)
            .accessibilityIdentifier("model-option-\(item.id)")
            if showingCatalog, let toggleAdded, !item.isLocal {
                Button { toggleAdded(item) } label: {
                    Image(systemName: item.isAdded || item.isFeatured ? "star.fill" : "star").frame(width: 44, height: 52)
                }
                .disabled(item.isFeatured)
                .accessibilityIdentifier("model-add-\(item.id)")
                .accessibilityLabel((item.isFeatured ? copy("Included by default", "Inclus par défaut") : item.isAdded ? copy("Remove model", "Retirer le modèle") : copy("Add model", "Ajouter le modèle")) + " " + item.name)
            } else if !showingCatalog {
                Button { detailID = item.id } label: { Image(systemName: "info.circle").frame(width: 44, height: 52) }
                    .accessibilityIdentifier("model-info-\(item.id)")
                    .accessibilityLabel(copy("Model details", "Détails du modèle") + " " + item.name)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let togglePinned, item.isAdded, !item.isLocal {
                Button { togglePinned(item) } label: {
                    Label(item.isPinned ? copy("Unpin model", "Désépingler le modèle") : copy("Pin model", "Épingler le modèle"),
                          systemImage: item.isPinned ? "pin.slash" : "pin")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                .frame(width: 48, height: 48).aimGlassCircle()
                .contentShape(Circle()).aimSwipeSafeTap(action: browseCatalog)
                .accessibilityLabel(catalogActionTitle)
                .accessibilityIdentifier("model-picker-add-models")
            Picker("Execution", selection: $local) {
                Text("Online").tag(false)
                Text("Local · Mac").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .accessibilityIdentifier("model-picker-execution-filter")
            if let openProviders {
                Image(systemName: "key").font(.system(size: 20, weight: .medium))
                    .frame(width: 48, height: 48).aimGlassCircle()
                    .contentShape(Circle()).aimSwipeSafeTap(action: openProviders)
                    .accessibilityLabel(copy("Providers", "Fournisseurs"))
                    .accessibilityIdentifier("model-picker-providers")
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .topTrailing) {
            if local, let remoteStore, remoteStore.selectedMachine?.capabilities?.features["remoteDownloads"] == true {
                Button { showingDownloads = true } label: { Image(systemName: "arrow.down.circle").frame(width: 44, height: 44).aimGlassCircle() }
                    .accessibilityLabel("Download model on selected Mac").offset(y: -52)
            }
        }
        .sheet(isPresented: $showingDownloads) {
            if let remoteStore, let machine = remoteStore.selectedMachine {
                AIMRemoteDownloadsView(store: remoteStore, machineID: machine.id, machineName: machine.name)
            }
        }
        .onChange(of: local) { _, _ in provider = nil }
    }

    private func browseCatalog() {
        showingCatalog = true
        focusSearch()
    }

    private func focusSearch() {
        searchFocused = true
        // An explicit request also re-focuses an already mounted field after
        // interactive keyboard dismissal or returning from model details.
        searchFocusRequest += 1
    }

    private var catalogActionTitle: String {
        toggleAdded == nil ? copy("Browse catalog", "Parcourir le catalogue") : copy("Add models", "Ajouter des modèles")
    }

    private var emptyTitle: String {
        if !query.isEmpty { return copy("No matching models", "Aucun modèle correspondant") }
        if local { return copy("No local model announced by the selected Mac", "Aucun modèle local annoncé par le Mac sélectionné") }
        return showingCatalog ? copy("Connect a provider to browse its models", "Connectez un fournisseur pour consulter ses modèles") : copy("Your added models appear here", "Vos modèles ajoutés apparaissent ici")
    }
    private func providerName(_ value: String) -> String { ChatProvider(rawValue: value)?.name ?? value.capitalized }
    private func copy(_ english: String, _ french: String) -> String { locale.language.languageCode?.identifier == "fr" ? french : english }
}

/// UIKit reports the real first-responder state, including interactive scroll
/// dismissal. A focus request is separate from that state so repeated presses
/// on Add models cannot become a no-op through a stale SwiftUI focus binding.
private struct AIMModelSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let focusRequest: Int
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .search
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.tintColor = .label
        field.accessibilityIdentifier = "model-search-field"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        if field.text != text { field.text = text }
        field.wantsFocus = focused
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.hasFocusRequest = focusRequest > 0
        }
        field.scheduleFocusUpdate()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SearchTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: max(28, (uiView.font?.lineHeight ?? 22) + 4))
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AIMModelSearchField
        var lastFocusRequest = 0
        init(parent: AIMModelSearchField) { self.parent = parent }

        @objc func textChanged(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.focused = true
        }
        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.focused = false
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.focused = false
            textField.resignFirstResponder()
            return false
        }
    }

    final class SearchTextField: UITextField {
        var wantsFocus = false
        var hasFocusRequest = false
        private var focusUpdateScheduled = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleFocusUpdate()
        }

        func scheduleFocusUpdate() {
            guard !focusUpdateScheduled else { return }
            focusUpdateScheduled = true
            // Apply after SwiftUI has committed visibility and presentation
            // changes, without a timer or remounting the editor.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusUpdateScheduled = false
                if self.wantsFocus && self.hasFocusRequest && self.window != nil {
                    let accepted = self.isFirstResponder || self.becomeFirstResponder()
                    if accepted { self.hasFocusRequest = false }
                } else if !self.wantsFocus && self.isFirstResponder {
                    self.resignFirstResponder()
                }
            }
        }
    }
}

private struct AIMModelPickerTopHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AIMModelPickerBottomHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AIMModelCapabilityIcons: View {
    let capabilities: [String]
    var body: some View {
        HStack(spacing: 9) {
            ForEach(Array(Set(capabilities)).sorted(), id: \.self) { capability in
                Image(systemName: Self.symbol(capability)).font(.caption)
                    .accessibilityLabel(Self.title(capability))
            }
        }.foregroundStyle(.secondary)
    }
    static func symbol(_ value: String) -> String {
        switch value.lowercased() {
        case "vision", "image_input": "eye"
        case "tools", "tool_use": "wrench.and.screwdriver"
        case "reasoning": "brain"
        case "files", "file_input": "doc"
        case "video", "video_output": "video"
        case "audio", "speech": "waveform"
        case "image", "imageoutput", "image_output": "photo"
        default: "sparkle"
        }
    }
    static func title(_ value: String) -> String {
        switch value.lowercased() {
        case "vision", "image_input": "Reads images"
        case "tools", "tool_use": "Uses tools"
        case "reasoning": "Reasoning"
        case "files", "file_input": "Reads files"
        case "video", "video_output": "Video"
        case "audio", "speech": "Audio"
        case "image", "imageoutput", "image_output": "Creates images"
        default: value.capitalized
        }
    }
}

/// Catalog facts only. Opening this internal page never changes the active route.
private struct AIMModelDetailsPage: View {
    let item: AIMModelPickerItem
    let back: () -> Void
    var toggleAdded: ((AIMModelPickerItem) -> Void)?
    var select: (AIMModelPickerItem) -> Void = { _ in }
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var copied = false
    private var details: ChatModel? { item.detail }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), alignment: .top), count: dynamicType.isAccessibilitySize ? 1 : 2) }
    private var unknown: String { copy("Not supplied by the provider", "Non communiqué par le fournisseur") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44).aimGlassCircle() }
                    .accessibilityLabel(copy("Back to models", "Retour aux modèles"))
                    .accessibilityIdentifier("model-details-back")
                Spacer()
                Text(copy("Model details", "Détails du modèle")).font(.headline)
                Spacer()
                if let toggleAdded, !item.isLocal {
                    Button { toggleAdded(item) } label: { Image(systemName: item.isAdded || item.isFeatured ? "star.fill" : "star").frame(width: 44, height: 44).aimGlassCircle() }
                        .disabled(item.isFeatured)
                        .accessibilityIdentifier("model-details-add")
                        .accessibilityLabel(item.isFeatured ? copy("Included by default", "Inclus par défaut") : item.isAdded ? copy("Remove model", "Retirer le modèle") : copy("Add model", "Ajouter le modèle"))
                } else { Color.clear.frame(width: 44, height: 44) }
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        AIMModelLogo(modelID: item.modelID, provider: item.displayProvider, displayName: item.name, size: 54)
                        Text(item.name).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.modelID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button {
                                UIPasteboard.general.string = item.modelID; copied = true
                            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44) }
                                .buttonStyle(.plain).accessibilityLabel(copy("Copy model ID", "Copier l’identifiant du modèle"))
                        }
                        if !item.available, let reason = item.unavailableReason { Text(reason).font(.subheadline).foregroundStyle(.secondary) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modelFactsCard()

                    if item.routes.count > 1 {
                        section(copy("Providers", "Fournisseurs")) {
                            ForEach(item.routes) { route in
                                Button { select(route) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(route.provider); Spacer(); if route.id == item.id { Image(systemName: "checkmark") } }
                                        Text(route.factsSubtitle(locale: locale)).font(.caption).foregroundStyle(.secondary)
                                        Text(route.available ? copy("Connected", "Connecté") : route.unavailableReason ?? copy("Unavailable", "Indisponible")).font(.caption)
                                    }
                                }.buttonStyle(.plain).disabled(!route.available)
                            }
                        }
                    }
                    section(copy("Overview", "Présentation")) {
                        Text(item.mediaModel?.description ?? details?.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? copy("The provider has not supplied a description for this model.", "Le fournisseur n’a pas communiqué de description pour ce modèle."))
                            .font(.subheadline).lineSpacing(4).textSelection(.enabled)
                    }
                    if let media = item.mediaModel {
                        section(copy("Creation", "Création")) {
                            labeled(copy("Type", "Type"), value: media.kind.rawValue.capitalized)
                            labeled(copy("Price", "Tarif"), value: item.factsSubtitle(locale: locale))
                            labeled(copy("Execution", "Exécution"), value: "This iPhone · " + media.route.title)
                        }
                    }
                    if item.mediaModel == nil { LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        fact(copy("Input price", "Prix d’entrée"), price(details?.pricing?.inputPerMillion))
                        fact(copy("Output price", "Prix de sortie"), price(details?.pricing?.outputPerMillion))
                        fact(copy("Cache read", "Lecture du cache"), price(details?.pricing?.cacheReadPerMillion))
                        fact(copy("Context", "Contexte"), tokens(details?.contextLength ?? details?.topProvider?.contextLength))
                        fact(copy("Maximum output", "Sortie maximale"), tokens(details?.maxOutputTokens ?? details?.topProvider?.maxCompletionTokens))
                        fact(copy("Released", "Date de sortie"), releaseDate)
                        if let cutoff = details?.knowledgeCutoff?.nonEmpty { fact(copy("Knowledge cutoff", "Fin des connaissances"), cutoff) }
                    } }
                    if item.isReferencePricing {
                        Text(copy("Price reference: public OpenRouter catalog. These are not confirmed prices for your direct provider connection.", "Référence tarifaire : catalogue public OpenRouter. Ces prix ne sont pas confirmés pour votre connexion directe au fournisseur."))
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    section(copy("Modalities", "Modalités")) {
                        labeled(copy("Input", "Entrée"), value: modalities(details?.architecture?.inputModalities ?? details?.inputModalities))
                        Divider()
                        labeled(copy("Output", "Sortie"), value: modalities(details?.architecture?.outputModalities))
                    }
                    section(copy("Capabilities", "Capacités")) {
                        if item.capabilities.isEmpty { Text(unknown).font(.subheadline).foregroundStyle(.secondary) }
                        else {
                            ForEach(Array(Set(item.capabilities)).sorted(), id: \.self) { capability in
                                Label(AIMModelCapabilityIcons.title(capability), systemImage: AIMModelCapabilityIcons.symbol(capability)).font(.subheadline).padding(.vertical, 3)
                            }
                        }
                        if let parameters = details?.supportedParameters, !parameters.isEmpty {
                            Divider()
                            Text(copy("Supported parameters", "Paramètres disponibles")).font(.subheadline.weight(.medium))
                            Text(parameters.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let reasoning = details?.reasoning {
                            Divider()
                            if let mandatory = reasoning.mandatory { labeled(copy("Reasoning required", "Raisonnement obligatoire"), value: yesNo(mandatory)) }
                            if let enabled = reasoning.defaultEnabled { labeled(copy("Reasoning by default", "Raisonnement par défaut"), value: yesNo(enabled)) }
                            if let efforts = reasoning.supportedEfforts, !efforts.isEmpty { labeled(copy("Reasoning levels", "Niveaux de raisonnement"), value: efforts.joined(separator: ", ")) }
                        }
                    }
                    section(copy("Provider", "Fournisseur")) {
                        HStack(spacing: 12) {
                            AIMModelLogo(modelID: "", provider: item.provider, displayName: providerName, size: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(providerName).font(.subheadline.weight(.medium))
                                if let route = item.subtitle?.nonEmpty { Text(route).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Text(item.isLocal ? copy("Runs on the selected Mac.", "Exécution sur le Mac sélectionné.") : copy("This is the connection used for this model. Opening its details does not change your selected model or provider.", "Cette connexion dessert ce modèle. Consulter sa fiche ne change ni votre modèle ni votre fournisseur sélectionné."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(copy("Prices are indicative catalog rates, which may come from the public OpenRouter catalog. Your selected provider’s actual charges may differ. Missing values remain unknown; prices and limits may change.", "Les prix sont indicatifs et peuvent provenir du catalogue public OpenRouter. Le tarif effectif dépend du fournisseur sélectionné. Les valeurs manquantes restent inconnues ; les prix et limites peuvent évoluer."))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(.horizontal, 16).padding(.bottom, 30)
            }.accessibilityIdentifier("model-details-content")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("model-details-page")
        .simultaneousGesture(
            DragGesture(minimumDistance: 16, coordinateSpace: .local)
                .onEnded { value in
                    // Only an intentional rightward drag starting at the
                    // page edge returns; ordinary horizontal/vertical content
                    // gestures and cancelled edge drags leave the page intact.
                    guard value.startLocation.x <= 24,
                          value.translation.width > 70,
                          value.translation.width > abs(value.translation.height) * 1.5
                    else { return }
                    back()
                }
        )
    }

    private var providerName: String { ChatProvider(rawValue: item.provider)?.name ?? item.provider.capitalized }
    private var releaseDate: String {
        guard let created = details?.created, created.isFinite, created > 0 else { return unknown }
        return Date(timeIntervalSince1970: created).formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }
    private func price(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unknown }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(0...4))) + " / 1M"
    }
    private func tokens(_ value: Int?) -> String { value.map { $0.formatted(.number.notation(.compactName)) + " tokens" } ?? unknown }
    private func modalities(_ values: [String]?) -> String { values.flatMap { $0.isEmpty ? nil : $0.map(\.capitalized).joined(separator: ", ") } ?? unknown }
    private func yesNo(_ value: Bool) -> String { value ? copy("Yes", "Oui") : copy("No", "Non") }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true) }
            .padding(14).frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading).modelFactsCard()
    }
    private func labeled(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline).padding(.horizontal, 4); VStack(alignment: .leading, spacing: 12, content: content).padding(16).frame(maxWidth: .infinity, alignment: .leading).modelFactsCard() }
    }
    private func copy(_ english: String, _ french: String) -> String { locale.language.languageCode?.identifier == "fr" ? french : english }
}

private extension View {
    func modelFactsCard() -> some View { background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20)) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
