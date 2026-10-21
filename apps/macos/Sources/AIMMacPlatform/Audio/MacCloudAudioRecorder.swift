import AVFoundation
import AIMApplication
import Foundation

/// A short, user-triggered recording for cloud transcription. The temporary
/// recording is deleted on stop/cancel, including when the network later fails.
@MainActor
public final class MacCloudAudioRecorder {
    private let permissions = MacPermissionCenter()
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var token = UUID()

    public init() {}
    public var isRecording: Bool { recorder?.isRecording == true }

    public func start() async throws {
        cancel()
        let current = token
        guard await permissions.request(.microphone) == .granted else {
            throw SpeechDictationError.microphoneDenied
        }
        try Task.checkCancellation()
        guard token == current else { throw CancellationError() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aim-dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw SpeechDictationError.failedToStart }
            self.recorder = recorder
            recordingURL = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw SpeechDictationError.failedToStart
        }
    }

    public func finish() throws -> Data {
        guard let recorder, let url = recordingURL else { throw OpenAITranscriptionError.emptyRecording }
        recorder.stop()
        self.recorder = nil
        recordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        guard data.count > 128 else { throw OpenAITranscriptionError.emptyRecording }
        return data
    }

    public func cancel() {
        token = UUID()
        recorder?.stop()
        recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }
}
