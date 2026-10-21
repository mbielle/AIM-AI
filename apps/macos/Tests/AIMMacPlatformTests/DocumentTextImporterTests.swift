import AIMApplication
import AIMMacPlatform
import CoreGraphics
import CoreText
import PDFKit
import XCTest

final class DocumentTextImporterTests: XCTestCase {
    func testInvalidAndOversizedSourcesAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Not a PDF".utf8).write(to: url)
        XCTAssertThrowsError(try DocumentTextImporter.read(url)) { XCTAssertEqual($0 as? DocumentImportError, .invalidPDF) }
        try Data(repeating: 65, count: 20_000_001).write(to: url)
        XCTAssertThrowsError(try DocumentTextImporter.read(url)) { XCTAssertEqual($0 as? DocumentImportError, .sourceLimit) }
    }

    private func pdf(pages: Int, lines: [String] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            for (index, text) in lines.enumerated() {
                context.textPosition = CGPoint(x: 20, y: 770 - index * 14)
                let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testExtractedSnapshotHasPageMarkersAndNoOriginalPath() throws {
        let url = try pdf(pages: 2, lines: ["AIM PDF fixture"])
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try DocumentTextImporter.read(url)
        XCTAssertEqual(snapshot.name, url.lastPathComponent)
        XCTAssertTrue(snapshot.content.contains("AIM PDF fixture"))
        XCTAssertTrue(snapshot.content.contains("Page 1"))
        XCTAssertTrue(snapshot.content.contains("Page 2"))
        XCTAssertTrue(snapshot.content.contains("local OCR"))
        XCTAssertTrue(snapshot.content.contains("layout is not preserved"))
        XCTAssertFalse(snapshot.content.contains(url.deletingLastPathComponent().path))
    }

    func testImageOnlyAndExcessivePageCountAreRejected() throws {
        let blank = try pdf(pages: 1), many = try pdf(pages: 2_001)
        defer { try? FileManager.default.removeItem(at: blank); try? FileManager.default.removeItem(at: many) }
        XCTAssertThrowsError(try DocumentTextImporter.read(blank)) { XCTAssertEqual($0 as? DocumentImportError, .noText) }
        XCTAssertThrowsError(try DocumentTextImporter.read(many)) { XCTAssertEqual($0 as? DocumentImportError, .pageLimit) }
    }

    func testLockedPDFIsNotImported() throws {
        let source = try pdf(pages: 1, lines: ["Locked content"])
        let locked = source.deletingPathExtension().appendingPathExtension("locked.pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: locked) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(document.write(to: locked, withOptions: [.ownerPasswordOption: "fixture-owner", .userPasswordOption: "fixture-reader"]))
        XCTAssertThrowsError(try DocumentTextImporter.read(locked)) { XCTAssertEqual($0 as? DocumentImportError, .lockedPDF) }
    }

    func testLongDocumentsAreImportedWhole() throws {
        // Formerly refused above 64 KB; long documents are kept whole and read by pages by the agent.
        let url = try pdf(pages: 20, lines: Array(repeating: String(repeating: "word ", count: 16), count: 50))
        defer { try? FileManager.default.removeItem(at: url) }
        let attachment = try DocumentTextImporter.read(url)
        XCTAssertGreaterThan(attachment.content.utf8.count, 64_000)
        XCTAssertLessThanOrEqual(attachment.content.utf8.count, TextAttachment.maximumFileBytes)
    }
}
