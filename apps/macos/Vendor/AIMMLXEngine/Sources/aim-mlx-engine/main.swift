// AIM's MLX engine. Loads one MLX model from a local folder and answers OpenAI-style
// chat requests on 127.0.0.1 (the same interface as llama.cpp's server, so AIM treats both
// engines alike):
//   aim-mlx-engine --model <folder> --port <port> [--alias <name>] [--context <tokens>] [--kv-bits 8]
//   GET /health · GET /v1/models · POST /v1/chat/completions (stream or not)
import Foundation
import MLXLLM
import MLXLMCommon
import Network
import Tokenizers

// MARK: Arguments

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard let modelPath = argument("--model"), let portText = argument("--port"), let port = UInt16(portText) else {
    FileHandle.standardError.write(Data("usage: aim-mlx-engine --model <folder> --port <port> [--alias <name>]\n".utf8))
    exit(2)
}
let modelFolder = URL(fileURLWithPath: modelPath, isDirectory: true)
let alias = argument("--alias") ?? modelFolder.lastPathComponent
/// The person's context length for this model (a KV cache of this size), and an 8-bit KV cache.
let contextLimit = argument("--context").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
let kvBits = argument("--kv-bits").flatMap(Int.init)

// MARK: Tokenizer bridge (swift-transformers → MLXLMCommon)

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do { return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
        catch Tokenizers.TokenizerError.missingChatTemplate { throw MLXLMCommon.TokenizerError.missingChatTemplate }
    }
}

struct TokenizerLoaderBridge: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

// MARK: Generation

/// One request at a time: the model and its memory are shared.
actor Engine {
    let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    struct Request {
        var instructions: String?
        var messages: [Chat.Message]
        var parameters: GenerateParameters
        var thinking: Bool?
        var stop: [String] = []
    }

    /// Streams the answer, then returns the engine's own counts and timings.
    func generate(_ request: Request, onText: @Sendable (String) -> Void) async throws -> GenerateCompletionInfo? {
        var context: [String: any Sendable]? = nil
        if let thinking = request.thinking { context = ["enable_thinking": thinking] }
        let session = ChatSession(container, instructions: request.instructions,
                                  generateParameters: request.parameters, additionalContext: context)
        var info: GenerateCompletionInfo?
        // Stop strings: text is held back while it could still be the start of one.
        let stops = request.stop.filter { !$0.isEmpty }
        let holdBack = stops.map(\.count).max().map { $0 - 1 } ?? 0
        var pending = ""
        generation: for try await generation in session.streamDetails(to: request.messages) {
            try Task.checkCancellation()
            if let details = generation.info { info = details }
            guard let text = generation.chunk else { continue }
            guard !stops.isEmpty else { onText(text); continue }
            pending += text
            if let range = stops.compactMap({ pending.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                let before = String(pending[..<range.lowerBound])
                if !before.isEmpty { onText(before) }
                pending = ""
                break generation
            }
            if pending.count > holdBack {
                onText(String(pending.dropLast(holdBack)))
                pending = String(pending.suffix(holdBack))
            }
        }
        if !pending.isEmpty { onText(pending) }
        return info
    }
}

/// llama.cpp's `timings` and OpenAI's `usage`, so AIM reads both engines the same way.
func metrics(_ info: GenerateCompletionInfo?) -> [String: Any] {
    guard let info else { return [:] }
    return [
        "usage": ["prompt_tokens": info.totalPromptTokenCount, "completion_tokens": info.generationTokenCount,
                  "total_tokens": info.totalPromptTokenCount + info.generationTokenCount,
                  "prompt_tokens_details": ["cached_tokens": info.cachedPromptTokenCount]],
        "timings": ["engine": "mlx", "prompt_n": info.promptTokenCount, "prompt_ms": info.promptTime * 1000,
                    "cache_n": info.cachedPromptTokenCount,
                    "predicted_n": info.generationTokenCount, "predicted_ms": info.generateTime * 1000],
    ]
}

func parseRequest(_ body: Data) throws -> (Engine.Request, stream: Bool) {
    guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
          let raw = json["messages"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
    var instructions: [String] = []
    var messages: [Chat.Message] = []
    for item in raw {
        let content: String
        if let text = item["content"] as? String { content = text }
        else if let parts = item["content"] as? [[String: Any]] { content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        else { content = "" }
        switch item["role"] as? String {
        case "system": instructions.append(content)
        case "assistant": messages.append(.assistant(content))
        case "tool": messages.append(.tool(content))
        default: messages.append(.user(content))
        }
    }
    var parameters = GenerateParameters()
    if let value = json["temperature"] as? Double { parameters.temperature = Float(value) }
    if let value = json["top_p"] as? Double { parameters.topP = Float(value) }
    if let value = json["top_k"] as? Int { parameters.topK = value }
    if let value = json["min_p"] as? Double { parameters.minP = Float(value) }
    if let value = (json["max_tokens"] ?? json["max_completion_tokens"]) as? Int { parameters.maxTokens = value }
    if let value = (json["repeat_penalty"] ?? json["repetition_penalty"]) as? Double, value != 1 { parameters.repetitionPenalty = Float(value) }
    if let value = json["seed"] as? Int, value >= 0 { parameters.seed = UInt64(value) }
    if let contextLimit { parameters.maxKVSize = contextLimit }
    if let kvBits { parameters.kvBits = kvBits }
    let stop = (json["stop"] as? [String]) ?? (json["stop"] as? String).map { [$0] } ?? []
    let thinking = (json["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool
    return (Engine.Request(instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"),
                           messages: messages, parameters: parameters, thinking: thinking, stop: stop),
            json["stream"] as? Bool ?? false)
}

/// Splits "<think>…</think>" from the answer so AIM can treat reasoning separately.
struct ThinkFilter {
    private var inside = false
    private var pending = ""

    mutating func feed(_ text: String) -> (answer: String, reasoning: String) {
        pending += text
        var answer = "", reasoning = ""
        while true {
            let tag = inside ? "</think>" : "<think>"
            if let range = pending.range(of: tag) {
                let before = String(pending[..<range.lowerBound])
                if inside { reasoning += before } else { answer += before }
                pending = String(pending[range.upperBound...])
                inside.toggle()
                continue
            }
            // Keep a possible partial tag for the next chunk.
            let keep = min(pending.count, tag.count - 1)
            let flush = String(pending.dropLast(keep))
            if inside { reasoning += flush } else { answer += flush }
            pending = String(pending.suffix(keep))
            return (answer, reasoning)
        }
    }

    mutating func finish() -> String {
        defer { pending = "" }
        return inside ? "" : pending
    }
}

// MARK: HTTP

final class Server: @unchecked Sendable {
    let engine: Engine
    let listener: NWListener
    let queue = DispatchQueue(label: "aim.mlx.server")

    init(engine: Engine, port: UInt16) throws {
        self.engine = engine
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 16 << 20 || error != nil { connection.cancel(); return }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            let length = lines.dropFirst().compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            let body = buffer[headerEnd.upperBound...]
            if body.count < length && !complete { self.receive(connection, buffer: buffer); return }
            let method = requestLine.count > 0 ? String(requestLine[0]) : ""
            let path = requestLine.count > 1 ? String(requestLine[1]) : ""
            Task { await self.handle(method: method, path: path, body: Data(body.prefix(length)), connection: connection) }
        }
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, close: Bool = true) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if body.isEmpty { head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in if close { connection.cancel() } })
    }

    private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8) }

    private func handle(method: String, path: String, body: Data, connection: NWConnection) async {
        switch (method, path) {
        case ("GET", "/health"):
            send(connection, status: "200 OK", type: "application/json", body: json(["status": "ok"]))
        case ("GET", "/v1/models"):
            send(connection, status: "200 OK", type: "application/json",
                 body: json(["object": "list", "data": [["id": alias, "object": "model", "owned_by": "aim"]]]))
        case ("POST", "/v1/chat/completions"):
            await chat(body: body, connection: connection)
        default:
            send(connection, status: "404 Not Found", type: "application/json", body: json(["error": ["message": "not found"]]))
        }
    }

    private func chat(body: Data, connection: NWConnection) async {
        let request: Engine.Request, stream: Bool
        do { (request, stream) = try parseRequest(body) } catch {
            send(connection, status: "400 Bad Request", type: "application/json", body: json(["error": ["message": "invalid request"]]))
            return
        }
        let id = "chatcmpl-" + UUID().uuidString.lowercased()
        let created = Int(Date.now.timeIntervalSince1970)
        if stream {
            let writer = StreamWriter(connection: connection, id: id, created: created, model: alias)
            writer.open()
            do {
                let info = try await engine.generate(request) { writer.write($0) }
                writer.finish(metrics: metrics(info))
            } catch {
                writer.fail()
            }
        } else {
            let collected = Collected()
            do {
                let info = try await engine.generate(request) { collected.append($0) }
                var filter = ThinkFilter()
                let parts = filter.feed(collected.text)
                var message: [String: Any] = ["role": "assistant", "content": parts.answer + filter.finish()]
                if !parts.reasoning.isEmpty { message["reasoning_content"] = parts.reasoning }
                var response: [String: Any] = [
                    "id": id, "object": "chat.completion", "created": created, "model": alias,
                    "choices": [["index": 0, "message": message, "finish_reason": "stop"]],
                ]
                response.merge(metrics(info)) { $1 }
                send(connection, status: "200 OK", type: "application/json", body: json(response))
            } catch {
                send(connection, status: "500 Internal Server Error", type: "application/json", body: json(["error": ["message": "generation failed"]]))
            }
        }
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func append(_ text: String) { lock.lock(); parts.append(text); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
}

// MARK: Start

/// The server lives for the whole process; AIM stops it by terminating the process.
nonisolated(unsafe) var runningServer: Server?

Task {
    do {
        let container = try await LLMModelFactory.shared.loadContainer(from: modelFolder, using: TokenizerLoaderBridge())
        let server = try Server(engine: Engine(container: container), port: port)
        server.start()
        runningServer = server
        print("aim-mlx-engine ready: \(alias) on 127.0.0.1:\(port)")
    } catch {
        FileHandle.standardError.write(Data("aim-mlx-engine: could not load the model: \(error)\n".utf8))
        exit(1)
    }
}
dispatchMain()

/// Sends one streamed answer as OpenAI-style server-sent events.
final class StreamWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let id: String
    private let created: Int
    private let model: String
    private let lock = NSLock()
    private var filter = ThinkFilter()

    init(connection: NWConnection, id: String, created: Int, model: String) {
        self.connection = connection; self.id = id; self.created = created; self.model = model
    }

    private func chunk(_ delta: [String: Any], finish: String? = nil, extra: [String: Any] = [:]) -> Data {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        choice["finish_reason"] = finish ?? NSNull()
        var object: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model, "choices": [choice]]
        object.merge(extra) { $1 }
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Data("data: ".utf8) + body + Data("\n\n".utf8)
    }

    func open() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    func write(_ text: String) {
        lock.lock()
        let parts = filter.feed(text)
        lock.unlock()
        if !parts.reasoning.isEmpty { connection.send(content: chunk(["reasoning_content": parts.reasoning]), completion: .contentProcessed { _ in }) }
        if !parts.answer.isEmpty { connection.send(content: chunk(["content": parts.answer]), completion: .contentProcessed { _ in }) }
    }

    func finish(metrics: [String: Any] = [:]) {
        lock.lock()
        let rest = filter.finish()
        lock.unlock()
        if !rest.isEmpty { connection.send(content: chunk(["content": rest]), completion: .contentProcessed { _ in }) }
        let connection = connection
        connection.send(content: chunk([:], finish: "stop", extra: metrics) + Data("data: [DONE]\n\n".utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    func fail() {
        let connection = connection
        connection.send(content: Data("data: {\"error\":{\"message\":\"generation failed\"}}\n\n".utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
