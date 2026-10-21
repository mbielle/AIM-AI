import AIMMacPlatform
import AppKit
import Foundation

package struct RuntimeAmbientAudioControl: Codable, Sendable {
    package enum Action: String, Codable, Sendable { case status, startRecording, stopRecording, listen, stopListening }
    package var action: Action
    package var phrase: String?
    package init(action: Action, phrase: String? = nil) { self.action = action; self.phrase = phrase }
}
package struct RuntimeAmbientAudioSnapshot: Codable, Sendable {
    package var recording: Bool
    package var listening: Bool
    package var wakeCount: Int
    package var recordingPath: String?
    package var failure: String?
    package static let idle = Self(recording: false, listening: false, wakeCount: 0)
}
/// Owned by the runtime process, including the windowless helper. Starting is
/// always a local human command; a restart does not silently reactivate capture.
@MainActor package final class RuntimeAmbientAudioController {
    private let recorder = MacSystemAudioRecorder()
    private let listener = MacWakeWordListener()
    private let applicationBundle: URL
    package init(applicationBundle: URL) { self.applicationBundle = applicationBundle }
    package func handle(_ data: Data) async throws -> Data {
        guard data.count <= 4096 else { throw AgentHostTransportError.invalidMessage }
        let command = try JSONDecoder().decode(RuntimeAmbientAudioControl.self, from: data)
        switch command.action {
        case .status: break
        case .startRecording: try await recorder.start()
        case .stopRecording: await recorder.stop()
        case .listen:
            guard let phrase = command.phrase else { throw AgentHostTransportError.invalidMessage }
            try await listener.start(phrase: phrase) { [applicationBundle] in
                // Opens only this signed AIM bundle, never an Agent objective.
                NSWorkspace.shared.open(applicationBundle)
            }
        case .stopListening: listener.stop()
        }
        return try JSONEncoder().encode(RuntimeAmbientAudioSnapshot(recording: recorder.isRecording,
            listening: listener.isListening, wakeCount: listener.wakeCount,
            recordingPath: recorder.lastRecording?.path, failure: recorder.failure ?? listener.failure))
    }
    package func stop() async { listener.stop(); await recorder.stop() }
}
