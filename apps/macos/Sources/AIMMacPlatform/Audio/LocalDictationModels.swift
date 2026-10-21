import AIMCore
import AIMApplication
import AVFoundation
import FluidAudio
import Foundation
import NaturalLanguage
import Observation
import Speech
import WhisperKit

/// Where dictated speech becomes text.
public enum DictationEngine: Hashable, Sendable, Identifiable {
    /// Apple's on-device recognizer (nothing leaves the Mac).
    case apple
    /// OpenAI's transcription model with the person's API key.
    case openAI
    /// Whisper on Core ML (WhisperKit), one downloadable variant.
    case whisper(String)
    /// NVIDIA Parakeet TDT 0.6B v3 (FluidAudio), 25 European languages.
    case parakeet

    public var id: String {
        switch self {
        case .apple: "apple"
        case .openAI: "openai"
        case .whisper(let variant): "whisper:" + variant
        case .parakeet: "parakeet-v3"
        }
    }

    public init?(id: String) {
        switch id {
        case "apple": self = .apple
        case "openai": self = .openAI
        case "parakeet-v3": self = .parakeet
        default:
            guard id.hasPrefix("whisper:"), id.count > 8 else { return nil }
            self = .whisper(String(id.dropFirst(8)))
        }
    }

    public var isLocalModel: Bool {
        switch self {
        case .whisper, .parakeet: true
        case .apple, .openAI: false
        }
    }

    public static let defaultsKey = "aim.dictation.engine"
    /// The engine the person chose explicitly; nil until they pick one.
    public static var chosen: DictationEngine? { UserDefaults.standard.string(forKey: defaultsKey).flatMap(DictationEngine.init(id:)) }
    public static var selected: DictationEngine {
        get { chosen ?? .apple }
        set { UserDefaults.standard.set(newValue.id, forKey: defaultsKey) }
    }
    /// The engine used: the person's choice, otherwise GPT Transcribe when an OpenAI key is saved
    /// (it detects the spoken language), otherwise Apple's on-device recognizer.
    public static func effective(hasOpenAIKey: Bool) -> DictationEngine {
        chosen ?? (hasOpenAIKey ? .openAI : .apple)
    }
    /// A newly saved OpenAI key makes GPT Transcribe the engine, unless the person chose a local model.
    public static func adoptOpenAI() {
        if chosen == nil || chosen == .apple { selected = .openAI }
    }
}

/// The spoken language: "auto" follows the Mac's first preferred language for Apple
/// (which needs one) and lets Whisper, OpenAI and Parakeet detect it.
public enum DictationLanguage {
    public static let defaultsKey = "aim.dictation.language"

    /// "auto" or a locale identifier such as "fr-FR".
    public static var selected: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// The language of the person's own recent messages, detected on this Mac (nothing is sent).
    public static let detectedKey = "aim.dictation.detectedLanguage"
    public static var detected: String? { UserDefaults.standard.string(forKey: detectedKey) }
    /// Records the language of a message the person wrote; short or ambiguous text is ignored.
    public static func learn(from text: String) {
        guard text.count >= 20 else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.6,
              language != .undetermined else { return }
        UserDefaults.standard.set(language.rawValue, forKey: detectedKey)
    }

    /// The locale Apple's recognizer uses. Apple cannot detect the spoken language, so "auto"
    /// follows the language the person writes in, then the Mac's first preferred language.
    public static func locale(_ choice: String = selected, preferred: [String] = Locale.preferredLanguages,
                              detected: String? = DictationLanguage.detected, supported: Set<String>? = nil) -> Locale {
        guard choice == "auto" else { return Locale(identifier: choice) }
        guard let language = detected else { return Locale(identifier: preferred.first ?? "en-US") }
        let available = supported ?? Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        func matches(_ id: String) -> Bool { Locale(identifier: id).language.languageCode?.identifier == language }
        // Prefer the person's own region, then any preferred variant, then the language's main one.
        let region = Locale(identifier: preferred.first ?? "").region?.identifier
        let candidates = available.filter(matches).sorted()
        if let region, let regional = candidates.first(where: { Locale(identifier: $0).region?.identifier == region }) { return Locale(identifier: regional) }
        if let preferredMatch = preferred.first(where: { id in matches(id) && candidates.contains(id.replacingOccurrences(of: "_", with: "-")) }) { return Locale(identifier: preferredMatch) }
        if let main = candidates.first(where: { Locale(identifier: $0).region?.identifier.lowercased() == language }) { return Locale(identifier: main) }
        return Locale(identifier: candidates.first ?? preferred.first ?? "en-US")
    }

    /// The two-letter code sent to Whisper, OpenAI and Parakeet; nil means detect.
    public static func code(_ choice: String = selected) -> String? {
        guard choice != "auto" else { return nil }
        return Locale(identifier: choice).language.languageCode?.identifier
    }

    /// The choices offered: languages Apple can recognize on this Mac, by display name.
    public static func options(display: Locale = .current) -> [(id: String, name: String)] {
        let ids = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        return ids.map { ($0, display.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Whether an engine can be used now; the message tells what to do otherwise.
public enum DictationAvailability: Equatable {
    case ready, needsOpenAIKey, needsDownload

    public static func check(_ engine: DictationEngine, hasOpenAIKey: Bool, isDownloaded: (DictationEngine) -> Bool) -> DictationAvailability {
        switch engine {
        case .apple: .ready
        case .openAI: hasOpenAIKey ? .ready : .needsOpenAIKey
        case .whisper, .parakeet: isDownloaded(engine) ? .ready : .needsDownload
        }
    }
}

/// A model downloadable from the dictation menu.
public struct LocalDictationModel: Identifiable, Sendable, Hashable {
    public let engine: DictationEngine
    public let title: String
    public let detail: String
    public let size: String
    public var id: String { engine.id }
}

/// Downloads, lists and runs the on-device dictation models. Files live in
/// Application Support/…/Dictation Models; nothing is downloaded until asked.
@MainActor @Observable
public final class LocalDictationModels {
    public enum State: Equatable, Sendable {
        case absent, downloading(Double), ready, failed(String)
    }

    public static let shared = LocalDictationModels()

    nonisolated public static let catalog: [LocalDictationModel] = [
        .init(engine: .parakeet, title: "Parakeet v3", detail: "Fastest · 25 European languages", size: "≈ 500 MB"),
        .init(engine: .whisper("large-v3-v20240930_turbo_632MB"), title: "Whisper Large v3 Turbo",
              detail: "Most accurate · 99 languages", size: "≈ 650 MB"),
        .init(engine: .whisper("small_216MB"), title: "Whisper Small", detail: "Balanced · 99 languages", size: "≈ 220 MB"),
        .init(engine: .whisper("base"), title: "Whisper Base", detail: "Lightest · 99 languages", size: "≈ 150 MB"),
    ]

    public private(set) var states: [String: State] = [:]
    @ObservationIgnored private var folders: [String: String] = [:]
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]

    /// Where this instance keeps its models (tests use a temporary folder).
    public let directory: URL

    nonisolated public static var defaultDirectory: URL {
        let base = (try? ApplicationPaths())?.applicationSupport ?? FileManager.default.temporaryDirectory
        let folder = base.appending(path: "Dictation Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var indexURL: URL { directory.appending(path: "installed.json") }
    private var privacyTask: Task<Void, Never>?

    public init(directory: URL = LocalDictationModels.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
        let changes = RuntimePrivacyPolicy.globalChanges()
        privacyTask = Task { [weak self] in
            for await enabled in changes where enabled {
                guard let self else { return }
                for model in Self.catalog { self.cancelDownload(model.engine) }
            }
        }
    }

    public func state(_ engine: DictationEngine) -> State { states[engine.id] ?? .absent }
    public func isReady(_ engine: DictationEngine) -> Bool { state(engine) == .ready }
    public var installed: [LocalDictationModel] { Self.catalog.filter { isReady($0.engine) } }

    /// Re-reads which models are on disk (a deleted folder is no longer "ready").
    public func refresh() {
        folders = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))) ?? [:]
        for model in Self.catalog {
            if case .downloading = states[model.id] { continue }
            let exists = folders[model.id].map { path in
                // FluidAudio keeps Parakeet's files beside the folder it is given: ask it.
                model.engine == .parakeet ? AsrModels.modelsExist(at: URL(fileURLWithPath: path), version: .v3)
                                          : FileManager.default.fileExists(atPath: path)
            } ?? false
            states[model.id] = exists ? .ready : .absent
        }
    }

    public func download(_ engine: DictationEngine) {
        guard !RuntimePrivacyPolicy.isApplicationNetworkBlocked else { return }
        guard engine.isLocalModel, downloads[engine.id] == nil, !isReady(engine) else { return }
        states[engine.id] = .downloading(0)
        let id = engine.id
        let target = directory
        downloads[id] = Task { [weak self] in
            do {
                try RuntimePrivacyPolicy.requireApplicationNetwork()
                let privacyLease = try AIMNetworkPrivacyPolicy.beginOpaqueOperation("dictation model download")
                defer { withExtendedLifetime(privacyLease) {} }
                let report: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.states[id] else { return }
                        self.states[id] = .downloading(min(0.99, fraction))
                    }
                }
                let folder: URL
                switch engine {
                case .whisper(let variant):
                    folder = try await WhisperKit.download(variant: variant, downloadBase: target.appending(path: "whisperkit")) { progress in
                        report(progress.fractionCompleted)
                    }
                case .parakeet:
                    folder = try await AsrModels.download(to: target.appending(path: "parakeet/parakeet-v3", directoryHint: .isDirectory),
                                                          version: .v3) { progress in report(progress.fractionCompleted) }
                default: return
                }
                guard let self else { return }
                self.folders[id] = folder.path
                try? JSONEncoder().encode(self.folders).write(to: self.indexURL, options: .atomic)
                self.states[id] = .ready
                // Compile it for this Mac now rather than on the first dictation.
                self.prepare(engine)
            } catch is CancellationError {
                self?.states[id] = .absent
            } catch {
                self?.states[id] = .failed("Download failed. Check your connection and try again.")
            }
            self?.downloads[id] = nil
        }
    }

    public func cancelDownload(_ engine: DictationEngine) {
        downloads[engine.id]?.cancel()
        downloads[engine.id] = nil
        states[engine.id] = .absent
    }

    public func delete(_ engine: DictationEngine) {
        cancelDownload(engine)
        if let path = folders[engine.id], path.hasPrefix(directory.path) {
            // Parakeet's files sit in its parent "parakeet" folder.
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: engine == .parakeet ? url.deletingLastPathComponent() : url)
        }
        folders[engine.id] = nil
        try? JSONEncoder().encode(folders).write(to: indexURL, options: .atomic)
        if case .whisper(let variant) = engine, whisperLoad?.variant == variant { whisperLoad = nil }
        if engine == .parakeet { parakeetLoad = nil }
        states[engine.id] = .absent
    }

    /// Transcribes a recording with a downloaded model (loaded once, then kept in memory).
    /// Models being loaded; the first load on a Mac compiles the model for its chip
    /// (about a minute or two for Whisper Large), later loads take seconds.
    public private(set) var preparing: Set<String> = []
    /// WhisperKit is not marked Sendable; AIM only uses it from this main-actor object.
    private final class WhisperBox: @unchecked Sendable { let pipe: WhisperKit; init(_ pipe: WhisperKit) { self.pipe = pipe } }
    @ObservationIgnored private var whisperLoad: (variant: String, task: Task<WhisperBox, Error>)?
    @ObservationIgnored private var parakeetLoad: Task<AsrManager, Error>?

    /// Loads a downloaded model in the background so the first dictation does not wait.
    public func prepare(_ engine: DictationEngine) {
        guard isReady(engine) else { return }
        Task { _ = try? await self.loaded(engine) }
    }

    private enum Loaded { case whisper(WhisperKit), parakeet(AsrManager) }

    private func loaded(_ engine: DictationEngine) async throws -> Loaded {
        guard isReady(engine), let folder = folders[engine.id] else { throw LocalDictationError.notInstalled }
        let id = engine.id
        switch engine {
        case .whisper(let variant):
            let task: Task<WhisperBox, Error>
            if let current = whisperLoad, current.variant == variant { task = current.task }
            else {
                task = Task { WhisperBox(try await WhisperKit(WhisperKitConfig(modelFolder: folder, verbose: false, logLevel: .error, load: true, download: false))) }
                whisperLoad = (variant, task)
            }
            preparing.insert(id)
            defer { preparing.remove(id) }
            do { return .whisper(try await task.value.pipe) }
            catch { if whisperLoad?.variant == variant { whisperLoad = nil }; throw error }
        case .parakeet:
            let task: Task<AsrManager, Error>
            if let parakeetLoad { task = parakeetLoad }
            else {
                task = Task {
                    let models = try await AsrModels.load(from: URL(fileURLWithPath: folder), version: .v3)
                    let manager = AsrManager(config: .default)
                    try await manager.loadModels(models)
                    return manager
                }
                parakeetLoad = task
            }
            preparing.insert(id)
            defer { preparing.remove(id) }
            do { return .parakeet(try await task.value) }
            catch { parakeetLoad = nil; throw error }
        case .apple, .openAI:
            throw LocalDictationError.notInstalled
        }
    }

    /// Transcribes a recording with a downloaded model (loaded once, then kept in memory).
    public func transcribe(_ url: URL, with engine: DictationEngine, language: String? = DictationLanguage.code()) async throws -> String {
        switch try await loaded(engine) {
        case .whisper(let pipe):
            // A fixed language avoids Whisper guessing wrong on short phrases.
            let options = DecodingOptions(language: language, detectLanguage: language == nil)
            let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        case .parakeet(let manager):
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(url, decoderState: &state, language: language.flatMap(Language.init(rawValue:)))
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

public enum LocalDictationError: LocalizedError {
    case notInstalled, noSpeech
    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Download this dictation model first (Dictation settings)."
        case .noSpeech: "No speech was detected. Try again."
        }
    }
}

/// Apple's on-device recognizer on a saved recording (nothing is sent to Apple).
public enum AppleFileDictation {
    @MainActor
    public static func transcribe(_ url: URL, locale: Locale = DictationLanguage.locale()) async throws -> String {
        guard await MacPermissionCenter().request(.speechRecognition) == .granted else { throw SpeechDictationError.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw SpeechDictationError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw SpeechDictationError.onDeviceUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.shouldReportPartialResults = false
        try Task.checkCancellation()
        let result = FileSpeechResult()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.attach(continuation)
                guard !result.isFinished else { return }
                let task = recognizer.recognitionTask(with: request) { response, error in
                    if let response, response.isFinal { result.finish(.success(response.bestTranscription.formattedString)) }
                    else if let error { result.finish(.failure(error)) }
                }
                result.attach(task)
            }
        } onCancel: { result.finish(.failure(CancellationError())) }
    }
}

private final class FileSpeechResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var task: SFSpeechRecognitionTask?
    private var outcome: Result<String, Error>?
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return outcome != nil }
    func attach(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock(); let result = outcome
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }
    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock(); let finished = outcome != nil
        if !finished { self.task = task }
        lock.unlock()
        if finished { task.cancel() }
    }
    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = self.continuation; self.continuation = nil
        let task = self.task; self.task = nil
        lock.unlock()
        task?.cancel(); continuation?.resume(with: result)
    }
}
