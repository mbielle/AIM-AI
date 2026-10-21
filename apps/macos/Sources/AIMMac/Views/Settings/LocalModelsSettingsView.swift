import AIMCore
import AIMApplication
import AIMMacPlatform
import SwiftUI

/// Downloads that keep going while Settings is closed.
@MainActor
@Observable
final class LocalModelDownloads {
    static let shared = LocalModelDownloads()
    struct Item: Identifiable { let id: String; var progress: Double; var detail: String; var error: String?; var finished = false }
    private(set) var items: [String: Item] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(repo: String, format: HuggingFaceModelHub.Format, quantization: String? = nil) {
        guard tasks[repo] == nil else { return }
        items[repo] = Item(id: repo, progress: 0, detail: "Preparing…")
        tasks[repo] = Task { [weak self] in
            do {
                let detail = try await HuggingFaceModelHub.detail(repo)
                let files = HuggingFaceModelHub.files(for: detail, format: format, ggufFile: quantization)
                let total = files.reduce(0) { $0 + $1.size }
                self?.items[repo]?.detail = "0 of \(Self.size(total))"
                _ = try await HuggingFaceModelHub.download(detail, files: files, format: format) { progress in
                    Task { @MainActor in
                        self?.items[repo]?.progress = progress.totalBytes > 0 ? Double(progress.completedBytes) / Double(progress.totalBytes) : 0
                        self?.items[repo]?.detail = "\(Self.size(progress.completedBytes)) of \(Self.size(progress.totalBytes)) · \(progress.file)"
                    }
                }
                self?.items[repo]?.progress = 1
                self?.items[repo]?.finished = true
                self?.items[repo]?.detail = "Ready. Choose it in the model picker → Local → My models."
            } catch is CancellationError {
                self?.items[repo]?.error = "Paused. Download again to resume."
            } catch {
                self?.items[repo]?.error = error.localizedDescription
            }
            self?.tasks[repo] = nil
        }
    }

    func cancel(_ repo: String) { tasks[repo]?.cancel() }
    func isRunning(_ repo: String) -> Bool { tasks[repo] != nil }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct LocalModelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var runtimes: [LocalModelRuntime.Status] = []
    @State private var installed: [(repo: String, bytes: Int64)] = []
    @State private var ggufModels: [HuggingFaceModelHub.InstalledModel] = []

    private var engineDescription: String {
        switch model.localEngineState {
        case .idle: "Idle. It starts when you choose a local model."
        case .loading(let name): "Loading \(name)…"
        case .ready(let name): "\(name) is loaded in memory."
        case .failed(let reason): reason
        }
    }

    /// The model's own settings, in the model picker (the same page as from its card).
    private func openSettings(name: String, file: URL) {
        model.pendingLocalModelSettings = LocalModelBrowser.settingsDetail(name: name, file: file)
        model.showModelPicker = true
    }

    private func delete(_ item: HuggingFaceModelHub.InstalledModel) async {
        if await BuiltInLocalEngine.shared.loadedModelFile == item.file { await BuiltInLocalEngine.shared.stop() }
        let folder = item.file.deletingLastPathComponent()
        let prefix = item.file.lastPathComponent.replacingOccurrences(of: #"-00001-of-\d{5}\.gguf$"#, with: "", options: .regularExpression)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent == item.file.lastPathComponent || file.lastPathComponent.hasPrefix(prefix + "-0") {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        await refresh()
    }
    @State private var query = ""
    @State private var format = HuggingFaceModelHub.Format.gguf
    @State private var results: [HuggingFaceModelHub.ModelSummary] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var message: String?
    @State private var busy = false
    private let downloads = LocalModelDownloads.shared

    var body: some View {
        SettingsPage("Local Models", subtitle: "Run open models on this Mac with AIM's built-in engine: private, offline and free. Choose a model in the model picker → Local; AIM loads it into memory and unloads it after 10 minutes without use.") {
            if let message { SettingsNotice(message) }
            SettingsGroup("AIM's engine", footer: "This Mac has \(LocalModelDownloads.size(Int64(ProcessInfo.processInfo.physicalMemory))) of unified memory. Small local models are slower and less reliable with tools than frontier models.") {
                SettingsRow("Built-in engine", description: engineDescription) {
                    if case .ready = model.localEngineState {
                        Button("Unload") { Task { await BuiltInLocalEngine.shared.stop() } }.buttonStyle(.settings)
                    }
                    SettingsStatus(text: BuiltInLocalEngine.isAvailable ? "Included" : "Missing", color: BuiltInLocalEngine.isAvailable ? .green : .orange)
                }
            }
            SettingsGroup("Downloaded models") {
                if ggufModels.isEmpty { SettingsRow("None yet", description: "Download one from the model picker → Local → Add models, or below.") }
                ForEach(ggufModels) { item in
                    SettingsRow(item.name, description: "\(item.repo) · \(LocalModelDownloads.size(item.bytes))") {
                        Button("Use") { Task { do { try await model.useBuiltInModel(item) } catch { message = error.localizedDescription } } }
                            .buttonStyle(.settings)
                        SettingsIconButton(systemImage: "slider.horizontal.3", help: "Settings for \(item.name): context, memory, sampling") {
                            openSettings(name: item.name, file: item.file)
                        }
                        SettingsIconButton(systemImage: "trash", destructive: true, help: "Delete \(item.name) from this Mac") {
                            Task { await delete(item) }
                        }
                    }
                }
            }
            SettingsGroup("MLX models on this Mac") {
                if installed.isEmpty { SettingsRow("None yet", description: "Download one below.") }
                ForEach(installed, id: \.repo) { item in
                    let name = LocalModelBrowser.shortName(item.repo)
                    SettingsRow(name, description: "\(item.repo) · \(LocalModelDownloads.size(item.bytes))") {
                        if let folder = HuggingFaceModelHub.mlxSnapshotFolder(item.repo) {
                            Button("Use") {
                                Task { do { try await model.useBuiltInMLXModel(repo: item.repo, folder: folder) } catch { message = error.localizedDescription } }
                            }.buttonStyle(.settings)
                            SettingsIconButton(systemImage: "slider.horizontal.3", help: "Settings for \(name): context, memory, sampling") {
                                openSettings(name: name, file: folder)
                            }
                        }
                    }
                }
            }
            SettingsDisclosure("Other local servers") {
            SettingsGroup("Servers", footer: "This Mac has \(LocalModelDownloads.size(Int64(ProcessInfo.processInfo.physicalMemory))) of unified memory. Small local models are slower and less reliable with tools than frontier models.") {
                ForEach(runtimes) { runtime in
                    let inUse = LocalModelEndpoint.baseURL == runtime.kind.baseURL && model.connectedProviders.contains(.local)
                    SettingsRow(runtime.kind.name,
                                description: runtime.running ? "Running · \(runtime.models.count) model(s) · \(runtime.kind.baseURL.absoluteString)"
                                    : (runtime.installed ? "Installed, not running" : "Not installed")) {
                        if runtime.running {
                            if inUse { SettingsStatus(text: "In use") }
                            else { Button("Use in AIM") { Task { await use(runtime.kind) } }.buttonStyle(.settingsPrimary) }
                        } else if runtime.installed {
                            Button("Start") { Task { await start(runtime.kind) } }.buttonStyle(.settings).disabled(busy)
                        }
                    }
                }
                SettingsRow("Detection", description: "AIM looks for servers on their usual local ports.") {
                    if model.connectedProviders.contains(.local) {
                        Button("Stop using local models") { model.removeProviderKey(.local) }.buttonStyle(.settings)
                    }
                    Button("Refresh") { Task { await refresh() } }.buttonStyle(.settings)
                }
            }
            }
            SettingsGroup("Download from Hugging Face") {
                SettingsBlock {
                    HStack(spacing: 8) {
                        TextField("Search, e.g. Qwen3 4B", text: $query).textFieldStyle(.settings)
                            .onSubmit { Task { await search() } }
                        Picker("Format", selection: $format) {
                            Text("MLX").tag(HuggingFaceModelHub.Format.mlx)
                            Text("GGUF").tag(HuggingFaceModelHub.Format.gguf)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
                        Button("Search") { Task { await search() } }.buttonStyle(.settingsPrimary)
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                ForEach(results) { result in resultRow(result) }
            }
        }
        .task { await refresh() }
    }

    @ViewBuilder private func resultRow(_ result: HuggingFaceModelHub.ModelSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(result.id, description: resultDetail(result)) {
                if let bytes = sizes[result.id] { fitBadge(HuggingFaceModelHub.fit(weightsBytes: bytes)) }
                if downloads.isRunning(result.id) {
                    Button("Pause") { downloads.cancel(result.id) }.buttonStyle(.settings)
                } else if downloads.items[result.id]?.finished == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Download") { downloads.start(repo: result.id, format: format) }.buttonStyle(.settings)
                }
            }
            if let item = downloads.items[result.id] {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: item.progress).tint(AIMTheme.toggleOn)
                    Text(item.error ?? item.detail).font(.system(size: 11)).foregroundStyle(item.error == nil ? Color.secondary : Color.red)
                }
                .padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.bottom, 14)
            }
        }
        .task(id: result.id) {
            guard sizes[result.id] == nil, let detail = try? await HuggingFaceModelHub.detail(result.id) else { return }
            sizes[result.id] = HuggingFaceModelHub.files(for: detail, format: format).reduce(0) { $0 + $1.size }
        }
    }

    private func resultDetail(_ result: HuggingFaceModelHub.ModelSummary) -> String {
        var parts = ["\(result.downloads.formatted()) downloads"]
        if result.supportsTools { parts.append("tools") }
        if let bytes = sizes[result.id] { parts.append(LocalModelDownloads.size(bytes)) }
        return parts.joined(separator: " · ")
    }

    private func fitBadge(_ fit: HuggingFaceModelHub.Fit) -> some View {
        let (text, color): (String, Color) = switch fit {
        case .comfortable: ("fits well", .green)
        case .tight: ("tight fit", .orange)
        case .tooLarge: ("too large for this Mac", .red)
        }
        return SettingsStatus(text: text, color: color)
    }

    private func refresh() async {
        runtimes = await LocalModelRuntime.detect()
        installed = HuggingFaceModelHub.installedMLXModels()
        ggufModels = HuggingFaceModelHub.installedGGUFModels()
    }

    private func start(_ kind: LocalModelRuntime.Kind) async {
        busy = true
        defer { busy = false }
        message = "Starting \(kind.name)…"
        do {
            let models = try await LocalModelRuntime.start(kind)
            message = "\(kind.name) is running with \(models.count) model(s)."
        } catch { message = error.localizedDescription }
        await refresh()
    }

    private func use(_ kind: LocalModelRuntime.Kind) async {
        do {
            try await model.connectLocalModels(baseURL: kind.baseURL)
            message = "AIM now lists \(kind.name)'s models under “On this Mac (local)” in the model picker."
        } catch { message = "Could not reach \(kind.name): \(error.localizedDescription)" }
        await refresh()
    }

    private func search() async {
        message = nil
        sizes = [:]
        do { results = try await HuggingFaceModelHub.search(query, format: format) }
        catch { message = error.localizedDescription }
    }
}
