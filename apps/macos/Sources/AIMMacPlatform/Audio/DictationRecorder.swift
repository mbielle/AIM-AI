import AVFoundation
import Foundation
import Observation

/// Dictation audio written straight to disk (Application Support/…/Dictations), so a long
/// recording survives a failed transcription, a lost connection or a quit. The file is
/// removed only after a transcription succeeds or the person discards it.
@MainActor @Observable
public final class DictationRecorder {
    /// Recent input levels in 0…1, newest last (drives the waveform).
    public private(set) var levels: [Float] = []
    public private(set) var isRecording = false
    @ObservationIgnored private let permissions = MacPermissionCenter()
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    /// Enough samples for the widest bar; one every 70 ms scrolls at a calm pace.
    nonisolated public static let historyLength = 600
    nonisolated public static let sampleInterval: Duration = .milliseconds(70)

    public init() {}

    nonisolated public static var directory: URL {
        let base = (try? ApplicationPaths())?.applicationSupport ?? FileManager.default.temporaryDirectory
        let folder = base.appending(path: "Dictations", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Recordings kept after a failed transcription (newest first).
    nonisolated public static func pending(in folder: URL = directory) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "m4a" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    nonisolated public static func discard(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL || url.path.hasPrefix(directory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func start() async throws {
        cancel()
        let current = token
        guard await permissions.request(.microphone) == .granted else { throw SpeechDictationError.microphoneDenied }
        try Task.checkCancellation()
        guard token == current else { throw CancellationError() }
        let url = Self.directory.appending(path: "dictation-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw SpeechDictationError.failedToStart }
            self.recorder = recorder
            self.url = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw SpeechDictationError.failedToStart
        }
        levels = Array(repeating: 0, count: Self.historyLength)
        isRecording = true
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                self?.sample()
            }
        }
    }

    private func sample() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // dBFS (-160…0) → 0…1 with a gentle curve so quiet speech still moves.
        let power = max(-50, recorder.averagePower(forChannel: 0))
        let level = Float(pow(10, Double(power) / 40))
        levels.append(min(1, max(0, (level - 0.05) / 0.95)))
        if levels.count > Self.historyLength { levels.removeFirst(levels.count - Self.historyLength) }
    }

    /// Stops and keeps the file; the caller deletes it once its text is safe.
    public func stop() throws -> URL {
        meter?.cancel(); meter = nil
        isRecording = false
        guard let recorder, let url else { throw OpenAITranscriptionErrorBridge.emptyRecording }
        recorder.stop()
        self.recorder = nil
        self.url = nil
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 512 else { try? FileManager.default.removeItem(at: url); throw OpenAITranscriptionErrorBridge.emptyRecording }
        return url
    }

    #if DEBUG
    /// Gallery only: a still waveform without a microphone.
    public func debugShow(levels: [Float]) { self.levels = levels; isRecording = true }
    #endif

    public func cancel() {
        token = UUID()
        meter?.cancel(); meter = nil
        recorder?.stop()
        recorder = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        isRecording = false
        levels = []
    }
}

/// Keeps the platform layer free of the OpenAI error type while sharing its message.
public enum OpenAITranscriptionErrorBridge: LocalizedError {
    case emptyRecording
    public var errorDescription: String? { "No audio was recorded. Try again." }
}
