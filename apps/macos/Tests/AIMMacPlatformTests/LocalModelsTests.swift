import AIMApplication
@testable import AIMMacPlatform
import XCTest

/// Serves fake Hugging Face file bytes, honouring Range like the real CDN.
private final class HubFileFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var failAfterFirstChunk = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let name = request.url!.lastPathComponent
        guard let body = Self.files[name] else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        var start = 0
        if let range = request.value(forHTTPHeaderField: "Range"), let value = Int(range.dropFirst(6).dropLast()) { start = value }
        let slice = body.subdata(in: start..<body.count)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: start > 0 ? 206 : 200, httpVersion: nil,
            headerFields: ["Content-Length": String(slice.count)])!, cacheStoragePolicy: .notAllowed)
        if Self.failAfterFirstChunk {
            client?.urlProtocol(self, didLoad: slice.prefix(slice.count / 2))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LocalModelsTests: XCTestCase {
    func testSearchDetailFilesAndFit() async throws {
        let responses: [String: String] = [
            "/api/models": #"[{"id":"mlx-community/Tiny-4bit","downloads":1200,"likes":3,"tags":["mlx","tool-use"]}]"#,
            "/api/models/mlx-community/Tiny-4bit": #"{"sha":"abc123","siblings":[{"rfilename":"config.json","size":10},{"rfilename":"model.safetensors","size":2000},{"rfilename":"README.md","size":5},{"rfilename":"../evil","size":1}]}"#
        ]
        let fetch: HuggingFaceModelHub.Fetch = { request in
            let body = responses[request.url!.path] ?? "[]"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let results = try await HuggingFaceModelHub.search("tiny", format: .mlx, fetch: fetch)
        XCTAssertEqual(results.first?.id, "mlx-community/Tiny-4bit")
        XCTAssertTrue(results.first?.supportsTools == true)
        let detail = try await HuggingFaceModelHub.detail("mlx-community/Tiny-4bit", fetch: fetch)
        XCTAssertEqual(detail.files.map(\.path), ["config.json", "model.safetensors", "README.md"], "unsafe paths are dropped")
        XCTAssertEqual(HuggingFaceModelHub.files(for: detail, format: .mlx).map(\.path), ["config.json", "model.safetensors"])
        let gb: Int64 = 1_000_000_000
        XCTAssertEqual(HuggingFaceModelHub.fit(weightsBytes: 1 * gb, memoryBytes: 16 * UInt64(gb)), .comfortable)
        XCTAssertEqual(HuggingFaceModelHub.fit(weightsBytes: 8 * gb, memoryBytes: 16 * UInt64(gb)), .tight)
        XCTAssertEqual(HuggingFaceModelHub.fit(weightsBytes: 20 * gb, memoryBytes: 16 * UInt64(gb)), .tooLarge)
        XCTAssertFalse(HuggingFaceModelHub.isValidRepo("../x"))
    }

    func testDownloadResumesAndCompletesTheCacheSnapshot() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("aim-hf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let weights = Data((0..<300_000).map { UInt8($0 % 251) })
        HubFileFixture.files = ["config.json": Data(#"{"model_type":"tiny"}"#.utf8), "model.safetensors": weights]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubFileFixture.self]
        let session = URLSession(configuration: configuration)
        let detail = HuggingFaceModelHub.ModelDetail(id: "org/tiny", sha: "sha1", files: [
            .init(path: "config.json", size: 21), .init(path: "model.safetensors", size: Int64(weights.count))], gated: false)

        HubFileFixture.failAfterFirstChunk = true
        do {
            _ = try await HuggingFaceModelHub.download(detail, files: detail.files, format: .mlx, cache: cache, session: session)
            XCTFail("the first attempt should fail mid-file")
        } catch {}
        XCTAssertTrue(HuggingFaceModelHub.installedMLXModels(cache: cache).isEmpty, "an incomplete snapshot is not listed")

        HubFileFixture.failAfterFirstChunk = false
        let folder = try await HuggingFaceModelHub.download(detail, files: detail.files, format: .mlx, cache: cache, session: session)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("model.safetensors")), weights, "resumed bytes join correctly")
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent("models--org--tiny/refs/main"), encoding: .utf8), "sha1")
        XCTAssertEqual(HuggingFaceModelHub.installedMLXModels(cache: cache).map(\.repo), ["org/tiny"])
    }

    /// Real end-to-end check against a running local server (oMLX/LM Studio) — free, offline.
    func testRealLocalModelToolCall() async throws {
        guard let raw = ProcessInfo.processInfo.environment["AIM_TEST_LOCAL_BASE_URL"], let base = URL(string: raw),
              let model = ProcessInfo.processInfo.environment["AIM_TEST_LOCAL_MODEL"] else {
            throw XCTSkip("set AIM_TEST_LOCAL_BASE_URL and AIM_TEST_LOCAL_MODEL to a running local server")
        }
        let previous = LocalModelEndpoint.baseURL
        LocalModelEndpoint.baseURL = base
        defer { LocalModelEndpoint.baseURL = previous }
        let listed = try await ProviderChatService().models(provider: .local, apiKey: nil)
        XCTAssertTrue(listed.contains { $0.id == model }, "\(listed.map(\.id))")
        let conversation = try ProviderToolConversation(provider: .local, modelID: model,
            messages: [ConversationMessage(conversationID: UUID(), role: .user, content: "Call list_dir on the path /tmp, then say done. /no_think", sequence: 0)],
            apiKey: "local", tools: [ModelToolDefinition(name: "list_dir", description: "List a directory", requiredArguments: ["path"])],
            meter: BillableRequestMeter())
        let first = try await conversation.next(outputs: [])
        let call = try XCTUnwrap(first.calls.first)
        XCTAssertEqual(call.name, "list_dir")
        let second = try await conversation.next(outputs: [ModelToolOutput(id: call.id, content: "a.txt\nb.txt", isError: false)])
        // Protocol-level: the tool result round-trips; a small model may call the tool again.
        XCTAssertTrue(second.calls.allSatisfy { $0.name == "list_dir" })
        XCTAssertTrue(!second.text.isEmpty || !second.calls.isEmpty)
        print("local model second turn:", second.calls.isEmpty ? "answered: \(second.text.prefix(200))" : "called the tool again")
    }

    func testRealHuggingFaceSearch() async throws {
        guard ProcessInfo.processInfo.environment["AIM_TEST_NETWORK"] == "1" else { throw XCTSkip("set AIM_TEST_NETWORK=1") }
        let results = try await HuggingFaceModelHub.search("Qwen3 1.7B", format: .mlx)
        let first = try XCTUnwrap(results.first { $0.id.hasPrefix("mlx-community/") })
        let detail = try await HuggingFaceModelHub.detail(first.id)
        XCTAssertTrue(HuggingFaceModelHub.files(for: detail, format: .mlx).contains { $0.path.hasSuffix(".safetensors") })
    }
}
