import AIMMacPlatform
import Foundation
import XCTest

final class MacPTYTerminalTests: XCTestCase {
    func testInteractiveShellKeepsWorkingDirectoryBetweenCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-pty-\(UUID())")
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = MacPTYTerminal(supervisor: ProcessSupervisor())

        let transcript = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var transcript = ""
                for try await event in terminal.stream(workspace: root.path) {
                    switch event {
                    case .ready:
                        try await terminal.send("cd child\npwd\ntty\nexit\n")
                    case .output(let value): transcript = value
                    case .completed(let code):
                        XCTAssertEqual(code, 0)
                        return transcript
                    }
                }
                XCTFail("Terminal ended without a completion event")
                return transcript
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                await terminal.terminateAll()
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertTrue(transcript.contains(child.path), transcript)
        XCTAssertTrue(transcript.contains("/dev/ttys"), transcript)
    }

    func testStoppingShellStopsBackgroundChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aim-pty-stop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("leaked-child.txt")
        let terminal = MacPTYTerminal(supervisor: ProcessSupervisor())
        let reader = Task {
            for try await event in terminal.stream(workspace: root.path) {
                switch event {
                case .ready:
                    try await terminal.send("(sleep 1; touch leaked-child.txt) & echo AIM_STARTED; wait\n")
                case .output(let snapshot) where snapshot.contains("AIM_STARTED\r\n"):
                    return
                default: break
                }
            }
        }
        try await reader.value
        await terminal.terminateAll()
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "A background child escaped terminal cancellation")
    }

    private struct TimeoutError: Error {}
}
