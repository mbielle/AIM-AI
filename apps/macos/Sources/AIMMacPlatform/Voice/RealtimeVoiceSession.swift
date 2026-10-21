import AIMCore
import AIMApplication
import AVFoundation
import Foundation
import Observation

/// A live spoken conversation with OpenAI's Realtime model. The microphone streams
/// only while the session is open (echo-cancelled, so AIM does not hear itself);
/// speaking over AIM interrupts it; real work is delegated to AIM's agent, whose
/// approvals still appear on screen. Each spoken response is admitted by the spend
/// ledger before it is requested, and reconciled from the reported usage.
@MainActor
@Observable
public final class RealtimeVoiceSession: VoiceConversation {
    public typealias State = VoiceConversationState
    public typealias Line = VoiceConversationLine

    public private(set) var state: State = .idle
    public private(set) var lines: [Line] = []

    public typealias AskAgent = @Sendable (String) async -> String

    private let apiKey: String
    private let model: String
    private let voice: String
    private let instructions: String
    private let meter: BillableRequestMeter
    private let askAgent: AskAgent
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: RealtimeVoiceProtocol.sampleRate, channels: 1)!
    private var pendingAudio = Data()
    private var currentItemID: String?
    private var responseWaiter: CheckedContinuation<RealtimeVoiceProtocol.Usage?, Never>?
    private var responding = false
    private var assistantDraft = ""
    /// Outgoing messages go through one ordered queue (audio chunks must not be reordered).
    private var outgoing: AsyncStream<String>.Continuation?
    private var senderTask: Task<Void, Never>?
    private var itemStartSample: AVAudioFramePosition = 0

    public init(apiKey: String, model: String = RealtimeVoiceProtocol.defaultModel, voice: String = "marin",
                instructions: String, meter: BillableRequestMeter, askAgent: @escaping AskAgent) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.meter = meter
        self.askAgent = askAgent
    }

    public static let defaultInstructions = """
    You are AIM, the person's assistant on their Mac, in a spoken conversation. Speak naturally and briefly, \
    in the person's language. For anything beyond small talk — actions, files, apps, email, calendar, web, code \
    or facts you are unsure about — call ask_aim_agent with the full request, tell the person you are on it, \
    then summarize its answer aloud in a few sentences. Never claim something was done unless ask_aim_agent said so.
    """

    // MARK: Lifecycle

    public func start() async {
        guard state == .idle || isFailed else { return }
        state = .connecting
        lines = []
        do {
            try RuntimePrivacyPolicy.requireApplicationNetwork()
            guard await MacPermissionCenter().request(.microphone) == .granted else {
                throw SpeechDictationError.microphoneDenied
            }
            var request = URLRequest(url: RealtimeVoiceProtocol.url(model: model))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let socket = RuntimeManagedNetworkSession.shared.webSocketTask(with: request)
            try RuntimePrivacyPolicy.requireApplicationNetwork()
            self.socket = socket
            socket.resume()
            let (stream, continuation) = AsyncStream<String>.makeStream()
            outgoing = continuation
            senderTask = Task {
                for await text in stream { try? await socket.send(.string(text)) }
            }
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
            try send(RealtimeVoiceProtocol.sessionUpdate(instructions: instructions, voice: voice))
            try startAudio()
            state = .listening
        } catch {
            stop()
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        outgoing?.finish()
        outgoing = nil
        senderTask?.cancel()
        senderTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        responseWaiter?.resume(returning: nil)
        responseWaiter = nil
        responding = false
        if !isFailed { state = .idle }
    }

    public func interrupt() {
        if responding { try? send(RealtimeVoiceProtocol.responseCancel()) }
        if let item = currentItemID {
            let played = playedMilliseconds
            player.stop(); player.play()
            try? send(RealtimeVoiceProtocol.truncate(itemID: item, playedMilliseconds: played))
            currentItemID = nil
            itemStartSample = 0
        }
        state = .listening
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    // MARK: Audio

    private func startAudio() throws {
        let input = engine.inputNode
        // Echo cancellation: AIM's own voice must not be heard as the person speaking.
        try? input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw SpeechDictationError.noMicrophone }
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let pcm = RealtimeVoiceProtocol.pcm16(from: samples, sourceRate: rate)
            Task { @MainActor in self?.queueMicrophone(pcm) }
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func queueMicrophone(_ pcm: Data) {
        pendingAudio.append(pcm)
        // ~100 ms per message keeps latency low without flooding the socket.
        guard pendingAudio.count >= Int(RealtimeVoiceProtocol.sampleRate * 0.1) * 2 else { return }
        let chunk = pendingAudio
        pendingAudio.removeAll(keepingCapacity: true)
        try? send(RealtimeVoiceProtocol.appendAudio(chunk))
    }

    private func play(_ pcm: Data, itemID: String) {
        if currentItemID != itemID {
            currentItemID = itemID
            itemStartSample = currentSample
        }
        let samples = RealtimeVoiceProtocol.floats(fromPCM16: pcm)
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        player.scheduleBuffer(buffer)
        if state != .speaking { state = .speaking }
    }

    private var currentSample: AVAudioFramePosition {
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return time.sampleTime
    }

    /// How much of the current item the person actually heard (the player clock spans all items).
    private var playedMilliseconds: Int {
        Int(Double(max(0, currentSample - itemStartSample)) / RealtimeVoiceProtocol.sampleRate * 1_000)
    }

    // MARK: Events

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message else { continue }
                await handle(RealtimeVoiceProtocol.parse(text))
            } catch {
                if !Task.isCancelled { state = .failed("Voice connection closed: \(error.localizedDescription)"); stop() }
                return
            }
        }
    }

    private func handle(_ event: RealtimeVoiceProtocol.ServerEvent) async {
        switch event {
        case .speechStarted:
            // Barge-in: stop speaking at once and drop the unplayed audio.
            if responding { try? send(RealtimeVoiceProtocol.responseCancel()) }
            if let item = currentItemID {
                let played = playedMilliseconds
                player.stop(); player.play()
                try? send(RealtimeVoiceProtocol.truncate(itemID: item, playedMilliseconds: played))
                currentItemID = nil
                itemStartSample = 0
            }
            if case .working = state {} else { state = .listening }
        case .speechStopped:
            state = .thinking
            Task { await requestResponse() }
        case .userTranscript(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(Line(speaker: .person, text: trimmed)) }
        case .audioDelta(let item, let pcm):
            play(pcm, itemID: item)
        case .assistantTranscriptDelta(let delta):
            assistantDraft += delta
        case .assistantTranscriptDone(let text):
            let final = text.isEmpty ? assistantDraft : text
            assistantDraft = ""
            if !final.isEmpty { lines.append(Line(speaker: .aim, text: final)) }
        case .functionCall(let callID, let name, let arguments):
            guard name == RealtimeVoiceProtocol.agentToolName else {
                try? send(RealtimeVoiceProtocol.functionOutput(callID: callID, output: "Unknown tool."))
                return
            }
            let request = ((try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any])?["request"] as? String ?? arguments
            Task { await delegate(request, callID: callID) }
        case .responseDone(_, let usage):
            responding = false
            responseWaiter?.resume(returning: usage)
            responseWaiter = nil
            if case .working = state {} else if state != .speaking { state = .listening }
        case .error(let message):
            // A cancelled response that already ended is harmless; anything else is shown.
            if !message.lowercased().contains("cancel") { lines.append(Line(speaker: .aim, text: "⚠️ \(message)")) }
        case .sessionReady, .other:
            break
        }
    }

    /// One billable spoken response, admitted first and reconciled from its usage.
    private func requestResponse() async {
        guard socket != nil, !responding else { return }
        responding = true
        let model = self.model
        do {
            _ = try await meter.perform(provider: ChatProvider.openAI.rawValue, modelID: model, feature: "voice",
                                        maximumUSD: "0.50",
                                        // Input transcription has its own billable
                                        // receipt, which is not collected here.
                                        // Keep the ledger reservation/unknown
                                        // state instead of understating total cost.
                                        receiptUSD: { _ in nil }) {
                await self.awaitResponse()
            }
        } catch {
            responding = false
            lines.append(Line(speaker: .aim, text: "⚠️ \(error.localizedDescription)"))
            state = .listening
        }
    }

    private func awaitResponse() async -> RealtimeVoiceProtocol.Usage? {
        await withCheckedContinuation { continuation in
            responseWaiter = continuation
            Task { do { try send(RealtimeVoiceProtocol.responseCreate()) } catch { resolveWaiter() } }
        }
    }

    private func resolveWaiter() {
        responseWaiter?.resume(returning: nil)
        responseWaiter = nil
    }

    private func delegate(_ request: String, callID: String) async {
        state = .working(request)
        lines.append(Line(speaker: .agent, text: "→ \(request)"))
        let answer = await askAgent(request)
        lines.append(Line(speaker: .agent, text: answer))
        try? send(RealtimeVoiceProtocol.functionOutput(callID: callID, output: String(answer.prefix(12_000))))
        state = .thinking
        await requestResponse()
    }

    private func send(_ object: [String: Any]) throws {
        try RuntimePrivacyPolicy.requireApplicationNetwork()
        guard let outgoing else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: object)
        outgoing.yield(String(decoding: data, as: UTF8.self))
    }
}
