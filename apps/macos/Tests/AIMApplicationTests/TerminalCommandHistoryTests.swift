import AIMApplication
import XCTest

final class TerminalCommandHistoryTests: XCTestCase {
    func testRecallRestoresUnsentDraftAndNeverExecutes() {
        var history = TerminalCommandHistory()
        XCTAssertNil(history.previous(current: "draft"))
        history.record("first"); history.record("second"); history.record("second")
        XCTAssertEqual(history.commands, ["first", "second"])
        XCTAssertEqual(history.previous(current: "unsent"), "second")
        XCTAssertEqual(history.previous(current: "second"), "first")
        XCTAssertEqual(history.previous(current: "first"), "first")
        XCTAssertEqual(history.next(), "second")
        XCTAssertEqual(history.next(), "unsent")
        XCTAssertNil(history.next())
    }

    func testBoundsAndForget() {
        var history = TerminalCommandHistory()
        for index in 0..<60 { history.record("command \(index)") }
        XCTAssertEqual(history.commands.count, 50)
        XCTAssertEqual(history.commands.first, "command 10")
        history.record(String(repeating: "x", count: 4_097))
        XCTAssertEqual(history.commands.count, 50)
        history.clear()
        XCTAssertTrue(history.commands.isEmpty)
        XCTAssertNil(history.next())
    }
}
