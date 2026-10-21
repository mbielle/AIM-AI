import Foundation
import XCTest
import AIMAgentKit
import AIMCore
@testable import AIMMacPlatform

private actor InstallationFixture {
    var count = 0
    let stream = AsyncThrowingStream<RuntimeInstallProgress, Error>.makeStream()
    func start(_ id: AgentEngineID) -> AsyncThrowingStream<RuntimeInstallProgress, Error> { count += 1; return stream.stream }
    func finish() { stream.continuation.finish() }
}
final class RemoteInstallationTests: XCTestCase {
    private func payload(_ operation: String) -> RemoteJSONValue {
        .object(["section": .string("downloads"), "version": .number(1), "operation": .string(operation), "agent": .string("hermes")])
    }
    func testExplicitInstallDoesNotStartAgentAndDuplicateAdmissionOnlyDownloadsOnce() async throws {
        let fixture = InstallationFixture(), url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        let engines = await service.engines()
        XCTAssertEqual(engines.map(\.id), ["aim", "openclaw", "hermes"])
        XCTAssertEqual(engines.last?.state, "not_installed"); XCTAssertEqual(engines.last?.providers, [ChatProvider.openRouter.rawValue])
        XCTAssertEqual(engines.first?.features?["imageAttachments"], true)
        XCTAssertEqual(engines.last?.features?["imageAttachments"], true, "images reach external engines since Round 23")
        let initialCount = await fixture.count; XCTAssertEqual(initialCount, 0)
        _ = try await service.execute(type: "set_mac_settings", payload: payload("agent"))
        _ = try await service.execute(type: "set_mac_settings", payload: payload("agent"))
        for _ in 0..<100 { if await fixture.count == 1 { break }; await Task.yield() }
        let count = await fixture.count; XCTAssertEqual(count, 1)
        await fixture.finish()
        for _ in 0..<100 { await Task.yield() }
        let status = try await service.execute(type: "get_mac_settings", payload: payload("status"))
        XCTAssertEqual(status.objectValue?["jobs"]?.objectValue?["agent:hermes"]?.objectValue?["state"], .string("complete"))
    }
    func testCancelledAndInterruptedDownloadsAreNotAutomaticallyRestarted() async throws {
        let fixture = InstallationFixture(), url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        _ = try await service.execute(type: "set_mac_settings", payload: payload("agent"))
        let reopened = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        let restored = try await reopened.execute(type: "get_mac_settings", payload: payload("status"))
        XCTAssertEqual(restored.objectValue?["jobs"]?.objectValue?["agent:hermes"]?.objectValue?["state"], .string("running"), "Another live host owns the lease")
        _ = try await service.execute(type: "set_mac_settings", payload: .object(["section": .string("downloads"), "version": .number(1), "operation": .string("cancel"), "key": .string("agent:hermes")]))
        await fixture.finish()
        for _ in 0..<1000 {
            let state = try await service.execute(type: "get_mac_settings", payload: payload("status"))
            if state.objectValue?["jobs"]?.objectValue?["agent:hermes"]?.objectValue?["state"] == .string("cancelled") { break }
            await Task.yield()
        }
        // A stale receipt without a live lease represents a process interruption.
        try Data(#"{"agent:hermes":{"state":"running","progress":0.2,"message":"old process"}}"#.utf8).write(to: url, options: .atomic)
        let crashed = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        let interrupted = try await crashed.execute(type: "get_mac_settings", payload: payload("status"))
        XCTAssertEqual(interrupted.objectValue?["jobs"]?.objectValue?["agent:hermes"]?.objectValue?["state"], .string("interrupted"))
    }
    func testSecondHostCannotDuplicateRunningInstallAndUnwritableReceiptFailsBeforeInstall() async throws {
        let fixture = InstallationFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("receipt.json")
        let first = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        let second = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        _ = try await first.execute(type: "set_mac_settings", payload: payload("agent"))
        do { _ = try await second.execute(type: "set_mac_settings", payload: payload("agent")); XCTFail("Duplicate cross-host installation") } catch {}
        let invalid = RemoteInstallationService(receiptURL: directory, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        do { _ = try await invalid.execute(type: "set_mac_settings", payload: payload("agent")); XCTFail("Undurable operation") } catch {}
        for _ in 0..<100 { if await fixture.count == 1 { break }; await Task.yield() }
        let count = await fixture.count; XCTAssertEqual(count, 1)
        await fixture.finish()
    }
    func testSeparateHostsMergeJobsAndObserveActiveLease() async throws {
        let fixture = InstallationFixture(), otherFixture = InstallationFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("receipt.json")
        let first = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        let second = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await otherFixture.start($0) }, networkAdmission: {})
        _ = try await first.execute(type: "set_mac_settings", payload: payload("agent"))
        let other = RemoteJSONValue.object(["section": .string("downloads"), "version": .number(1), "operation": .string("agent"), "agent": .string("openclaw")])
        _ = try await second.execute(type: "set_mac_settings", payload: other)
        let status = try await first.execute(type: "get_mac_settings", payload: payload("status"))
        XCTAssertEqual(status.objectValue?["jobs"]?.objectValue?["agent:hermes"]?.objectValue?["state"], .string("running"))
        XCTAssertEqual(status.objectValue?["jobs"]?.objectValue?["agent:openclaw"]?.objectValue?["state"], .string("running"))
        await fixture.finish()
        await otherFixture.finish()
        for _ in 0..<1000 {
            let a = try await first.execute(type: "get_mac_settings", payload: payload("status"))
            if a.objectValue?["jobs"]?.objectValue?.values.allSatisfy({ $0.objectValue?["state"] == .string("complete") }) == true { return }
            await Task.yield()
        }
        XCTFail("Both explicit jobs should complete")
    }
    func testInvalidVersionAndUnknownAgentNeverReachInstaller() async throws {
        let fixture = InstallationFixture(), url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = RemoteInstallationService(receiptURL: url, installedAgent: { _ in nil }, installAgent: { await fixture.start($0) }, networkAdmission: {})
        for payload in [RemoteJSONValue.object(["section": .string("downloads"), "version": .number(2), "operation": .string("agent"), "agent": .string("hermes")]),
            .object(["section": .string("downloads"), "version": .number(1), "operation": .string("agent"), "agent": .string("unknown")])] {
            do { _ = try await service.execute(type: "set_mac_settings", payload: payload); XCTFail("Invalid install admitted") } catch {}
        }
        let count = await fixture.count; XCTAssertEqual(count, 0)
    }
}
