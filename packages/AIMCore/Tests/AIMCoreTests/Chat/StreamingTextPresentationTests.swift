import XCTest
@testable import AIMCore

final class StreamingTextPresentationTests: XCTestCase {
    func testBurstSettlesWithinSixFramesWithoutSplittingGraphemes() {
        var display = StreamingTextPresentation()
        let text = String(repeating: "👨‍👩‍👧‍👦日本語 ", count: 400)
        display.update(text, animated: true)
        XCTAssertTrue(display.visible.isEmpty)
        for _ in 0..<6 { display.advance(); XCTAssertTrue(text.hasPrefix(display.visible)) }
        XCTAssertEqual(display.visible, text); XCTAssertTrue(display.isSettled)
    }
    func testNewChunksPreservePrefixAndCompletionCanFlushImmediately() {
        var display = StreamingTextPresentation()
        display.update("A", animated: false)
        display.update("ABCDEFG", animated: true); display.advance()
        XCTAssertEqual(display.visible, "AB")
        display.update("ABCDEFGHI", animated: true)
        display.update("ABCDEFGHI", animated: false)
        XCTAssertEqual(display.visible, "ABCDEFGHI"); XCTAssertTrue(display.isSettled)
    }
    func testReplacementAndArchivedMessagesAppearWithoutReplay() {
        var display = StreamingTextPresentation()
        display.update("Stored answer", animated: false)
        XCTAssertEqual(display.visible, "Stored answer")
        display.update("Other conversation", animated: true)
        XCTAssertEqual(display.visible, "Other conversation")
        display.update("", animated: true)
        XCTAssertTrue(display.visible.isEmpty)
    }
}
