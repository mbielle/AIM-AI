@testable import AIMMacPlatform
import XCTest

final class VoiceTests: XCTestCase {
    func testDefaultsPreferChatGPTVoiceThenOpenRouterThenTheMac() {
        let savedProvider = VoicePreferences.provider, savedEngine = VoicePreferences.engine
        defer { VoicePreferences.provider = savedProvider; VoicePreferences.engine = savedEngine }
        VoicePreferences.provider = nil
        VoicePreferences.engine = nil
        XCTAssertEqual(VoicePreferences.resolved(connected: [.openAI, .openRouter]).provider, .openAI)
        XCTAssertEqual(VoicePreferences.resolved(connected: [.openRouter]),
                       SpeechConfiguration(provider: .openRouter, model: SpeechConfiguration.openRouterDefaultModel))
        XCTAssertEqual(VoicePreferences.resolved(connected: []).provider, .system)
        XCTAssertEqual(VoicePreferences.resolvedEngine(connected: [.openAI]), .openAIRealtime)
        XCTAssertEqual(VoicePreferences.resolvedEngine(connected: [.openRouter]), .anyModel, "OpenRouter-only users still get live voice")
    }

    func testOpenRouterSpeechCatalogParses() {
        let models = OpenRouterSpeechCatalog.parse([
            ["id": "x-ai/grok-voice-tts-1.0", "name": "xAI: Grok Voice", "supported_voices": ["eve", "ara"], "pricing": ["prompt": "0.000015"]],
            ["id": "fish-audio/s1", "name": "Fish Audio S1", "pricing": ["prompt": "0"]]
        ])
        XCTAssertEqual(models.map(\.id), ["fish-audio/s1", "x-ai/grok-voice-tts-1.0"])
        XCTAssertEqual(models.last?.voices, ["eve", "ara"])
        XCTAssertEqual(models.last?.pricePerCharacter, Decimal(string: "0.000015"))
    }

    func testSessionConfigurationAdmitsEachResponse() throws {
        let update = RealtimeVoiceProtocol.sessionUpdate(instructions: "Be brief.", voice: "cedar")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let vad = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(vad["create_response"] as? Bool, false, "AIM requests each billable response itself")
        XCTAssertEqual((audio["output"] as? [String: Any])?["voice"] as? String, "cedar")
        XCTAssertEqual(((session["tools"] as? [[String: Any]])?.first)?["name"] as? String, "ask_aim_agent")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: update))
        XCTAssertEqual(RealtimeVoiceProtocol.url().absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime")
    }

    func testServerEventsParse() {
        let audio = Data([1, 0, 255, 127])
        XCTAssertEqual(RealtimeVoiceProtocol.parse(#"{"type":"response.output_audio.delta","item_id":"i1","delta":"\#(audio.base64EncodedString())"}"#),
                       .audioDelta(itemID: "i1", pcm16: audio))
        XCTAssertEqual(RealtimeVoiceProtocol.parse(#"{"type":"input_audio_buffer.speech_started"}"#), .speechStarted)
        XCTAssertEqual(RealtimeVoiceProtocol.parse(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Bonjour"}"#), .userTranscript("Bonjour"))
        XCTAssertEqual(RealtimeVoiceProtocol.parse(#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"ask_aim_agent","arguments":"{\"request\":\"x\"}"}"#),
                       .functionCall(callID: "c1", name: "ask_aim_agent", arguments: #"{"request":"x"}"#))
        let done = RealtimeVoiceProtocol.parse(#"{"type":"response.done","response":{"status":"completed","usage":{"input_token_details":{"text_tokens":1000,"audio_tokens":2000,"cached_tokens":0},"output_token_details":{"text_tokens":100,"audio_tokens":3000}}}}"#)
        guard case .responseDone(let status, let usage?) = done else { return XCTFail("\(done)") }
        XCTAssertEqual(status, "completed")
        // 1000×4 + 2000×32 + 100×16 + 3000×64 = 261,600 micro-dollars.
        XCTAssertEqual(RealtimeVoiceProtocol.costUSD(usage, model: "gpt-realtime"), Decimal(string: "0.2616"))
        XCTAssertNil(RealtimeVoiceProtocol.costUSD(usage, model: "unknown-model"))
    }

    func testAudioConversionRoundTrip() {
        let samples: [Float] = (0..<480).map { sin(Float($0) / 10) * 0.5 }
        let pcm = RealtimeVoiceProtocol.pcm16(from: samples, sourceRate: 48_000)
        XCTAssertEqual(pcm.count, 240 * 2, "48 kHz → 24 kHz halves the samples")
        let back = RealtimeVoiceProtocol.floats(fromPCM16: pcm)
        XCTAssertEqual(back.count, 240)
        XCTAssertEqual(back[10], samples[20], accuracy: 0.001)
    }

    func testSpeakableTextAndCloudRequests() {
        XCTAssertEqual(SpeechPlayer.speakable("**Done.** See [the file](https://x.y).\n```swift\nlet a = 1\n```\n# Next"),
                       "Done. See the file. (code omitted) Next")
        let openAI = SpeechPlayer.request("Hi", configuration: .init(provider: .openAI), key: "k")
        XCTAssertEqual(openAI.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: openAI.httpBody!) as? [String: String])?["voice"], "marin")
        let eleven = SpeechPlayer.request("Hi", configuration: .init(provider: .elevenLabs, voice: "abc"), key: "k")
        XCTAssertEqual(eleven.value(forHTTPHeaderField: "xi-api-key"), "k")
        XCTAssertTrue(eleven.url!.absoluteString.contains("/v1/text-to-speech/abc"))
        let router = SpeechPlayer.request("Hi", configuration: .init(provider: .openRouter, model: "x-ai/grok-voice-tts-1.0", voice: "eve"), key: "or")
        XCTAssertEqual(router.url?.absoluteString, "https://openrouter.ai/api/v1/audio/speech")
        XCTAssertEqual(router.value(forHTTPHeaderField: "Authorization"), "Bearer or")
        let body = try? JSONSerialization.jsonObject(with: router.httpBody!) as? [String: String]
        XCTAssertEqual(body?["model"], "x-ai/grok-voice-tts-1.0")
        XCTAssertEqual(body?["voice"], "eve")
        XCTAssertEqual(body?["response_format"], "mp3")
        let cost = SpeechPlayer.estimate(String(repeating: "a", count: 1_000), configuration: .init(provider: .openRouter),
                                         pricePerCharacter: Decimal(string: "0.000015"))
        XCTAssertEqual(cost.estimate, "0.015")
        }
}
