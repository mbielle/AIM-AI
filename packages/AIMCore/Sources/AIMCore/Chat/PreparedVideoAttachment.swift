import Foundation
@preconcurrency import AVFoundation
import ImageIO
import Speech

public struct PreparedVideoAttachment: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case automatic, detailed, excerpt }
    public struct Frame: Codable, Hashable, Identifiable, Sendable {
        public let id: UUID
        public let seconds: Double
        public let jpeg: Data
        public init(id: UUID = UUID(), seconds: Double, jpeg: Data) {
            self.id = id; self.seconds = seconds; self.jpeg = jpeg
        }
    }
    public let id: UUID
    public let name: String
    public let duration: Double
    public let rangeStart: Double
    public let rangeEnd: Double
    public let mode: Mode
    public let originDeviceID: String
    public let originDeviceName: String
    public var frames: [Frame]
    public var transcript: String?
    public var audioNotice: String?
    public init(id: UUID = UUID(), name: String, duration: Double, rangeStart: Double, rangeEnd: Double,
                mode: Mode, originDeviceID: String, originDeviceName: String, frames: [Frame],
                transcript: String? = nil, audioNotice: String? = nil) {
        self.id = id; self.name = name; self.duration = duration; self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd; self.mode = mode; self.originDeviceID = originDeviceID
        self.originDeviceName = originDeviceName; self.frames = frames; self.transcript = transcript; self.audioNotice = audioNotice
    }
    public var context: String {
        "Video: \(name). Duration \(duration)s. Sampled range \(rangeStart)–\(rangeEnd)s, mode \(mode.rawValue). "
        + "These are sampled observations, not every frame; events between samples are not established.\n"
        + frames.map { "Image \($0.id.uuidString): decoded timestamp \($0.seconds)s" }.joined(separator: "\n")
        + "\nLocal transcript: \(transcript ?? audioNotice ?? "Unavailable")"
    }
    public func validate() throws {
        guard duration.isFinite, duration > 0, rangeStart.isFinite, rangeEnd.isFinite,
              rangeStart >= 0, rangeEnd <= duration + 0.1, rangeEnd > rangeStart,
              !frames.isEmpty, frames.count <= 256, Set(frames.map(\.id)).count == frames.count,
              frames.reduce(0, { $0 + $1.jpeg.count }) <= 12_000_000,
              (transcript?.utf8.count ?? 0) <= 128_000 else { throw NativeDocumentError.limit }
        var prior = -Double.infinity
        for frame in frames {
            guard frame.seconds.isFinite, frame.seconds >= rangeStart - 0.1,
                  frame.seconds <= rangeEnd + 0.1, frame.seconds > prior else { throw NativeDocumentError.invalidSelection }
            _ = try NativeImageSnapshot(id: frame.id, name: "frame.jpg", mimeType: "image/jpeg", data: frame.jpeg)
            prior = frame.seconds
        }
    }
}

/// Local decoding only. The caller owns the account-private original and chooses
/// when any prepared image may leave this device. Resource limits fail explicitly.
public enum VideoPreparationError: LocalizedError {
    case excerptRequired(maximumSeconds: Double)
    public var errorDescription: String? {
        switch self {
        case .excerptRequired(let seconds): "This mode needs more than 256 decoded images. Choose an excerpt of at most \(Int(seconds)) seconds or a less detailed mode. The original is unchanged."
        }
    }
}
public enum VideoPreparationService {
    public static func sampleCount(duration: Double, mode: PreparedVideoAttachment.Mode) throws -> Int {
        let spacing = mode == .detailed ? 0.25 : 1.0
        guard duration.isFinite, duration > 0 else { throw NativeDocumentError.invalidSelection }
        guard duration <= 255 * spacing else { throw VideoPreparationError.excerptRequired(maximumSeconds: 255 * spacing) }
        return max(2, Int(ceil(duration / spacing)) + 1)
    }
    public static func prepare(_ url: URL, id: UUID = UUID(), mode: PreparedVideoAttachment.Mode = .automatic,
                               range: ClosedRange<Double>? = nil, originDeviceID: String,
                               originDeviceName: String) async throws -> PreparedVideoAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 250_000_000 else { throw NativeDocumentError.limit }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw NativeDocumentError.invalidSelection }
        let start = range?.lowerBound ?? 0, end = range?.upperBound ?? duration
        guard start >= 0, end <= duration, end > start else { throw NativeDocumentError.invalidSelection }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let count = try sampleCount(duration: end - start, mode: mode)
        var frames: [PreparedVideoAttachment.Frame] = []
        var previousSignature: [UInt8]?
        for index in 0..<count {
            try Task.checkCancellation()
            let time = start + (end - start) * Double(index) / Double(count - 1)
            // Avoid requesting an undecodable sample exactly beyond the final frame.
            let target = min(time, max(start, end - min(0.04, (end - start) / 10)))
            let (image, actual) = try await generator.image(at: CMTime(seconds: target, preferredTimescale: 600))
            let seconds = actual.seconds
            guard seconds.isFinite, frames.last.map({ seconds > $0.seconds }) ?? true else { continue }
            let signature = signature(image)
            let difference = previousSignature.map { old in zip(old, signature).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } } ?? Int.max
            // Keep chronological anchors plus observed scene changes; detailed
            // mode preserves all decoded samples. Never claim complete frame coverage.
            let anchor = index == 0 || index == count - 1 || index.isMultiple(of: 3)
            if mode != .automatic || anchor || difference > 900 {
                let original = NSMutableData()
                guard let out = CGImageDestinationCreateWithData(original, "public.jpeg" as CFString, 1, nil) else { throw NativeDocumentError.invalidSelection }
                CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                guard CGImageDestinationFinalize(out) else { throw NativeDocumentError.invalidSelection }
                var bounded: Data?
                for pixels in [1280, 960, 640, 384] {
                    bounded = InputMediaPreview.jpeg(original as Data, maximumPixels: pixels, maximumBytes: min(200_000, 12_000_000 / count))
                    if bounded != nil { break }
                }
                guard let bounded else { throw NativeDocumentError.limit }
                frames.append(.init(seconds: seconds, jpeg: bounded))
                guard frames.reduce(0, { $0 + $1.jpeg.count }) <= 12_000_000 else { throw NativeDocumentError.limit }
            }
            previousSignature = signature
        }
        var result = PreparedVideoAttachment(id: id, name: url.lastPathComponent, duration: duration,
            rangeStart: start, rangeEnd: end, mode: mode, originDeviceID: originDeviceID, originDeviceName: originDeviceName, frames: frames)
        if try await asset.loadTracks(withMediaType: .audio).isEmpty { result.audioNotice = "No audio track." }
        else if range != nil { result.audioNotice = "Audio transcription is unavailable for this excerpt." }
        else {
            do { result.transcript = try await LocalVideoTranscription.transcribe(asset) }
            catch is CancellationError { throw CancellationError() }
            catch { result.audioNotice = "Audio was not analysed: on-device transcription is unavailable or was refused." }
        }
        try result.validate(); return result
    }
    private static func signature(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.withUnsafeMutableBytes { memory in
            if let context = CGContext(data: memory.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
        return bytes
    }
}

@MainActor private enum LocalVideoTranscription {
    static func transcribe(_ asset: AVURLAsset) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw NativeDocumentError.invalidSelection }
        let audio = URL.temporaryDirectory.appendingPathComponent("aim-audio-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        export.outputURL = audio; export.outputFileType = .m4a
        await export.export()
        try Task.checkCancellation()
        guard export.status == .completed else { throw NativeDocumentError.invalidSelection }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false
        let operation = VideoSpeechOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(continuation)
                let recognition = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal { operation.finish(.success(result.bestTranscription.formattedString)) }
                    else if let error { operation.finish(.failure(error)) }
                }
                operation.install(recognition)
                Task { try? await Task.sleep(for: .seconds(60)); operation.finish(.failure(NativeDocumentError.limit)) }
            }
        } onCancel: { operation.finish(.failure(CancellationError())) }
    }
}
private final class VideoSpeechOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var task: SFSpeechRecognitionTask?
    func install(_ value: SFSpeechRecognitionTask) {
        let cancel = lock.withLock { task = value; return finished != nil }; if cancel { value.cancel() }
    }
    private var finished: Result<String, any Error>?
    func start(_ continuation: CheckedContinuation<String, any Error>) {
        let done = lock.withLock { () -> Result<String, any Error>? in if let finished { return finished }; self.continuation = continuation; return nil }
        if let done { continuation.resume(with: done) }
    }
    func finish(_ result: Result<String, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            guard finished == nil else { return nil }; finished = result
            defer { self.continuation = nil }; return self.continuation
        }
        continuation?.resume(with: result); lock.withLock { task }?.cancel()
    }
}

public struct VideoPreparationOptions: Codable, Equatable, Sendable {
    public var mode: PreparedVideoAttachment.Mode
    public var start: Double?
    public var end: Double?
    public init(mode: PreparedVideoAttachment.Mode = .automatic, start: Double? = nil, end: Double? = nil) {
        self.mode = mode; self.start = start; self.end = end
    }
    public func range() throws -> ClosedRange<Double>? {
        guard mode == .excerpt else { return nil }
        guard let start, let end, start.isFinite, end.isFinite, start >= 0, end > start else { throw NativeDocumentError.invalidSelection }
        return start...end
    }
}
