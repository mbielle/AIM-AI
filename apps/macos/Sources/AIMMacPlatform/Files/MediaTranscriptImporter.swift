import AIMApplication
import AVFoundation
import Foundation

public enum MediaImportError: LocalizedError {
    case invalidFile, noAudio, exportFailed, externalEngine
    public var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose an audio or video file up to 250 MB."
        case .noAudio: "This media file has no readable audio track."
        case .exportFailed: "The audio track could not be extracted locally."
        case .externalEngine: "This import accepts on-device transcription only. Choose Apple, Whisper or Parakeet."
        }
    }
}
@MainActor public enum MediaTranscriptImporter {
    public static func read(_ url: URL, engine: DictationEngine = .apple) async throws -> TextAttachment {
        guard engine != .openAI else { throw MediaImportError.externalEngine }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 250_000_000,
              ["wav", "m4a", "mp3", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
            throw MediaImportError.invalidFile
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw MediaImportError.noAudio }
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-media-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw MediaImportError.exportFailed }
        let audio = folder.appending(path: "audio.m4a")
        exporter.outputURL = audio; exporter.outputFileType = .m4a
        let job = MediaExportOperation(exporter)
        await withTaskCancellationHandler { await job.run() } onCancel: { job.cancel() }
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw MediaImportError.exportFailed }
        let text: String
        if engine == .apple { text = try await AppleFileDictation.transcribe(audio) }
        else { text = try await LocalDictationModels.shared.transcribe(audio, with: engine) }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalDictationError.noSpeech }
        let snapshot = TextAttachment(name: url.lastPathComponent + ".transcript.txt",
            content: "Local audio transcription of \(url.lastPathComponent), engine \(engine.id). Recognition may be imperfect; this snapshot does not describe video images or speakers.\n\n" + text)
        try TextAttachment.validate([snapshot]); return snapshot
    }
}

/// Configuration is complete before crossing queues; AV export cancellation is
/// serialized against startup. No AVAsset state is mutated by the caller later.
private final class MediaExportOperation: @unchecked Sendable {
    private let exporter: AVAssetExportSession
    private let lock = NSLock()
    private var cancelled = false
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(); return }
            exporter.exportAsynchronously { continuation.resume() }
            lock.unlock()
        }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); exporter.cancelExport() }
}
