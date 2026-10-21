import AIMCore
import AIMApplication
import XCTest

final class ComposerDraftTests: XCTestCase {
    func testPendingVisualConsentSurvivesReopenWithoutBecomingAuthorization() throws {
        let database = try AIMDatabase(inMemory: true)
        let store = ComposerDraftStore(database: database)
        let pending = DraftVisualApproval(id: UUID(), accountID: UUID(), primaryProvider: .openRouter,
            primaryModel: "principal", sources: [], conversationID: UUID(), target: "mac:fixture")
        let draft = ComposerDraft(text: "Analyse input", visualApproval: pending)
        try store.save(draft, key: "conversation:fixture")
        let restored = try ComposerDraftStore(database: database).load(key: "conversation:fixture")
        XCTAssertEqual(restored.visualApproval, pending)
        XCTAssertNil(restored.visualReport)
        let legacy = try JSONDecoder().decode(ComposerDraft.self, from: Data("{\"text\":\"Old\",\"attachments\":[]}".utf8))
        XCTAssertNil(legacy.visualApproval); XCTAssertEqual(legacy.text, "Old")
    }

    func testSnapshotsSurviveReopenAndAreScoped() throws {
        let database = try AIMDatabase(inMemory: true)
        let store = ComposerDraftStore(database: database)
        let draft = ComposerDraft(text: "Unsent text", attachments: [TextAttachment(name: "note.txt", content: "Snapshot")])
        try store.save(draft, key: "conversation:first")
        try store.save(ComposerDraft(text: "Other"), key: "new:code")
        let reopened = ComposerDraftStore(database: database)
        XCTAssertEqual(try reopened.load(key: "conversation:first"), draft)
        XCTAssertEqual(try reopened.load(key: "new:code").text, "Other")
        XCTAssertTrue(try reopened.load(key: "new:chat").isEmpty)
        try reopened.save(ComposerDraft(), key: "conversation:first")
        XCTAssertTrue(try reopened.load(key: "conversation:first").isEmpty)
    }

    func testAcknowledgingOldSendCannotDeleteNewDraft() throws {
        let store = ComposerDraftStore(database: try AIMDatabase(inMemory: true))
        let sent = ComposerDraft(text: "Sent"), newer = ComposerDraft(text: "Next message")
        try store.save(newer, key: "conversation:first")
        try store.removeIfUnchanged(sent, key: "conversation:first")
        XCTAssertEqual(try store.load(key: "conversation:first"), newer)
        try store.removeIfUnchanged(newer, key: "conversation:first")
        XCTAssertTrue(try store.load(key: "conversation:first").isEmpty)
    }

    func testOversizedDraftDoesNotOverwriteSavedCopy() throws {
        let store = ComposerDraftStore(database: try AIMDatabase(inMemory: true))
        try store.save(ComposerDraft(text: "Safe copy"), key: "new:chat")
        XCTAssertThrowsError(try store.save(ComposerDraft(text: String(repeating: "x", count: 1_000_001)), key: "new:chat"))
        XCTAssertEqual(try store.load(key: "new:chat").text, "Safe copy")
    }
}
