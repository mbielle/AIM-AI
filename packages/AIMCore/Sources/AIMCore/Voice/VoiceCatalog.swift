import Foundation

public struct AIMSpeechModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let voices: [String]
    public let usdPerCharacter: Double?
    public init(id: String, name: String, voices: [String], usdPerCharacter: Double? = nil) {
        self.id = id; self.name = name; self.voices = voices; self.usdPerCharacter = usdPerCharacter
    }
}
public struct AIMSpeechVoice: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
}
public enum AIMVoiceCatalog {
    public static func models(provider: AIMVoiceConfiguration.SpeechProvider, key: String?) async throws -> [AIMSpeechModel] {
        switch provider {
        case .system: return []
        case .openAI: return [.init(id: "gpt-4o-mini-tts", name: "GPT-4o mini TTS", voices: AIMVoiceConfiguration.voices)]
        case .openRouter:
            let root = try await fetch("https://openrouter.ai/api/v1/models?output_modalities=speech", key: key, elevenLabs: false)
            guard let rows = root["data"] as? [[String: Any]] else { throw ChatServiceError.invalidResponse }
            return rows.compactMap { row in
                guard let id = row["id"] as? String, let voices = row["supported_voices"] as? [String], !voices.isEmpty else { return nil }
                let raw = (row["pricing"] as? [String: Any])?["per_character"]
                let price = (raw as? String).flatMap(Double.init) ?? raw as? Double
                return .init(id: id, name: row["name"] as? String ?? id, voices: voices, usdPerCharacter: price.flatMap { $0 >= 0 && $0.isFinite ? $0 : nil })
            }
        case .elevenLabs:
            guard let key, !key.isEmpty else { throw ChatServiceError.missingKey }
            let root = try await fetch("https://api.elevenlabs.io/v1/models", key: key, elevenLabs: true)
            guard let rows = root["models"] as? [[String: Any]] else { throw ChatServiceError.invalidResponse }
            return rows.compactMap { row in
                guard row["can_do_text_to_speech"] as? Bool == true, let id = row["model_id"] as? String else { return nil }
                return .init(id: id, name: row["name"] as? String ?? id, voices: [])
            }
        }
    }
    public static func elevenLabsVoices(key: String) async throws -> [AIMSpeechVoice] {
        let root = try await fetch("https://api.elevenlabs.io/v1/voices", key: key, elevenLabs: true)
        guard let rows = root["voices"] as? [[String: Any]] else { throw ChatServiceError.invalidResponse }
        return rows.compactMap { row in guard let id = row["voice_id"] as? String, let name = row["name"] as? String else { return nil }; return .init(id: id, name: name) }
    }
    private static func fetch(_ address: String, key: String?, elevenLabs: Bool) async throws -> [String: Any] {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        if let key, key.contains(where: \.isWhitespace) { throw ChatServiceError.missingKey }
        let session = NativeChatTransport.secretSession(); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 30)
        if let key, !key.isEmpty { request.setValue(elevenLabs ? key : "Bearer " + key, forHTTPHeaderField: elevenLabs ? "xi-api-key" : "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ChatServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        var data = Data()
        for try await byte in bytes { guard data.count < 4_000_000 else { throw ChatServiceError.invalidResponse }; data.append(byte) }
        let json = try JSONSerialization.jsonObject(with: data)
        if let rows = json as? [[String: Any]] { return ["models": rows] }
        guard let root = json as? [String: Any] else { throw ChatServiceError.invalidResponse }; return root
    }
}
