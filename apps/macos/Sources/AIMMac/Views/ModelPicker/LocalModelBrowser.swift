import AIMCore
import AIMApplication
import AIMMacPlatform
import AppKit
import SwiftUI

/// The "Local" side of the model picker. My models: what AIM has downloaded, run by AIM's
/// built-in engine in one click. Add models: the whole Hugging Face catalog, page by page,
/// with a full sheet per repository.
struct LocalModelBrowser: View {
    let tab: ModelPickerView.Tab
    let query: String
    @Binding var detail: String?
    let switchTab: (ModelPickerView.Tab) -> Void

    @Environment(AppModel.self) private var model
    @State private var installed: [HuggingFaceModelHub.InstalledModel] = []
    @State private var mlxModels: [(repo: String, bytes: Int64)] = []
    @State private var external: [LocalModelRuntime.Status] = []
    @State private var results: [HuggingFaceModelHub.ModelSummary] = []
    @State private var nextPage: URL?
    @State private var format = HuggingFaceModelHub.Format.mlx
    @State private var sort = HuggingFaceModelHub.Sort.downloads
    @State private var showSort = false
    @State private var searching = false
    @State private var message: String?
    @State private var loading: String?
    @State private var showExternal = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let message { SettingsNotice(message, tone: .warning) }
                if let detail, detail.hasPrefix(Self.settingsPrefix) {
                    let target = Self.settingsTarget(detail)
                    LocalModelSettingsView(name: target.name, file: target.file, creator: Self.creator(for: target.name))
                } else if let detail {
                    LocalRepositoryDetail(repo: detail, format: format, summary: results.first { $0.id == detail })
                } else if tab == .mine {
                    myModels
                } else {
                    catalog
                }
            }
            .padding(.horizontal, 22).padding(.top, ModelPickerView.headerHeight + 4).padding(.bottom, ModelPickerView.footerHeight + 16)
        }
        #if DEBUG
        .onChange(of: model.debugOpenMenu) { _, menu in
            if menu == "local-sampling" { proxy.scrollTo("local-sampling", anchor: .top) }
        }
        #endif
        }
        .task { await refresh() }
        .task(id: "\(tab == .add)|\(query)|\(format.rawValue)|\(sort.rawValue)") {
            guard tab == .add else { return }
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await search(reset: true)
        }
        .onChange(of: LocalModelDownloads.shared.items.values.filter(\.finished).count) { _, _ in Task { await refresh() } }
    }

    // MARK: My models

    @ViewBuilder private var myModels: some View {
        let mine = installed.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.repo.localizedCaseInsensitiveContains(query) }
        if !BuiltInLocalEngine.isAvailable {
            SettingsNotice("This copy of AIM was built without its local model engine.", tone: .warning)
        }
        if mine.isEmpty && downloading.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "cpu").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("No local model yet").font(.system(size: 14, weight: .medium))
                Text(BuiltInLocalEngine.isAvailable ? "Download an open model from Hugging Face; AIM runs it privately on this Mac, offline and free." : "Local downloads require a copy of AIM with its local model engine. Existing external servers remain available below.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Browse Hugging Face") { switchTab(.add) }.buttonStyle(.settingsPrimary)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("On this Mac").font(.system(size: 14, weight: .semibold))
                    Text(engineStatus).font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 228), spacing: 10)], spacing: 10) {
                    ForEach(mine) { item in
                        ModelCard(name: item.name, creator: Self.creator(for: item.repo),
                                  meta: loading == item.name ? "Loading into memory…" : "\(LocalModelDownloads.size(item.bytes)) · " + (BuiltInLocalEngine.isAvailable ? "runs on this Mac" : "local engine required"),
                                  capabilities: [], selected: model.selectedProvider == .local && model.selectedModelID == item.name,
                                  mode: .select(pinned: false), primary: { Task { await use(item) } },
                                  info: { detail = item.repo }, settings: { detail = Self.settingsDetail(name: item.name, file: item.file) })
                    }
                    ForEach(downloading, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 9) {
                                ModelCreatorLogo(creator: Self.creator(for: item.id), size: 20)
                                Text(Self.shortName(item.id)).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                            }
                            ProgressView(value: item.progress).tint(AIMTheme.toggleOn)
                            Text(item.error ?? item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        if !mlxModels.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("MLX models").font(.system(size: 14, weight: .semibold))
                    Text("Apple's MLX engine, fastest on this Mac").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                if !BuiltInLocalEngine.isMLXAvailable {
                    SettingsNotice("This copy of AIM was built without its MLX engine.", tone: .warning)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 228), spacing: 10)], spacing: 10) {
                    ForEach(mlxModels.filter { query.isEmpty || $0.repo.localizedCaseInsensitiveContains(query) }, id: \.repo) { item in
                        let name = Self.shortName(item.repo)
                        ModelCard(name: name, creator: Self.creator(for: item.repo),
                                  meta: loading == name ? "Loading into memory…" : LocalModelDownloads.size(item.bytes) + (BuiltInLocalEngine.isMLXAvailable ? " · MLX · runs on this Mac" : " · MLX engine required"),
                                  capabilities: [], selected: model.selectedProvider == .local && model.selectedModelID == name,
                                  mode: .select(pinned: false), primary: { Task { await useMLX(item.repo) } },
                                  info: { detail = item.repo }, settings: {
                                      if let folder = HuggingFaceModelHub.mlxSnapshotFolder(item.repo) {
                                          detail = Self.settingsDetail(name: name, file: folder)
                                      }
                                  })
                    }
                }
            }
        }
        let running = external.filter(\.running)
        if !running.isEmpty {
            SettingsDisclosure("Other local servers") {
                ForEach(running) { status in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status.kind.name).font(.system(size: 13, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 228), spacing: 10)], spacing: 10) {
                            ForEach(status.models, id: \.self) { id in
                                ModelCard(name: Self.shortName(id), creator: Self.creator(for: id), meta: "Served by \(status.kind.name)",
                                          capabilities: [], selected: model.selectedProvider == .local && model.selectedModelID == id,
                                          mode: .select(pinned: false), primary: { Task { await useExternal(id, on: status.kind) } })
                            }
                        }
                    }
                }
            }
        }
    }

    private var downloading: [LocalModelDownloads.Item] {
        LocalModelDownloads.shared.items.values.filter { !$0.finished }.sorted { $0.id < $1.id }
    }

    private var engineStatus: String {
        switch model.localEngineState {
        case .idle: return "Loads when you choose a model"
        case .loading(let name): return "Loading \(name)…"
        case .ready(let name): return "\(name) is loaded"
        case .failed: return "Last load failed"
        }
    }

    // MARK: Hugging Face catalog

    @ViewBuilder private var catalog: some View {
        HStack(spacing: 10) {
            Text(query.isEmpty ? "Hugging Face" : "Results on Hugging Face").font(.system(size: 14, weight: .semibold))
            if searching { ProgressView().controlSize(.small) }
            Spacer()
            Button { showSort.toggle() } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down").font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 28)
            }
            .buttonStyle(.aimHover(radius: 8, active: showSort))
            .aimMenu(isPresented: $showSort, alignment: .trailing) {
                ForEach(HuggingFaceModelHub.Sort.allCases, id: \.self) { option in
                    AIMMenuItem(option.title, checked: option == sort) { sort = option }
                }
            }
            AIMSegmentedControl(selection: $format, options: [(.mlx, "MLX"), (.gguf, "GGUF")], compact: true, identifierPrefix: "hf-format-")
                .help("MLX: Apple's engine, fastest on this Mac. GGUF: llama.cpp, the widest choice of models.")
        }
        if query.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text((format == .mlx ? BuiltInLocalEngine.isMLXAvailable : BuiltInLocalEngine.isAvailable) ? "Recommended for this Mac" : "Models to explore · engine required").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 228), spacing: 10)], spacing: 10) {
                    ForEach(Self.recommended(memoryBytes: ProcessInfo.processInfo.physicalMemory, format: format), id: \.repo) { pick in
                        let downloaded = installed.contains { $0.repo == pick.repo } || mlxModels.contains { $0.repo == pick.repo }
                        ModelCard(name: pick.name, creator: Self.creator(for: pick.repo), meta: pick.note, capabilities: [.tools],
                                  selected: false, mode: .add(added: downloaded), primary: { detail = pick.repo },
                                  toggleAdded: { detail = pick.repo })
                    }
                }
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 228), spacing: 10)], spacing: 10) {
            ForEach(results) { result in
                let downloaded = installed.contains { $0.repo == result.id } || LocalModelDownloads.shared.items[result.id]?.finished == true
                ModelCard(name: Self.shortName(result.id), creator: Self.creator(for: result.id),
                          meta: "\(result.id.split(separator: "/").first.map(String.init) ?? "") · \(Self.count(result.downloads)) downloads",
                          capabilities: result.supportsTools ? [.tools] : [], selected: false,
                          mode: .add(added: downloaded), primary: { detail = result.id },
                          toggleAdded: {
                              if !downloaded, !LocalModelDownloads.shared.isRunning(result.id) {
                                  LocalModelDownloads.shared.start(repo: result.id, format: format)
                              }
                              detail = result.id
                          })
                    .onAppear { if result.id == results.last?.id { Task { await search(reset: false) } } }
            }
        }
        if results.isEmpty && !searching {
            Text("No model found.").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    // MARK: Model settings

    /// `detail` value that opens a model's settings: its engine name and its file or folder.
    static let settingsPrefix = "settings:"

    static func settingsDetail(name: String, file: URL) -> String {
        settingsPrefix + name + "\n" + file.path
    }

    static func settingsTarget(_ detail: String) -> (name: String, file: URL?) {
        let parts = detail.dropFirst(settingsPrefix.count).split(separator: "\n", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? URL(fileURLWithPath: parts[1]) : nil)
    }

    // MARK: Actions

    private func refresh() async {
        installed = HuggingFaceModelHub.installedGGUFModels()
        mlxModels = HuggingFaceModelHub.installedMLXModels().filter { !$0.repo.contains("whisper") && !$0.repo.contains("sentence-transformers") }
        external = await LocalModelRuntime.detect()
    }

    private func search(reset: Bool) async {
        if !reset && nextPage == nil { return }
        guard !searching else { return }
        searching = true
        defer { searching = false }
        do {
            let page = try await HuggingFaceModelHub.searchPage(query, format: format, sort: sort, next: reset ? nil : nextPage)
            if reset { results = page.models } else {
                let known = Set(results.map(\.id))
                results += page.models.filter { !known.contains($0.id) }
            }
            nextPage = page.next
            message = nil
        } catch { message = "Hugging Face is unreachable: \(error.localizedDescription)" }
    }

    private func use(_ item: HuggingFaceModelHub.InstalledModel) async {
        loading = item.name
        defer { loading = nil }
        do { try await model.useBuiltInModel(item) }
        catch { message = error.localizedDescription }
    }

    private func useMLX(_ repo: String) async {
        guard let folder = HuggingFaceModelHub.mlxSnapshotFolder(repo) else { message = "This MLX model's files are incomplete. Download it again."; return }
        let name = Self.shortName(repo)
        loading = name
        defer { loading = nil }
        do { try await model.useBuiltInMLXModel(repo: repo, folder: folder) }
        catch { message = error.localizedDescription }
    }

    private func useExternal(_ id: String, on kind: LocalModelRuntime.Kind) async {
        do {
            if !(model.connectedProviders.contains(.local) && LocalModelEndpoint.baseURL == kind.baseURL) {
                try await model.connectLocalModels(baseURL: kind.baseURL)
            }
            model.selectProvider(.local)
            model.availableModels = (try? await ProviderChatService().models(provider: .local, apiKey: nil)) ?? []
            model.selectModel(id)
        } catch { message = "Could not reach \(kind.name): \(error.localizedDescription)" }
    }

    /// Well-tested open models sized for the Mac's memory (GGUF, AIM's built-in engine).
    static func recommended(memoryBytes: UInt64, format: HuggingFaceModelHub.Format = .gguf) -> [(repo: String, name: String, note: String)] {
        let gigabytes = Double(memoryBytes) / 1e9
        var picks: [(String, String, String)] = []
        if format == .mlx {
            if gigabytes >= 30 { picks.append(("mlx-community/Qwen3-30B-A3B-4bit", "Qwen3 30B A3B", "~17 GB · best quality here, fast")) }
            if gigabytes >= 14 { picks.append(("mlx-community/Qwen3-8B-4bit", "Qwen3 8B", "~4.6 GB · great all-rounder, French, tools")) }
            picks.append(("mlx-community/gemma-3-4b-it-4bit", "Gemma 3 4B", "~3 GB · light and quick"))
            picks.append(("mlx-community/Qwen3-4B-4bit", "Qwen3 4B", "~2.3 GB · small, good with tools"))
            return picks.map { (repo: $0.0, name: $0.1, note: $0.2) }
        }
        if gigabytes >= 30 { picks.append(("unsloth/Qwen3-30B-A3B-GGUF", "Qwen3 30B A3B", "~18 GB · best quality here, fast")) }
        if gigabytes >= 14 { picks.append(("unsloth/Qwen3-8B-GGUF", "Qwen3 8B", "~5 GB · great all-rounder, French, tools")) }
        picks.append(("unsloth/gemma-3-4b-it-GGUF", "Gemma 3 4B", "~2.5 GB · light and quick, reads images"))
        picks.append(("unsloth/Qwen3-4B-GGUF", "Qwen3 4B", "~2.5 GB · small, good with tools"))
        return picks.map { (repo: $0.0, name: $0.1, note: $0.2) }
    }

    // MARK: Naming

    static func shortName(_ id: String) -> String {
        String(id.split(separator: "/").last ?? Substring(id))
    }

    static func count(_ value: Int) -> String {
        value >= 1_000_000 ? (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M"
            : value >= 1_000 ? "\(value / 1_000)K" : "\(value)"
    }

    /// Guesses the model's maker from its name, for the logo (local repos are often re-uploads).
    static func creator(for id: String) -> String {
        let name = id.lowercased()
        let table: [(String, String)] = [
            ("qwen", "qwen"), ("qwq", "qwen"), ("llama", "meta-llama"), ("gemma", "gemma"), ("mistral", "mistralai"),
            ("mixtral", "mistralai"), ("ministral", "mistralai"), ("devstral", "mistralai"), ("deepseek", "deepseek"),
            ("phi", "microsoft"), ("granite", "ibm-granite"), ("glm", "z-ai"), ("kimi", "moonshotai"), ("gpt-oss", "openai"),
            ("nemotron", "nvidia"), ("smollm", "huggingface"), ("hermes", "nousresearch"), ("olmo", "allenai"),
            ("minimax", "minimax"), ("lfm", "liquid"), ("ernie", "baidu"), ("hunyuan", "tencent"), ("internlm", "internlm"),
            ("command", "cohere"), ("aya", "cohere"), ("falcon", "tiiuae"), ("yi-", "01-ai"), ("seed", "bytedance"),
        ]
        // Otherwise the repository's organization (its Hugging Face avatar is used as logo).
        return table.first { name.contains($0.0) }?.1 ?? String(id.split(separator: "/").first ?? "huggingface")
    }
}

/// One Hugging Face repository, as complete as its page: facts, variants with their size
/// and fit on this Mac, one-click download, and the model card itself.
private struct LocalRepositoryDetail: View {
    let repo: String
    let format: HuggingFaceModelHub.Format
    let summary: HuggingFaceModelHub.ModelSummary?
    @Environment(\.colorScheme) private var scheme
    @State private var info: HuggingFaceModelHub.RepositoryInfo?
    @State private var variants: [HuggingFaceModelHub.Quantization] = []
    @State private var mlxBytes: Int64?
    @State private var gated = false
    @State private var readme: String?
    @State private var showFullReadme = false
    @State private var error: String?
    @State private var speed: [ModelStatsStore.SpeedSample] = []
    private let downloads = LocalModelDownloads.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                ModelCreatorLogo(creator: LocalModelBrowser.creator(for: repo), size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalModelBrowser.shortName(repo)).font(.system(size: 22, weight: .semibold))
                    Text(repo).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Link(destination: URL(string: "https://huggingface.co/\(repo)")!) {
                    Label("Hugging Face", systemImage: "arrow.up.right.square")
                }.buttonStyle(.settings)
                if format == .mlx { mlxDownloadButton }
            }
            if let item = downloads.items[repo] {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: item.progress).tint(AIMTheme.toggleOn)
                    Text(item.error ?? item.detail).font(.system(size: 12)).foregroundStyle(item.error == nil ? Color.secondary : Color.red)
                }
            }
            if let error { SettingsNotice(error, tone: .warning) }
            if gated { SettingsNotice("This repository asks you to accept its terms on Hugging Face before downloading.", tone: .warning) }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                if let parameters = info?.parameters { fact("Parameters", Self.parameters(parameters)) }
                if let architecture = info?.architecture { fact("Architecture", architecture) }
                if let context = info?.contextLength { fact("Context", ModelFacts.tokens(context) + " tokens") }
                if let types = info?.tensorTypes, !types.isEmpty { fact("Tensor type", types.joined(separator: " · ")) }
                if let license = info?.license { fact("License", license) }
                fact("Downloads", LocalModelBrowser.count(info?.downloads ?? summary?.downloads ?? 0))
                fact("Likes", LocalModelBrowser.count(info?.likes ?? summary?.likes ?? 0))
                if let date = info?.lastModified.flatMap(Self.date) { fact("Updated", date.formatted(date: .abbreviated, time: .omitted)) }
            }

            if !speed.isEmpty { ModelSpeedSection(samples: speed, local: true) }

            if format == .gguf && !variants.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Versions").font(.system(size: 14, weight: .semibold))
                    Text("Smaller versions use less memory and run faster; larger ones are more precise. AIM suggests the best fit for this Mac.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    SettingsCard {
                        let best = HuggingFaceModelHub.bestQuantization(variants)
                        ForEach(variants) { variant in
                            let fit = HuggingFaceModelHub.fit(weightsBytes: variant.bytes)
                            SettingsRow(variant.name, description: "\(LocalModelDownloads.size(variant.bytes)) · \(Self.fitText(fit))"
                                        + (variant == best ? " · recommended" : "")) {
                                if downloads.isRunning(repo) {
                                    EmptyView()
                                } else {
                                    Button(variant == best ? "Download" : "Get") {
                                        downloads.start(repo: repo, format: .gguf, quantization: variant.name)
                                    }
                                    .buttonStyle(variant == best ? .settingsPrimary : .settings)
                                    .disabled(gated || fit == .tooLarge)
                                }
                            }
                        }
                    }
                }
            }

            if let base = info?.baseModels, !base.isEmpty { labeled("Based on", base.joined(separator: ", ")) }
            if let languages = info?.languages, !languages.isEmpty { labeled("Languages", languages.joined(separator: ", ")) }
            if let tags = info?.tags, !tags.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag).font(.system(size: 11.5)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }
            }

            if let readme, !readme.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Model card").font(.system(size: 14, weight: .semibold))
                    NativeMarkdownView(source: showFullReadme ? readme : String(readme.prefix(4_000)),
                                       appearance: ConversationAppearance(typeface: .system, textSize: 13))
                        .padding(16)
                        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
                    if readme.count > 4_000 {
                        Button(showFullReadme ? "Show less" : "Show the full model card") { showFullReadme.toggle() }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(AIMTheme.toggleOn)
                    }
                }
            }
        }
        .task(id: "\(repo)|\(format.rawValue)") { await load() }
    }

    @ViewBuilder private var mlxDownloadButton: some View {
        if downloads.isRunning(repo) {
            Button("Pause") { downloads.cancel(repo) }.buttonStyle(.settings)
        } else if downloads.items[repo]?.finished == true {
            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 13, weight: .medium))
        } else {
            Button { downloads.start(repo: repo, format: .mlx) } label: {
                Label(mlxBytes.map { "Download · " + LocalModelDownloads.size($0) } ?? "Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.settingsPrimary).disabled(gated)
        }
    }

    private func load() async {
        speed = await ModelStatsStore.shared.localSpeed(repo: repo)
        async let infoTask = try? HuggingFaceModelHub.info(repo)
        async let readmeTask = try? HuggingFaceModelHub.readme(repo)
        do {
            let detail = try await HuggingFaceModelHub.detail(repo)
            gated = detail.gated
            variants = HuggingFaceModelHub.ggufQuantizations(detail)
            mlxBytes = HuggingFaceModelHub.files(for: detail, format: .mlx).reduce(0) { $0 + $1.size }
        } catch { self.error = "Details unavailable: \(error.localizedDescription)" }
        info = await infoTask
        readme = await readmeTask
    }

    private static func parameters(_ count: Int64) -> String {
        count >= 1_000_000_000 ? (Double(count) / 1e9).formatted(.number.precision(.fractionLength(0...1))) + "B"
            : (Double(count) / 1e6).formatted(.number.precision(.fractionLength(0))) + "M"
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func fitText(_ fit: HuggingFaceModelHub.Fit) -> String {
        switch fit { case .comfortable: "fits well"; case .tight: "tight fit"; case .tooLarge: "too large for this Mac" }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).font(.system(size: 12.5)).textSelection(.enabled)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).kerning(0.3)
            Text(value).font(.system(size: 15, weight: .medium)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(12)
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }
}
