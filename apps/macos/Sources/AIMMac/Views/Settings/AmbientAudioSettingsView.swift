import AIMAgentRuntime
import AIMMacPlatform
import AppKit
import SwiftUI

struct AmbientAudioSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshot = RuntimeAmbientAudioSnapshot.idle
    @State private var busy = false
    @State private var phrase = "Hey AIM"
    @State private var transcript = ""
    @State private var error: String?
    @State private var importTask: Task<Void, Never>?
    var body: some View {
        SettingsGroup("Local ambient audio", description: "Starts only when you choose it. System recordings stay on this Mac; the wake phrase only brings AIM forward and never sends a task.") {
            SettingsRow("System audio", description: "Records sounds played by applications, excluding AIM. macOS may request Screen & System Audio Recording access. Stop recording before private calls or sensitive audio.") {
                if snapshot.recording { SettingsStatus(text: "Recording", color: .red) }
                Button(snapshot.recording ? "Stop recording" : "Start recording") {
                    busy = true
                    Task {
                        do {
                            snapshot = try await model.ambientAudioControl(.init(action: snapshot.recording ? .stopRecording : .startRecording))
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.buttonStyle(.settings).disabled(busy)
            }
            if let path = snapshot.recordingPath {
                let file = URL(fileURLWithPath: path)
                SettingsRow("Last recording", description: file.lastPathComponent) {
                    Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.buttonStyle(.settings)
                    Button("Transcribe locally") {
                        busy = true
                        Task {
                            do {
                                transcript = try await AppleFileDictation.transcribe(file)
                                let output = file.deletingPathExtension().appendingPathExtension("txt")
                                try Data(transcript.utf8).write(to: output, options: .atomic)
                                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                            } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.buttonStyle(.settings).disabled(busy || snapshot.recording)
                }
            }
            if !transcript.isEmpty { SettingsBlock { Text(transcript).textSelection(.enabled) } }
            SettingsRow("Import audio or video", description: "Transcribes the audio locally with your installed dictation model or Apple. Video frames are not interpreted, and nothing is uploaded.") {
                Button("Choose file…") {
                    let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.audio, .movie]
                    guard panel.runModal() == .OK, let file = panel.url else { return }
                    busy = true
                    importTask = Task {
                        defer { busy = false; importTask = nil }
                        do {
                            let chosen = DictationEngine.selected
                            let local = chosen == .openAI ? DictationEngine.apple : chosen
                            let snapshot = try await MediaTranscriptImporter.read(file, engine: local)
                            transcript = snapshot.content
                            let output = file.deletingPathExtension().appendingPathExtension("transcript.txt")
                            // Do not overwrite an existing transcript beside the source.
                            if !FileManager.default.fileExists(atPath: output.path) {
                                try Data(transcript.utf8).write(to: output, options: .withoutOverwriting)
                                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                            }
                        } catch is CancellationError {}
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.settings).disabled(busy)
                if importTask != nil { Button("Cancel") { importTask?.cancel() }.buttonStyle(.settings) }
            }
            SettingsRow("Wake phrase", description: "On-device microphone recognition. Owned by the runtime; in background mode it continues after quitting the interface. A service restart stops listening. It does not grant Agent permissions.") {
                TextField("Hey AIM", text: $phrase).textFieldStyle(.settings).frame(width: 140)
                    .disabled(snapshot.listening)
                Button(snapshot.listening ? "Stop listening" : "Listen") {
                    busy = true
                    Task {
                        do {
                            snapshot = try await model.ambientAudioControl(.init(action: snapshot.listening ? .stopListening : .listen, phrase: phrase))
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.buttonStyle(.settings).disabled(busy)
            }
            if snapshot.listening { SettingsRow("Listening locally", description: "Wake events: \(snapshot.wakeCount)") }
            if let failure = error ?? snapshot.failure {
                SettingsNotice(failure, tone: .error)
            }
        }.task {
            while !Task.isCancelled {
                if !busy { if let status = try? await model.ambientAudioControl(.init(action: .status)) { snapshot = status } }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
