import Foundation

public struct AIMVoiceConfiguration: Codable, Equatable, Sendable {
    public enum Engine: String, Codable, CaseIterable, Sendable { case realtime, cascade }
    public enum SpeechProvider: String, Codable, CaseIterable, Sendable { case system, openAI, openRouter, elevenLabs }
    public var engine: Engine = .cascade
    public var provider: SpeechProvider = .system
    public var voice = "marin"
    public var language = ""
    public var speechModel = "gpt-4o-mini-tts"
    public var elevenLabsVoice = ""
    public init() {}
    public static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    public var model: String { engine == .realtime ? RealtimeVoiceProtocol.defaultModel : speechModel }
}

public struct VoiceSpeechTransport: Sendable {
    public init() {}
    public func audio(text: String, configuration: AIMVoiceConfiguration, key: String) async throws -> Data {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard !text.isEmpty, text.utf8.count <= 16000, !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw ChatServiceError.invalidResponse }
        let url: URL
        var body: [String: Any]
        switch configuration.provider {
        case .system: throw ChatServiceError.invalidResponse
        case .openAI, .openRouter:
            url = URL(string: configuration.provider == .openAI ? "https://api.openai.com/v1/audio/speech" : "https://openrouter.ai/api/v1/audio/speech")!
            body = ["model": configuration.speechModel, "input": text, "voice": configuration.voice, "response_format": "mp3"]
        case .elevenLabs:
            guard configuration.elevenLabsVoice.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), !configuration.elevenLabsVoice.isEmpty else { throw ChatServiceError.invalidResponse }
            url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(configuration.elevenLabsVoice)")!
            body = ["text": text, "model_id": configuration.speechModel]
        }
        var request = URLRequest(url: url, timeoutInterval: 60); request.httpMethod = "POST"
        request.setValue(configuration.provider == .elevenLabs ? key : "Bearer \(key)", forHTTPHeaderField: configuration.provider == .elevenLabs ? "xi-api-key" : "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = NativeChatTransport.secretSession(); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ChatServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard http.mimeType?.hasPrefix("audio/") == true, response.expectedContentLength <= 32_000_000 else { throw ChatServiceError.invalidResponse }
        var data = Data()
        for try await byte in bytes { guard data.count < 32_000_000 else { throw ChatServiceError.invalidResponse }; data.append(byte) }
        return data
    }
}
