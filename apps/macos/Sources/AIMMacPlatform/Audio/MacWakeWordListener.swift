import Foundation
import Observation

/// A wake phrase only raises a local callback. It never sends an objective,
/// grants tool authority, stores ambient audio, or invokes a cloud recognizer.
@MainActor @Observable
public final class MacWakeWordListener {
    public private(set) var isListening = false
    public private(set) var failure: String?
    public private(set) var wakeCount = 0
    @ObservationIgnored private let recognizer = MacSpeechDictationService()
    @ObservationIgnored private var restart: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var phrase = ""
    @ObservationIgnored private var callback: (@MainActor () -> Void)?
    @ObservationIgnored private var triggered = false
    @ObservationIgnored private var lastWake = Date.distantPast
    public init() {}
    public func start(phrase: String, onWake: @escaping @MainActor () -> Void) async throws {
        stop()
        let normalized = Self.normalize(phrase)
        guard normalized.count >= 3, normalized.count <= 120 else { throw SpeechDictationError.unavailable }
        self.phrase = normalized; callback = onWake; isListening = true; failure = nil
        do { try await listen(token: token) } catch { stop(); throw error }
    }
    public func stop() {
        token = UUID(); isListening = false
        restart?.cancel(); restart = nil; recognizer.cancel(); callback = nil
    }
    private func listen(token current: UUID) async throws {
        guard current == token, isListening else { return }
        triggered = false
        try await recognizer.start(locale: DictationLanguage.locale()) { [weak self] event in
            guard let self, self.token == current, self.isListening else { return }
            switch event {
            case .partial(let text):
                let words = " " + Self.normalize(text) + " "
                if !self.triggered, words.contains(" " + self.phrase + " "), Date().timeIntervalSince(self.lastWake) >= 5 {
                    self.triggered = true; self.lastWake = .now; self.wakeCount += 1; self.callback?()
                }
            case .finished:
                self.scheduleRestart(token: current)
            case .failed(let error):
                // Avoid a permission/error retry loop that repeatedly opens UI.
                self.failure = error; self.stop()
            }
        }
    }
    private func scheduleRestart(token current: UUID) {
        restart?.cancel()
        restart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.token == current, self.isListening else { return }
            do { try await self.listen(token: current) }
            catch { self.failure = error.localizedDescription; self.stop() }
        }
    }
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
