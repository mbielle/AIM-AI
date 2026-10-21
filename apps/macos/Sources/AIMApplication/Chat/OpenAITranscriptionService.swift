import AIMCore
import Foundation

public enum OpenAITranscriptionError: LocalizedError, Sendable {
    case missingKey, emptyRecording, recordingTooLarge, invalidResponse
    case credentialsRejected, providerRateLimited, unavailable

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your OpenAI API key in Settings → Providers to use AI transcription."
        case .emptyRecording: "The recording is empty. Try speaking again."
        case .recordingTooLarge: "This recording exceeds OpenAI's 25 MB upload limit. Record a shorter message."
        case .invalidResponse: "OpenAI did not return a usable transcript."
        case .credentialsRejected: "OpenAI rejected this API key. Check it in Settings → Providers."
        case .providerRateLimited: "OpenAI temporarily limited requests for this API key. AIM does not impose a voice-usage quota."
        case .unavailable: "OpenAI transcription is unavailable. Check your connection and API key."
        }
    }
}

/// File transcription is initiated only by an explicit user choice. The key is
/// supplied by the caller from Keychain and never persisted in the request body.
public struct OpenAITranscriptionService: Sendable {
    private let session: URLSession
    private let meter: BillableRequestMeter
    public init(session: URLSession? = nil, meter: BillableRequestMeter = BillableRequestMeter()) {
        self.session = session ?? ProviderHTTPSession.make()
        self.meter = meter
    }

    /// `language`: an ISO 639-1 code ("fr"), or nil to let the model detect it.
    public func transcribe(m4a: Data, apiKey: String, language: String? = nil) async throws -> String {
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw OpenAITranscriptionError.missingKey
        }
        guard !m4a.isEmpty else { throw OpenAITranscriptionError.emptyRecording }
        guard m4a.count <= 25_000_000 else { throw OpenAITranscriptionError.recordingTooLarge }

        let boundary = "AIMAudio-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n".utf8))
        if let language, language.count == 2, language.allSatisfy(\.isLetter) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language.lowercased())\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(m4a)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let billableRequest = request
        let (data, response) = try await meter.perform(provider: ChatProvider.openAI.rawValue,
            modelID: "gpt-transcribe", feature: "transcription") {
            try await session.data(for: billableRequest)
        }
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw OpenAITranscriptionError.unavailable
        }
        if status == 401 || status == 403 { throw OpenAITranscriptionError.credentialsRejected }
        if status == 429 { throw OpenAITranscriptionError.providerRateLimited }
        guard (200..<300).contains(status) else { throw OpenAITranscriptionError.unavailable }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcript = root["text"] as? String,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAITranscriptionError.invalidResponse
        }
        return transcript
    }
}
