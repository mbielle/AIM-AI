import AIMApplication
import AVFoundation
import Foundation
import Observation
import Speech

/// What the voice panel shows, whatever the engine.
@MainActor
public protocol VoiceConversation: AnyObject {
    var state: VoiceConversationState { get }
    var lines: [VoiceConversationLine] { get }
    func start() async
    func stop()
    /// Stops AIM speaking now (the person can also just talk with the Realtime engine).
    func interrupt()
}

public enum VoiceConversationState: Equatable, Sendable { case idle, connecting, listening, thinking, speaking, working(String), failed(String) }

public struct VoiceConversationLine: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let speaker: Speaker
    public var text: String
    public enum Speaker: Sendable { case person, aim, agent }
    public init(speaker: Speaker, text: String) { self.speaker = speaker; self.text = text }
}

/// A spoken conversation with any model: the Mac recognizes speech on-device
/// (nothing is uploaded for recognition), AIM answers with the conversation's own
/// model and agent tools, and the answer is spoken with the chosen voice (OpenAI,
/// one of OpenRouter's speech models, ElevenLabs or the Mac). Turn-taking: AIM
/// listens, a ~1.2 s pause ends the person's turn, AIM answers, then listens again.
/// While AIM speaks the microphone is paused so it does not hear itself.
@MainActor
@Observable
public final class CascadeVoiceSession: VoiceConversation {
    public private(set) var state: VoiceConversationState = .idle
    public private(set) var lines: [VoiceConversationLine] = []

    public typealias Answer = @Sendable (String) async -> String
    public typealias Speak = @MainActor (String) async throws -> Void

    private let answer: Answer
    private let speak: Speak
    private let locale: Locale
    private let silence: Duration
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var silenceTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var active = false

    public init(locale: Locale = .current, silence: Duration = .milliseconds(1_200), answer: @escaping Answer, speak: @escaping Speak) {
        self.locale = locale
        self.silence = silence
        self.answer = answer
        self.speak = speak
    }

    public func start() async {
        guard !active else { return }
        state = .connecting
        let permissions = MacPermissionCenter()
        guard await permissions.request(.microphone) == .granted else { return fail(SpeechDictationError.microphoneDenied) }
        guard await permissions.request(.speechRecognition) == .granted else { return fail(SpeechDictationError.speechDenied) }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return fail(SpeechDictationError.unavailable) }
        guard recognizer.supportsOnDeviceRecognition else { return fail(SpeechDictationError.onDeviceUnavailable) }
        active = true
        listen(with: recognizer)
    }

    public func stop() {
        active = false
        turnTask?.cancel()
        turnTask = nil
        endListening()
        SpeechPlayer.shared.stop()
        if case .failed = state {} else { state = .idle }
    }

    public func interrupt() {
        SpeechPlayer.shared.stop()
    }

    private func fail(_ error: Error) {
        stop()
        state = .failed(error.localizedDescription)
    }

    // MARK: Listening

    private func listen(with recognizer: SFSpeechRecognizer) {
        guard active else { return }
        transcript = ""
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return fail(SpeechDictationError.noMicrophone) }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { return fail(SpeechDictationError.failedToStart) }
        self.engine = engine
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            Task { @MainActor in self?.recognized(text, final: isFinal, error: error, recognizer: recognizer) }
        }
        state = .listening
    }

    private func recognized(_ text: String?, final: Bool, error: Error?, recognizer: SFSpeechRecognizer) {
        guard active, engine != nil else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            // Each new word restarts the end-of-turn timer.
            silenceTask?.cancel()
            silenceTask = Task { [weak self, silence] in
                try? await Task.sleep(for: silence)
                guard !Task.isCancelled else { return }
                self?.endTurn(recognizer: recognizer)
            }
        }
        if final || error != nil, !transcript.isEmpty { endTurn(recognizer: recognizer) }
        else if error != nil, transcript.isEmpty {
            // The recognizer gives up after a long silence; just listen again.
            endListening()
            listen(with: recognizer)
        }
    }

    private func endListening() {
        silenceTask?.cancel()
        silenceTask = nil
        if let engine, engine.isRunning { engine.stop() }
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
    }

    // MARK: Turn

    private func endTurn(recognizer: SFSpeechRecognizer) {
        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        endListening()
        guard active, !said.isEmpty, turnTask == nil else { return }
        lines.append(VoiceConversationLine(speaker: .person, text: said))
        state = .working(said)
        turnTask = Task { [weak self, answer] in
            let reply = await answer(said)
            guard let self, !Task.isCancelled, self.active else { return }
            self.lines.append(VoiceConversationLine(speaker: .aim, text: reply))
            self.state = .speaking
            do { try await self.speak(reply) } catch {
                self.lines.append(VoiceConversationLine(speaker: .aim, text: "⚠️ \(error.localizedDescription)"))
            }
            self.turnTask = nil
            if self.active { self.listen(with: recognizer) }
        }
    }
}
