import AIMMacPlatform
import XCTest

final class SpeechDictationTests: XCTestCase {
    func testTranscriptAppendPreservesExistingAndNewlyTypedDraft() {
        XCTAssertEqual(DictationText.appending("  hello world  ", to: ""), "hello world")
        XCTAssertEqual(DictationText.appending("hello", to: "Typed while recording"), "Typed while recording hello")
        XCTAssertEqual(DictationText.appending("hello", to: "Typed\n"), "Typed\nhello")
        XCTAssertEqual(DictationText.appending("   ", to: "Keep draft"), "Keep draft")
    }
}
