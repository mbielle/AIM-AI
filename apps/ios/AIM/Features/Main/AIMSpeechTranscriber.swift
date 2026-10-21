import AVFoundation
import Observation
@preconcurrency import Speech

@MainActor
@Observable
final class AIMSpeechTranscriber {
    var transcript = ""
    var isRecording = false
    var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var audioSessionActive = false

    func toggle() {
        if isRecording { stop() }
        else { Task { await start() } }
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        let speechStatus = await speechAuthorization()
        guard speechStatus == .authorized, await microphoneAuthorized() else {
            errorMessage = String(localized: "speech.permission.error")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            errorMessage = String(localized: "speech.unavailable")
            return
        }

        stop()
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try await activateAudioSession()
            audioSessionActive = true
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable [weak request] buffer, _ in
                request?.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = error != nil || result?.isFinal == true
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if finished { self.stop() }
                }
            }
        } catch {
            stop()
            errorMessage = String(localized: "speech.unavailable")
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        if audioSessionActive {
            audioSessionActive = false
            Task.detached {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await AIMMediaPermissionBridge.request { SFSpeechRecognizer.requestAuthorization($0) }
    }

    private func microphoneAuthorized() async -> Bool {
        await AIMMediaPermissionBridge.request { AVAudioApplication.requestRecordPermission(completionHandler: $0) }
    }

    private func activateAudioSession() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// System permission completions may arrive on any queue. Keeping their bridge
/// nonisolated prevents inheriting a caller's MainActor isolation in Swift 6.
enum AIMMediaPermissionBridge {
    nonisolated static func request<Value: Sendable>(
        _ register: @Sendable (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            register { value in continuation.resume(returning: value) }
        }
    }
}
