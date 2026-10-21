import AIMCore
import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech
import UIKit

private final class VoiceObserverTokens: @unchecked Sendable {
    let values: [NSObjectProtocol]
    init(_ values: [NSObjectProtocol]) { self.values = values }
    deinit { values.forEach(NotificationCenter.default.removeObserver) }
}

/// AVAudioSession calls may block while negotiating a route. Enqueue them in
/// actor order, then execute them off the UI thread on one serial queue.
@MainActor final class AIMVoiceAudioSession {
    private let queue = DispatchQueue(label: "com.aimai.voice.audio-session")
    private let activateOperation: @Sendable (Bool) throws -> Void
    private let deactivateOperation: @Sendable () throws -> Void
    init(activate: @escaping @Sendable (Bool) throws -> Void = { preview in
        let session = AVAudioSession.sharedInstance()
        if preview { try session.setCategory(.playback, mode: .default) }
        else { try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth]) }
        try session.setActive(true)
    }, deactivate: @escaping @Sendable () throws -> Void = {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }) {
        activateOperation = activate; deactivateOperation = deactivate
    }
    func activate(preview: Bool) async throws {
        let operation = activateOperation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try operation(preview); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func deactivate() {
        let operation = deactivateOperation
        queue.async { try? operation() }
    }
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }
}

struct AIMDictationEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
    var conversationID: UUID?
}

struct AIMVoiceChatSelection: Codable, Equatable {
    var provider: ChatProvider
    var modelID: String
}

@MainActor @Observable final class AIMVoiceController {
    var active = false
    var listening = false
    var responding = false
    var transcript = ""
    var answer = ""
    var error: String?
    var configuration = AIMVoiceConfiguration()
    var startWithVoice = false
    var history: [AIMDictationEntry] = []
    var conversationSelection: AIMVoiceChatSelection?
    private(set) var previewing = false
    private unowned let chat: NativeChatStore
    private let audioSession: AIMVoiceAudioSession
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var tapInstalled = false
    private var responseID = UUID()
    private var responseStart = Date()
    private var sessionReady = false
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var observerTokens: VoiceObserverTokens?
    private var starting = false
    private var generation = UUID()
    private var historyReadable = true
    private var cascadeTask: Task<Void, Never>?
    private var historyURL: URL
    private var sessionOwner: UUID?
    private var sessionContext: RealtimeVoiceContext?
    private var pendingRealtimeResponse = false
    private var receivedTranscript = false
    private var previewRecorded = false
    private var responseRecorded = false
    private var responseAdmitted = false
    private var sessionChatSelection: AIMVoiceChatSelection?
    private var sessionChatCatalog: [ChatModel] = []
    private var responseTranscript = ""
    init(chat: NativeChatStore, audioSession: AIMVoiceAudioSession? = nil) {
        self.chat = chat; self.audioSession = audioSession ?? AIMVoiceAudioSession()
        let prefix = "aim.voice." + chat.accountID.uuidString
        if let data = UserDefaults.standard.data(forKey: prefix + ".configuration"), let saved = try? JSONDecoder().decode(AIMVoiceConfiguration.self, from: data) { configuration = saved }
        if let data = UserDefaults.standard.data(forKey: prefix + ".chat-selection") { conversationSelection = try? JSONDecoder().decode(AIMVoiceChatSelection.self, from: data) }
        startWithVoice = UserDefaults.standard.bool(forKey: prefix + ".start")
        historyURL = URL.applicationSupportDirectory.appending(path: "Chat/\(chat.accountID.uuidString)/dictation.json")
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do { history = try JSONDecoder().decode([AIMDictationEntry].self, from: Data(contentsOf: historyURL)) }
            catch { historyReadable = false; self.error = "Saved dictation history could not be read. It has been preserved." }
        }
        let interruptions = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stop() } }
        let routeChanges = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] event in
            let reason = event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.stop() } }
        }
        let privacy = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in if self?.active == true { self?.stop() } } }
        observerTokens = VoiceObserverTokens([interruptions, routeChanges, privacy])
    }
    func saveConfiguration() {
        let prefix = "aim.voice." + chat.accountID.uuidString
        UserDefaults.standard.set(try? JSONEncoder().encode(configuration), forKey: prefix + ".configuration")
        UserDefaults.standard.set(startWithVoice, forKey: prefix + ".start")
        UserDefaults.standard.set(conversationSelection.flatMap { try? JSONEncoder().encode($0) }, forKey: prefix + ".chat-selection")
    }
    func enableStart(_ enabled: Bool) async {
        if enabled {
            guard await microphonePermission(), ready else { error = "Configure the selected provider, model and microphone first."; return }
        }
        startWithVoice = enabled; saveConfiguration()
    }
    var ready: Bool {
        if configuration.engine == .realtime { return chat.connectedProviders.contains(.openAI) }
        let selection = resolvedConversationSelection
        return !selection.modelID.isEmpty && chat.connectedProviders.contains(selection.provider) && chat.executionTarget == .thisDevice
    }
    var resolvedConversationSelection: AIMVoiceChatSelection { conversationSelection ?? .init(provider: chat.provider, modelID: chat.modelID) }
    func captureSessionContext() {
        sessionOwner = chat.accountID
        if let conversation = chat.selected {
            sessionContext = .init(conversationID: conversation.id, projectID: conversation.projectID.flatMap(UUID.init(uuidString:)))
        } else { sessionContext = .init(projectID: chat.selectedProjectID) }
    }
    func selectConversationModel(provider: ChatProvider, model: ChatModel) -> Bool {
        guard !active, !starting, !chat.isSending, chat.connectedProviders.contains(provider), model.isChatModel else { return false }
        conversationSelection = .init(provider: provider, modelID: model.id); saveConfiguration(); error = nil; return true
    }
    /// The same provider/model pair displayed in Voice is applied before the dictation enters Chat.
    @discardableResult func applyConversationSelection(_ selection: AIMVoiceChatSelection, catalog: [ChatModel]) -> Bool {
        guard !chat.isSending, chat.executionTarget == .thisDevice, chat.connectedProviders.contains(selection.provider),
              catalog.contains(where: { $0.id == selection.modelID && $0.isChatModel }) else {
            error = "The selected voice Chat model is unavailable. Choose another explicitly."; return false
        }
        chat.provider = selection.provider; chat.models = catalog; chat.modelID = selection.modelID; return true
    }
    private func microphonePermission() async -> Bool {
        await AIMMediaPermissionBridge.request { AVAudioApplication.requestRecordPermission(completionHandler: $0) }
    }
    func start() async {
        guard !active, !starting, !chat.isSending else { return }
        starting = true; let sessionGeneration = generation
        defer { if generation == sessionGeneration { starting = false } }
        error = nil; captureSessionContext()
        if configuration.engine == .cascade {
            let selection = resolvedConversationSelection
            do {
                let catalog = try await chat.catalog(for: selection.provider)
                guard generation == sessionGeneration, sessionOwner == chat.accountID, !Task.isCancelled,
                      applyConversationSelection(selection, catalog: catalog) else { return }
                sessionChatSelection = selection; sessionChatCatalog = catalog
            } catch { self.error = "The selected voice Chat model could not be checked. No model was substituted."; return }
        }
        guard ready, await microphonePermission() else { error = "Choose a model and allow microphone access in iOS Settings."; return }
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        if configuration.engine == .cascade {
            let permission = await AIMMediaPermissionBridge.request { SFSpeechRecognizer.requestAuthorization($0) }
            guard permission == .authorized else { error = "Allow speech recognition in iOS Settings."; return }
            guard generation == sessionGeneration, !Task.isCancelled else { return }
        } else {
            responseID = UUID()
            guard chat.admitRealtimeVoice(id: responseID, context: sessionContext) else { error = chat.errorMessage; return }
            responseAdmitted = true; responseRecorded = false; responseStart = .now
        }
        active = true; previewing = false; transcript = ""; answer = ""; pendingRealtimeResponse = false; receivedTranscript = false
        do {
            guard try await activateAudioSession(preview: false, generation: sessionGeneration) else { return }
            if configuration.engine == .realtime { try await connectRealtime() }
            else { try await beginDictation() }
            guard generation == sessionGeneration, active else { return }
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            self.error = "Voice could not start with this configuration. No provider was substituted."; stop()
        }
    }
    /// A cancelled/obsolete activation cannot proceed to audio/network or stop a
    /// newer session. Its already-enqueued Stop is ordered before the next Start.
    func activateAudioSession(preview: Bool, generation expectedGeneration: UUID? = nil) async throws -> Bool {
        let expected = expectedGeneration ?? generation
        do { try await audioSession.activate(preview: preview) }
        catch {
            if generation == expected, active, Task.isCancelled { stop(); return false }
            throw error
        }
        guard generation == expected, active else { return false }
        if Task.isCancelled { stop(); return false }
        return true
    }
    private func beginDictation() async throws {
        guard active else { throw CancellationError() }
        let locale = configuration.language.isEmpty ? Locale.current : Locale(identifier: configuration.language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { error = "On-device dictation is unavailable for this language."; throw ChatServiceError.invalidResponse }
        let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; self.request = request
        let sessionGeneration = generation
        recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, failure in
            let text = result?.bestTranscription.formattedString; let final = result?.isFinal == true; let failed = failure != nil
            Task { @MainActor in
                guard let self, self.active, self.generation == sessionGeneration else { return }
                if let text { self.transcript = text }
                if failed { self.error = "Dictation was interrupted."; self.stop() }
                else if final { self.submitDictation() }
            }
        }
        let input = audio.inputNode, format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in request.append(buffer) }
        tapInstalled = true; try audio.start(); listening = true
    }
    func submitDictation() {
        guard cascadeTask == nil, active, listening else { return }
        cascadeTask = Task { [weak self] in await self?.finishDictation() }
    }
    private func finishDictation() async {
        guard active, configuration.engine == .cascade, listening else { return }
        let sessionGeneration = generation
        defer { if generation == sessionGeneration { cascadeTask = nil } }
        listening = false; removeTap(); request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { stop(); return }
        responding = true
        guard sessionOwner == chat.accountID else { stop(); return }
        guard let selection = sessionChatSelection, chat.connectedProviders.contains(selection.provider),
              sessionChatCatalog.contains(where: { $0.id == selection.modelID && $0.isChatModel }) else { stop(); return }
        let capturedContext = sessionContext ?? .init()
        let conversationID = capturedContext.conversationID ?? UUID()
        let accepted = await chat.send(text, conversationID: conversationID, projectID: capturedContext.projectID,
            provider: selection.provider, modelID: selection.modelID, catalog: sessionChatCatalog, target: .thisDevice,
            selectConversation: chat.selectedID == capturedContext.conversationID)
        if accepted {
            sessionContext = .init(conversationID: conversationID, projectID: capturedContext.projectID)
            guard generation == sessionGeneration, active, !Task.isCancelled else { return }
            recordDictation(text, conversation: conversationID)
            await chat.waitForResponse(conversationID: conversationID)
            guard active, generation == sessionGeneration, !Task.isCancelled, chat.responseError(conversationID: conversationID) == nil, let last = chat.conversations.first(where: { $0.id == conversationID })?.messages.last, last.role == .assistant else { return }
            answer = last.text
            chat.speak(last.text, conversationID: conversationID)
        } else {
            guard generation == sessionGeneration, active, !Task.isCancelled else { return }
            error = chat.errorMessage
        }
        responding = false
    }
    func previewRealtimeVoice() async {
        guard !active, !starting, !chat.isSending, configuration.engine == .realtime, chat.connectedProviders.contains(.openAI) else { return }
        starting = true; let sessionGeneration = generation
        defer { if generation == sessionGeneration { starting = false } }
        error = nil; sessionOwner = chat.accountID; sessionContext = .init()
        responseID = UUID()
        guard chat.admitRealtimeVoice(id: responseID, context: sessionContext) else { error = chat.errorMessage; return }
        responseAdmitted = true
        active = true; previewing = true; previewRecorded = false; responding = false; transcript = ""; answer = ""; responseStart = .now
        do {
            guard try await activateAudioSession(preview: true, generation: sessionGeneration) else { return }
            try await connectRealtime()
            guard generation == sessionGeneration, active else { return }
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            guard generation == sessionGeneration else { return }
            self.error = "The OpenAI Realtime preview could not start. No other provider was used."; stop()
        }
    }
    private func connectRealtime() async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard let key = try chat.key(for: .openAI), !key.isEmpty else { throw ChatServiceError.missingKey }
        // Keep the existing Mac model in this phase; the user chooses an upgrade later.
        var request = URLRequest(url: RealtimeVoiceProtocol.url()); request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let session = NativeChatTransport.secretSession(); self.session = session
        let socket = session.webSocketTask(with: request); self.socket = socket; socket.resume()
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!)
        let sessionGeneration = generation
        if !previewing {
            let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(8)) { self.audioContinuation = $0 }
            let continuation = audioContinuation!
            let input = audio.inputNode, format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                let pcm = RealtimeVoiceProtocol.pcm16(from: Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))), sourceRate: format.sampleRate)
                if case .dropped = continuation.yield(pcm) { continuation.finish() }
            }
            tapInstalled = true
            sender = Task { [weak self] in
                do { for await pcm in stream { guard !Task.isCancelled, let self, self.generation == sessionGeneration else { return }; if self.sessionReady { try await self.send(RealtimeVoiceProtocol.appendAudio(pcm)) } } }
                catch {
                    guard !Task.isCancelled, self?.generation == sessionGeneration else { return }
                    self?.error = "Voice connection interrupted."; self?.stop()
                }
                if !Task.isCancelled, self?.active == true, self?.generation == sessionGeneration { self?.error = "Microphone audio could not be sent in time."; self?.stop() }
            }
        }
        try audio.start(); player.play(); listening = !previewing
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.active, self.generation == sessionGeneration else { return }
                    let text: String
                    switch message { case .string(let value): text = value; case .data(let data): text = String(decoding: data, as: UTF8.self); @unknown default: continue }
                    if let raw = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], raw["type"] as? String == "session.created" { continue }
                    try await self.receive(RealtimeVoiceProtocol.parse(text))
                }
            } catch { guard !Task.isCancelled, self?.generation == sessionGeneration else { return }; self?.error = "Realtime connection unavailable. Choose another engine explicitly to continue."; self?.stop() }
        }
        try await send(realtimeSessionUpdate(query: "", preview: previewing))
    }
    func realtimeSessionUpdate(query: String, preview: Bool = false) -> [String: Any] {
        var instructions = preview ? "Read a short voice sample only. Do not access personal context." : chat.voiceContextInstructions(query: query, projectID: sessionContext?.projectID)
        if !configuration.language.isEmpty { instructions += "\nSpeak in " + configuration.language }
        return RealtimeVoiceProtocol.sessionUpdate(instructions: instructions, voice: configuration.voice, allowsAgent: false)
    }
    func realtimeContextUpdate(query: String) -> [String: Any] {
        let initial = realtimeSessionUpdate(query: query)["session"] as? [String: Any]
        // Realtime forbids changing voice after audio output. Later turns update instructions only.
        return ["type": "session.update", "session": ["type": "realtime", "instructions": initial?["instructions"] as? String ?? ""]]
    }
    static func realtimePreviewResponse() -> [String: Any] {
        ["type": "response.create", "response": ["conversation": "none", "input": [], "output_modalities": ["audio"],
            "tools": [], "tool_choice": "none", "max_output_tokens": 128, "instructions": "Say exactly: Hello, I’m AIM. Let’s get started."]]
    }
    private func beginRealtimeResponse() async throws {
        guard pendingRealtimeResponse, receivedTranscript, !responding, sessionOwner == chat.accountID else { return }
        pendingRealtimeResponse = false
        guard prepareRealtimeTurn(transcript: transcript) else { stop(); return }
        try await send(realtimeContextUpdate(query: responseTranscript))
        try await send(["type": "response.create", "response": ["max_output_tokens": "inf"]])
    }
    /// Local admission/bookkeeping is separate from audio/network so interruption
    /// persistence can be verified without microphone access or a paid request.
    @discardableResult func prepareRealtimeTurn(transcript: String, at date: Date = .now) -> Bool {
        guard sessionOwner == chat.accountID, !responding, !previewing else { return false }
        guard chat.admitRealtimeVoice(id: responseID, context: sessionContext) else { error = chat.errorMessage; return false }
        responseAdmitted = true; responseRecorded = false; responding = true
        responseStart = date; responseTranscript = transcript; receivedTranscript = false; answer = ""
        return true
    }
    private func closeRealtimeTurn(tokens: Int? = nil) {
        guard !previewing, !responseRecorded, sessionOwner == chat.accountID,
              responseAdmitted || responding else { return }
        responseRecorded = true
        // OpenAI bills input transcription separately. Until both receipts are
        // measured, a response-only estimate cannot represent the turn's cost.
        let conversationID = chat.recordVoiceTurn(id: responseID, userText: responseTranscript, assistantText: answer,
            start: responseStart, tokens: tokens, cost: nil, context: sessionContext)
        if let conversationID { sessionContext?.conversationID = conversationID }
        recordDictation(responseTranscript, conversation: conversationID)
        responding = false; responseAdmitted = false; responseTranscript = ""
    }
    private func send(_ value: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let socket else { throw CancellationError() }; try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func receive(_ event: RealtimeVoiceProtocol.ServerEvent) async throws {
        switch event {
        case .sessionReady:
            guard !sessionReady else { return }; sessionReady = true
            if previewing {
                responding = true
                try await send(Self.realtimePreviewResponse())
            }
        case .speechStarted:
            guard !previewing else { return }
            transcript = ""; receivedTranscript = false; pendingRealtimeResponse = false
            player.stop(); player.play()
            if responding { try await send(RealtimeVoiceProtocol.responseCancel()) }
        case .speechStopped:
            guard !previewing else { return }
            pendingRealtimeResponse = true; try await beginRealtimeResponse()
        case .userTranscript(let text):
            guard !previewing else { return }; transcript = text; receivedTranscript = true
            try await beginRealtimeResponse()
        case .assistantTranscriptDelta(let text): answer += text
        case .assistantTranscriptDone(let text): answer = text
        case .audioDelta(_, let data): play(data)
        case .responseDone(_, let usage):
            let tokens = usage?.totalTokens
            let cost = usage.flatMap { RealtimeVoiceProtocol.costUSD($0, model: RealtimeVoiceProtocol.defaultModel) }.map { NSDecimalNumber(decimal: $0).doubleValue }
            guard sessionOwner == chat.accountID else { stop(); return }
            if previewing {
                chat.recordRealtimeVoicePreview(id: responseID, startedAt: responseStart, totalTokens: tokens, costUSD: cost)
                previewRecorded = true
                responding = false
                // Leave the scheduled PCM playing; the preview stops automatically after its short tail.
                deadline?.cancel()
                deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(8)); guard !Task.isCancelled else { return }; self?.stop() }
                return
            }
            guard responding, !responseRecorded else { return }
            closeRealtimeTurn(tokens: tokens)
            responseID = UUID(); responseRecorded = false
            try await beginRealtimeResponse()
        case .functionCall: throw ChatServiceError.unsupportedTools
        case .error: throw ChatServiceError.invalidResponse
        case .other("conversation.item.input_audio_transcription.failed"):
            error = "Realtime could not transcribe this turn. End the session and retry explicitly."; stop()
        default: break
        }
    }
    private func play(_ data: Data) {
        let values = RealtimeVoiceProtocol.floats(fromPCM16: data)
        guard !values.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)), let pointer = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(values.count); values.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: $0.count) }; player.scheduleBuffer(buffer)
    }
    private func removeTap() { if tapInstalled { audio.inputNode.removeTap(onBus: 0); tapInstalled = false }; audio.stop() }
    func stop() {
        if previewing, !previewRecorded, sessionOwner == chat.accountID {
            chat.recordRealtimeVoicePreview(id: responseID, startedAt: responseStart, totalTokens: nil, costUSD: nil)
        }
        if configuration.engine == .realtime, !previewing {
            closeRealtimeTurn()
            // Preserve a newly transcribed barge-in even if Stop/lock arrives
            // before the next response is requested. No new request is sent.
            if receivedTranscript, !transcript.isEmpty, sessionOwner == chat.accountID {
                responseID = UUID(); responseTranscript = transcript; responseStart = .now
                responseRecorded = false; responseAdmitted = true; answer = ""
                closeRealtimeTurn()
            }
        }
        if configuration.engine == .cascade, responding, !previewing, let id = sessionContext?.conversationID { chat.cancel(conversationID: id) }
        generation = UUID(); starting = false
        active = false; previewing = false; listening = false; responding = false; sessionReady = false
        sessionOwner = nil; sessionContext = nil; sessionChatSelection = nil; sessionChatCatalog = []
        responseRecorded = false; responseAdmitted = false
        pendingRealtimeResponse = false; receivedTranscript = false; previewRecorded = false; responseTranscript = ""
        removeTap(); player.stop(); if player.engine != nil { audio.detach(player) }
        recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil
        audioContinuation?.finish(); audioContinuation = nil
        sender?.cancel(); receiver?.cancel(); deadline?.cancel(); cascadeTask?.cancel()
        sender = nil; receiver = nil; deadline = nil; cascadeTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil; session?.invalidateAndCancel(); session = nil
        chat.stopSpeaking()
        audioSession.deactivate()
    }
    func stopAndWait() async {
        let tasks = [sender, receiver, deadline, cascadeTask]; stop()
        for task in tasks { await task?.value }
        await audioSession.drain()
    }
    func recordDictation(_ text: String, conversation: UUID?) {
        guard historyReadable, !text.isEmpty else { return }; history.append(.init(text: text, conversationID: conversation))
        do { try JSONEncoder().encode(history).write(to: historyURL, options: [.atomic, .completeFileProtection]) } catch { self.error = "Dictation text could not be saved." }
    }
    func clearHistory() { guard historyReadable else { return }; history = []; try? JSONEncoder().encode(history).write(to: historyURL, options: [.atomic, .completeFileProtection]) }
}
