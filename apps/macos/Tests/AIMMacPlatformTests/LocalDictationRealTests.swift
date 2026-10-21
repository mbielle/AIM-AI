@testable import AIMMacPlatform
import XCTest

/// Opt-in: AIM_TEST_DICTATION_MODELS=1 downloads Whisper Base (≈150 MB) and, with
/// AIM_TEST_PARAKEET=1, Parakeet v3 (≈500 MB) into a temporary folder, then transcribes
/// a sentence spoken by macOS's own voice.
final class LocalDictationRealTests: XCTestCase {
    @MainActor
    func testDownloadedModelsTranscribeSpeech() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIM_TEST_DICTATION_MODELS"] == "1", "Set AIM_TEST_DICTATION_MODELS=1")
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-dictation-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appending(path: "speech.m4a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", audio.path, "--file-format=m4af", "--data-format=aac",
                         "The quick brown fox jumps over the lazy dog."]
        try say.run(); say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        var engines: [DictationEngine] = ProcessInfo.processInfo.environment["AIM_TEST_ONLY_PARAKEET"] == "1" ? [] : [.whisper("base")]
        if ProcessInfo.processInfo.environment["AIM_TEST_PARAKEET"] == "1" { engines.append(.parakeet) }
        let models = LocalDictationModels(directory: folder.appending(path: "models"))
        for engine in engines {
            models.download(engine)
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline {
                if case .downloading = models.state(engine) { try await Task.sleep(for: .milliseconds(500)); continue }
                break
            }
            XCTAssertEqual(models.state(engine), .ready, "\(engine.id) download")
            let started = Date()
            let text = try await models.transcribe(audio, with: engine).lowercased()
            print("[dictation] \(engine.id): \"\(text)\" in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            XCTAssertTrue(text.contains("fox"), text)
            XCTAssertTrue(text.contains("lazy dog"), text)
            // A fresh instance finds the downloaded model on disk.
            let index = (try? String(contentsOf: folder.appending(path: "models/installed.json"), encoding: .utf8)) ?? "none"
            XCTAssertTrue(LocalDictationModels(directory: folder.appending(path: "models")).isReady(engine), "\(engine.id) index: \(index)")
        }
    }
}

/// Opt-in: AIM_TEST_DICTATION_FR=1 uses the Whisper models already downloaded in AIM
/// (read only, nothing is downloaded) on French spoken by macOS's French voice.
final class FrenchDictationRealTests: XCTestCase {
    @MainActor
    func testFrenchSpeechWithInstalledWhisper() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIM_TEST_DICTATION_FR"] == "1", "Set AIM_TEST_DICTATION_FR=1")
        let models = LocalDictationModels()
        let installed = LocalDictationModels.catalog.map(\.engine).filter { models.isReady($0) }
        try XCTSkipIf(installed.isEmpty, "No dictation model downloaded in AIM")
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-fr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appending(path: "fr.m4a")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Thomas", "-o", audio.path, "--file-format=m4af", "--data-format=aac",
                         "Bonjour, je voudrais réserver une table pour deux personnes ce soir."]
        try say.run(); say.waitUntilExit()
        for engine in installed {
            let started = Date()
            let text = try await models.transcribe(audio, with: engine, language: "fr").lowercased()
            print("[dictation-fr] \(engine.id): \"\(text)\" in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            XCTAssertTrue(text.contains("réserver"), text)
            XCTAssertTrue(text.contains("table"), text)
        }
    }
}
