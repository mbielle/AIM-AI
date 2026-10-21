import XCTest
@testable import AIMCore

private actor DirectFixtureRPC: DirectRemoteRPCTransport {
    nonisolated let events = AsyncStream<RemoteEvent> { $0.finish() }
    var calls: [(String, RemoteJSONValue, UUID)] = []
    var replies: [String: RemoteJSONValue]
    var failNext = false
    func failOnce() { failNext = true }
    init(_ replies: [String: RemoteJSONValue]) { self.replies = replies }
    func connectionState() -> DirectRemoteConnectionState { .connected(.lan) }
    func request(operation: String, payload: RemoteJSONValue, id: UUID) throws -> RemoteJSONValue {
        calls.append((operation, payload, id))
        if failNext { failNext = false; throw DirectRemoteError.unavailable("disconnected") }
        guard let reply = replies[operation] else { throw DirectRemoteError.unavailable("fixture_missing") }; return reply
    }
}

final class DirectRemoteClientServiceTests: XCTestCase {
    func testSnapshotRoundTripPreservesReadableTimelineAndScopeWithoutCloudKeys() async throws {
        let machine = UUID(), session = UUID().uuidString.lowercased()
        let snapshot = DirectRemoteOverviewSnapshot(machineID: machine, name: "Fixture Mac", appVersion: "1",
            capabilities: .init(models: [], features: ["chat": true]), sessions: [
                .init(id: session, mode: .chat, title: "Local only", status: "running", messageCount: 1, updatedAt: Date(timeIntervalSince1970: 50))
            ])
        let text = String(repeating: "large answer ", count: 10_000)
        let message = DirectRemoteMessageSnapshot(id: UUID().uuidString, sequence: 0, role: .assistant,
            content: text, timeline: [.object(["type": .string("text"), "text": .string(text)])])
        let rpc = DirectFixtureRPC(["overview": try DirectRemoteSnapshotCodec.value(snapshot),
            "messages": try DirectRemoteSnapshotCodec.value([message]), "health": .object(["authenticated": .bool(true)])])
        let service = DirectRemoteClientService { rpc }
        let overview = try await service.loadOverview()
        XCTAssertEqual(overview.machines.first?.id, machine.uuidString.lowercased())
        XCTAssertNil(overview.machines.first?.keyVersion)
        XCTAssertEqual(overview.sessions.first?.readState, .readable)
        XCTAssertEqual(overview.sessions.first?.id, session)
        let messages = try await service.loadMessages(sessionID: session, machineID: machine.uuidString)
        XCTAssertEqual(messages.first?.content, text)
        XCTAssertEqual(messages.first?.timeline, message.timeline)
        XCTAssertEqual(messages.first?.sessionID, session)
        let authenticated = try await service.isAuthenticatedDirectSession()
        XCTAssertTrue(authenticated)
        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.0), ["overview", "messages", "health"])
    }
    func testStableCommandIDIsRetainedAndInvalidIdentityNeverSent() async throws {
        let rpc = DirectFixtureRPC(["command": .null])
        let service = DirectRemoteClientService { rpc }
        let id = UUID(), payload = RemoteJSONValue.object(["text": .string("hello"), "client_request_id": .string(id.uuidString)])
        _ = try await service.sendCommand(machineID: "mac", sessionID: "session", type: .userMessage, payload: payload)
        _ = try await service.sendCommand(machineID: "mac", sessionID: "session", type: .userMessage, payload: payload)
        do {
            _ = try await service.sendCommand(machineID: "mac", sessionID: "session", type: .userMessage,
                payload: .object(["client_request_id": .string("bad")]))
            XCTFail("Invalid operation identity must fail before dispatch")
        } catch { XCTAssertEqual(error as? DirectRemoteError, .invalidPacket) }
        let calls = await rpc.calls
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls.map(\.2), [id, id])
    }
    func testHealthRequiresAffirmativeEncryptedEndpointReply() async throws {
        let rpc = DirectFixtureRPC(["health": .object([:])])
        let service = DirectRemoteClientService { rpc }
        let result = try await service.isAuthenticatedDirectSession()
        XCTAssertFalse(result)
        do { try await service.checkBridge(machineID: "mac"); XCTFail("Empty reply must not authorize a device") }
        catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
    }
    func testContinuousGoalIsRejectedBeforeTransportInsteadOfDowngradingIt() async throws {
        let rpc = DirectFixtureRPC([:]), service = DirectRemoteClientService { rpc }
        do {
            _ = try await service.createSession(.init(machineID: "mac", mode: .agent, modelID: "fixture", text: "goal", goal: .init(continuous: true)))
            XCTFail("Cannot silently drop unsupported goal")
        } catch { }
        let calls = await rpc.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testUploadUsesBoundedChunksAndWaitsForVerifiedReadyReply() async throws {
        let rpc = DirectFixtureRPC(["upload": .object(["ready": .bool(true)])]), service = DirectRemoteClientService { rpc }
        let data = Data(repeating: 42, count: 600_000), session = UUID().uuidString
        let reference = try await service.uploadAttachment(data: data, name: "fixture.txt", mimeType: "text/plain", machineID: "mac", sessionID: session)
        let calls = await rpc.calls
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(calls.first?.1.objectValue?["phase"]?.stringValue, "begin")
        XCTAssertEqual(calls.last?.1.objectValue?["phase"]?.stringValue, "finish")
        let chunks = calls.dropFirst().dropLast()
        let assembled = chunks.reduce(into: Data()) { data, call in data.append(Data(base64Encoded: call.1.objectValue?["data"]?.stringValue ?? "") ?? Data()) }
        XCTAssertEqual(assembled, data)
        XCTAssertTrue(chunks.allSatisfy { (Data(base64Encoded: $0.1.objectValue?["data"]?.stringValue ?? "")?.count ?? Int.max) <= 256 * 1024 })
        XCTAssertTrue(calls.allSatisfy { $0.1.objectValue?["session_id"]?.stringValue == session })
        XCTAssertEqual(reference.size, data.count)
    }
    func testUnconfirmedCommandRetainsIntentAcrossClientRestartButCompletedIntentDoesNotBlockNewMessage() async throws {
        let rpc = DirectFixtureRPC(["command": .null]), secrets = DirectClientSecrets(), profile = LocalProfile(id: UUID())
        let first = DirectRemoteClientService(profile: profile, store: secrets) { rpc }
        await rpc.failOnce()
        do { _ = try await first.sendCommand(machineID: "mac", sessionID: "session", type: .userMessage, payload: .object(["text": .string("same message")])) ; XCTFail("Fixture must lose its reply") } catch { }
        let restarted = DirectRemoteClientService(profile: profile, store: secrets) { rpc }
        _ = try await restarted.sendCommand(machineID: "mac", sessionID: "session", type: .userMessage, payload: .object(["text": .string("same message")]))
        _ = try await restarted.sendCommand(machineID: "mac", sessionID: "session", type: .userMessage, payload: .object(["text": .string("same message")]))
        let calls = await rpc.calls
        XCTAssertEqual(calls[0].2, calls[1].2)
        XCTAssertNotEqual(calls[1].2, calls[2].2)
        let otherProfile = DirectRemoteClientService(profile: .init(id: UUID()), store: secrets) { rpc }
        _ = try await otherProfile.sendCommand(machineID: "mac", sessionID: "session", type: .userMessage, payload: .object(["text": .string("same message")]))
        let last = await rpc.calls.last
        XCTAssertNotEqual(calls[0].2, last?.2)
    }
    func testDeleteOnlyDispatchesOwnedVisibleSessionsWithManagementPermission() async throws {
        let machine = UUID(), session = UUID().uuidString.lowercased()
        func snapshot(allowed: Bool) throws -> RemoteJSONValue {
            try DirectRemoteSnapshotCodec.value(DirectRemoteOverviewSnapshot(machineID: machine, name: "Fixture", appVersion: "1",
                capabilities: .init(features: [RemoteCapabilities.Feature.sessionManagement: allowed]),
                sessions: [.init(id: session, mode: .chat, title: "Fixture", status: "idle", messageCount: 0, updatedAt: .now)]))
        }
        let allowed = DirectFixtureRPC(["overview": try snapshot(allowed: true), "command": .object(["deleted": .bool(true)])])
        let service = DirectRemoteClientService { allowed }
        try await service.deleteSessions(ids: [session])
        let calls = await allowed.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.1.objectValue?["type"]?.stringValue, "delete_session")
        XCTAssertEqual(calls.last?.1.objectValue?["session_id"]?.stringValue, session)
        XCTAssertEqual(calls.last?.1.objectValue?["machine_id"]?.stringValue, machine.uuidString.lowercased())
        let denied = DirectFixtureRPC(["overview": try snapshot(allowed: false), "command": .null])
        let deniedService = DirectRemoteClientService { denied }
        do { try await deniedService.deleteSessions(ids: [session]); XCTFail("Read access cannot imply delete permission") }
        catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
        let deniedCalls = await denied.calls; XCTAssertEqual(deniedCalls.map(\.0), ["overview"])
        do { try await service.deleteSessions(ids: [session, UUID().uuidString]); XCTFail("One foreign ID must prevent dispatch of the entire selection") }
        catch { XCTAssertEqual(error as? DirectRemoteError, .unauthorized) }
        let afterForeign = await allowed.calls; XCTAssertEqual(afterForeign.filter { $0.0 == "command" }.count, 1)
    }
    func testTerminalAndDiffKeepStructuredReplies() async throws {
        let rpc = DirectFixtureRPC(["command": .object(["output": .string("fixture output"), "exitCode": .number(7), "truncated": .bool(true), "diff": .string("diff fixture"), "files": .array([])])])
        let service = DirectRemoteClientService { rpc }
        let terminal = try await service.runTerminalCommand("fixture", machineID: "mac", sessionID: "session")
        XCTAssertEqual(terminal.exitCode, 7); XCTAssertEqual(terminal.output, "fixture output"); XCTAssertTrue(terminal.truncated)
        let diff = try await service.requestDiff(machineID: "mac", sessionID: "session")
        XCTAssertEqual(diff.diff, "diff fixture")
        let calls = await rpc.calls
        XCTAssertEqual(calls.map { $0.1.objectValue?["type"]?.stringValue }, ["run_command", "request_diff"])
    }

}

private final class DirectClientSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func readData(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
    func store(_ value: Data, forKey key: String) throws { lock.withLock { values[key] = value } }
    func removeData(forKey key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
