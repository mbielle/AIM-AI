import AIMCore
import AVFoundation
import SwiftUI

struct AIMVoiceOrb: View {
    var active = false
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.primary.opacity(0.9), .primary.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: active ? "waveform" : "waveform.circle").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(Color(uiColor: .systemBackground))
        }.frame(width: 112, height: 112).accessibilityHidden(true)
    }
}
struct AIMVoiceSettingsView: View {
    let chat: NativeChatStore
    let openHistory: () -> Void
    let back: () -> Void
    @State private var models: [AIMSpeechModel] = []
    @State private var elevenVoices: [AIMSpeechVoice] = []
    @State private var keyDraft = ""
    @State private var loading = false
    @State private var showPreviewConsent = false
    @State private var showStartConsent = false
    @State private var conversationModels: [ChatModel] = []
    @State private var conversationProvider: ChatProvider?
    @State private var loadingConversation = false
    @State private var conversationError: String?
    @AppStorage("aim.voice.identifier") private var systemVoice = ""
    @AppStorage("aim.voice.rate") private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    private var voice: AIMVoiceController { chat.voiceController }
    private var voiceName: String {
        if voice.configuration.engine == .realtime { return voice.configuration.voice.capitalized }
        if voice.configuration.provider == .system { return AVSpeechSynthesisVoice(identifier: systemVoice)?.name ?? "System voice" }
        if voice.configuration.provider == .elevenLabs { return elevenVoices.first { $0.id == voice.configuration.elevenLabsVoice }?.name ?? "Choose voice" }
        return voice.configuration.voice.capitalized
    }
    private var speechProviderName: String { switch voice.configuration.provider { case .system: "This iPhone"; case .openAI: "OpenAI"; case .openRouter: "OpenRouter"; case .elevenLabs: "ElevenLabs" } }
    private var voiceDescription: String {
        if voice.configuration.engine == .realtime { return "Live, AI-generated speech · OpenAI" }
        if voice.configuration.provider == .system {
            let language = AVSpeechSynthesisVoice(identifier: systemVoice)?.language ?? Locale.current.identifier
            return "On-device speech · " + (Locale.current.localizedString(forIdentifier: language) ?? language)
        }
        return "AI-generated speech · " + speechProviderName
    }
    private var selectedConversationProvider: ChatProvider { conversationProvider ?? voice.resolvedConversationSelection.provider }
    private var previewInformation: String {
        if voice.configuration.engine == .realtime {
            return "OpenAI · " + RealtimeVoiceProtocol.defaultModel + ". Reads one short sample with the selected voice. The microphone stays off. OpenAI audio charges apply; the estimated cost is recorded after the response."
        }
        let selected = models.first { $0.id == voice.configuration.speechModel }
        let estimate = selected?.usdPerCharacter.map { (Double("Hello, I’m AIM. Let’s get started.".count) * $0).formatted(.currency(code: "USD").precision(.fractionLength(2...6))) }
        return speechProviderName + " · " + voice.configuration.speechModel + ". A short speech request uses your key. " + (estimate.map { "Estimated sample: " + $0 + "." } ?? "Provider audio charges apply; a reliable sample price is unavailable.")
    }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Voice", back: back)
            AIMSettingsForm {
                Section {
                    VStack(spacing: 14) {
                        AIMVoiceOrb(active: voice.active)
                        Text(voiceName).font(.system(.title3, weight: .semibold))
                        Text(voiceDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Preview voice", systemImage: "play.fill") {
                            if voice.configuration.provider == .system && voice.configuration.engine == .cascade { chat.speak("Hello, I’m AIM. Let’s get started.") }
                            else { showPreviewConsent = true }
                        }.buttonStyle(.plain).frame(minHeight: 44).disabled(voice.active || chat.isSending || (voice.configuration.engine == .realtime && !chat.connectedProviders.contains(.openAI)))
                        if voice.previewing { Button("Stop preview", systemImage: "stop.fill") { voice.stop() }.buttonStyle(.plain).frame(minHeight: 44) }
                        if voice.configuration.provider == .system && voice.configuration.engine == .cascade { Text("On-device preview · no API charge").font(.caption).foregroundStyle(.secondary) }
                        if voice.configuration.engine == .realtime && !chat.connectedProviders.contains(.openAI) { Text("Connect OpenAI to preview this voice.").font(.footnote).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                Section {
                    Picker("Engine", selection: Binding(get: { voice.configuration.engine }, set: { voice.stop(); voice.configuration.engine = $0; voice.saveConfiguration(); Task { await loadConversationCatalog() } })) {
                        Text("Dictation → Chat → Speech").tag(AIMVoiceConfiguration.Engine.cascade)
                        Text("OpenAI Realtime").tag(AIMVoiceConfiguration.Engine.realtime)
                    }
                    if voice.configuration.engine == .realtime {
                        LabeledContent("Model", value: RealtimeVoiceProtocol.defaultModel)
                        Picker("Voice", selection: configBinding(\.voice)) { ForEach(AIMVoiceConfiguration.voices, id: \.self) { Text($0.capitalized).tag($0) } }
                        Text("This is AIM’s supported Realtime model. Choose Dictation → Chat → Speech to use another text model.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("Chat provider", selection: Binding(get: { selectedConversationProvider }, set: { conversationProvider = $0; Task { await loadConversationCatalog() } })) {
                            if !chat.connectedProviders.contains(selectedConversationProvider) { Text(selectedConversationProvider.name + " · disconnected").tag(selectedConversationProvider) }
                            ForEach(ChatProvider.allCases.filter { chat.connectedProviders.contains($0) && $0 != .local && $0 != .chatgpt }) { Text($0.name).tag($0) }
                        }.disabled(voice.active || chat.isSending)
                        Picker("Chat model", selection: Binding(get: {
                            let selection = voice.resolvedConversationSelection
                            return selection.provider == selectedConversationProvider ? selection.modelID : ""
                        }, set: { id in
                            if let model = conversationModels.first(where: { $0.id == id }) { _ = voice.selectConversationModel(provider: selectedConversationProvider, model: model) }
                        })) {
                            Text("Choose model").tag("")
                            let selection = voice.resolvedConversationSelection
                            if selection.provider == selectedConversationProvider, !selection.modelID.isEmpty, !conversationModels.contains(where: { $0.id == selection.modelID }) {
                                Text(selection.modelID + " · unavailable").tag(selection.modelID)
                            }
                            ForEach(conversationModels.filter(\.isChatModel)) { Text($0.name).tag($0.id) }
                        }.disabled(loadingConversation || voice.active || chat.isSending)
                        if loadingConversation { ProgressView() }
                        if let conversationError { AIMSettingsMessage(text: conversationError) }
                        Text("Dictation uses this provider and model on this iPhone. Its API charges apply; choosing a model never starts a request.").font(.footnote).foregroundStyle(.secondary)
                        Picker("Speech provider", selection: Binding(get: { voice.configuration.provider }, set: { voice.stop(); voice.configuration.provider = $0; voice.configuration.speechModel = ""; voice.saveConfiguration(); Task { await loadCatalog() } })) {
                            Text("This iPhone").tag(AIMVoiceConfiguration.SpeechProvider.system)
                            Text("OpenAI").tag(AIMVoiceConfiguration.SpeechProvider.openAI)
                            Text("OpenRouter").tag(AIMVoiceConfiguration.SpeechProvider.openRouter)
                            Text("ElevenLabs").tag(AIMVoiceConfiguration.SpeechProvider.elevenLabs)
                        }
                        if voice.configuration.provider == .system {
                            Picker("Voice", selection: $systemVoice) { Text("System default").tag(""); ForEach(AVSpeechSynthesisVoice.speechVoices(), id: \.identifier) { Text($0.name + " · " + $0.language).tag($0.identifier) } }
                            Slider(value: $rate, in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)) { Text("Speech rate") }.accessibilityLabel("Speech rate")
                        } else {
                            Picker("Speech model", selection: configBinding(\.speechModel)) {
                                Text("Choose model").tag("")
                                ForEach(models) { Text($0.name).tag($0.id) }
                            }
                            if voice.configuration.provider == .elevenLabs {
                                Picker("Voice", selection: configBinding(\.elevenLabsVoice)) { Text("Choose voice").tag(""); ForEach(elevenVoices) { Text($0.name).tag($0.id) } }
                            } else {
                                Picker("Voice", selection: configBinding(\.voice)) { ForEach(models.first(where: { $0.id == voice.configuration.speechModel })?.voices ?? [], id: \.self) { Text($0.capitalized).tag($0) } }
                            }
                            Button("Refresh available models") { Task { await loadCatalog() } }.buttonStyle(.plain)
                            if loading { ProgressView() }
                        }
                    }
                } footer: { Text("Voice is AI generated. Provider charges apply. No provider is substituted automatically.") }
                if voice.configuration.provider == .elevenLabs && voice.configuration.engine == .cascade {
                    Section("ElevenLabs on this iPhone") {
                        SecureField("API key", text: $keyDraft).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("ElevenLabs API key")
                        Button("Validate and save") { Task { await saveElevenKey() } }.buttonStyle(.plain).disabled(keyDraft.isEmpty || loading)
                    }
                }
                Section {
                    Picker("Language", selection: configBinding(\.language)) { Text("Automatic").tag(""); Text("English").tag("en-US"); Text("Français").tag("fr-FR") }
                    AIMSettingsAction(title: "Dictation history", icon: "clock.arrow.circlepath", action: openHistory)
                    Toggle("Start with Voice", isOn: Binding(get: { voice.startWithVoice }, set: { if $0 { showStartConsent = true } else { Task { await voice.enableStart(false) } } })).tint(.green)
                } footer: { Text("Dictation saves text only. Voice stops when AIM leaves the foreground or locks.") }
                if let error = voice.error { AIMSettingsMessage(text: error) }
            }
        }
        .task { await loadCatalog(); await loadConversationCatalog() }
        .onDisappear { if voice.previewing { voice.stop() }; chat.stopSpeaking() }
        .alert("Preview with your provider?", isPresented: $showPreviewConsent) {
            Button("Play preview") { if voice.configuration.engine == .realtime { Task { await voice.previewRealtimeVoice() } } else { chat.speak("Hello, I’m AIM. Let’s get started.") } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(previewInformation) }
        .alert("Start voice when AIM opens?", isPresented: $showStartConsent) { Button("Enable") { Task { await voice.enableStart(true) } }; Button("Cancel", role: .cancel) {} } message: { Text("After unlocking, AIM will access the microphone and use the selected provider. Realtime uses OpenAI pricing and stops after 10 minutes. A device spending limit requires the dictation engine.") }
    }
    private func configBinding<T>(_ path: WritableKeyPath<AIMVoiceConfiguration, T>) -> Binding<T> { Binding(get: { voice.configuration[keyPath: path] }, set: { voice.stop(); voice.configuration[keyPath: path] = $0; voice.saveConfiguration() }) }
    private func loadConversationCatalog() async {
        guard voice.configuration.engine == .cascade else { return }
        let provider = selectedConversationProvider
        loadingConversation = true; conversationError = nil; conversationModels = []
        do {
            let loaded = try await chat.catalog(for: provider)
            guard selectedConversationProvider == provider else { return }
            conversationModels = loaded.filter(\.isChatModel); loadingConversation = false
        } catch {
            guard selectedConversationProvider == provider else { return }
            loadingConversation = false; conversationError = "Connect this provider or refresh its models before choosing it for voice."
        }
    }
    private func loadCatalog() async {
        guard !loading, voice.configuration.engine == .cascade else { return }; loading = true; defer { loading = false }
        let provider = voice.configuration.provider
        do {
            let key = try chat.voiceKey(provider)
            let loaded = try await AIMVoiceCatalog.models(provider: provider, key: key)
            guard voice.configuration.provider == provider else { return }; models = loaded
            if provider == .elevenLabs, let key { elevenVoices = try await AIMVoiceCatalog.elevenLabsVoices(key: key) }
        } catch { voice.error = "Connect the selected speech provider to load its models and voices." }
    }
    private func saveElevenKey() async {
        loading = true; defer { loading = false }
        do { let voices = try await AIMVoiceCatalog.elevenLabsVoices(key: keyDraft); let loaded = try await AIMVoiceCatalog.models(provider: .elevenLabs, key: keyDraft); try chat.saveElevenLabsKey(keyDraft); keyDraft = ""; elevenVoices = voices; models = loaded; voice.error = nil }
        catch { voice.error = "The key could not be validated. It was not saved." }
    }
}
struct AIMDictationHistoryView: View {
    let chat: NativeChatStore
    let back: () -> Void
    let openConversation: (UUID) -> Void
    @State private var confirmClear = false
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Dictation history", back: back)
            AIMSettingsForm {
                if chat.voiceController.history.isEmpty { Text("No saved dictation yet.").foregroundStyle(.secondary) }
                ForEach(chat.voiceController.history.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.text)
                        Text(entry.date, style: .date).font(.footnote).foregroundStyle(.secondary)
                        if let id = entry.conversationID { Button("Open conversation") { openConversation(id) }.buttonStyle(.plain) }
                    }.padding(.vertical, 6)
                }
                if !chat.voiceController.history.isEmpty { Button("Clear dictation history") { confirmClear = true }.buttonStyle(.plain) }
            }
        }.alert("Clear saved dictation texts?", isPresented: $confirmClear) { Button("Clear history", role: .destructive) { chat.voiceController.clearHistory() }; Button("Cancel", role: .cancel) {} }
    }
}
struct AIMVoiceConversationView: View {
    let chat: NativeChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var consent = false
    private var voice: AIMVoiceController { chat.voiceController }
    private var conversationModelDescription: String {
        let selected = voice.resolvedConversationSelection
        return selected.provider.name + " · " + (chat.models.first { chat.provider == selected.provider && $0.id == selected.modelID }?.name ?? selected.modelID)
    }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Voice", back: { voice.stop(); dismiss() })
            ScrollView {
                VStack(spacing: 24) {
                    AIMVoiceOrb(active: voice.active).padding(.top, 30)
                    Text(voice.configuration.engine == .realtime ? "OpenAI · " + RealtimeVoiceProtocol.defaultModel : conversationModelDescription).font(.system(.subheadline)).foregroundStyle(.secondary)
                    if !voice.transcript.isEmpty { Text(voice.transcript).frame(maxWidth: .infinity, alignment: .leading) }
                    if !voice.answer.isEmpty { AIMMarkdownView(source: voice.answer).frame(maxWidth: .infinity, alignment: .leading) }
                    if let error = voice.error { AIMSettingsMessage(text: error) }
                    if voice.active {
                        if voice.listening && voice.configuration.engine == .cascade { Button("Send dictation") { voice.submitDictation() }.buttonStyle(.borderedProminent).tint(.primary) }
                        Button("End voice", systemImage: "stop.fill") { voice.stop() }.buttonStyle(.plain).frame(minHeight: 44)
                    } else {
                        Button("Start voice", systemImage: "mic.fill") { consent = true }.buttonStyle(.borderedProminent).tint(.primary).frame(minHeight: 44).disabled(!voice.ready)
                        Text("AI generated voice. API charges apply.").font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
        }.background(Color(uiColor: .secondarySystemBackground)).font(.system(.body)).tint(.primary)
        .alert("Start with this provider?", isPresented: $consent) { Button("Start") { Task { await voice.start() } }; Button("Cancel", role: .cancel) {} } message: { Text(voice.configuration.engine == .realtime ? "The microphone sends audio to OpenAI. OpenAI charges apply. Realtime is unavailable while a device spending limit is enabled." : "Dictation runs on this iPhone. The text uses your selected Chat model; speech uses " + voice.configuration.provider.rawValue + ". Provider charges apply.") }
        .task { if voice.startWithVoice { await voice.start() } }
        .onDisappear { voice.stop() }
    }
}
