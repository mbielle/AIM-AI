@testable import AIMAgentRuntime
import AIMCore
import AIMMacPlatform
import XCTest

final class MacLocalProfileStoreTests: XCTestCase {
    func testConcurrentCreatorsObserveOnePersistentProfile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConcurrentProfileSecrets(), results = ProfileResults(), lockURL = folder.appendingPathComponent("identity.lock")
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { results.add(try MacLocalProfileStore.loadOrCreate(store: store, lockURL: lockURL).id) }
            catch { results.fail() }
        }
        XCTAssertEqual(results.failures, 0)
        XCTAssertEqual(Set(results.ids).count, 1)
        XCTAssertEqual(results.ids.count, 16)
    }
    func testOtherProcessMustReleaseTheIdentityLockBeforeSecureStoreRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lockURL = folder.appendingPathComponent("identity.lock"), store = ConcurrentProfileSecrets()
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl, os, sys; fd=os.open(sys.argv[1], os.O_CREAT|os.O_RDWR, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); print('ready', flush=True); sys.stdin.buffer.read(1); os.close(fd)", lockURL.path]
        process.standardOutput = output; process.standardInput = input
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(ready, Data("ready\n".utf8))
        let creator = Task.detached { try MacLocalProfileStore.loadOrCreate(store: store, lockURL: lockURL) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.reads, 0, "No Keychain read may happen while the helper owns the lock")
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try input.fileHandleForWriting.close()
        _ = try await creator.value
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(store.reads, 1)
    }

    func testUnsafeLockDoesNotReadOrReplaceProfile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target"), link = folder.appendingPathComponent("identity.lock")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = ConcurrentProfileSecrets()
        XCTAssertThrowsError(try MacLocalProfileStore.loadOrCreate(store: store, lockURL: link))
        XCTAssertNil(try store.readData(forKey: "local-profile.v1"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
    }
}
private final class ConcurrentProfileSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var readCount = 0
    var reads: Int { lock.withLock { readCount } }
    func readData(forKey key: String) throws -> Data? { lock.withLock { readCount += 1; return values[key] } }
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
}
private final class ProfileResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ids: [UUID] = []
    private(set) var failures = 0
    func add(_ id: UUID) { lock.withLock { ids.append(id) } }
    func fail() { lock.withLock { failures += 1 } }
}
