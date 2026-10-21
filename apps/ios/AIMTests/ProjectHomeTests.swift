import AIMCore
import Foundation
import XCTest
@testable import AIM

private final class ProjectHomeSecrets: SecureStoring, @unchecked Sendable {
    func store(_ data: Data, forKey key: String) throws {}
    func readData(forKey key: String) throws -> Data? { nil }
    func removeData(forKey key: String) throws {}
}
private actor ProjectHomeSync: AccountContentSyncing {
    var incoming: [AccountDocument]
    private var writes: [AccountDocument] = []
    let rejectChats: Bool
    init(_ incoming: [AccountDocument], rejectChats: Bool = false) { self.incoming = incoming; self.rejectChats = rejectChats }
    func documents(accountID: UUID) async throws -> [AccountDocument] { incoming }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        if rejectChats && document.kind == "chat" { throw AccountServiceError.unavailable }
        var saved = document; saved.revision += 1; writes.append(saved); return saved
    }
    func tombstones() -> [AccountDocument] { writes.filter { $0.deleted } }
}
final class ProjectHomeTests: XCTestCase {
    @MainActor func testProjectDraftsDoNotMoveExistingConversationAndStaySeparate() async throws {
        let owner = UUID(), directory = Self.directory(owner)
        let chat = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        let first = NativeChatProject(name: "First"), second = NativeChatProject(name: "Second")
        XCTAssertTrue(chat.saveProject(first)); XCTAssertTrue(chat.saveProject(second))
        let globalDraft = chat.draftIdentifier(conversationID: nil)
        chat.setDraftText("Outside project draft", conversationID: globalDraft)
        let original = NativeChatConversation(title: "Outside", provider: .openAI, modelID: "test")
        chat.conversations = [original]; await chat.open(original)
        chat.startProjectChat(first.id)
        XCTAssertNil(chat.selectedID); XCTAssertEqual(chat.selectedProjectID, first.id)
        let firstDraft = chat.draftIdentifier(conversationID: nil)
        chat.setDraftText("First draft", conversationID: firstDraft)
        chat.startProjectChat(second.id)
        let secondDraft = chat.draftIdentifier(conversationID: nil)
        XCTAssertNotEqual(firstDraft, secondDraft)
        chat.setDraftText("Second draft", conversationID: secondDraft)
        chat.startProjectChat(first.id)
        XCTAssertEqual(chat.draftIdentifier(conversationID: nil), firstDraft)
        XCTAssertEqual(chat.draftText(conversationID: firstDraft), "First draft")
        XCTAssertNil(chat.conversations[0].projectID)
        chat.newConversation()
        XCTAssertNil(chat.selectedProjectID)
        XCTAssertEqual(chat.draftIdentifier(conversationID: nil), globalDraft)
        XCTAssertEqual(chat.draftText(conversationID: globalDraft), "Outside project draft")
        let reopened = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        XCTAssertNil(reopened.selectedProjectID)
        XCTAssertEqual(reopened.draftIdentifier(conversationID: nil), globalDraft)
        XCTAssertEqual(reopened.draftText(conversationID: globalDraft), "Outside project draft")
        reopened.startProjectChat(second.id)
        XCTAssertEqual(reopened.draftIdentifier(conversationID: nil), secondDraft)
        XCTAssertEqual(reopened.draftText(conversationID: secondDraft), "Second draft")
    }
    @MainActor func testPinMemoryInstructionsAndDeletionPersistWithoutLosingChats() async throws {
        let owner = UUID(), directory = Self.directory(owner)
        let chat = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        let project = NativeChatProject(name: "Private", instructions: "Project instruction", memoryScope: .projectOnly)
        XCTAssertTrue(chat.saveProject(project)); chat.togglePinnedProject(project.id)
        var conversation = NativeChatConversation(title: "Keep me", provider: .openAI, modelID: "test", projectID: project.id.uuidString)
        conversation.messages = [.init(role: .user, text: "Keep this history")]; chat.conversations = [conversation]
        let reopened = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        XCTAssertTrue(try XCTUnwrap(reopened.projects.first).isPinned)
        XCTAssertEqual(reopened.projects.first?.memoryScope, .projectOnly)
        XCTAssertTrue(chat.deleteProject(project.id))
        let deleted = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        XCTAssertTrue(deleted.projects.isEmpty); XCTAssertEqual(deleted.conversations.count, 1)
        XCTAssertNil(deleted.conversations.first?.projectID)
        XCTAssertEqual(deleted.conversations.first?.messages.first?.text, "Keep this history")
        XCTAssertFalse(deleted.saveProject(project), "A stale editor must not resurrect a deleted project")
    }
    @MainActor func testFailedProjectSaveAndDeleteRollBackInMemory() throws {
        let owner = UUID(), directory = Self.directory(owner)
        let chat = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        let project = NativeChatProject(name: "Retain")
        XCTAssertTrue(chat.saveProject(project))
        let path = directory.appending(path: "conversations.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        var edited = project; edited.name = "Must not appear"
        XCTAssertFalse(chat.saveProject(edited)); XCTAssertEqual(chat.projects, [project])
        XCTAssertFalse(chat.deleteProject(project.id)); XCTAssertEqual(chat.projects, [project])
    }
    @MainActor func testRemoteTombstoneDetachesChatRegardlessOfResponseOrder() async throws {
        for tombstoneFirst in [true, false] {
            let owner = UUID(), directory = Self.directory(owner)
                let project = NativeChatProject(name: "Deleted elsewhere")
            let conversation = NativeChatConversation(title: "Retain", provider: .openAI, modelID: "test", projectID: project.id.uuidString)
            let tombstone = AccountDocument(id: project.id, kind: "project", payload: "{}", revision: 2, deleted: true)
            let record = AccountDocument(id: conversation.id, kind: "chat", payload: String(decoding: try JSONEncoder().encode(conversation), as: UTF8.self))
            let sync = ProjectHomeSync(tombstoneFirst ? [tombstone, record] : [record, tombstone])
            let chat = trackNativeChatFixture(NativeChatStore(accountID: owner, sync: sync, credentials: ProjectHomeSecrets()))
            chat.projects = [project]; await chat.synchronize()
            XCTAssertTrue(chat.projects.isEmpty); XCTAssertNil(chat.conversations.first?.projectID)
            XCTAssertEqual(chat.conversations.first?.id, conversation.id)
        }
    }
    @MainActor func testDirtyPrivateInstructionsWinOverFutureServerClock() async throws {
        let owner = UUID(), directory = Self.directory(owner)
        let local = NativeChatProject(name: "Private", instructions: "Local instruction", memoryScope: .projectOnly)
        let initial = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        XCTAssertTrue(initial.saveProject(local))
        var future = local; future.instructions = "Stale remote instruction"; future.memoryScope = .default
        future.updatedAt = .now.addingTimeInterval(86_400)
        let sync = ProjectHomeSync([.init(id: local.id, kind: "project", payload: String(decoding: try JSONEncoder().encode(future), as: UTF8.self), revision: 3)])
        let reopened = trackNativeChatFixture(NativeChatStore(accountID: owner, sync: sync, credentials: ProjectHomeSecrets()))
        await reopened.synchronize()
        XCTAssertEqual(reopened.projects.first?.instructions, "Local instruction")
        XCTAssertEqual(reopened.projects.first?.memoryScope, .projectOnly)
    }
    @MainActor func testLegacyClientPayloadCannotResetKnownPrivateMemoryScope() async throws {
        let owner = UUID(), directory = Self.directory(owner)
        let project = NativeChatProject(name: "Existing", isPinned: true, memoryScope: .projectOnly)
        let initial = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        initial.projects = [project]; initial.newConversation()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        payload.removeValue(forKey: "memoryScope"); payload.removeValue(forKey: "isPinned")
        payload["name"] = "Edited by earlier client"
        payload["updatedAt"] = Date.now.addingTimeInterval(86_400).timeIntervalSinceReferenceDate
        let data = try JSONSerialization.data(withJSONObject: payload)
        let sync = ProjectHomeSync([.init(id: project.id, kind: "project", payload: String(decoding: data, as: UTF8.self), revision: 3)])
        let reopened = trackNativeChatFixture(NativeChatStore(accountID: owner, sync: sync, credentials: ProjectHomeSecrets()))
        await reopened.synchronize()
        XCTAssertEqual(reopened.projects.first?.name, "Edited by earlier client")
        XCTAssertEqual(reopened.projects.first?.memoryScope, .projectOnly)
        XCTAssertEqual(reopened.projects.first?.isPinned, true)
    }
    @MainActor func testFailedChatCannotBlockProjectTombstone() async throws {
        let owner = UUID(), directory = Self.directory(owner)
        let project = NativeChatProject(name: "Delete safely")
        let initial = trackNativeChatFixture(NativeChatStore(accountID: owner, credentials: ProjectHomeSecrets()))
        XCTAssertTrue(initial.saveProject(project))
        initial.conversations = [.init(title: "Retained", provider: .openAI, modelID: "test", projectID: project.id.uuidString)]
        let sync = ProjectHomeSync([], rejectChats: true)
        let chat = trackNativeChatFixture(NativeChatStore(accountID: owner, sync: sync, credentials: ProjectHomeSecrets()))
        // Save the synthetic conversation through the normal project-delete persistence path.
        chat.conversations = initial.conversations
        XCTAssertTrue(chat.deleteProject(project.id))
        await chat.synchronize()
        // A save schedules synchronization; an overlapping explicit synchronize()
        // requests another pass rather than waiting for the in-flight pass.
        for _ in 0..<100 {
            if await sync.tombstones().contains(where: { $0.id == project.id }), chat.syncMessage != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let tombstones = await sync.tombstones()
        XCTAssertTrue(tombstones.contains { $0.id == project.id })
        XCTAssertEqual(chat.conversations.count, 1)
        XCTAssertNil(chat.conversations.first?.projectID)
        XCTAssertNotNil(chat.syncMessage)
    }
    private static func directory(_ owner: UUID) -> URL {
        URL.applicationSupportDirectory.appending(path: "Chat/\(owner.uuidString)", directoryHint: .isDirectory)
    }
}
