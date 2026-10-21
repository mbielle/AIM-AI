import Foundation
import CoreFoundation

/// The conversation and project chosen when a voice session starts. An explicit
/// nil project remains unassigned even if the UI selects another project later.
public struct RealtimeVoiceContext: Equatable, Sendable {
    public var conversationID: UUID?
    public var projectID: UUID?
    public init(conversationID: UUID? = nil, projectID: UUID? = nil) {
        self.conversationID = conversationID; self.projectID = projectID
    }
}

/// The OpenAI Realtime API (GA, `gpt-realtime`) wire format AIM uses: one
/// WebSocket, PCM16 24 kHz mono both ways, server voice activity detection
/// without automatic responses (AIM admits each billable response first), and a
/// single tool through which the voice model hands real work to AIM's agent —
/// the same split ChatGPT's voice mode uses with its reasoning model.
public enum RealtimeVoiceProtocol {
    public static let defaultModel = "gpt-realtime"
    public static let sampleRate: Double = 24_000
    public static let agentToolName = "ask_aim_agent"

    public static func url(model: String = defaultModel) -> URL {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

    public static func sessionUpdate(instructions: String, voice: String, transcriptionModel: String = "gpt-4o-mini-transcribe", allowsAgent: Bool = true) -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
                        "transcription": ["model": transcriptionModel],
                        "turn_detection": ["type": "semantic_vad", "create_response": false, "interrupt_response": true]
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
                        "voice": voice
                    ]
                ],
                "tools": allowsAgent ? [[
                    "type": "function",
                    "name": agentToolName,
                    "description": "Hand a request to AIM, the person's agent on this Mac, which can use their files, apps, web and tools and asks them for approval when needed. Use it for anything beyond simple conversation: actions, looking things up, files, email, calendar, code. Pass the full request in the person's words with any context. It returns AIM's answer, which you then summarize aloud.",
                    "parameters": [
                        "type": "object",
                        "properties": ["request": ["type": "string", "description": "What AIM should do or find, self-contained."]],
                        "required": ["request"]
                    ]
                ]] : [],
                "tool_choice": allowsAgent ? "auto" : "none"
            ]
        ]
    }

    public static func appendAudio(_ pcm16: Data) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()]
    }

    public static func responseCreate() -> [String: Any] { ["type": "response.create"] }
    public static func responseCancel() -> [String: Any] { ["type": "response.cancel"] }

    public static func functionOutput(callID: String, output: String) -> [String: Any] {
        ["type": "conversation.item.create",
         "item": ["type": "function_call_output", "call_id": callID, "output": output]]
    }

    public static func truncate(itemID: String, playedMilliseconds: Int) -> [String: Any] {
        ["type": "conversation.item.truncate", "item_id": itemID, "content_index": 0, "audio_end_ms": max(0, playedMilliseconds)]
    }

    public struct Usage: Equatable, Sendable {
        public var textIn = 0, audioIn = 0, cachedIn = 0, textOut = 0, audioOut = 0
        public var cachedTextIn: Int?, cachedAudioIn: Int?
        public var hasCompleteTokenDetails = false
        public var totalTokens: Int? {
            guard hasCompleteTokenDetails, [textIn, audioIn, textOut, audioOut].allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000 }) else { return nil }
            return textIn + audioIn + textOut + audioOut
        }
    }

    public enum ServerEvent: Equatable, Sendable {
        case sessionReady
        case speechStarted
        case speechStopped
        case userTranscript(String)
        case audioDelta(itemID: String, pcm16: Data)
        case assistantTranscriptDelta(String)
        case assistantTranscriptDone(String)
        case functionCall(callID: String, name: String, arguments: String)
        case responseDone(status: String, usage: Usage?)
        case error(String)
        case other(String)
    }

    public static func parse(_ text: String) -> ServerEvent {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = json["type"] as? String else { return .other("invalid") }
        switch type {
        case "session.created", "session.updated": return .sessionReady
        case "input_audio_buffer.speech_started": return .speechStarted
        case "input_audio_buffer.speech_stopped": return .speechStopped
        case "conversation.item.input_audio_transcription.completed":
            return .userTranscript(json["transcript"] as? String ?? "")
        case "response.output_audio.delta":
            guard let delta = (json["delta"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return .other(type) }
            return .audioDelta(itemID: json["item_id"] as? String ?? "", pcm16: delta)
        case "response.output_audio_transcript.delta": return .assistantTranscriptDelta(json["delta"] as? String ?? "")
        case "response.output_audio_transcript.done": return .assistantTranscriptDone(json["transcript"] as? String ?? "")
        case "response.function_call_arguments.done":
            return .functionCall(callID: json["call_id"] as? String ?? "", name: json["name"] as? String ?? "",
                                 arguments: json["arguments"] as? String ?? "{}")
        case "response.done":
            let response = json["response"] as? [String: Any]
            return .responseDone(status: response?["status"] as? String ?? "completed",
                                 usage: (response?["usage"] as? [String: Any]).flatMap(usage))
        case "error":
            let error = json["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Realtime error")
        default: return .other(type)
        }
    }

    static func usage(_ object: [String: Any]) -> Usage? {
        guard let input = object["input_token_details"] as? [String: Any],
              let output = object["output_token_details"] as? [String: Any],
              let textIn = tokenCount(input["text_tokens"]), let audioIn = tokenCount(input["audio_tokens"]),
              let cached = tokenCount(input["cached_tokens"]),
              let textOut = tokenCount(output["text_tokens"]), let audioOut = tokenCount(output["audio_tokens"]),
              cached <= textIn + audioIn else { return nil }
        // AIM's voice session sends text/audio only. An unexpected modality or an
        // inconsistent aggregate is an incomplete receipt, not a zero-cost turn.
        if let image = input["image_tokens"], tokenCount(image) != 0 { return nil }
        for (key, expected) in [("input_tokens", textIn + audioIn), ("output_tokens", textOut + audioOut),
                                ("total_tokens", textIn + audioIn + textOut + audioOut)] {
            if let value = object[key], tokenCount(value) != expected { return nil }
        }
        var result = Usage(textIn: textIn, audioIn: audioIn, cachedIn: cached, textOut: textOut, audioOut: audioOut)
        result.hasCompleteTokenDetails = true
        if cached == 0 { result.cachedTextIn = 0; result.cachedAudioIn = 0 }
        else if let details = input["cached_tokens_details"] as? [String: Any],
                let text = tokenCount(details["text_tokens"]), let audio = tokenCount(details["audio_tokens"]),
                text <= textIn, audio <= audioIn, text + audio == cached,
                details["image_tokens"] == nil || tokenCount(details["image_tokens"]) == 0 {
            result.cachedTextIn = text; result.cachedAudioIn = audio
        }
        return result
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value.rounded() == value, value <= 1_000_000_000 else { return nil }
        return Int(value)
    }

    /// Published gpt-realtime prices (USD per 1M tokens): text in 4, audio in 32,
    /// cached text/audio in 0.4, text out 16, audio out 64. This is the Response
    /// receipt only: input transcription is separately billed by OpenAI.
    public static func costUSD(_ usage: Usage, model: String) -> Decimal? {
        guard model == "gpt-realtime", usage.hasCompleteTokenDetails,
              let cachedText = usage.cachedTextIn, let cachedAudio = usage.cachedAudioIn,
              [usage.textIn, usage.audioIn, usage.cachedIn, usage.textOut, usage.audioOut, cachedText, cachedAudio].allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000 }),
              cachedText <= usage.textIn, cachedAudio <= usage.audioIn, cachedText + cachedAudio == usage.cachedIn else { return nil }
        let micro = Decimal(usage.textIn - cachedText) * 4 + Decimal(usage.audioIn - cachedAudio) * 32
            + Decimal(usage.cachedIn) * Decimal(string: "0.4")! + Decimal(usage.textOut) * 16 + Decimal(usage.audioOut) * 64
        return micro / 1_000_000
    }

    /// Converts the microphone's float samples (any rate, channel 0) to PCM16 mono at 24 kHz.
    public static func pcm16(from samples: [Float], sourceRate: Double) -> Data {
        guard !samples.isEmpty, sourceRate > 0 else { return Data() }
        let ratio = sourceRate / sampleRate
        let count = Int(Double(samples.count) / ratio)
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let position = Double(index) * ratio
            let base = Int(position)
            let fraction = Float(position - Double(base))
            let next = min(base + 1, samples.count - 1)
            let value = samples[base] * (1 - fraction) + samples[next] * fraction
            var sample = Int16(max(-1, min(1, value)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// PCM16 little-endian to float samples for playback.
    public static func floats(fromPCM16 data: Data) -> [Float] {
        stride(from: 0, to: data.count - 1, by: 2).map { offset in
            let value = Int16(littleEndian: data[data.startIndex + offset..<data.startIndex + offset + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
            return Float(value) / Float(Int16.max)
        }
    }
}
