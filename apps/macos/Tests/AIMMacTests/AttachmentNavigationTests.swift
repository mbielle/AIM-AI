@testable import AIMAgentRuntime
@testable import AIMMac
import AIMApplication
import ImageIO
import XCTest

@MainActor
final class AttachmentNavigationTests: XCTestCase {
    func testImageImportAndDraftNavigationStayIsolated() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database)
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        try png.write(to: imageURL)
        await model.importAttachment(imageURL)
        XCTAssertEqual(model.pendingImages.first?.data, png)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        model.composerText = "Describe this"
        model.selectMode(.code)
        XCTAssertTrue(model.pendingImages.isEmpty)
        model.selectMode(.chat)
        XCTAssertEqual(model.pendingImages.first?.data, png)
    }

    func testHEICAttachmentIsConvertedBeforeEnteringComposer() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let pixels = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        let source = try XCTUnwrap(CGImageSourceCreateWithData(pixels as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let expanded = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, expanded, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try (encoded as Data).write(to: url)

        await model.importAttachment(url)
        XCTAssertNil(model.alertMessage)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertEqual(model.pendingImages.first?.mimeType, "image/jpeg")
        XCTAssertEqual(model.pendingImages.first?.name, url.deletingPathExtension().lastPathComponent + ".jpg")
    }

    func testBatchImportKeepsValidFilesAndReportsEachFailure() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let invalid = directory.appendingPathComponent("invalid.bin")
        try Data("One".utf8).write(to: first)
        try Data("Two".utf8).write(to: second)
        try Data([0, 255]).write(to: invalid)

        await model.importAttachments([first, invalid])
        XCTAssertEqual(model.pendingAttachments.map(\.content), ["One"])
        XCTAssertEqual(model.attachmentImportErrors.count, 1)
        XCTAssertTrue(model.attachmentImportErrors.first?.hasPrefix("invalid.bin:") == true)
        XCTAssertFalse(model.isImportingAttachment)
        await model.importAttachments([first, first])
        XCTAssertEqual(model.pendingAttachments.map(\.content), ["One"])
        XCTAssertNotNil(model.alertMessage)
        model.alertMessage = nil
        await model.importAttachments([URL(string: "https://example.com/test.txt")!])
        XCTAssertEqual(model.pendingAttachments.map(\.content), ["One"])
        XCTAssertNotNil(model.alertMessage)
        await model.importAttachments([second])
        XCTAssertEqual(model.pendingAttachments.map(\.content), ["One", "Two"])
        XCTAssertTrue(model.attachmentImportErrors.isEmpty)
        await model.importAttachments([invalid])
        XCTAssertEqual(model.pendingAttachments.map(\.content), ["One", "Two"])
        XCTAssertEqual(model.attachmentImportErrors.count, 1)
        _ = await model.prepareForTermination()
    }

    func testDelayedPickerResultCannotEnterAnotherDraftOrLoadingConversation() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let context = model.attachmentImportContext
        await model.newConversation()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Must not attach".utf8).write(to: file)
        await model.importAttachments([file], context: context)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        model.isLoadingConversation = true
        XCTAssertFalse(model.canImportAttachments)
        await model.importAttachment(file)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
    }

    func testCombinedSizeFailurePreservesExistingAttachments() async throws {
        let model = AppModel(database: try AIMDatabase(inMemory: true))
        let existing = TextAttachment(name: "existing.txt", content: String(repeating: "a", count: TextAttachment.maximumFileBytes))
        model.pendingAttachments = (0..<4).map { TextAttachment(name: "existing-\($0).txt", content: existing.content) }
        let before = model.pendingAttachments
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = [directory.appendingPathComponent("one"), directory.appendingPathComponent("two")]
        for url in urls { try Data(repeating: 65, count: 40_000).write(to: url) }
        await model.importAttachments(urls)
        XCTAssertEqual(model.pendingAttachments, before)
        XCTAssertEqual(model.attachmentImportErrors.count, 2)
        _ = await model.prepareForTermination()
    }

    func testImportPreviewStateAndNavigationIsolation() async throws {
        let database = try AIMDatabase(inMemory: true)
        let model = AppModel(database: database)
        let conversation = Conversation(title: "Attachment draft")
        try await SQLiteConversationRepository(database: database).save(conversation)
        await model.selectConversation(conversation.id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("A local snapshot".utf8).write(to: file)
        await model.importAttachment(file)
        XCTAssertEqual(model.pendingAttachments.first?.content, "A local snapshot")
        XCTAssertFalse(model.isImportingAttachment)
        await model.newConversation()
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        await model.selectConversation(conversation.id)
        XCTAssertEqual(model.pendingAttachments.count, 1)
        await model.selectConversation(nil)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        model.isSending = true
        await model.importAttachment(file)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
    }
}
