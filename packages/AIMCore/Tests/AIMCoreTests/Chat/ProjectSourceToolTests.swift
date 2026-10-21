import XCTest
@testable import AIMCore

private actor SourceToolFixture: ProjectSourceToolRuntime {
    var searches = 0, reads = 0
    let resultBytes: Int?
    let suspend: Bool
    init(resultBytes: Int? = nil, suspend: Bool = false) { self.resultBytes = resultBytes; self.suspend = suspend }
    func search(query: String) async throws -> String {
        searches += 1
        if suspend { try await Task.sleep(for: .seconds(30)) }
        return resultBytes.map { String(repeating: "x", count: $0) } ?? #"{"sourceID":"fixture-source","chunkID":"0","citation":"fixture-source#0","text":"synthetic excerpt"}"#
    }
    func read(sourceID: String, chunkID: String?) async throws -> String {
        guard sourceID == "fixture-source", chunkID == "0" else { throw ProjectSourceToolError.unavailable }
        reads += 1
        return #"{"sourceID":"fixture-source","chunkID":"0","citation":"fixture-source#0","text":"verified synthetic source"}"#
    }
    func counts() -> (Int,Int) { (searches,reads) }
}
private actor SourceAdmissionFixture {
    var count = 0
    let rejectAt: Int?
    init(rejectAt: Int? = nil) { self.rejectAt = rejectAt }
    func admit() throws { count += 1; if count == rejectAt { throw ProjectSourceToolError.unavailable } }
}

private final class SourceToolFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var bytes = request.httpBody
        if bytes == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            bytes = data
        }
        do {
            let body = try XCTUnwrap(bytes.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            let model = body["model"] as? String ?? ""
            let history = body["messages"] as? [[String: Any]] ?? []
            let anthropic = model.contains("anthropic")
            let results = history.filter { $0["role"] as? String == "tool" }.count + history.reduce(0) { count, message in
                count + ((message["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "tool_result" }.count ?? 0)
            }
            let tools = body["tools"] as? [[String: Any]] ?? []
            let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String ?? $0["name"] as? String }
            guard names.contains(ProjectSourceTools.searchName), names.contains(ProjectSourceTools.readName), !model.contains("combined") || names.contains("skill_view") else { throw ProjectSourceToolError.unavailable }
            let combined = model.contains("combined"), endless = model.contains("endless")
            let shouldCall = endless || results < (combined ? 3 : 2)
            let name = combined && results == 0 ? "skill_view" : (endless || results == (combined ? 1 : 0) ? ProjectSourceTools.searchName : ProjectSourceTools.readName)
            let args = name == "skill_view" ? ["name":"writing"] : name == ProjectSourceTools.searchName ? ["query":"fixture query"] : ["sourceID":"fixture-source","chunkID":"0"]
            let response: [String: Any]
            if anthropic {
                let content: [[String:Any]] = shouldCall ? [["type":"tool_use","id":"call-\(results)","name":name,"input":model.contains("malformed") ? ["query":42] : args]] : [["type":"text","text":"Answer [fixture-source#0]."]]
                response = ["content":content,"stop_reason":shouldCall ? "tool_use" : "end_turn","usage":["input_tokens":5,"output_tokens":2]]
            } else {
                let message: [String:Any] = shouldCall ? ["role":"assistant","content":"","tool_calls":[["id":"call-\(results)","type":"function","function":["name":name,"arguments":model.contains("malformed") ? "{invalid" : String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self)]]]] : ["role":"assistant","content":"Answer [fixture-source#0]."]
                response = ["choices":[["message":message,"finish_reason":shouldCall ? "tool_calls" : "stop"]],"usage":["prompt_tokens":5,"completion_tokens":2]]
            }
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:response));client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
}

final class ProjectSourceToolTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SourceToolFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    private static func collect(_ session: URLSession, model: String, runtime: SourceToolFixture, skills: [NativeSkill] = [], admission: (@Sendable () async throws -> Void)? = nil) async throws -> [NativeChatEvent] {
        var events: [NativeChatEvent] = []
        for try await event in NativeSkillChatTransport(session:session,networkAdmission:{}).stream(provider:model.contains("anthropic") ? .anthropic : .openRouter,modelID:model,messages:[.init(role:.user,text:"Read project source")],key:"fixture-key",maxOutputTokens:128,skills:skills,projectSources:runtime,admission:admission) { events.append(event) }
        return events
    }
    func testSearchReadRoundTripUsesRealToolsWithoutSkillsForBothWireFormats() async throws {
        for model in ["fixture/sources","fixture/anthropic-sources"] {
            let session = session(); defer { session.invalidateAndCancel() }
            let runtime = SourceToolFixture(), admission = SourceAdmissionFixture()
            let events = try await Self.collect(session,model:model,runtime:runtime,admission:{try await admission.admit()})
            XCTAssertEqual(events.map(\.text).joined(),"Answer [fixture-source#0].")
            XCTAssertTrue(events.last?.isComplete == true)
            let activities = events.compactMap(\.skillActivities).flatMap{$0}
            XCTAssertEqual(activities.map(\.name),[ProjectSourceTools.searchName,ProjectSourceTools.searchName,ProjectSourceTools.readName,ProjectSourceTools.readName])
            XCTAssertTrue(activities.contains { $0.detail?.contains("fixture-source#0") == true })
            let counts = await runtime.counts(); XCTAssertEqual(counts.0,1);XCTAssertEqual(counts.1,1)
        }
    }
    func testSkillsAndProjectSourcesShareOneTurn() async throws {
        let session = session();defer{session.invalidateAndCancel()}
        let skill = try NativeSkill(name:"writing",summary:"Writing guidance",origin:"fixture",files:["SKILL.md":"---\nname: writing\ndescription: Writing guidance\n---\n\nUse clear prose."],enabled:true)
        let events = try await Self.collect(session,model:"fixture/combined",runtime:SourceToolFixture(),skills:[skill])
        XCTAssertTrue(events.last?.isComplete == true)
        XCTAssertEqual(Set(events.compactMap(\.skillActivities).flatMap{$0}.map(\.name)),["skill_view",ProjectSourceTools.searchName,ProjectSourceTools.readName])
    }
    func testOwnershipAdmissionFailurePreventsSourceAccessAndFurtherModelRound() async throws {
        let session = session();defer{session.invalidateAndCancel()}
        let runtime = SourceToolFixture(), admission = SourceAdmissionFixture(rejectAt:2)
        do { _ = try await Self.collect(session,model:"fixture/sources",runtime:runtime,admission:{try await admission.admit()});XCTFail("Expected rejected captured owner") }
        catch { XCTAssertEqual(error as? ProjectSourceToolError,.unavailable) }
        let counts = await runtime.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0)
    }
    func testOversizedResultAndCumulativeToolReadsStopWithoutReplay() async throws {
        for size in [ProjectSourceTools.maximumResultBytes+1,ProjectSourceTools.maximumResultBytes] {
            let session = session();defer{session.invalidateAndCancel()}
            let runtime = SourceToolFixture(resultBytes:size)
            do { _ = try await Self.collect(session,model:"fixture/endless",runtime:runtime);XCTFail("Expected bounded source failure") }
            catch { XCTAssertEqual(error as? ProjectSourceToolError,.resultLimit) }
            let counts = await runtime.counts();XCTAssertLessThanOrEqual(counts.0,5)
        }
    }
    func testRepeatedSmallToolCallsHaveFiniteTurnLimit() async throws {
        let session = session();defer{session.invalidateAndCancel()}
        let runtime = SourceToolFixture()
        do { _ = try await Self.collect(session,model:"fixture/endless",runtime:runtime);XCTFail("Expected call ceiling") }
        catch { XCTAssertEqual(error as? ProjectSourceToolError,.callLimit) }
        let counts = await runtime.counts();XCTAssertEqual(counts.0,ProjectSourceTools.maximumCalls)
    }
    func testInvalidToolArgumentsNeverReachRuntime() async throws {
        let runtime = SourceToolFixture()
        for args in [["query":""],["query":"fixture","path":"outside"],["query":String(repeating:"x",count:4097)]] {
            do { _ = try await ProjectSourceTools.execute(name:ProjectSourceTools.searchName,arguments:args,runtime:runtime);XCTFail("Expected invalid arguments") }
            catch { XCTAssertEqual(error as? ProjectSourceToolError,.invalidArguments) }
        }
        let counts = await runtime.counts();XCTAssertEqual(counts.0,0)
    }
    func testLocalRuntimeCitationsAndProjectBoundaryUseOnlyEnabledStoreChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aim-source-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProjectSourceStore(directory: directory), project = UUID(), foreign = UUID()
        let own = try store.add(projectID: project, name: "fixture.txt", mimeType: "text/plain", text: "searchable synthetic fixture", original: nil)
        let other = try store.add(projectID: foreign, name: "foreign.txt", mimeType: "text/plain", text: "foreign synthetic fixture", original: nil)
        let runtime = LocalProjectSourceToolRuntime(store: store, projectID: project)
        let search = try await runtime.search(query: "synthetic")
        XCTAssertTrue(search.contains(own.id.uuidString.lowercased())); XCTAssertFalse(search.contains(other.id.uuidString.lowercased()))
        XCTAssertTrue(search.contains("untrustedSourceData")); XCTAssertLessThanOrEqual(search.utf8.count, ProjectSourceTools.maximumResultBytes)
        let read = try await runtime.read(sourceID: own.id.uuidString, chunkID: "0")
        XCTAssertTrue(read.contains("source:" + own.id.uuidString.lowercased() + "#1"))
        let readJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        let excerpts = try XCTUnwrap(readJSON["excerpts"] as? [[String: Any]])
        XCTAssertEqual(excerpts.first?["displayCitation"] as? String, own.name)
        XCTAssertEqual(excerpts.first?["sourceID"] as? String, own.id.uuidString.lowercased())
        XCTAssertEqual(excerpts.first?["chunkID"] as? String, "0")
        XCTAssertTrue(ProjectSourceTools.instructions.contains("displayCitation/name"))
        XCTAssertFalse(ProjectSourceTools.instructions.contains("Cite the exact source/chunk identifiers"))
        do { _ = try await runtime.read(sourceID: other.id.uuidString, chunkID: "0"); XCTFail("Foreign chunk must stay inaccessible") } catch { }
        try store.setEnabled(own.id, enabled: false)
        do { _ = try await runtime.read(sourceID: own.id.uuidString, chunkID: nil); XCTFail("Disabled chunk must stay inaccessible") } catch { }
    }
    func testAttachmentProjectProvenanceIsOptionalAndRoundTripsWithoutChangingLegacy() throws {
        let original = NativeChatAttachment(name: "fixture.txt", kind: .document, mimeType: "text/plain", text: "fixture")
        let old = try JSONDecoder().decode(NativeChatAttachment.self, from: JSONEncoder().encode(original))
        XCTAssertNil(old.projectSourceID)
        var marked = original; marked.projectSourceID = UUID()
        let decoded = try JSONDecoder().decode(NativeChatAttachment.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(decoded.projectSourceID, marked.projectSourceID)
        XCTAssertEqual(decoded.text, original.text)
    }
    func testMalformedWireToolArgumentsFailWithoutReadingSources() async throws {
        for model in ["fixture/malformed", "fixture/anthropic-malformed"] {
            let session = session(); defer { session.invalidateAndCancel() }
            let runtime = SourceToolFixture()
            do { _ = try await Self.collect(session, model: model, runtime: runtime); XCTFail("Malformed call cannot be treated as a completed answer") }
            catch { XCTAssertTrue(error is ChatServiceError) }
            let counts = await runtime.counts()
            XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        }
    }
    func testTransmissionHistoryDropsStaleProjectContextButPreservesManualFilesAndSavedOriginals() throws {
        let source = UUID(), legacySource = UUID(), deletedSource = UUID()
        let manual = NativeChatAttachment(name: "manual.txt", kind: .document, mimeType: "text/plain", text: "manual content")
        let marked = NativeChatAttachment(name: "source.txt", kind: .document, mimeType: "text/plain", text: "source excerpt", projectSourceID: source)
        let deleted = NativeChatAttachment(name: "deleted.txt", kind: .document, mimeType: "text/plain", text: "deleted excerpt", projectSourceID: deletedSource)
        let legacy = NativeChatAttachment(id: legacySource, name: "legacy.txt", kind: .document, mimeType: "text/plain", text: "legacy excerpt")
        let old = NativeChatMessage(role: .user, text: "Old question", attachments: [manual, marked, deleted, legacy])
        let current = NativeChatMessage(role: .user, text: "Current question", attachments: [marked, deleted])
        let saved = [old, current]
        let fallback = ProjectSourceRequestHistory.filtered(saved, knownSourceIDs: [source, legacySource], currentMessageID: current.id, allowedCurrentSourceIDs: [source])
        XCTAssertEqual(fallback[0].attachments, [manual])
        XCTAssertEqual(fallback[1].attachments, [marked])
        let tools = ProjectSourceRequestHistory.filtered(saved, knownSourceIDs: [source, legacySource], currentMessageID: nil, allowedCurrentSourceIDs: [])
        XCTAssertEqual(tools[0].attachments, [manual]); XCTAssertNil(tools[1].attachments)
        XCTAssertEqual(saved[0].attachments?.count, 4); XCTAssertEqual(saved[1].attachments?.count, 2)
        let empty = NativeChatMessage(role: .user, text: "", attachments: [deleted])
        let safe = ProjectSourceRequestHistory.filtered([empty], knownSourceIDs: [], currentMessageID: nil, allowedCurrentSourceIDs: [])
        XCTAssertNil(safe[0].attachments); XCTAssertFalse(safe[0].text.isEmpty)
        XCTAssertEqual(empty.attachments, [deleted])
    }
    func testCancellationDuringAsyncSourceReadDoesNotContinueTheTurn() async throws {
        let session = session();defer{session.invalidateAndCancel()}
        let runtime = SourceToolFixture(suspend:true)
        let task = Task { try await Self.collect(session,model:"fixture/sources",runtime:runtime) }
        for _ in 0..<1000 { if await runtime.counts().0 > 0 { break };try await Task.sleep(for:.milliseconds(2)) }
        let before = await runtime.counts();XCTAssertEqual(before.0,1)
        task.cancel()
        do { let events = try await task.value; XCTAssertFalse(events.contains { $0.isComplete }); XCTAssertTrue(task.isCancelled) } catch { XCTAssertTrue(error is CancellationError) }
        let after = await runtime.counts();XCTAssertEqual(after.1,0)
    }
}
