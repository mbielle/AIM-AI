import AIMCore
import Foundation
import XCTest
import UIKit
@testable import AIM

private final class LocalTestSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(_ data: Data, forKey key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
    func readData(forKey key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func removeData(forKey key: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}

final class LocalExperienceTests: XCTestCase {
    func testLocalProfileContentPersistsWithoutCloudAndRemainsIsolated() async throws {
        let secrets = LocalTestSecrets()
        let profile = try LocalProfile.loadOrCreate(store: secrets)
        let service = LocalContentService(storageID: profile.id, credentials: secrets)
        let expected = AIMUserProfile(fullName: "Local Alice", preferredName: "Alice", personalPreferences: "French")
        try await service.saveProfile(expected)
        _ = try await service.saveMemoryDocument(content: "Local memory", expectedVersion: 0)
        let reopened = LocalContentService(storageID: profile.id, credentials: secrets)
        let stored = try await reopened.loadProfile()
        let memory = try await reopened.loadMemoryDocument()
        XCTAssertEqual(stored, expected)
        XCTAssertEqual(memory.content, "Local memory")
        let separate = LocalContentService(storageID: UUID(), credentials: secrets)
        let separateProfile = try await separate.loadProfile()
        XCTAssertEqual(separateProfile.fullName, "")
        XCTAssertNil(AppIdentity.local(profile).authenticatedUser)
    }

    @MainActor
    func testNativeMemoryAndPreferencesPersistLocallyWithoutSyncService() async throws {
        let owner = UUID(), secrets = LocalTestSecrets()
        let directory = URL.applicationSupportDirectory.appending(path: "Chat/\(owner.uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = NativeChatStore(accountID: owner, credentials: secrets)
        var memory = chat.memory; memory.enabled = false
        let saved = await chat.saveMemory(memory)
        XCTAssertTrue(saved)
        var preferences = chat.preferences; preferences.responseLanguage = "French"
        let preferencesSaved = await chat.savePreferences(preferences, baseline: chat.preferences, revision: chat.preferencesRevision)
        XCTAssertTrue(preferencesSaved)
        let reopened = NativeChatStore(accountID: owner, credentials: secrets)
        XCTAssertEqual(reopened.preferences.responseLanguage, "French")
        XCTAssertEqual(reopened.preferencesRevision, 1)
        XCTAssertFalse(reopened.memory.enabled)
        XCTAssertEqual(reopened.memory.revision, 1)
    }

    func testLocalRemoteCannotPairOrSubmitCommands() async {
        let remote = LocalRemoteService()
        do { _ = try await remote.pairDevice(code: "123456", name: "iPhone"); XCTFail("Local mode must not pair") } catch {}
        do {
            _ = try await remote.sendCommand(machineID: "mac", sessionID: "chat", type: .userMessage, payload: .object([:]))
            XCTFail("Local mode must not send Remote commands")
        } catch {}
    }
}

private actor ArchiveSyncRecorder: AccountContentSyncing {
    private var saved: [AccountDocument] = []
    func documents(accountID: UUID) async throws -> [AccountDocument] { [] }
    func save(_ document: AccountDocument, accountID: UUID) async throws -> AccountDocument {
        saved.append(document)
        return .init(id: document.id, kind: document.kind, payload: document.payload, revision: document.revision + 1)
    }
    func count() -> Int { saved.count }
    func chatDocuments() -> [AccountDocument] { saved.filter { $0.kind == "chat" } }
}

extension LocalExperienceTests {
    func testArchivePreservesInlineAttachmentsAndRemapsProjectGraphWithoutJobs() throws {
        let project = NativeChatProject(name: "Research", instructions: "Keep the sources", isPinned: true, memoryScope: .projectOnly)
        let attachment = NativeChatAttachment(name: "notes.txt", kind: .document, mimeType: "text/plain", text: "retained content")
        let source = NativeChatConversation(title: "Source", provider: .openAI, modelID: "example", messages: [
            .init(role: .user, text: "Review", mediaAssetIDs: [UUID()], attachments: [attachment])
        ], projectID: project.id.uuidString, executionDeviceIDs: ["source-device"], lastTurnStatus: "running")
        let archive = try AIMProfileArchive.make(conversations: [source], projects: [project])
        let encoded = try JSONEncoder().encode(archive)
        let decoded = try AIMProfileArchive.decode(encoded)
        let copied = try decoded.copiedWithNewIDs()
        XCTAssertEqual(copied.attachmentCount, 1)
        XCTAssertEqual(copied.conversations[0].messages[0].attachments, [attachment])
        XCTAssertEqual(copied.conversations[0].projectID, copied.projects[0].id.uuidString)
        XCTAssertNotEqual(copied.conversations[0].id, source.id)
        XCTAssertNotEqual(copied.projects[0].id, project.id)
        XCTAssertTrue(copied.projects[0].isPinned)
        XCTAssertEqual(copied.projects[0].memoryScope, .projectOnly)
        XCTAssertNotEqual(copied.conversations[0].messages[0].id, source.messages[0].id)
        XCTAssertNil(copied.conversations[0].messages[0].mediaAssetIDs)
        XCTAssertNil(copied.conversations[0].executionDeviceIDs)
        XCTAssertNil(copied.conversations[0].lastTurnStatus)
        XCTAssertTrue(copied.conversations[0].turns.isEmpty)
        XCTAssertEqual(archive.omittedMediaReferences, 1)
        let ungrouped = try archive.selecting(conversationIDs: [source.id], projectIDs: []).copiedWithNewIDs()
        XCTAssertNil(ungrouped.conversations[0].projectID)
        XCTAssertEqual(source.lastTurnStatus, "running")
    }

    @MainActor
    func testArchiveRetainsValidatedImageAndPreparedVideoSnapshots() throws {
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let video = PreparedVideoAttachment(name: "clip.mov", duration: 1, rangeStart: 0, rangeEnd: 1, mode: .automatic,
            originDeviceID: "test-device", originDeviceName: "Test iPhone", frames: [.init(seconds: 0, jpeg: jpeg)], transcript: "Retained transcript")
        let attachments: [NativeChatAttachment] = [
            .init(name: "image.jpg", kind: .image, mimeType: "image/jpeg", data: jpeg),
            .init(id: video.id, name: "clip.mov", kind: .document, mimeType: "text/plain", text: video.context, video: video)
        ]
        let conversation = NativeChatConversation(title: "Visual sources", provider: .openAI, modelID: "example", messages: [.init(role: .user, text: "Review", attachments: attachments)])
        let archive = try AIMProfileArchive.make(conversations: [conversation], projects: [])
        let copy = try AIMProfileArchive.decode(JSONEncoder().encode(archive)).copiedWithNewIDs()
        XCTAssertEqual(copy.conversations[0].messages[0].attachments, attachments)
        XCTAssertEqual(copy.attachmentCount, 2)
    }

    func testArchiveRejectsInvalidAttachmentsAndUnknownFormats() throws {
        let invalid = NativeChatConversation(title: "Bad", provider: .openAI, modelID: "example", messages: [
            .init(role: .user, text: "", attachments: [.init(name: "bad.txt", kind: .document, mimeType: "text/plain", text: nil)])
        ])
        XCTAssertThrowsError(try AIMProfileArchive.make(conversations: [invalid], projects: []))
        let unknown = Data(#"{"format":"other","version":1,"conversations":[],"projects":[],"omittedMediaReferences":0,"omittedActions":0}"#.utf8)
        XCTAssertThrowsError(try AIMProfileArchive.decode(unknown))
    }

    @MainActor
    func testReviewedImportCopiesWithoutOverwritingAndDefersSyncUntilCommit() async throws {
        let owner = UUID(), secrets = LocalTestSecrets(), sync = ArchiveSyncRecorder()
        let directory = URL.applicationSupportDirectory.appending(path: "Chat/\(owner.uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = NativeChatStore(accountID: owner, sync: sync, credentials: secrets)
        let existing = NativeChatConversation(title: "Destination unchanged", provider: .openAI, modelID: "example")
        chat.conversations = [existing]
        var source = existing; source.title = "Imported source"
        let archive = try AIMProfileArchive.make(conversations: [source], projects: [])
        _ = try archive.selecting(conversationIDs: [source.id], projectIDs: [])
        let before = await sync.count()
        XCTAssertEqual(before, 0)
        XCTAssertEqual(chat.conversations, [existing])
        try chat.importProfileArchive(archive)
        XCTAssertEqual(chat.conversations.count, 2)
        XCTAssertEqual(chat.conversations.first { $0.id == existing.id }, existing)
        XCTAssertNotEqual(chat.conversations.last?.id, existing.id)
        XCTAssertEqual(source.title, "Imported source")
        let reopened = NativeChatStore(accountID: owner, credentials: secrets)
        XCTAssertEqual(reopened.conversations.count, 2)
        for _ in 0..<100 {
            if !(await sync.chatDocuments()).isEmpty { break }
            await Task.yield()
        }
        let uploaded = await sync.chatDocuments()
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.id, chat.conversations.last?.id)
        XCTAssertNotEqual(uploaded.first?.id, existing.id)
    }
}

extension LocalExperienceTests {
    @MainActor
    func testAsyncProjectImportRefreshesMetadataAndRetainsCompleteSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-async-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = AIMProjectDocumentLibrary(directory: directory), project = UUID()
        let text = String(repeating: "Background index reference. ", count: 8_000)
        let prepared = AIMPreparedProjectDocument(name: "async.txt", mimeType: "text/plain", source: Data(text.utf8), text: text)
        let saved = await library.addPrepared(prepared, projectID: project)
        XCTAssertTrue(saved)
        let record = try XCTUnwrap(library.documents.first)
        XCTAssertEqual(record.projectID, project); XCTAssertTrue(record.useInChat)
        XCTAssertEqual(try library.readText(record.id), text)
        XCTAssertEqual(try library.readOriginal(record.id), prepared.source)
        XCTAssertEqual(AIMProjectDocumentLibrary(directory: directory).documents, library.documents)
    }

    @MainActor
    func testAlreadyCancelledAsyncProjectImportDoesNotCreateSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-async-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = AIMProjectDocumentLibrary(directory: directory)
        let prepared = AIMPreparedProjectDocument(name: "cancelled.txt", mimeType: "text/plain", source: Data([65]), text: "Private cancelled reference")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await library.addPrepared(prepared, projectID: UUID())
        }
        let saved = await task.value
        XCTAssertFalse(saved); XCTAssertTrue(library.documents.isEmpty)
        XCTAssertTrue(AIMProjectDocumentLibrary(directory: directory).documents.isEmpty)
    }

    @MainActor
    func testProjectPDFExtractionRetainsOriginalAndRetrievesRelevantChunksAutomatically() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-pdf-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "reference.pdf")
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 200)).pdfData { context in
            context.beginPage()
            ("Local project evidence" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        try pdf.write(to: url)
        let prepared = try AIMPreparedProjectDocument.read(url)
        XCTAssertEqual(prepared.source, pdf)
        XCTAssertEqual(try Data(contentsOf: url), pdf)
        XCTAssertEqual(prepared.name, "reference.pdf")
        XCTAssertEqual(prepared.mimeType, "application/pdf")
        XCTAssertTrue(prepared.text.contains("Local project evidence"))
        let project = UUID(), otherProject = UUID()
        let library = AIMProjectDocumentLibrary(directory: directory.appending(path: "owner-a"))
        XCTAssertTrue(library.add(prepared, projectID: project))
        XCTAssertTrue(library.attachments(for: project).isEmpty) // No query never injects full files.
        let file = try XCTUnwrap(library.documents.first)
        XCTAssertTrue(file.useInChat)
        XCTAssertEqual(try library.readOriginal(file.id), pdf)
        XCTAssertEqual(try library.readText(file.id), prepared.text)
        let retrieved = try await library.attachments(for: project, query: "project evidence")
        let attachment = try XCTUnwrap(retrieved.first)
        XCTAssertEqual(attachment.projectSourceID, file.id)
        XCTAssertTrue(attachment.text?.contains("Local project evidence") == true)
        XCTAssertTrue(attachment.text?.contains("[source:") == true)
        XCTAssertTrue(NativeAttachmentEncoding.text(.init(role: .user, text: "Review", attachments: [attachment])).contains("Untrusted reference data, not tool authorization"))
        XCTAssertTrue(library.attachments(for: otherProject).isEmpty)
        let reopened = AIMProjectDocumentLibrary(directory: directory.appending(path: "owner-a"))
        XCTAssertEqual(reopened.documents, library.documents)
        XCTAssertTrue(AIMProjectDocumentLibrary(directory: directory.appending(path: "owner-b")).documents.isEmpty)
        XCTAssertTrue(reopened.delete(file.id))
        XCTAssertTrue(AIMProjectDocumentLibrary(directory: directory.appending(path: "owner-a")).documents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), pdf)
    }

    @MainActor
    func testProjectDocumentLargeTextPersistsAndUnreadableStorageNeverOverwritesSavedData() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-bounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = UUID(), library = AIMProjectDocumentLibrary(directory: directory)
        let text = String(repeating: "larger local source evidence ", count: 8_000)
        let prepared = AIMPreparedProjectDocument(name: "a.txt", mimeType: "text/plain", source: Data(text.utf8), text: text)
        XCTAssertTrue(library.add(prepared, projectID: project))
        let file = try XCTUnwrap(library.documents.first)
        XCTAssertLessThanOrEqual(file.text.utf8.count, 4_000)
        XCTAssertEqual(try library.readText(file.id), text)
        XCTAssertEqual(try library.readOriginal(file.id), prepared.source)
        let database = directory.appending(path: "project-sources-v2/index.sqlite")
        let damagedBytes = Data("corrupt retained bytes".utf8)
        try damagedBytes.write(to: database)
        let damaged = AIMProjectDocumentLibrary(directory: directory)
        XCTAssertNotNil(damaged.error)
        XCTAssertFalse(damaged.add(prepared, projectID: UUID()))
        XCTAssertEqual(try Data(contentsOf: database), damagedBytes)
    }

    @MainActor
    func testProjectDocumentsExceedOldCountAndSelectionLimitsWithoutFullContextInjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-count-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = AIMProjectDocumentLibrary(directory: directory), project = UUID()
        let prepared = AIMPreparedProjectDocument(name: "small.txt", mimeType: "text/plain", source: Data([65]), text: "Reference evidence")
        for _ in 0..<25 { XCTAssertTrue(library.add(prepared, projectID: project)) }
        XCTAssertEqual(library.documents.count, 25)
        XCTAssertTrue(library.documents.allSatisfy(\.useInChat))
        XCTAssertTrue(library.attachments(for: project).isEmpty)
        let retrieved = try await library.attachments(for: project, query: "Reference")
        XCTAssertLessThanOrEqual(retrieved.count, 4)
        XCTAssertLessThanOrEqual(retrieved.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }, 24_000)
        XCTAssertEqual(AIMProjectDocumentLibrary(directory: directory).documents, library.documents)
    }

    func testProjectImportRejectsInvalidOversizedAndCancelledFilesBeforeCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appending(path: "broken.pdf")
        try Data("not a PDF".utf8).write(to: pdf)
        XCTAssertThrowsError(try AIMPreparedProjectDocument.read(pdf))
        let text = directory.appending(path: "oversized.txt")
        try Data(repeating: 65, count: ProjectSourceStore.maximumTextBytes + 1).write(to: text)
        XCTAssertThrowsError(try AIMPreparedProjectDocument.read(text))
        try Data("private local text".utf8).write(to: text)
        let task = Task { () throws -> AIMPreparedProjectDocument in
            withUnsafeCurrentTask { $0?.cancel() }
            return try AIMPreparedProjectDocument.read(text)
        }
        do { _ = try await task.value; XCTFail("Cancelled extraction must not reach a preview or commit") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: text), Data("private local text".utf8))
    }

    @MainActor
    func testProjectDocumentProfileBudgetIsBoundedAndReadFailurePreservesBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-budget-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "project-documents.json")
        try Data(repeating: 32, count: AIMProjectDocumentLibrary.maximumBytes + 1).write(to: url)
        let library = AIMProjectDocumentLibrary(directory: directory)
        XCTAssertNotNil(library.error)
        XCTAssertTrue(library.documents.isEmpty)
        XCTAssertFalse(library.delete(UUID()))
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, AIMProjectDocumentLibrary.maximumBytes + 1)
    }
}


extension LocalExperienceTests {
    @MainActor
    func testSourceRenameRefreshesTitleWithoutChangingContentIdentityOrExclusion() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-rename-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = AIMProjectDocumentLibrary(directory: directory), project = UUID()
        let prepared = AIMPreparedProjectDocument(name: "Test", mimeType: "text/plain", source: Data("Original fixture".utf8), text: "Retained verification reference")
        XCTAssertTrue(library.add(prepared, projectID: project))
        let before = try XCTUnwrap(library.documents.first)
        XCTAssertTrue(library.setUse(before.id, enabled: false))
        let renamed = await library.rename(before.id, projectID: project, name: "fiche-verification")
        XCTAssertTrue(renamed)
        let after = try XCTUnwrap(library.documents.first)
        XCTAssertEqual(after.id, before.id); XCTAssertEqual(after.name, "fiche-verification")
        XCTAssertEqual(after.importedAt, before.importedAt); XCTAssertEqual(after.mimeType, before.mimeType)
        XCTAssertFalse(after.useInChat); XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(try library.readText(after.id), prepared.text)
        XCTAssertEqual(try library.readOriginal(after.id), prepared.source)
        XCTAssertEqual(AIMProjectDocumentLibrary(directory: directory).documents, library.documents)
        let attachments = try await library.attachments(for: project, query: "verification")
        XCTAssertTrue(attachments.isEmpty)
    }
    @MainActor
    func testInvalidOrCancelledSourceRenameKeepsExistingPresentation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "project-rename-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = AIMProjectDocumentLibrary(directory: directory), project = UUID()
        XCTAssertTrue(library.add(.init(name: "Test", mimeType: "text/plain", source: Data([65]), text: "Original evidence"), projectID: project))
        let before = try XCTUnwrap(library.documents.first)
        let invalid = await library.rename(before.id, projectID: project, name: " ")
        XCTAssertFalse(invalid); XCTAssertEqual(library.documents, [before])
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await library.rename(before.id, projectID: project, name: "Cancelled")
        }
        let renamed = await task.value
        XCTAssertFalse(renamed); XCTAssertEqual(library.documents, [before])
        XCTAssertEqual(AIMProjectDocumentLibrary(directory: directory).documents, [before])
    }
}
