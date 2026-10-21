import AIMApplication
import XCTest

final class ConversationAppearanceTests: XCTestCase {
    func testDefaultAndConsistentScaling() {
        let normal = ConversationAppearance()
        XCTAssertEqual(normal.typeface, .lora)
        XCTAssertEqual(normal.textSize, 15)
        XCTAssertEqual(normal.codeSize, 12)
        XCTAssertEqual(normal.tableSize, 13)
        XCTAssertEqual(normal.mathSize, 17)
        XCTAssertEqual(normal.headingSize(level: 1), 25)
        let large = ConversationAppearance(typeface: .system, textSize: 24)
        XCTAssertEqual(large.codeSize, 21)
        XCTAssertEqual(large.headingSize(level: 2), 30)
    }

    func testBoundsAndForwardCompatibleTypeface() throws {
        XCTAssertEqual(ConversationAppearance(textSize: Int.min).textSize, 12)
        XCTAssertEqual(ConversationAppearance(textSize: Int.max).textSize, 24)
        let decoded = try JSONDecoder().decode(ConversationAppearance.self, from: Data(#"{"typeface":"future-font","textSize":100}"#.utf8))
        XCTAssertEqual(decoded.typeface, .lora)
        XCTAssertEqual(decoded.textSize, 24)
        XCTAssertEqual(try JSONDecoder().decode(ConversationAppearance.self, from: Data("{}".utf8)), .init())
    }

    func testSettingsRoundTripAndOlderSettingsWithoutAppearance() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var settings = AppSettings()
        XCTAssertNil(try decoder.decode(AppSettings.self, from: encoder.encode(settings)).conversationAppearance)
        settings.conversationAppearance = .init(typeface: .system, textSize: 18)
        XCTAssertEqual(try decoder.decode(AppSettings.self, from: encoder.encode(settings)), settings)
    }
}
