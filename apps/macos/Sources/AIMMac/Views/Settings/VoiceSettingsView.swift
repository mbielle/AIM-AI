import AIMApplication
import AIMMacPlatform
import AVFoundation
import SwiftUI

struct VoiceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var engine = VoicePreferences.Engine.openAIRealtime
    @State private var provider = SpeechProvider.system
    @State private var speechModel = ""
    @State private var voice = ""
    @State private var realtimeVoice = VoicePreferences.realtimeVoice
    @State private var elevenLabsKey = ""
    @State private var hasElevenLabsKey = VoicePreferences.elevenLabsKey() != nil
    @State private var openRouterModels: [OpenRouterSpeechCatalog.Model] = []
    @State private var catalogError: String?
    @State private var loaded = false
    @State private var dictationEngine = DictationEngine.selected
    private let realtimeVoices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    private let openAIVoices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]

    var body: some View {
        SettingsPage("Voice", subtitle: "Talk with AIM and hear its answers. Requests that need action go to AIM's agent, with the usual approvals.") {
            SettingsGroup("Dictation", description: "The microphone button in the composer. Recordings are kept until their text is safe.") {
                SettingsBlock {
                    DictationSettingsMenu(selected: $dictationEngine, hasOpenAIKey: model.connectedProviders.contains(.openAI))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            AmbientAudioSettingsView()
            SettingsGroup("Live conversation", description: "The waveform button in the composer.") {
                SettingsMenuRow("Engine", description: engine == .openAIRealtime
                        ? "Speech-to-speech with OpenAI's Realtime model. You can interrupt by speaking. Billed to your OpenAI key and counted in Consumption."
                        : "Your speech is recognized on this Mac, the conversation's own model answers (any provider, including OpenRouter or a local model), and the voice below speaks.",
                    selection: $engine, options: [(.openAIRealtime, "OpenAI Realtime"), (.anyModel, "Any model")])
                if engine == .openAIRealtime {
                    SettingsMenuRow("Voice", selection: $realtimeVoice, options: realtimeVoices.map { ($0, $0.capitalized) })
                    if !model.connectedProviders.contains(.openAI) {
                        SettingsBlock { SettingsNotice("No OpenAI key: AIM will use the “Any model” engine instead.", tone: .warning) }
                    }
                }
            }
            SettingsGroup("Spoken voice", description: "Used to read answers aloud and by the “Any model” engine.") {
                SettingsMenuRow("Provider", selection: $provider, options: SpeechProvider.allCases.map { ($0, $0.name) })
                switch provider {
                case .system:
                    SettingsMenuRow("Voice", description: "Spoken on this Mac; nothing leaves it.", selection: $voice,
                                    options: [("", "Default for my language")] + systemVoices)
                case .openAI:
                    SettingsMenuRow("Voice", description: "gpt-4o-mini-tts with your OpenAI key.", selection: $voice,
                                    options: [("", "Marin (default)")] + openAIVoices.map { ($0, $0.capitalized) })
                case .openRouter:
                    if openRouterModels.isEmpty {
                        SettingsRow("Model", description: catalogError ?? "Loading OpenRouter's speech models…")
                    } else {
                        SettingsMenuRow("Model", description: "Uses your OpenRouter key and is billed by OpenRouter.", selection: $speechModel,
                                        options: openRouterModels.map { ($0.id, modelLabel($0)) })
                        let voices = openRouterModels.first { $0.id == speechModel }?.voices ?? []
                        if !voices.isEmpty {
                            SettingsMenuRow("Voice", description: "\(voices.count) voices for this model.", selection: $voice,
                                            options: [("", "Model default")] + voices.map { ($0, $0) })
                        }
                    }
                case .elevenLabs:
                    SettingsRow("Voice ID", description: "Leave empty for George.") {
                        TextField("Voice ID", text: $voice).textFieldStyle(.settings).frame(width: 240)
                    }
                    SettingsRow("API key", description: hasElevenLabsKey ? "Saved in this Mac's Keychain." : "Needed for ElevenLabs voices.") {
                        SecureField(hasElevenLabsKey ? "Replace key" : "ElevenLabs API key", text: $elevenLabsKey)
                            .textFieldStyle(.settings).frame(width: 220)
                        Button("Save") {
                            try? VoicePreferences.setElevenLabsKey(elevenLabsKey)
                            elevenLabsKey = ""
                            hasElevenLabsKey = VoicePreferences.elevenLabsKey() != nil
                        }.buttonStyle(.settings).disabled(elevenLabsKey.isEmpty)
                    }
                }
                SettingsRow("Try it", description: "Reads a short sentence with the current choice.") {
                    Button("Play sample") { Task { await model.readAloud("Hello, this is AIM. This is how I sound.") } }
                        .buttonStyle(.settings)
                }
            }
        }
        .task { await load() }
        .onChange(of: engine) { _, value in if loaded { VoicePreferences.engine = value } }
        .onChange(of: realtimeVoice) { _, value in VoicePreferences.realtimeVoice = value }
        .onChange(of: provider) { _, value in
            guard loaded else { return }
            VoicePreferences.provider = value
            voice = ""
            speechModel = value == .openRouter ? SpeechConfiguration.openRouterDefaultModel : ""
            save()
        }
        .onChange(of: speechModel) { _, _ in if loaded { voice = ""; save() } }
        .onChange(of: voice) { _, _ in if loaded { save() } }
    }

    private var systemVoices: [(value: String, label: String)] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
            .map { ($0.identifier, "\($0.name) (\($0.language))") }
    }

    private func modelLabel(_ item: OpenRouterSpeechCatalog.Model) -> String {
        item.name + (item.pricePerCharacter.map { " · $\(($0 * 1_000_000).formatted(.number.precision(.fractionLength(0...2))))/M chars" } ?? "")
    }

    private func save() {
        VoicePreferences.model = speechModel
        VoicePreferences.voice = voice
    }

    private func load() async {
        let resolved = VoicePreferences.resolved(connected: model.connectedProviders)
        engine = VoicePreferences.resolvedEngine(connected: model.connectedProviders)
        provider = resolved.provider
        speechModel = resolved.provider == .openRouter ? resolved.model : ""
        voice = resolved.voice
        loaded = true
        do { openRouterModels = try await OpenRouterSpeechCatalog.models() }
        catch { catalogError = "OpenRouter's speech catalog is unavailable: \(error.localizedDescription)" }
    }
}
