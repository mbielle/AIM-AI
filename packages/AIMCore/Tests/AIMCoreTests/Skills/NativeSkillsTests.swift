import XCTest
@testable import AIMCore

final class NativeSkillsTests: XCTestCase {
    private func skill(_ body: String = "Use clear prose.") throws -> NativeSkill {
        try NativeSkill(name: "writing", summary: "Writing guidance", origin: "test", files: ["SKILL.md": "---\nname: writing\ndescription: Writing guidance\n---\n\n" + body, "references/style.md": "A supporting note."], enabled: true)
    }
    func testFrontmatterAndDisableModelInvocation() throws {
        let text = "---\nname: writing\ndescription: 'Writing guidance'\ndisable-model-invocation: true\n---\n\nBody"
        let parsed = try XCTUnwrap(NativeSkillRules.parse(text))
        XCTAssertEqual(parsed.body, "Body"); XCTAssertFalse(parsed.modelInvocable)
        XCTAssertNil(NativeSkillRules.parse("---\nname: ../bad\ndescription: x\n---\nbody"))
    }
    func testPathsRejectTraversalHiddenSecretsAndAbsolute() {
        for path in ["../secret", "/etc/passwd", "scripts/../token", "a//b", "a\\b", ".env", "nested/credentials.json", "AuthKey.p8", "key.pem", "keys/id_rsa"] { XCTAssertFalse(NativeSkillRules.safePath(path), path) }
        XCTAssertTrue(NativeSkillRules.safePath("scripts/example.py"))
    }
    func testReadonlyRuntimeNeverExecutesFilesOrUnknownTools() throws {
        let runtime = NativeSkillToolRuntime(skills: [try skill()])
        XCTAssertTrue(try runtime.execute(name: "skill_view", arguments: ["name": "writing"]).contains("Use clear prose."))
        XCTAssertEqual(try runtime.execute(name: "skill_read_file", arguments: ["name": "writing", "path": "references/style.md"]), "A supporting note.")
        XCTAssertThrowsError(try runtime.execute(name: "run_command", arguments: ["name": "writing", "path": "references/style.md"]))
        XCTAssertThrowsError(try runtime.execute(name: "skill_read_file", arguments: ["name": "writing", "path": "../x"]))
        var off = try skill(); off.enabled = false
        XCTAssertTrue(NativeSkillToolRuntime(skills: [off]).catalogInstructions.isEmpty)
    }
    func testAccountIsolationConflictAndVersionPreservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NativeSkillsRepository(root: directory), a = UUID(), b = UUID()
        try await repository.install(skill(), account: a)
        let empty = try await repository.all(account: b); XCTAssertTrue(empty.isEmpty)
        do { try await repository.install(skill("New guidance"), account: a); XCTFail("Expected conflict") } catch { XCTAssertEqual(error as? NativeSkillError, .conflict) }
        try await repository.install(skill("New guidance"), account: a, replace: true)
        let versions = try await repository.versions("writing", account: a); XCTAssertEqual(versions.count, 1)
        XCTAssertTrue(versions[0].instructions.contains("Use clear prose."))
        try await repository.setEnabled("writing", enabled: false, account: a)
        let current = try await repository.all(account: a); XCTAssertFalse(current[0].enabled)
        try await repository.remove("writing", account: a)
        let removed = try await repository.all(account: a); XCTAssertTrue(removed.isEmpty)
    }
    func testImportRequiresSkillsSectionAndRevalidatesCodablePayload() throws {
        XCTAssertThrowsError(try NativeSkillImportContract.manifests(.object(["appearance": .string("system")])))
        var malformed = try skill(); malformed.files["../secret"] = "secret"
        let value = try JSONDecoder().decode(RemoteJSONValue.self, from: JSONEncoder().encode(malformed))
        XCTAssertThrowsError(try NativeSkillImportContract.skill(.object(["section": .string("skills"), "skill": value])))
        XCTAssertThrowsError(try NativeSkillImportContract.request(name: "../x"))
    }
    func testCatalogFiltersUntrustedRepositoryPathsAndDuplicates() throws {
        let data = Data(#"{"skills":[{"source":"anthropics/skills","skillId":"pdf","name":"pdf"},{"source":"anthropics/skills","skillId":"pdf","name":"again"},{"source":"../secrets","skillId":"bad","name":"bad"}]}"#.utf8)
        XCTAssertEqual(try NativeSkillCatalogService.decode(data).map(\.name), ["pdf"])
    }
    func testLegacyMessagesDecodeWithoutSkillEvents() throws {
        let original = NativeChatMessage(role: .user, text: "Hello")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]); object.removeValue(forKey: "skillActivities")
        let decoded = try JSONDecoder().decode(NativeChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.skillActivities)
    }
}

private final class SkillsLoopFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }; data = bytes
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let history = body["messages"] as? [[String: Any]] ?? []
        if body["model"] as? String == "fixture/vision-skills" {
            let content = history.first(where: { $0["role"] as? String == "user" })?["content"] as? [[String: Any]]
            if content?.contains(where: { $0["type"] as? String == "image_url" && ($0["image_url"] as? [String: String])?["url"]?.hasPrefix("data:image/png;base64,") == true }) != true {
                client?.urlProtocol(self, didFailWithError: NSError(domain: "MissingImage", code: 1)); return
            }
        }
        let hasResult = history.contains { $0["role"] as? String == "tool" }
        let validResult = history.contains { ($0["content"] as? String ?? "").contains("Use clear prose.") }
        let text: String
        if body["model"] as? String == "fixture/interrupted-skills" {
            text = #"{"choices":[{"message":{"role":"assistant","content":"Partial response"},"finish_reason":"length"}],"usage":{"prompt_tokens":7,"completion_tokens":9}}"#
        } else if hasResult && validResult {
            text = #"{"choices":[{"message":{"role":"assistant","content":"Clear answer."},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":4}}"#
        } else {
            text = #"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call-1","type":"function","function":{"name":"skill_view","arguments":"{\"name\":\"writing\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension NativeSkillsTests {
    func testReadonlyToolRoundTripAndCumulativeUsage() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SkillsLoopFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var events: [NativeChatEvent] = []
        for try await event in NativeSkillChatTransport(session: session, networkAdmission: {}).stream(provider: .openRouter, modelID: "fixture/skills", messages: [.init(role: .user, text: "Write clearly")], key: "fixture-key", skills: [try skill()]) { events.append(event) }
        let activities = events.compactMap(\.skillActivities).flatMap { $0 }
        XCTAssertEqual(activities.map(\.name), ["skill_view", "skill_view"])
        XCTAssertEqual(activities.map(\.running), [true, false])
        XCTAssertEqual(Set(activities.map(\.id)).count, 1)
        XCTAssertFalse(activities.last?.isError ?? true)
        XCTAssertEqual(events.map(\.text).joined(), "Clear answer.")
        XCTAssertEqual(events.compactMap(\.usage).last?.inputTokens, 18)
        XCTAssertEqual(events.compactMap(\.usage).last?.outputTokens, 6)
        XCTAssertTrue(events.last?.isComplete == true)
    }
    func testImageSurvivesReadOnlySkillLoop() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SkillsLoopFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        let message = NativeChatMessage(role: .user, text: "Inspect clearly", attachments: [.init(name: "pixel.png", kind: .image, mimeType: "image/png", data: png)])
        var answer = "", loaded = false
        for try await event in NativeSkillChatTransport(session: session, networkAdmission: {}).stream(provider: .openRouter, modelID: "fixture/vision-skills", messages: [message], key: "fixture-key", skills: [try skill()]) {
            answer += event.text; loaded = loaded || !(event.skillActivities ?? []).isEmpty
        }
        XCTAssertEqual(answer, "Clear answer."); XCTAssertTrue(loaded)
    }
    func testInterruptedRoundPreservesTextAndUsageWithoutReplay() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SkillsLoopFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var events: [NativeChatEvent] = []
        do {
            for try await event in NativeSkillChatTransport(session: session, networkAdmission: {}).stream(provider: .openRouter, modelID: "fixture/interrupted-skills", messages: [.init(role: .user, text: "Test")], key: "fixture-key", skills: [try skill()]) { events.append(event) }
            XCTFail("Expected interrupted response")
        } catch { XCTAssertEqual(error as? NativeSkillError, .incomplete) }
        XCTAssertEqual(events.map(\.text).joined(), "Partial response")
        XCTAssertEqual(events.compactMap(\.usage).last?.outputTokens, 9)
        XCTAssertFalse(events.contains { $0.isComplete })
    }
    func testCredentialContentRejectedAndExternalVersionRecomputed() throws {
        var files = try skill().files
        files["references/key.md"] = "-----BEGIN PRIVATE KEY-----\nsecret"
        XCTAssertThrowsError(try NativeSkill(name: "writing", summary: "Guidance", origin: "x", files: files))
        let valid = try skill()
        let changedVersion = try NativeSkill(name: valid.name, summary: valid.summary, origin: valid.origin, version: "../unsafe", files: valid.files)
        XCTAssertEqual(changedVersion.version, valid.version)
    }
}
