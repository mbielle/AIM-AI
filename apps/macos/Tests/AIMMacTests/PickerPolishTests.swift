@testable import AIMAgentRuntime
import AIMApplication
@testable import AIMMac
import AppKit
import XCTest

final class PickerPolishTests: XCTestCase {
    func testSVGAvatarsAreRefusedAndBitmapsKept() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><filter id="f"><feGaussianBlur stdDeviation="2"/></filter><rect width="10" height="10" filter="url(#f)"/></svg>"#.utf8)
        XCTAssertNil(CreatorAvatarCache.bitmap(from: svg), "SVG can crash macOS's renderer and is never drawn")
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        XCTAssertNotNil(CreatorAvatarCache.bitmap(from: png))
    }

    @MainActor
    func testRawModelIdsAreTidiedUntilTheRealNameIsKnown() {
        XCTAssertEqual(AppModel.tidy("claude-fable-5-1"), "Claude Fable 5.1")
        XCTAssertEqual(AppModel.tidy("anthropic/claude-haiku-4-5"), "Claude Haiku 4.5")
    }

    func testImageModelsKeepTheirImageOutput() throws {
        let json = #"{"id":"google/gemini-3-flash-image","name":"Nano Banana","architecture":{"input_modalities":["text","image"],"output_modalities":["image","text"]}}"#
        let reference = try JSONDecoder().decode(ChatModel.self, from: Data(json.utf8))
        let direct = ChatModel(id: "gemini-3-flash-image", name: "Nano Banana")
        let enriched = ModelDetailsLookup.enriched(direct, provider: .google, catalog: [reference])
        XCTAssertEqual(enriched.architecture?.outputModalities, ["image", "text"])
    }
}
