import AVFoundation
import Foundation
import Speech

public enum SpeechDictationError: LocalizedError {
    case microphoneDenied, speechDenied, unavailable, onDeviceUnavailable, noMicrophone, failedToStart

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is required. Allow AIM AI in System Settings → Privacy & Security → Microphone."
        case .speechDenied: "Speech Recognition access is required. Allow AIM AI in System Settings → Privacy & Security → Speech Recognition."
        case .unavailable: "Speech recognition is unavailable for the current language."
        case .onDeviceUnavailable: "Apple cannot recognize this language on this Mac. Choose Whisper or Parakeet in Dictation settings (your recording is kept)."
        case .noMicrophone: "No microphone input is available. Connect a microphone and try again."
        case .failedToStart: "The microphone could not start. Check that it is connected and not in use by another app."
        }
    }
}

public enum SpeechDictationEvent: Sendable {
    case partial(String)
    case finished(String)
    case failed(String)
}

public enum DictationText {
    /// Dictation never replaces text typed while the microphone was active.
    public static func appending(_ transcript: String, to draft: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return draft }
        guard !draft.isEmpty else { return spoken }
        return draft + (draft.last?.isWhitespace == true ? "" : " ") + spoken
    }
}

/// One foreground, memory-only dictation session. The Speech request is strictly on-device.
/// Audio is never written to disk and permissions are requested only by start().
@MainActor
public final class MacSpeechDictationService {
    private let permissions = MacPermissionCenter()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onEvent: (@MainActor (SpeechDictationEvent) -> Void)?
    private var token = UUID()
    private var latestTranscript = ""
    private var stopping = false
    private var hasTap = false
    private var hasEndedAudio = false
    private var stopFallback: Task<Void, Never>?

    public init() {}
    public var isActive: Bool { engine?.isRunning == true }

    public func start(locale: Locale = .current,
                      onEvent: @escaping @MainActor (SpeechDictationEvent) -> Void) async throws {
        cancel()
        let current = token
        guard await permissions.request(.microphone) == .granted else { throw SpeechDictationError.microphoneDenied }
        try Task.checkCancellation()
        guard await permissions.request(.speechRecognition) == .granted else { throw SpeechDictationError.speechDenied }
        try Task.checkCancellation()
        guard token == current else { throw CancellationError() }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechDictationError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else { throw SpeechDictationError.onDeviceUnavailable }

        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw SpeechDictationError.noMicrophone }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.engine = engine
        self.request = request
        self.onEvent = onEvent
        self.latestTranscript = ""
        self.stopping = false
        self.hasEndedAudio = false

        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.receive(text: text, isFinal: isFinal, failure: failure, token: current)
            }
        }
        guard token == current else { throw CancellationError() }
        try Task.checkCancellation()
        engine.prepare()
        do { try engine.start() }
        catch {
            cancel()
            throw SpeechDictationError.failedToStart
        }
    }

    /// Stop capturing, then allow Speech a short interval to produce its final result.
    public func stop() {
        guard !stopping, engine != nil else { return }
        stopping = true
        stopInput()
        let current = token
        stopFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.finish(token: current)
        }
    }

    public func cancel() {
        token = UUID()
        stopFallback?.cancel(); stopFallback = nil
        stopInput()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        engine = nil
        onEvent = nil
        latestTranscript = ""
        stopping = false
    }

    private func stopInput() {
        if let engine {
            if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
            if engine.isRunning { engine.stop() }
        }
        if !hasEndedAudio {
            request?.endAudio()
            hasEndedAudio = true
        }
    }

    private func receive(text: String?, isFinal: Bool, failure: String?, token current: UUID) {
        guard token == current else { return }
        if let text, !text.isEmpty {
            latestTranscript = text
            onEvent?(.partial(text))
        }
        if isFinal { finish(token: current); return }
        if let failure {
            if stopping, !latestTranscript.isEmpty { finish(token: current) }
            else {
                let callback = onEvent
                cancel()
                callback?(.failed("Dictation stopped: \(failure)"))
            }
        }
    }

    private func finish(token current: UUID) {
        guard token == current else { return }
        let final = latestTranscript
        let callback = onEvent
        cancel()
        callback?(.finished(final))
    }

}
