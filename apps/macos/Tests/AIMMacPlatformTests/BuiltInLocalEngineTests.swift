import AIMApplication
@testable import AIMMacPlatform
import Foundation
import XCTest

final class BuiltInLocalEngineTests: XCTestCase {
    func testContextShrinksWithLargeWeights() {
        XCTAssertEqual(BuiltInLocalEngine.contextTokens(weightsBytes: 1_100_000_000, budget: 12_000_000_000), 32_768)
        XCTAssertEqual(BuiltInLocalEngine.contextTokens(weightsBytes: 9_000_000_000, budget: 12_000_000_000), 2_048)
        XCTAssertGreaterThan(BuiltInLocalEngine.freePort(), 0)
    }

    func testMissingEngineAndModelAreClearErrors() async {
        let missing = BuiltInLocalEngine(executable: nil)
        do { _ = try await missing.load(URL(fileURLWithPath: "/tmp/x.gguf"), name: "x", contextTokens: 4_096); XCTFail() }
        catch { XCTAssertEqual(error as? BuiltInLocalEngine.EngineError, .notBundled) }
    }

    /// Real llama.cpp + GGUF, opt-in: AIM_TEST_LLAMA_SERVER and AIM_TEST_GGUF.
    func testRealModelAnswersAndStops() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["AIM_TEST_LLAMA_SERVER"], let gguf = env["AIM_TEST_GGUF"] else { throw XCTSkip("set AIM_TEST_LLAMA_SERVER and AIM_TEST_GGUF") }
        let engine = BuiltInLocalEngine(executable: URL(fileURLWithPath: server), idleLimit: 600)
        let base = try await engine.load(URL(fileURLWithPath: gguf), name: "qwen3-test", contextTokens: 4_096)
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "qwen3-test", "max_tokens": 64,
            "messages": [["role": "user", "content": "Reply with the single word: ready /no_think"]],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.lowercased().contains("ready"), text)
        let reused = try await engine.load(URL(fileURLWithPath: gguf), name: "qwen3-test", contextTokens: 4_096)
        XCTAssertEqual(reused, base, "the same model is not reloaded")
        await engine.stop()
        let state = await engine.state
        XCTAssertEqual(state, .idle)
        let healthy = await BuiltInLocalEngine.isHealthy(base.deletingLastPathComponent().appendingPathComponent("health"))
        XCTAssertFalse(healthy, "the server stops with the engine")
    }
}

final class GGUFSelectionTests: XCTestCase {
    private func detail(_ files: [(String, Int64)]) -> HuggingFaceModelHub.ModelDetail {
        HuggingFaceModelHub.ModelDetail(id: "org/model-GGUF", sha: "abc",
                                        files: files.map { HuggingFaceModelHub.FileEntry(path: $0.0, size: $0.1) }, gated: false)
    }

    func testSplitFilesFormOneVersionAndProjectorsAreIgnored() {
        let variants = HuggingFaceModelHub.ggufQuantizations(detail([
            ("model-Q8_0-00001-of-00002.gguf", 5_000_000_000), ("model-Q8_0-00002-of-00002.gguf", 4_000_000_000),
            ("model-Q4_K_M.gguf", 5_000_000_000), ("mmproj-model-f16.gguf", 900_000_000),
        ]))
        XCTAssertEqual(variants.map(\.name), ["model-Q4_K_M", "model-Q8_0"])
        XCTAssertEqual(variants.last?.files.count, 2)
    }

    func testRecommendedVersionFitsMemory() {
        let variants = HuggingFaceModelHub.ggufQuantizations(detail([
            ("m-Q4_K_M.gguf", 20_000_000_000), ("m-Q3_K_M.gguf", 8_000_000_000), ("m-Q8_0.gguf", 30_000_000_000),
        ]))
        XCTAssertEqual(HuggingFaceModelHub.bestQuantization(variants, memoryBytes: 64_000_000_000)?.name, "m-Q4_K_M")
        XCTAssertEqual(HuggingFaceModelHub.bestQuantization(variants, memoryBytes: 17_000_000_000)?.name, "m-Q3_K_M")
    }

    func testNextPageComesFromTheLinkHeader() {
        let header = #"<https://huggingface.co/api/models?cursor=abc&limit=60>; rel="next""#
        XCTAssertEqual(HuggingFaceModelHub.nextLink(header)?.absoluteString, "https://huggingface.co/api/models?cursor=abc&limit=60")
        XCTAssertNil(HuggingFaceModelHub.nextLink(#"<https://huggingface.co/x>; rel="prev""#))
    }
}

final class LocalAnswerQualityTests: XCTestCase {
    /// Real model, opt-in (AIM_TEST_LLAMA_SERVER + AIM_TEST_GGUF): French answers with AIM's
    /// local instructions and sampling, timings printed for the report.
    func testFrenchAnswersWithAIMInstructions() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["AIM_TEST_LLAMA_SERVER"], let gguf = env["AIM_TEST_GGUF"] else { throw XCTSkip("opt-in") }
        let engine = BuiltInLocalEngine(executable: URL(fileURLWithPath: server))
        let started = Date.now
        let base = try await engine.load(URL(fileURLWithPath: gguf), name: "local-test", contextTokens: 8_192)
        print("LOAD seconds:", Date.now.timeIntervalSince(started))
        for prompt in ["fait moi une blague", "Quelle est la capitale de l'Australie ?", "Si j'ai 3 pommes et que j'en mange une, combien m'en reste-t-il ?"] {
            var body: [String: Any] = ["model": "local-test", "max_tokens": 300, "stream": false,
                "messages": [["role": "system", "content": LocalModelTuning.systemPrompt(mode: .chat)], ["role": "user", "content": prompt]]]
            for (key, value) in LocalModelTuning.sampling(modelID: "qwen3-8b", thinking: false) { body[key] = value }
            var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let asked = Date.now
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let text = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            print("PROMPT:", prompt, "| seconds:", Date.now.timeIntervalSince(asked), "\nANSWER:", text, "\n---")
            XCTAssertFalse(text.isEmpty)
        }
        await engine.stop()
    }
}

final class BuiltInMLXEngineTests: XCTestCase {
    /// Real MLX engine + MLX model folder, opt-in (AIM_TEST_MLX_ENGINE + AIM_TEST_MLX_MODEL).
    func testMLXFolderLoadsInTheMLXEngineAndAnswers() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let engineURL = env["AIM_TEST_MLX_ENGINE"], let folder = env["AIM_TEST_MLX_MODEL"] else { throw XCTSkip("opt-in") }
        XCTAssertTrue(BuiltInLocalEngine.isMLXFolder(URL(fileURLWithPath: folder)))
        let engine = BuiltInLocalEngine(executable: nil, mlxExecutable: URL(fileURLWithPath: engineURL))
        let started = Date.now
        let base = try await engine.load(URL(fileURLWithPath: folder), name: "qwen3-mlx", contextTokens: 0)
        print("MLX LOAD seconds:", Date.now.timeIntervalSince(started))
        var body: [String: Any] = ["model": "qwen3-mlx", "max_tokens": 120, "stream": false,
            "messages": [["role": "system", "content": LocalModelTuning.systemPrompt(mode: .chat)], ["role": "user", "content": "Combien font 12 fois 12 ?"]]]
        for (key, value) in LocalModelTuning.sampling(modelID: "qwen3-8b", thinking: false) { body[key] = value }
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        print("MLX ANSWER:", text.prefix(400))
        XCTAssertTrue(text.contains("144"), text)
        await engine.stop()
        let healthy = await BuiltInLocalEngine.isHealthy(base.deletingLastPathComponent().appendingPathComponent("health"))
        XCTAssertFalse(healthy)
    }
}

/// The real path of a first answer: AIM's request with the title instruction, streamed by a
/// built-in engine, gives a hidden title, clean text and engine timings. Opt-in:
/// AIM_TEST_MLX_ENGINE + AIM_TEST_MLX_MODEL, and/or AIM_TEST_LLAMA_SERVER + AIM_TEST_GGUF.
final class LocalFirstAnswerTests: XCTestCase {
    private func firstAnswer(engine: BuiltInLocalEngine, model: URL, name: String) async throws {
        let base = try await engine.load(model, name: name, contextTokens: 8_192)
        LocalModelEndpoint.baseURL = base
        let conversation = UUID()
        var text = "", title: String?, metrics: TurnMetrics?
        for try await event in ProviderChatService().events(provider: .local, modelID: name,
            messages: [ConversationMessage(conversationID: conversation, role: .user,
                content: "dit moi comment fonctionne la quantisation d'intelligence artificiel", sequence: 0)],
            apiKey: "local", mode: .chat, openAIReasoningEffort: OpenAIReasoningEffort.none, titleRequested: true) {
            switch event {
            case .requestAccepted, .routing: break
            case .text(let piece): text += piece
            case .title(let value): title = value
            case .metrics(let value): metrics = value
            case .webSearch, .connectionWaiting, .reasoning: break
            }
        }
        await engine.stop()
        print("TITLE:", title ?? "none")
        print("ANSWER:", text.prefix(300))
        if let metrics {
            print("METRICS engine=\(metrics.usage.engine ?? "?") prompt=\(metrics.usage.processedPromptTokens ?? -1) tok in \(metrics.usage.promptSeconds ?? -1)s",
                  "(\(Int(metrics.promptTokensPerSecond ?? 0)) tok/s) · output=\(metrics.outputTokens) tok at \(metrics.outputTokensPerSecond ?? 0) tok/s",
                  "· first words \(metrics.firstTokenSeconds ?? -1)s · total \(metrics.totalSeconds)s")
        }
        XCTAssertNotNil(title)
        XCTAssertFalse(text.contains("aim_title"))
        XCTAssertNotNil(metrics?.usage.promptSeconds)
        XCTAssertNotNil(metrics?.outputTokensPerSecond)
    }

    func testMLXFirstAnswer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let engine = env["AIM_TEST_MLX_ENGINE"], let model = env["AIM_TEST_MLX_MODEL"] else { throw XCTSkip("opt-in") }
        try await firstAnswer(engine: BuiltInLocalEngine(executable: nil, mlxExecutable: URL(fileURLWithPath: engine)),
                              model: URL(fileURLWithPath: model), name: "Qwen3-8B-4bit")
    }

    func testLlamaCppFirstAnswer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["AIM_TEST_LLAMA_SERVER"], let gguf = env["AIM_TEST_GGUF"] else { throw XCTSkip("opt-in") }
        try await firstAnswer(engine: BuiltInLocalEngine(executable: URL(fileURLWithPath: server)),
                              model: URL(fileURLWithPath: gguf), name: "Qwen3-8B-Q4_K_M")
    }
}

/// Real engines with a model's own settings. Opt-in like `LocalFirstAnswerTests`.
final class LocalSettingsRealTests: XCTestCase {
    private func answer(_ name: String, _ question: String) async throws -> (String, TurnMetrics?) {
        var text = "", metrics: TurnMetrics?
        for try await event in ProviderChatService().events(provider: .local, modelID: name,
            messages: [ConversationMessage(conversationID: UUID(), role: .user, content: question, sequence: 0)],
            apiKey: "local", mode: .chat, openAIReasoningEffort: OpenAIReasoningEffort.none) {
            if case .text(let piece) = event { text += piece }
            if case .metrics(let value) = event { metrics = value }
        }
        return (text, metrics)
    }

    private func run(engine: BuiltInLocalEngine, model: URL) async throws {
        do { try await scenario(engine: engine, model: model) } catch {
            await engine.stop()
            throw error
        }
    }

    private func scenario(engine: BuiltInLocalEngine, model: URL) async throws {
        let name = "AIMTest-Qwen3-8B"
        defer { LocalModelSettingsStore.shared.save(LocalModelSettings(), for: name) }
        LocalModelEndpoint.baseURL = try await engine.load(model, name: name, contextTokens: 16_384)
        let question = "dit moi comment fonctionne la quantisation d'intelligence artificiel essaye d'être le plus précis possible s'il te plaît"
        let (detailed, metrics) = try await answer(name, question)
        print("DETAILED output tokens:", metrics?.outputTokens ?? -1, "· characters:", detailed.count,
              "· tok/s:", metrics?.outputTokensPerSecond ?? -1, "· total s:", metrics?.totalSeconds ?? -1)
        print("DETAILED start:", detailed.prefix(240))
        XCTAssertGreaterThan(metrics?.outputTokens ?? 0, 400, "A request for precision gets a full answer")

        // Same model, other context: the engine restarts with it.
        let reloadStart = Date.now
        let reloaded = try await engine.load(model, name: name, contextTokens: 32_768)
        print("RELOAD seconds:", Date.now.timeIntervalSince(reloadStart))
        LocalModelEndpoint.baseURL = reloaded
        let configuration = await engine.loadedModelConfiguration
        XCTAssertEqual(configuration?.contextTokens, 32_768)

        // A fixed seed and temperature: the same answer twice.
        var settings = LocalModelSettings()
        settings.seed = 7
        settings.temperature = 0.9
        settings.maxResponseTokens = 60
        LocalModelSettingsStore.shared.save(settings, for: name)
        let first = try await answer(name, "Invente un nom de chat original.")
        let second = try await answer(name, "Invente un nom de chat original.")
        print("SEED answers:", first.0.prefix(80), "|", second.0.prefix(80))
        XCTAssertEqual(first.0, second.0)
        XCTAssertLessThanOrEqual(first.1?.outputTokens ?? 0, 61)
        await engine.stop()
    }

    func testMLXSettings() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let engine = env["AIM_TEST_MLX_ENGINE"], let model = env["AIM_TEST_MLX_MODEL"] else { throw XCTSkip("opt-in") }
        try await run(engine: BuiltInLocalEngine(executable: nil, mlxExecutable: URL(fileURLWithPath: engine)), model: URL(fileURLWithPath: model))
    }

    func testLlamaCppSettings() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["AIM_TEST_LLAMA_SERVER"], let gguf = env["AIM_TEST_GGUF"] else { throw XCTSkip("opt-in") }
        try await run(engine: BuiltInLocalEngine(executable: URL(fileURLWithPath: server)), model: URL(fileURLWithPath: gguf))
    }
}
