#if DEBUG
@testable import AIMCore
import Foundation
import Testing

struct QAIsolationTests {
    @Test func correlationTraceContainsIDsButNoInvitationOrPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AIMQAContext(runID: "synthetic", directory: root, invitation: "PRIVATE-INVITATION",
            expectedCatalog: nil, injectCatalogMismatch: false)
        let trace = AIMQATraceRecorder(context: context, role: .phone)
        let id = UUID()
        await trace.record(commandID: id, operation: "untrusted-private-operation", phase: "request")
        let text = try String(contentsOf: root.appendingPathComponent("phone-rpc.jsonl"), encoding: .utf8)
        #expect(text.contains(id.uuidString.lowercased()))
        #expect(text.contains("unsupported"))
        #expect(!text.contains("PRIVATE-INVITATION"))
        #expect(!text.contains("untrusted-private-operation"))
    }
    private actor RecordingRPC: DirectRemoteRPCTransport {
        nonisolated let events = AsyncStream<RemoteEvent> { $0.finish() }
        var ids: [UUID] = []
        func connectionState() async -> DirectRemoteConnectionState { .connected(.lan) }
        func request(operation: String, payload: RemoteJSONValue, id: UUID) async throws -> RemoteJSONValue {
            ids.append(id)
            return .object(["ok": .bool(true)])
        }
    }

    @Test func lostReplyIsInjectedAfterOneDispatchAndNeverRetriesOrChangesIDs() async throws {
        let rpc = RecordingRPC()
        let state = AIMQAFaultState()
        let first = AIMQAFaultTransport(base: rpc, fault: .dropReplyOnce, state: state)
        let id = UUID()
        do {
            _ = try await first.request(operation: "command", payload: .object([:]), id: id)
            Issue.record("The first reply should have been lost")
        } catch { #expect(error as? DirectRemoteError == .outcomeUnknown) }
        #expect(await rpc.ids == [id])
        // A newly acquired session shares fault state, while the client retains
        // the command identity. The production journal decides effect deduplication.
        let reconnected = AIMQAFaultTransport(base: rpc, fault: .dropReplyOnce, state: state)
        _ = try await reconnected.request(operation: "command", payload: .object([:]), id: id)
        #expect(await rpc.ids == [id, id])
    }

    @Test func cancellingInjectedNetworkDelayDoesNotDispatchAnEffect() async throws {
        let rpc = RecordingRPC()
        let transport = AIMQAFaultTransport(base: rpc, fault: .delayRequest, delay: .seconds(3600))
        let task = Task { try await transport.request(operation: "command", payload: .object([:]), id: UUID()) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation was ignored") }
        catch { #expect(error is CancellationError) }
        #expect(await rpc.ids.isEmpty)
    }

    @Test func disposableStorePersistsOnlyInsideItsOwnDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AIMQAFileStore(directory: root.appendingPathComponent("first"))
        let second = try AIMQAFileStore(directory: root.appendingPathComponent("second"))
        try first.store(Data("synthetic".utf8), forKey: "profile")
        #expect(try first.readData(forKey: "profile") == Data("synthetic".utf8))
        #expect(try second.readData(forKey: "profile") == nil)
        let reopened = try AIMQAFileStore(directory: root.appendingPathComponent("first"))
        #expect(try reopened.readData(forKey: "profile") == Data("synthetic".utf8))
        let file = try #require(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("first"), includingPropertiesForKeys: nil).first)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try reopened.removeData(forKey: "profile")
        #expect(try reopened.readData(forKey: "profile") == nil)
    }

    @Test func catalogParityIncludesProviderAndExplicitLibraryState() throws {
        let one = RemoteModelAnnouncement(id: "model", name: "QA", provider: "local", isAdded: true)
        let two = RemoteModelAnnouncement(id: "other", name: "QA2", provider: "local")
        #expect(try AIMQAContext.catalogDigest([one, two]) == AIMQAContext.catalogDigest([two, one]))
        let wrongRoute = RemoteModelAnnouncement(id: "model", name: "QA", provider: "openRouter", isAdded: true)
        let wrongLibrary = RemoteModelAnnouncement(id: "model", name: "QA", provider: "local", isAdded: false)
        #expect(try AIMQAContext.catalogDigest([one]) != AIMQAContext.catalogDigest([wrongRoute]))
        #expect(try AIMQAContext.catalogDigest([one]) != AIMQAContext.catalogDigest([wrongLibrary]))
    }
}
#endif
