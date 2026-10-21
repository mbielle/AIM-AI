import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import AppKit
import CryptoKit
import XCTest
@testable import AIMAgentRuntime

private final class ExternalMediaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func append(_ data: Data) { lock.lock(); bodies.append(data); lock.unlock() }
    func reset() { lock.lock(); bodies = []; lock.unlock() }
    var values: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}
private final class ExternalMediaProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = ExternalMediaRecorder()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        Self.recorder.append(body)
        let response = #"{"id":"fixture-receipt","choices":[{"message":{"role":"assistant","content":"Observed fixture"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"cost":0.001}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StreamingProviderProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        for piece in [#"data: {"choices":[{"delta":{"content":"Bon"}}]}"#, #"data: {"choices":[{"delta":{"content":"jour"}}]}"#,
                      #"data: {"choices":[],"usage":{"cost":0.000489}}"#, "data: [DONE]"] {
            client?.urlProtocol(self, didLoad: Data((piece + "\n\n").utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor StreamRecorder {
    var pieces: [Data] = []
    func add(_ data: Data) { pieces.append(data) }
}

final class Round23ExternalMediaTests: XCTestCase {
    private func image() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 24))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    }
    private func fixture(_ engine: AgentEngineID, network: AnyClass = ExternalMediaProtocol.self) async throws -> (NativeExternalProviderDispatcher, AgentRequest, ExternalFinanceGrant, SQLiteGlobalSpendLedger) {
        let db = try AIMDatabase(inMemory: true), account = UUID(), owner = UUID()
        let conversation = Conversation(title: "Visual fixture", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        var request = AgentRequest(conversationID: conversation.id, text: "Inspect", modelID: "fixture/vision", mode: .agent, workspacePath: "/tmp", provider: .openRouter, modelSupportsImages: true)
        request.externalEngineID = engine
        let repository = SQLiteAgentExecutionRepository(database: db); try await repository.installOwner(owner)
        var execution = try await repository.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, accountID: account, request: JSONEncoder().encode(request)), owner: owner)
        execution = try await repository.transition(execution.id, owner: owner, expectedRevision: execution.revision, to: .running)
        let context = RuntimeExecutionContext(repository: repository, executionID: execution.id, owner: owner)
        try await context.checkpointing.prepare(ExecutionCheckpoint(conversation: ModelConversationCheckpoint(codec: "aim-external-v1", provider: .openRouter, modelID: request.modelID, transcript: Data("[]".utf8), pendingIDs: [], seenIDs: [], finished: false, usage: TokenUsage()), turn: ModelToolTurn(text: "", calls: []), effects: [], ordinal: 0, seenCallIDs: []))
        let ledger = SQLiteGlobalSpendLedger(database: db)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [network]
        let dispatcher = NativeExternalProviderDispatcher(context: context, credentials: { "fixture-key" }, meter: BillableRequestMeter(ledger: ledger), accountID: { account }, session: URLSession(configuration: config))
        let grant = ExternalFinanceGrant(id: UUID(), runID: UUID(), accountID: account, executionID: execution.id, ownerGeneration: owner, conversationID: conversation.id, engineIdentity: engine.rawValue, engineVersion: "fixture", executableSHA256: String(repeating: "a", count: 64), provider: "openrouter", modelID: request.modelID, allowedFeatures: ["external_model"], expiresAt: .now.addingTimeInterval(600))
        return (dispatcher, request, grant, ledger)
    }
    private func wire(_ grant: ExternalFinanceGrant, tools: Bool = false) throws -> ExternalProviderRequest {
        var messages: [[String: Any]] = [["role": "user", "content": "Inspect source"]]
        if tools {
            messages += [["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call-1", "type": "function", "function": ["name": "read_file", "arguments": "{}"]]]], ["role": "tool", "tool_call_id": "call-1", "content": "Fixture output"]]
        }
        let body = try JSONSerialization.data(withJSONObject: ["model": grant.modelID, "messages": messages, "stream": false])
        return .init(requestID: UUID(), grantID: grant.id, body: body, sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
    }
    func testBothEnginesKeepVideoFramesAcrossToolRoundsAndDoNotRepeatARequest() async throws {
        for engine in [AgentEngineID.hermes, .openClaw] {
            ExternalMediaProtocol.recorder.reset()
            let (dispatcher, request, grant, ledger) = try await fixture(engine)
            let jpeg = try image(), videoID = UUID()
            let video = PreparedVideoAttachment(id: videoID, name: "scene.mov", duration: 10, rangeStart: 0, rangeEnd: 10, mode: .detailed, originDeviceID: "iphone", originDeviceName: "Fixture iPhone", frames: (0..<12).map { .init(seconds: Double($0) * 0.8, jpeg: jpeg) }, transcript: "Local transcript", audioNotice: nil)
            let input = TextAttachment(id: videoID, name: video.name, content: video.context, video: video)
            try await dispatcher.setVisualContext([ConversationMessage(conversationID: request.conversationID, role: .user, content: "", sequence: 0, attachments: [input])], supportsImages: true)
            let first = try wire(grant)
            _ = try await dispatcher.handler(first, request, grant, ExternalCallContext())
            _ = try await dispatcher.handler(wire(grant, tools: true), request, grant, ExternalCallContext())
            do { _ = try await dispatcher.handler(first, request, grant, ExternalCallContext()); XCTFail("Duplicate provider attempt repeated") } catch {}
            XCTAssertEqual(ExternalMediaProtocol.recorder.values.count, 2, engine.rawValue)
            for data in ExternalMediaProtocol.recorder.values {
                let body = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
                XCTAssertEqual(body.components(separatedBy: jpeg.base64EncodedString()).count - 1, 12)
                XCTAssertTrue(body.contains("Local transcript"))
            }
            let policy = try await ledger.policy(); XCTAssertFalse(policy.enabled)
            await dispatcher.close()
        }
    }
    func testStreamedAnswerReachesTheEngineWhileItArrivesWithAnExactReceipt() async throws {
        let (dispatcher, request, grant, ledger) = try await fixture(.hermes, network: StreamingProviderProtocol.self)
        let recorder = StreamRecorder()
        let body = try JSONSerialization.data(withJSONObject: ["model": request.modelID, "stream": true, "messages": [["role": "user", "content": "Hi"]]])
        let wire = ExternalProviderRequest(requestID: UUID(), grantID: grant.id, body: body,
            sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
        let response = try await dispatcher.handler(wire, request, grant, ExternalCallContext(stream: { status, type, bytes in
            XCTAssertEqual(status, 200); XCTAssertTrue(type.contains("event-stream")); await recorder.add(bytes)
        }))
        let pieces = await recorder.pieces
        XCTAssertFalse(pieces.isEmpty, "the answer was passed on while it arrived")
        XCTAssertEqual(Data(pieces.joined()), response.body, "the streamed pieces are the whole answer")
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.confirmedUSD, "0.000489", "the streamed receipt keeps the exact cost")
        await dispatcher.close()
    }

    func testEngineSubagentsAreShownAsChildrenWithTheirJournal() async throws {
        let db = try AIMDatabase(inMemory: true), owner = UUID()
        let conversation = Conversation(title: "Delegation", mode: .agent)
        try await SQLiteConversationRepository(database: db).save(conversation)
        var request = AgentRequest(conversationID: conversation.id, text: "Delegate", modelID: "fixture/model", mode: .agent, workspacePath: "/tmp", provider: .openRouter)
        request.externalEngineID = .hermes
        let repository = SQLiteAgentExecutionRepository(database: db); try await repository.installOwner(owner)
        var execution = try await repository.admit(AgentExecution(commandID: UUID(), conversationID: conversation.id, accountID: UUID(), request: JSONEncoder().encode(request)), owner: owner)
        execution = try await repository.transition(execution.id, owner: owner, expectedRevision: execution.revision, to: .running)
        let tracker = ExternalSubagentTracker(context: RuntimeExecutionContext(repository: repository, executionID: execution.id, owner: owner), request: request)
        await tracker.started("child-session-1", title: "Multiply", prompt: "Find 6 x 7.")
        await tracker.journal("child-session-1", .text, text: "Child report: ", streamed: true)
        await tracker.journal("child-session-1", .toolStarted, text: "{}", callID: "c1", name: "web_search")
        await tracker.finished("child-session-1", failed: false, result: "42")
        // A sub-agent the engine never closed is closed with the task.
        await tracker.started("child-session-2", title: nil, prompt: "Second")
        await tracker.closeAll(cancelled: true)
        let children = try await repository.children(parentExecutionID: execution.id)
        XCTAssertEqual(children.map(\.title), ["Multiply", "Second"])
        XCTAssertEqual(children.map(\.state), [.accepted, .cancelled])
        XCTAssertEqual(children.first?.result, "42")
        XCTAssertEqual(children.first?.modelID, "fixture/model", "the person's model is shown")
        let journal = try await repository.latestEvents(execution.id, kind: SubagentJournalEntry.eventKind, limit: 10)
        XCTAssertEqual(journal.count, 2)
        // Same engine key, same child: no duplicate row.
        let again = await tracker.started("child-session-1", title: "Multiply", prompt: "Find 6 x 7.")
        XCTAssertEqual(again, children.first?.id)
    }

    func testEngineToolsAreForwardedAsOfferedAndHermesDelegationIsAccepted() async throws {
        ExternalMediaProtocol.recorder.reset()
        let (dispatcher, request, grant, _) = try await fixture(.hermes)
        let aimTool: [String: Any] = ["type": "function", "function": ["name": "read_file", "description": "AIM read", "parameters": ["type": "object"]]]
        await dispatcher.setToolSchemas(try JSONSerialization.data(withJSONObject: [aimTool]))
        await dispatcher.setEngineToolNames(["delegate_task"])
        func send(_ tools: [[String: Any]]?) async throws -> [String: Any] {
            var object: [String: Any] = ["model": request.modelID, "messages": [["role": "user", "content": "Go"]]]
            if let tools { object["tools"] = tools }
            let body = try JSONSerialization.data(withJSONObject: object)
            _ = try await dispatcher.handler(ExternalProviderRequest(requestID: UUID(), grantID: grant.id, body: body,
                sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()), request, grant, ExternalCallContext())
            return try XCTUnwrap(ExternalMediaProtocol.recorder.values.last.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        }
        let delegate: [String: Any] = ["type": "function", "function": ["name": "delegate_task", "description": "Hermes", "parameters": ["type": "object"]]]
        let withDelegation = try await send([["type": "function", "function": ["name": "read_file", "description": "engine text"]], delegate])
        let names = (withDelegation["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["read_file", "delegate_task"])
        let readFile = (withDelegation["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        XCTAssertEqual(readFile?["description"] as? String, "AIM read", "AIM's own schema replaces the engine's copy")
        // A summary call offers no tools: none are added.
        let summary = try await send(nil)
        XCTAssertNil(summary["tools"])
        do { _ = try await send([["type": "function", "function": ["name": "terminal"]]]); XCTFail("Unknown engine tool accepted") } catch {}
        await dispatcher.close()
    }

    func testToolScreenshotReachesTheMainAgentsNextRequestOnly() async throws {
        ExternalMediaProtocol.recorder.reset()
        let (dispatcher, request, grant, _) = try await fixture(.openClaw)
        let png = try image()
        func send(origin: String?) async throws -> [[String: Any]] {
            let body = try JSONSerialization.data(withJSONObject: ["model": request.modelID, "messages": [["role": "user", "content": "Look"]]])
            _ = try await dispatcher.handler(ExternalProviderRequest(requestID: UUID(), grantID: grant.id, body: body,
                sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()), request, grant, ExternalCallContext(origin: origin))
            let sent = try XCTUnwrap(ExternalMediaProtocol.recorder.values.last.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            return try XCTUnwrap(sent["messages"] as? [[String: Any]])
        }
        await dispatcher.attachScreenshot(png, tool: "bg_observe_window")
        // A sub-agent's concurrent request does not take the main agent's screenshot.
        let child = try await send(origin: "child-1")
        XCTAssertEqual(child.count, 1)
        let main = try await send(origin: nil)
        XCTAssertEqual(main.count, 2)
        let parts = try XCTUnwrap(main.last?["content"] as? [[String: Any]])
        XCTAssertTrue((parts.first?["text"] as? String ?? "").contains("bg_observe_window"))
        XCTAssertEqual((parts.last?["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64," + png.base64EncodedString())
        // Sent once: the following request carries no stale image.
        let after = try await send(origin: nil)
        XCTAssertEqual(after.count, 1)
        await dispatcher.close()
    }

    func testEngineSubagentsCannotUseScreenPlanOrQuestionTools() {
        for name in ["desktop_click", "bg_observe_window", "browser_snapshot", "run_applescript", "open_url", "update_plan", "ask_user"] {
            XCTAssertTrue(RuntimeExternalTools.parentOnly(name), name)
        }
        for name in ["read_file", "web_search", "run_command", "search_memory"] { XCTAssertFalse(RuntimeExternalTools.parentOnly(name), name) }
        XCTAssertFalse(ExternalToolHosting.excluded.contains("update_plan"), "The main engine keeps a plan in AIM's panel")
        XCTAssertFalse(ExternalToolHosting.excluded.contains("ask_user"))
        XCTAssertTrue(ExternalToolHosting.excluded.contains("delegate_task"))
    }

    func testEngineModelChoiceIsReplacedByThePersonsModel() async throws {
        ExternalMediaProtocol.recorder.reset()
        let (dispatcher, request, grant, _) = try await fixture(.hermes)
        // An auxiliary call (summary, sub-agent) asking for another model runs on the chosen one.
        let body = try JSONSerialization.data(withJSONObject: ["model": "openai/gpt-cheap", "messages": [["role": "user", "content": "Summarize"]]])
        let wire = ExternalProviderRequest(requestID: UUID(), grantID: grant.id, body: body,
            sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
        _ = try await dispatcher.handler(wire, request, grant, ExternalCallContext())
        let sent = try XCTUnwrap(ExternalMediaProtocol.recorder.values.first.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(sent["model"] as? String, request.modelID)
        await dispatcher.close()
    }

    func testUnavailableVisionRefusesBeforeProviderSend() async throws {
        ExternalMediaProtocol.recorder.reset()
        let (dispatcher, request, _, _) = try await fixture(.hermes)
        let attachment = try ImageAttachment(name: "source.jpg", mimeType: "image/jpeg", data: image())
        do { try await dispatcher.setVisualContext([ConversationMessage(conversationID: request.conversationID, role: .user, content: "", sequence: 0, images: [attachment])], supportsImages: false); XCTFail("Images silently dropped") } catch {}
        XCTAssertTrue(ExternalMediaProtocol.recorder.values.isEmpty)
        await dispatcher.close()
    }
}
