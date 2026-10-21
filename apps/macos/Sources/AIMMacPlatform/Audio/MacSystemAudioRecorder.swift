import AVFoundation
import CoreMedia
import Foundation
import Observation
import ScreenCaptureKit

public enum SystemAudioError: LocalizedError {
    case noDisplay, invalidAudio, recordingFailed(String)
    public var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available for system audio capture."
        case .invalidAudio: "The system audio format could not be recorded."
        case .recordingFailed(let reason): "System audio recording stopped: \(reason)"
        }
    }
}
private final class SystemAudioSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failure: String?
    private var stopped = false
    private let url: URL
    init(url: URL) { self.url = url }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); failure = error.localizedDescription; stopped = true; file = nil; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= 65536, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        lock.lock(); defer { lock.unlock() }
        guard !stopped, failure == nil else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try file?.write(from: pcm)
        } catch { failure = error.localizedDescription; stopped = true; file = nil }
    }
    func close() -> String? { lock.lock(); defer { lock.unlock() }; stopped = true; file = nil; return failure }
    func currentFailure() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
}
/// Explicit foreground control; no automatic startup, upload, or hidden screen storage.
@MainActor @Observable
public final class MacSystemAudioRecorder {
    public private(set) var isRecording = false
    public private(set) var lastRecording: URL?
    public private(set) var failure: String?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var sink: SystemAudioSink?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var monitor: Task<Void, Never>?
    public init() {}
    public func start() async throws {
        guard stream == nil, !starting else { return }
        starting = true; defer { starting = false }
        let current = UUID(); token = current; failure = nil
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard token == current else { throw CancellationError() }
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }
        let directory = try ApplicationPaths().applicationSupport.appending(path: "SystemAudio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "system-audio-\(UUID().uuidString).caf")
        let sink = SystemAudioSink(url: url)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.aimai.system-audio"))
        self.stream = stream; self.sink = sink
        do {
            try await stream.startCapture()
            guard token == current else { try? await stream.stopCapture(); throw CancellationError() }
            lastRecording = url; isRecording = true
            monitor = Task { [weak self, sink] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if let error = sink.currentFailure() { self?.failure = error; await self?.stop(); return }
                }
            }
        } catch {
            try? await stream.stopCapture()
            self.stream = nil; self.sink = nil; _ = sink.close(); throw error
        }
    }
    public func stop() async {
        token = UUID(); monitor?.cancel(); monitor = nil
        let current = stream; stream = nil; isRecording = false
        do { try await current?.stopCapture() } catch { failure = error.localizedDescription }
        if let error = sink?.close() { failure = error }
        sink = nil
    }
}
