import Foundation
import XCTest
import ZIPFoundation
@testable import AIMCore

final class NativeAttachmentTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
    private func image() -> NativeChatAttachment { .init(name: "pixel.png", kind: .image, mimeType: "image/png", data: png) }
    private func document(_ text: String = "document fixture") -> NativeChatAttachment { .init(name: "notes.txt", kind: .document, mimeType: "text/plain", text: text) }
    func testOldHistoryDecodesAndSnapshotIdentityRoundTrips() throws {
        let old = NativeChatMessage(role: .user, text: "old")
        XCTAssertNil(try JSONDecoder().decode(NativeChatMessage.self, from: JSONEncoder().encode(old)).attachments)
        let value = NativeChatMessage(role: .user, text: "", attachments: [document(), image()])
        XCTAssertEqual(try JSONDecoder().decode(NativeChatMessage.self, from: JSONEncoder().encode(value)), value)
    }
    func testMergePreservesInputsAgainstOlderTextOnlyClientAndRename() {
        let input = image(), id = UUID(), messageID = UUID()
        let a = NativeChatConversation(id: id, title: "A", provider: .openRouter, modelID: "vision", messages: [.init(id: messageID, role: .user, text: "", attachments: [input])])
        let b = NativeChatConversation(id: id, title: "Renamed", provider: .openRouter, modelID: "vision", messages: [.init(id: messageID, role: .user, text: "longer")], updatedAt: .distantFuture)
        for result in [a.merging(b), b.merging(a)] {
            XCTAssertEqual(result.messages.count, 1); XCTAssertEqual(result.messages[0].attachments, [input]); XCTAssertEqual(result.title, "Renamed")
        }
    }
    func testImageWireContractsAndDocumentUntrustedContext() throws {
        let input = image(), message = NativeChatMessage(role: .user, text: "Inspect", attachments: [document(), input])
        for provider in [ChatProvider.openRouter, .anthropic, .openAI, .google] {
            let request = try NativeChatTransport.request(provider: provider, modelID: "vision", messages: [message], key: "fixture", catalogMaximum: 8192)
            let data = try XCTUnwrap(request.httpBody), json = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(json.replacingOccurrences(of: "\\/", with: "/").contains(png.base64EncodedString()))
            XCTAssertTrue(json.contains("Untrusted reference data")); XCTAssertFalse(json.contains("file://"))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if provider == .openRouter {
                let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
                let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
                XCTAssertEqual(content[0]["type"] as? String, "text"); XCTAssertEqual(content[1]["type"] as? String, "image_url")
            }
        }
    }
    func testInvalidInputsAndTextOnlyProviderRefuseBeforeNetwork() throws {
        let duplicate = image()
        XCTAssertThrowsError(try NativeChatAttachment.validate([duplicate, duplicate]))
        XCTAssertThrowsError(try NativeChatAttachment.validate([document(String(repeating: "x", count: 64_001))]))
        XCTAssertThrowsError(try NativeChatAttachment.validate([.init(name: "fake.png", kind: .image, mimeType: "image/png", data: Data("fake".utf8))]))
        XCTAssertThrowsError(try NativeChatTransport.request(provider: .deepSeek, modelID: "deepseek-chat", messages: [.init(role: .user, text: "", attachments: [image()])], key: "fixture"))
        XCTAssertThrowsError(try NativeChatTransport.request(provider: .openRouter, modelID: "vision", messages: [.init(role: .assistant, text: "", attachments: [image()])], key: "fixture"))
    }
    func testPortableOfficeReaderExtractsTextAndRejectsTraversalAndEntities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func archive(_ name: String, entries: [(String, String)]) throws -> URL {
            let url = directory.appendingPathComponent(name + ".docx")
            let zip = try Archive(url: url, accessMode: .create)
            for (path, text) in [("[Content_Types].xml", "<Types/>")] + entries {
                let bytes = Data(text.utf8)
                try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), provider: { position, size in bytes.subdata(in: Int(position)..<Int(position) + size) })
            }
            return url
        }
        let xml = "<w:document xmlns:w=\"w\"><w:body><w:p><w:r><w:t>Fixture document</w:t></w:r></w:p></w:body></w:document>"
        let valid = try archive("valid", entries: [("word/document.xml", xml)])
        XCTAssertTrue(try NativeDocumentImporter.read(valid).content.contains("Fixture document"))
        let unsafe = try archive("unsafe", entries: [("../escape", "x"), ("word/document.xml", xml)])
        XCTAssertThrowsError(try NativeDocumentImporter.read(unsafe))
        let entity = try archive("entity", entries: [("word/document.xml", "<!DOCTYPE doc [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><doc>&x;</doc>")])
        XCTAssertThrowsError(try NativeDocumentImporter.read(entity))
    }
    func testEngineCapabilityExtensionsAreOptional() throws {
        let legacy = try JSONDecoder().decode(RemoteEngineAnnouncement.self, from: Data(#"{"id":"aim","state":"ready"}"#.utf8))
        XCTAssertNil(legacy.providers); XCTAssertNil(legacy.features)
        XCTAssertEqual(RemoteEngineRules.engines(capabilities: nil).count, 3)
    }
}
