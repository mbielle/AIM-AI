import AIMApplication
import AIMCore
import AVFoundation
import Foundation

/// Reads answers aloud. Providers: the Mac's own voices (private, free, offline),
/// OpenAI text-to-speech, OpenRouter's speech models (Gemini, Grok, MiniMax,
/// Deepgram, Microsoft, Mistral, Kokoro…) and ElevenLabs. Cloud speech is
/// metered like any other billable request.
public enum SpeechProvider: String, CaseIterable, Codable, Sendable {
    case system, openAI = "openai", openRouter = "openrouter", elevenLabs = "elevenlabs"

    public var name: String {
        switch self {
        case .system: "This Mac (private)"
        case .openAI: "OpenAI (ChatGPT voices)"
        case .openRouter: "OpenRouter (23 speech models)"
        case .elevenLabs: "ElevenLabs"
        }
    }
}

/// What to speak with: provider, model (OpenAI/OpenRouter) and voice.
public struct SpeechConfiguration: Equatable, Sendable {
    public var provider: SpeechProvider
    public var model: String
    public var voice: String

    public init(provider: SpeechProvider, model: String = "", voice: String = "") {
        self.provider = provider; self.model = model; self.voice = voice
    }

    public static let openAIModel = "gpt-4o-mini-tts"
    public static let openRouterDefaultModel = "google/gemini-3.8-flash-tts"
}

public enum VoicePreferences {
    static let providerKey = "AIMSpeechProvider", voiceKey = "AIMSpeechVoice", modelKey = "AIMSpeechModel",
               autoReadKey = "AIMSpeechAutoRead", realtimeVoiceKey = "AIMRealtimeVoice", engineKey = "AIMVoiceEngine"

    /// The person's explicit choice, if any; otherwise `resolved(connected:)` picks one.
    public static var provider: SpeechProvider? {
        get { UserDefaults.standard.string(forKey: providerKey).flatMap(SpeechProvider.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: providerKey) }
    }
    public static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
    public static var voice: String {
        get { UserDefaults.standard.string(forKey: voiceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }
    public static var autoRead: Bool {
        get { UserDefaults.standard.bool(forKey: autoReadKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoReadKey) }
    }
    /// Voice of the OpenAI Realtime conversation (marin, cedar, alloy, ash, ballad, coral, echo, sage, shimmer, verse).
    public static var realtimeVoice: String {
        get { UserDefaults.standard.string(forKey: realtimeVoiceKey) ?? "marin" }
        set { UserDefaults.standard.set(newValue, forKey: realtimeVoiceKey) }
    }

    public enum Engine: String, CaseIterable, Sendable {
        /// OpenAI's speech-to-speech model (needs an OpenAI key).
        case openAIRealtime = "openai_realtime"
        /// On-device recognition → AIM with any model → the chosen speech voice.
        case anyModel = "any_model"

        public var name: String {
            switch self {
            case .openAIRealtime: "OpenAI Realtime (ChatGPT-style, lowest latency)"
            case .anyModel: "Any model: Mac speech recognition → AIM → chosen voice"
            }
        }
    }

    public static var engine: Engine? {
        get { UserDefaults.standard.string(forKey: engineKey).flatMap(Engine.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: engineKey) }
    }

    /// ChatGPT's voice by default when an OpenAI key exists, else OpenRouter's, else the Mac's.
    public static func resolved(connected: Set<ChatProvider>) -> SpeechConfiguration {
        let provider = Self.provider ?? (connected.contains(.openAI) ? .openAI : connected.contains(.openRouter) ? .openRouter : .system)
        let model = Self.provider == provider ? Self.model : ""
        let voice = Self.provider == provider ? Self.voice : ""
        switch provider {
        case .openAI: return SpeechConfiguration(provider: .openAI, model: model.isEmpty ? SpeechConfiguration.openAIModel : model, voice: voice)
        case .openRouter: return SpeechConfiguration(provider: .openRouter, model: model.isEmpty ? SpeechConfiguration.openRouterDefaultModel : model, voice: voice)
        default: return SpeechConfiguration(provider: provider, voice: voice)
        }
    }

    public static func resolvedEngine(connected: Set<ChatProvider>) -> Engine {
        engine ?? (connected.contains(.openAI) ? .openAIRealtime : .anyModel)
    }

    static let keychain = KeychainSecureStore(service: AIMInstallationContext.keychainService("com.aimai.macos.voice"))
    public static func elevenLabsKey() -> String? {
        (try? keychain.readData(forKey: "elevenlabs")).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }
    }
    public static func setElevenLabsKey(_ key: String?) throws {
        if let key, !key.isEmpty { try keychain.store(Data(key.utf8), forKey: "elevenlabs") }
        else { try keychain.removeData(forKey: "elevenlabs") }
    }
}

/// OpenRouter's speech models and their voices (public catalog, no key needed).
public enum OpenRouterSpeechCatalog {
    public struct Model: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let voices: [String]
        /// USD per input character (OpenRouter's `pricing.prompt` for speech models).
        public let pricePerCharacter: Decimal?
    }

    public static func models(session: URLSession = RuntimeManagedNetworkSession.shared) async throws -> [Model] {
        try RuntimePrivacyPolicy.requireApplicationNetwork()
        let (data, response) = try await session.data(from: URL(string: "https://openrouter.ai/api/v1/models?output_modalities=speech")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else {
            throw SpeechSynthesisError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return parse(rows)
    }

    static func parse(_ rows: [[String: Any]]) -> [Model] {
        rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let price = ((row["pricing"] as? [String: Any])?["prompt"] as? String).flatMap { Decimal(string: $0) }
            return Model(id: id, name: row["name"] as? String ?? id, voices: row["supported_voices"] as? [String] ?? [],
                         pricePerCharacter: price)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum SpeechSynthesisError: LocalizedError, Equatable {
    case missingKey(String), http(Int), emptyText
    public var errorDescription: String? {
        switch self {
        case .missingKey(let provider): "Add a \(provider) key first."
        case .http(let status): "The speech service answered HTTP \(status)."
        case .emptyText: "Nothing to read."
        }
    }
}

@MainActor
public final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    public static let shared = SpeechPlayer()
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Never>?
    public private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Plain text for speech: no markdown symbols, code blocks summarized, bounded length.
    public nonisolated static func speakable(_ markdown: String, limit: Int = 4_000) -> String {
        var text = markdown.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (code omitted) ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`#>|]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(limit))
    }

    /// Speaks and returns when done (or stopped). `key` is the provider's API key when it needs one.
    public func speak(_ markdown: String, configuration: SpeechConfiguration, key: String?, meter: BillableRequestMeter) async throws {
        stop()
        let text = Self.speakable(markdown)
        guard !text.isEmpty else { throw SpeechSynthesisError.emptyText }
        isSpeaking = true
        defer { isSpeaking = false }
        if configuration.provider == .system {
            let utterance = AVSpeechUtterance(string: text)
            let voice = configuration.voice
            utterance.voice = voice.isEmpty ? AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
                : AVSpeechSynthesisVoice(identifier: voice) ?? AVSpeechSynthesisVoice(language: nil)
            await withCheckedContinuation { continuation in
                finished = continuation
                synthesizer.speak(utterance)
            }
            return
        }
        let audio = try await Self.synthesize(text, configuration: configuration, key: key, meter: meter)
        try Task.checkCancellation()
        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        self.player = player
        await withCheckedContinuation { continuation in
            finished = continuation
            player.play()
        }
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        finish()
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    /// The request for cloud speech (separate for tests).
    nonisolated static func request(_ text: String, configuration: SpeechConfiguration, key: String) -> URLRequest {
        var request: URLRequest
        let voice = configuration.voice
        switch configuration.provider {
        case .elevenLabs:
            let voiceID = voice.isEmpty ? "JBFqnCBsd6RMkjVDRZzb" : voice // ElevenLabs' default “George”.
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_128")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_flash_v2_5"])
        case .openRouter:
            // OpenAI-compatible speech endpoint; the voice must be one of the model's `supported_voices`.
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/speech")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var body: [String: Any] = ["model": configuration.model.isEmpty ? SpeechConfiguration.openRouterDefaultModel : configuration.model,
                                       "input": text, "response_format": "mp3"]
            if !voice.isEmpty { body["voice"] = voice }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        default:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": configuration.model.isEmpty ? SpeechConfiguration.openAIModel : configuration.model,
                "voice": voice.isEmpty ? "marin" : voice, "input": text, "response_format": "mp3"])
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// A conservative cost bound and estimate (USD) for speaking `text`.
    nonisolated static func estimate(_ text: String, configuration: SpeechConfiguration, pricePerCharacter: Decimal?) -> (bound: String, estimate: String?) {
        let characters = Decimal(max(text.count, 1))
        switch configuration.provider {
        case .openAI:
            // gpt-4o-mini-tts ≈ 0.015 USD per minute of speech ≈ 1,000 characters.
            let value = characters / 1_000 * Decimal(string: "0.015")!
            return ("\(value * 3)", "\(value)")
        case .openRouter:
            if let pricePerCharacter, pricePerCharacter > 0 {
                let value = characters * pricePerCharacter
                return ("\(value * 2)", "\(value)")
            }
            return ("\(characters * Decimal(string: "0.0001")!)", nil)
        default:
            return ("\(characters * Decimal(string: "0.0003")!)", nil)
        }
    }

    nonisolated static func synthesize(_ text: String, configuration: SpeechConfiguration, key: String?,
                                       meter: BillableRequestMeter, pricePerCharacter: Decimal? = nil) async throws -> Data {
        try RuntimePrivacyPolicy.requireApplicationNetwork()
        guard let key = configuration.provider == .elevenLabs ? VoicePreferences.elevenLabsKey() : key, !key.isEmpty else {
            throw SpeechSynthesisError.missingKey(configuration.provider == .elevenLabs ? "ElevenLabs"
                                                  : configuration.provider == .openRouter ? "OpenRouter" : "OpenAI")
        }
        let request = request(text, configuration: configuration, key: key)
        let cost = estimate(text, configuration: configuration, pricePerCharacter: pricePerCharacter)
        let billingProvider: String = switch configuration.provider {
        case .openAI: ChatProvider.openAI.rawValue
        case .openRouter: ChatProvider.openRouter.rawValue
        default: "elevenlabs"
        }
        return try await meter.perform(provider: billingProvider,
                                       modelID: configuration.provider == .elevenLabs ? "eleven_flash_v2_5" : configuration.model,
                                       feature: "speech", maximumUSD: cost.bound, receiptUSD: { _ in cost.estimate }) {
            try RuntimePrivacyPolicy.requireApplicationNetwork()
            let (data, response) = try await RuntimeManagedNetworkSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                throw SpeechSynthesisError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return data
        }
    }

    // MARK: Delegates

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }
}
