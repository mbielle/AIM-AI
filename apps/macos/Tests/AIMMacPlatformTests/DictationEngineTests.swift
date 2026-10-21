@testable import AIMMacPlatform
import XCTest

final class DictationEngineTests: XCTestCase {
    func testEngineIdentifiersRoundTrip() {
        for engine in [DictationEngine.apple, .openAI, .parakeet, .whisper("small_216MB")] {
            XCTAssertEqual(DictationEngine(id: engine.id), engine)
        }
        XCTAssertNil(DictationEngine(id: "whisper:"))
        XCTAssertNil(DictationEngine(id: "unknown"))
        XCTAssertTrue(DictationEngine.parakeet.isLocalModel)
        XCTAssertFalse(DictationEngine.apple.isLocalModel)
        XCTAssertEqual(Set(LocalDictationModels.catalog.map(\.id)).count, LocalDictationModels.catalog.count)
        XCTAssertTrue(LocalDictationModels.catalog.allSatisfy(\.engine.isLocalModel))
    }

    func testPendingRecordingsAreListedNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-dictation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "a.m4a"), new = folder.appending(path: "b.m4a"), other = folder.appending(path: "notes.txt")
        for url in [old, new, other] { try Data("audio".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: old.path)
        XCTAssertEqual(DictationRecorder.pending(in: folder).map(\.lastPathComponent), ["b.m4a", "a.m4a"])
        // Discard never deletes outside AIM's dictation folder.
        DictationRecorder.discard(new)
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    func testDownloadedModelsAreUsableWhateverTheirKind() {
        let downloaded: Set<String> = [DictationEngine.whisper("large-v3-v20240930_turbo_632MB").id]
        let isDownloaded: (DictationEngine) -> Bool = { downloaded.contains($0.id) }
        // The round 11 bug: a downloaded Whisper model was reported as missing.
        XCTAssertEqual(DictationAvailability.check(.whisper("large-v3-v20240930_turbo_632MB"), hasOpenAIKey: false, isDownloaded: isDownloaded), .ready)
        XCTAssertEqual(DictationAvailability.check(.whisper("base"), hasOpenAIKey: false, isDownloaded: isDownloaded), .needsDownload)
        XCTAssertEqual(DictationAvailability.check(.parakeet, hasOpenAIKey: true, isDownloaded: isDownloaded), .needsDownload)
        XCTAssertEqual(DictationAvailability.check(.openAI, hasOpenAIKey: false, isDownloaded: isDownloaded), .needsOpenAIKey)
        XCTAssertEqual(DictationAvailability.check(.apple, hasOpenAIKey: false, isDownloaded: isDownloaded), .ready)
    }

    func testSpokenLanguageReachesEachEngine() {
        XCTAssertEqual(DictationLanguage.locale("auto", preferred: ["fr-FR", "en-US"], detected: nil).identifier, "fr-FR")
        XCTAssertEqual(DictationLanguage.locale("de-DE").identifier, "de-DE")
        XCTAssertEqual(DictationLanguage.locale("auto", preferred: ["fr-FR"], detected: "en", supported: ["en-US", "fr-FR"]).identifier, "en-US")
        XCTAssertNil(DictationLanguage.code("auto"))
        XCTAssertEqual(DictationLanguage.code("fr-FR"), "fr")
        XCTAssertEqual(DictationLanguage.code("en_GB"), "en")
    }

    func testWaveformHistoryCoversAWideBarAtACalmPace() {
        // 6 pt per sample: a 2,000 pt bar needs 334 samples; 600 are kept.
        XCTAssertGreaterThanOrEqual(DictationRecorder.historyLength * 6, 3_000)
        XCTAssertEqual(DictationRecorder.sampleInterval, .milliseconds(70))
    }
}
