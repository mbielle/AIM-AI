import AIMApplication
import SwiftUI

/// One deliberate, possibly billed request for an image or a video; never started from
/// ordinary chat text. OpenAI (GPT Image), Black Forest Labs (FLUX, own key) and OpenRouter.
struct ImageGenerationView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Choice: Hashable, Identifiable {
        case openAI(OpenAIImageModel)
        case media(MediaModel)
        var id: String {
            switch self {
            case .openAI(let model): "openai/" + model.rawValue
            case .media(let model): model.id
            }
        }
        var title: String {
            switch self {
            case .openAI(let model): model.title
            case .media(let model): model.name
            }
        }
        var creator: String {
            switch self {
            case .openAI: "openai"
            case .media(let model): model.creator
            }
        }
    }

    @State private var kind: MediaKind = .image
    @State private var choice: Choice?
    @State private var route: MediaRoute = .blackForestLabs
    @State private var mediaModels: [MediaModel] = []
    @State private var loaded = false
    @State private var prompt = ""
    @State private var fluxKey = ""
    @State private var size: OpenAIImageSize = .square
    @State private var quality: OpenAIImageQuality = .medium
    @State private var aspect = "auto"
    @State private var resolution = ""
    @State private var duration = 0
    @State private var audio = true
    @State private var useReferences = true
    @State private var error: String?
    @State private var working = false
    @State private var showOpenAISetup = false

    private var choices: [Choice] {
        let media = mediaModels.filter { $0.kind == kind }.map(Choice.media)
        return kind == .image ? OpenAIImageModel.allCases.map(Choice.openAI) + media : media
    }

    private var routes: [MediaRoute] {
        guard case .media(let model) = choice else { return [] }
        return model.routes(hasBFLKey: true, hasOpenRouter: app.connectedProviders.contains(.openRouter))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Create").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { if working { app.cancelImageGeneration() }; dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            AIMSegmentedControl(selection: $kind, options: [(.image, "Image"), (.video, "Video")], compact: true)
                .disabled(working)
            modelRow
            if routes.count > 1 {
                AIMSegmentedControl(selection: $route, options: routes.map { ($0, $0.title) }, compact: true)
                    .disabled(working)
            }
            TextEditor(text: $prompt)
                .font(.body)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text(kind == .video ? "Describe the video: subject, motion, camera, sound…" : "Describe the image…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 1).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(kind == .video ? "Video description" : "Image description")
            optionsRow.disabled(working)
            if !app.pendingImages.isEmpty, case .media = choice {
                Toggle(isOn: $useReferences) {
                    Text("Use the \(app.pendingImages.count) image\(app.pendingImages.count == 1 ? "" : "s") attached in the chat bar as reference")
                }.toggleStyle(.checkbox).font(.callout)
            }
            requirementRow
            Text(billingNote).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(kind == .video ? "Creating the video… this can take a few minutes." : "Creating the image…")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Cancel") { app.cancelImageGeneration() }
                }
                Spacer()
                Button(kind == .video ? "Create video" : "Create image", action: create)
                    .buttonStyle(.settingsPrimary)
                    .disabled(working || !ready || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 660)
        .sheet(isPresented: $showOpenAISetup) { ProviderSetupView(initialProvider: .openAI) }
        .onDisappear { if working { app.cancelImageGeneration() } }
        .task { await load() }
        .onChange(of: kind) { _, _ in if !choices.contains(where: { $0 == choice }) { choice = choices.first }; resetOptions() }
        .onChange(of: choice) { _, _ in
            if !routes.contains(route), let first = routes.first { route = first }
            if case .media(let model) = choice, model.bflEndpoint != nil, app.hasFluxKey { route = .blackForestLabs }
            resetOptions()
        }
    }

    // MARK: Rows

    private var modelRow: some View {
        HStack(spacing: 10) {
            if let choice { ModelCreatorLogo(creator: choice.creator, size: 20) }
            Picker("Model", selection: $choice) {
                ForEach(choices) { item in Text(item.title).tag(Optional(item)) }
            }
            .disabled(working || choices.isEmpty)
            if !loaded { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var optionsRow: some View {
        HStack(spacing: 14) {
            switch choice {
            case .openAI:
                Picker("Size", selection: $size) { ForEach(OpenAIImageSize.allCases) { Text($0.title).tag($0) } }
                Picker("Quality", selection: $quality) { ForEach(OpenAIImageQuality.allCases) { Text($0.title).tag($0) } }
            case .media:
                Picker("Format", selection: $aspect) {
                    ForEach(aspects, id: \.self) { Text($0 == "auto" ? "Auto" : $0).tag($0) }
                }
                if !resolutions.isEmpty {
                    Picker("Quality", selection: $resolution) {
                        ForEach(resolutions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                if kind == .video {
                    Picker("Length", selection: $duration) {
                        Text("Auto").tag(0)
                        ForEach([5, 8, 10, 15, 20], id: \.self) { Text("\($0) s").tag($0) }
                    }
                    Toggle("Sound", isOn: $audio).toggleStyle(.checkbox)
                }
            case nil:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var requirementRow: some View {
        switch choice {
        case .openAI where !app.connectedProviders.contains(.openAI):
            HStack {
                Label("An OpenAI API key is required.", systemImage: "key")
                Spacer()
                Button("Add key…") { showOpenAISetup = true }
            }.font(.callout)
        case .media(let model) where route == .blackForestLabs && model.bflEndpoint != nil && !app.hasFluxKey:
            HStack(spacing: 8) {
                SecureField("Black Forest Labs API key", text: $fluxKey).textFieldStyle(.settings)
                Button("Save") {
                    do { try app.saveFluxKey(fluxKey); fluxKey = "" } catch { self.error = error.localizedDescription }
                }.buttonStyle(.settings).disabled(fluxKey.isEmpty)
                Link("Get a key", destination: BlackForestLabsImageService.keyURL).font(.callout)
            }
        case .media where routes.isEmpty:
            Label("Connect OpenRouter in Settings → Providers to use this model.", systemImage: "key").font(.callout)
        case nil where loaded:
            Label(kind == .video ? "Add a Black Forest Labs key or connect OpenRouter to create videos." : "No image model available.",
                  systemImage: "key").font(.callout)
        default:
            EmptyView()
        }
    }

    // MARK: Logic

    private var ready: Bool {
        switch choice {
        case .openAI: app.connectedProviders.contains(.openAI)
        case .media: route == .blackForestLabs ? app.hasFluxKey : app.connectedProviders.contains(.openRouter)
        case nil: false
        }
    }

    private var billingNote: String {
        switch choice {
        case .openAI: "Sent directly to OpenAI with your API key, which may be charged."
        case .media where route == .blackForestLabs: "Sent directly to Black Forest Labs with your key; it bills your credits."
        case .media: "Sent through OpenRouter; billed to your OpenRouter credits."
        case nil: ""
        }
    }

    private var isFlux3: Bool {
        if case .media(let model) = choice, route == .blackForestLabs { return model.bflEndpoint?.hasPrefix("flux-3") == true }
        return false
    }

    private var aspects: [String] {
        kind == .video ? ["auto", "16:9", "9:16", "1:1", "4:3", "3:4", "21:9"] : ["auto", "1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "21:9"]
    }

    private var resolutions: [(String, String)] {
        if kind == .video {
            return isFlux3 ? [("hd", "HD"), ("fhd", "Full HD"), ("qhd", "QHD"), ("uhd", "4K")] : [("", "Default"), ("720p", "720p"), ("1080p", "1080p")]
        }
        guard case .media(let model) = choice else { return [] }
        if isFlux3 { return [("1k", "1K"), ("1.5k", "1.5K"), ("2k", "2K"), ("4k", "4K")] }
        return route == .openRouter && model.bflEndpoint == nil ? [("", "Default"), ("1K", "1K"), ("2K", "2K"), ("4K", "4K")] : []
    }

    private func resetOptions() {
        aspect = "auto"
        resolution = resolutions.first?.0 ?? ""
        if kind == .video { duration = 0 }
    }

    private func load() async {
        await app.refreshFluxKey()
        mediaModels = await app.availableMediaModels()
        if let preset = app.mediaCreatorPreset, let model = mediaModels.first(where: { $0.id == preset }) {
            kind = model.kind
            choice = .media(model)
        } else {
            choice = choices.first
        }
        app.mediaCreatorPreset = nil
        if let first = routes.first, !routes.contains(route) { route = first }
        resetOptions()
        loaded = true
    }

    private func create() {
        guard let choice else { return }
        working = true
        error = nil
        let text = prompt
        Task {
            do {
                switch choice {
                case .openAI(let model):
                    try await app.generateImage(prompt: text, model: model, size: size, quality: quality)
                case .media(let model):
                    let options = MediaOptions(aspectRatio: aspect, resolution: resolution.isEmpty ? nil : resolution,
                                               durationSeconds: duration == 0 ? nil : duration, generateAudio: audio,
                                               references: useReferences ? app.pendingImages : [])
                    try await app.generateMedia(prompt: text, model: model, route: route, options: options)
                }
                working = false
                dismiss()
            } catch is CancellationError {
                working = false
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
