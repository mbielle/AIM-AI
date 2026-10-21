@testable import AIMAgentRuntime
@testable import AIMMac
import XCTest

final class ToolProgressWindowTests: XCTestCase {
    func testTracksSuccessFailureAndInterruptedWorkWithoutArguments() {
        var progress = ToolProgressWindow()
        progress.start(id: "first", name: "read_file")
        progress.start(id: "second", name: "run_command")
        progress.finish(id: "first", isError: false)
        progress.finish(id: "second", isError: true)
        progress.start(id: "third", name: "git_status")
        progress.interruptRunning()
        XCTAssertEqual(progress.items.map(\.state), [.succeeded, .failed, .interrupted])
        XCTAssertEqual(progress.totalStarted, 3)
        XCTAssertEqual(progress.failedCount, 1)
        XCTAssertEqual(progress.omittedCount, 0)
    }

    func testVisiblePreviewIsBoundedButKeepsExactTotal() {
        var progress = ToolProgressWindow()
        for index in 0..<27 { progress.start(id: "call-\(index)", name: "read_file") }
        XCTAssertEqual(progress.totalStarted, 27)
        XCTAssertEqual(progress.items.count, 20)
        XCTAssertEqual(progress.omittedCount, 7)
        XCTAssertEqual(progress.items.first?.id, "call-7")
        progress.finish(id: "call-0", isError: true)
        XCTAssertEqual(progress.items.first?.state, .running)
        progress.finish(id: "call-26", isError: false)
        XCTAssertEqual(progress.items.last?.state, .succeeded)
    }
}
