import AIMApplication
@testable import AIMMacPlatform
import Foundation
import XCTest

private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(UUID, String)] = []
    func add(_ id: UUID, _ reason: String) { lock.withLock { values.append((id, reason)) } }
    var count: Int { lock.withLock { values.count } }
}

final class TaskTriggerMonitorTests: XCTestCase {
    @MainActor
    func testFolderChangeFiresOnceWithinTheDebounceWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fired = Fired()
        let monitor = TaskTriggerMonitor(debounce: 60) { id, reason, _ in fired.add(id, reason) }
        let task = ScheduledTask(title: "Inbox", prompt: "x",
            spec: ScheduledTaskSpec(trigger: .folderChanged(path: folder.path), modelID: "m"))
        let disabled = ScheduledTask(title: "Off", prompt: "x", state: .disabled,
            spec: ScheduledTaskSpec(trigger: .folderChanged(path: folder.path), modelID: "m"))
        monitor.update([task, disabled])
        try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: false, encoding: .utf8)
        try "b".write(to: folder.appendingPathComponent("b.txt"), atomically: false, encoding: .utf8)
        for _ in 0..<40 where fired.count == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fired.count, 1, "Two quick changes fire one run; disabled tasks are not watched")
        monitor.stopAll()
    }
}
