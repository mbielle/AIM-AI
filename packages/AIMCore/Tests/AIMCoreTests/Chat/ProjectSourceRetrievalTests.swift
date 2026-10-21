import Foundation
import XCTest
@testable import AIMCore

final class ProjectSourceRetrievalTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-source-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testLargeSourcesAndOriginalAreRetainedBeyondOldProjectLimits() throws {
        let directory = try temporary(), project = UUID()
        let store = try ProjectSourceStore(directory: directory)
        let text = String(repeating: "Documented orbital mechanism.\n", count: 10_000)
        let original = Data("synthetic original bytes".utf8)
        let large = try store.add(projectID: project, name: "mechanism.txt", mimeType: "text/plain", text: text, original: original)
        XCTAssertTrue(large.useInChat); XCTAssertTrue(large.hasOriginal)
        XCTAssertLessThanOrEqual(large.preview.utf8.count, 4_000)
        XCTAssertEqual(try store.readText(large.id), text)
        XCTAssertEqual(try store.readOriginal(large.id), original)
        for index in 0..<24 { try store.add(projectID: project, name: "source-\(index).txt", mimeType: "text/plain", text: "Reference \(index)", original: nil) }
        let reopened = try ProjectSourceStore(directory: directory)
        XCTAssertEqual(try reopened.records(projectID: project).count, 25)
        XCTAssertEqual(try reopened.readText(large.id), text)
    }
    func testRetrievalRanksRelevantChunksAndCitesOnlyBoundedReferences() throws {
        let store = try ProjectSourceStore(directory: temporary()), project = UUID()
        let irrelevant = try store.add(projectID: project, name: "gardening.txt", mimeType: "text/plain", text: String(repeating: "Plant tomatoes in sunshine. ", count: 300), original: nil)
        let evidence = try store.add(projectID: project, name: "launch.txt", mimeType: "text/plain", text: String(repeating: "Ordinary project background. ", count: 300) + "\nQuasar propulsion launches on Tuesday.\n" + String(repeating: "Additional background. ", count: 300), original: nil)
        let excerpts = try store.search(projectID: project, query: "What is the Quasar propulsion launch?")
        XCTAssertFalse(excerpts.isEmpty)
        XCTAssertTrue(excerpts.allSatisfy { $0.sourceID == evidence.id && $0.sourceID != irrelevant.id })
        XCTAssertTrue(excerpts.contains { $0.text.contains("Quasar propulsion") })
        XCTAssertLessThanOrEqual(excerpts.count, 8)
        XCTAssertLessThanOrEqual(excerpts.reduce(0) { $0 + $1.text.utf8.count + $1.citation.utf8.count + $1.name.utf8.count + 128 }, 24_000)
        let first = try XCTUnwrap(excerpts.first)
        XCTAssertEqual(try store.readChunk(sourceID: first.sourceID, chunkIndex: first.chunkIndex, projectID: project), first)
        XCTAssertTrue(first.citation.hasPrefix("source:")); XCTAssertTrue(first.citation.contains("#"))
        XCTAssertTrue(try store.search(projectID: project, query: "").isEmpty)
        XCTAssertTrue(try store.search(projectID: project, query: "unmatchedsentinel").isEmpty)
        XCTAssertThrowsError(try store.search(projectID: project, query: String(repeating: "x", count: 8_001)))
    }
    func testProjectProfileAndDisabledSourcesCannotBeRetrievedOrReadByTool() throws {
        let directory = try temporary(), project = UUID(), other = UUID()
        let store = try ProjectSourceStore(directory: directory.appendingPathComponent("profile-a"))
        let excluded = try store.add(projectID: project, name: "private-cv.txt", mimeType: "text/plain", text: "Cedar curriculum vitae sensitive fact", original: nil, enabled: false)
        try store.add(projectID: other, name: "other.txt", mimeType: "text/plain", text: "Cedar other project fact", original: nil)
        XCTAssertTrue(try store.search(projectID: project, query: "Cedar").isEmpty)
        XCTAssertThrowsError(try store.readChunk(sourceID: excluded.id, chunkIndex: 0, projectID: project))
        try store.setEnabled(excluded.id, enabled: true)
        XCTAssertEqual(try store.search(projectID: project, query: "Cedar").map(\.sourceID), [excluded.id])
        XCTAssertThrowsError(try store.readChunk(sourceID: excluded.id, chunkIndex: 0, projectID: other))
        let profileB = try ProjectSourceStore(directory: directory.appendingPathComponent("profile-b"))
        XCTAssertTrue(try profileB.search(projectID: project, query: "Cedar").isEmpty)
        XCTAssertThrowsError(try profileB.readText(excluded.id))
    }
    func testFrenchAccentAndJapaneseRetrievalRemainOnDevice() throws {
        let store = try ProjectSourceStore(directory: temporary()), project = UUID()
        let french = try store.add(projectID: project, name: "réunion.txt", mimeType: "text/plain", text: "La réunion présente une stratégie énergétique à Montréal.", original: nil)
        let japanese = try store.add(projectID: project, name: "voyage.txt", mimeType: "text/plain", text: "東京旅行の予定。京都のホテルを予約しました。", original: nil)
        XCTAssertEqual(try store.search(projectID: project, query: "strategie energetique Montreal").first?.sourceID, french.id)
        XCTAssertEqual(try store.search(projectID: project, query: "京都 ホテル").first?.sourceID, japanese.id)
    }
    func testLegacyMigrationPreservesPrivateOptOutIDsDatesTextAndOriginalJSON() throws {
        struct Old: Codable { let id: UUID, projectID: UUID, name: String, mimeType: String, sourceBytes: Int, text: String, importedAt: Date, useInChat: Bool }
        let directory = try temporary(), project = UUID(), id = UUID(), date = Date(timeIntervalSince1970: 1_000)
        let old = [Old(id: id, projectID: project, name: "private-cv.txt", mimeType: "text/plain", sourceBytes: 987, text: "Curriculum original retained", importedAt: date, useInChat: false), Old(id: UUID(), projectID: project, name: "public.txt", mimeType: "text/plain", sourceBytes: 123, text: "Enabled reference", importedAt: date, useInChat: true)]
        let bytes = try JSONEncoder().encode(old), legacy = directory.appendingPathComponent("project-documents.json")
        try bytes.write(to: legacy)
        let store = try ProjectSourceStore(directory: directory)
        let records = try store.records(projectID: project)
        let cv = try XCTUnwrap(records.first { $0.id == id })
        XCTAssertFalse(cv.useInChat); XCTAssertFalse(cv.hasOriginal); XCTAssertEqual(cv.importedAt, date)
        XCTAssertEqual(try store.readText(id), old[0].text)
        XCTAssertThrowsError(try store.readOriginal(id)) // Legacy implementation never retained originals.
        XCTAssertTrue(try store.search(projectID: project, query: "Curriculum").isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try ProjectSourceStore(directory: directory).records().count, 2) // Idempotent.
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        try store.rename(id, projectID: project, name: "fiche-verification")
        let renamed = try XCTUnwrap(store.records(sourceID: id).first)
        XCTAssertFalse(renamed.useInChat); XCTAssertFalse(renamed.hasOriginal)
        XCTAssertEqual(try store.readText(id), old[0].text)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }
    func testCorruptLegacyAndDatabaseFailClosedWithoutOverwritingExistingBytes() throws {
        let directory = try temporary(), legacy = directory.appendingPathComponent("project-documents.json")
        let bytes = Data("corrupt private legacy bytes".utf8); try bytes.write(to: legacy)
        XCTAssertThrowsError(try ProjectSourceStore(directory: directory))
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        let other = try temporary(), db = other.appendingPathComponent("project-sources-v2/index.sqlite")
        do { _ = try ProjectSourceStore(directory: other) }
        let corrupt = Data("unreadable index".utf8); try corrupt.write(to: db)
        XCTAssertThrowsError(try ProjectSourceStore(directory: other))
        XCTAssertEqual(try Data(contentsOf: db), corrupt)
    }
    func testQuotasRejectWholeImportAndRetainPreviousSources() throws {
        let directory = try temporary(), project = UUID()
        let store = try ProjectSourceStore(directory: directory, quotaBytes: 200_000, projectLimit: 2)
        let first = try store.add(projectID: project, name: "first.txt", mimeType: "text/plain", text: "Preserved first evidence", original: Data([1, 2, 3]))
        try store.add(projectID: project, name: "second.txt", mimeType: "text/plain", text: "Second evidence", original: nil)
        XCTAssertThrowsError(try store.add(projectID: project, name: "third.txt", mimeType: "text/plain", text: "Third", original: nil))
        XCTAssertThrowsError(try store.add(projectID: UUID(), name: "disk.txt", mimeType: "text/plain", text: "Disk budget", original: Data(repeating: 1, count: 200_000)))
        XCTAssertEqual(try store.records().count, 2)
        XCTAssertEqual(try store.readOriginal(first.id), Data([1, 2, 3]))
        XCTAssertEqual(try ProjectSourceStore(directory: directory).records().count, 2)
        let payloads = directory.appendingPathComponent("project-sources-v2/payloads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: payloads.path).count, 2)
    }
    func testDeleteRemovesIndexAndPayloadWithoutTouchingOtherSource() throws {
        let directory = try temporary(), project = UUID(), store = try ProjectSourceStore(directory: directory)
        let first = try store.add(projectID: project, name: "first", mimeType: "text/plain", text: "Deletion sentinel", original: Data([1]))
        let second = try store.add(projectID: project, name: "second", mimeType: "text/plain", text: "Retained sentinel", original: Data([2]))
        try store.remove(first.id)
        XCTAssertThrowsError(try store.readText(first.id)); XCTAssertTrue(try store.search(projectID: project, query: "Deletion").isEmpty)
        XCTAssertEqual(try store.readOriginal(second.id), Data([2]))
        XCTAssertEqual(try ProjectSourceStore(directory: directory).records().map(\.id), [second.id])
    }
    func testCancellationLeavesNoPartiallyImportedSource() async throws {
        let directory = try temporary(), store = try ProjectSourceStore(directory: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try store.add(projectID: UUID(), name: "cancelled", mimeType: "text/plain", text: "Cancelled text", original: nil)
        }
        do { _ = try await task.value; XCTFail("Cancelled import committed") } catch is CancellationError { }
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("project-sources-v2/payloads").path).count, 0)
    }
    func testProjectExtractionIsLargerWithoutRelaxingChatAttachmentLimits() throws {
        let file = try temporary().appendingPathComponent("long.txt")
        let text = String(repeating: "Long source reference.\n", count: 10_000)
        try Data(text.utf8).write(to: file)
        XCTAssertThrowsError(try NativeDocumentImporter.read(file))
        XCTAssertEqual(try NativeDocumentImporter.read(file, limits: .project).content, text)
        XCTAssertThrowsError(try NativeDocumentSnapshot.validate([.init(name: "long.txt", content: text)]))
    }
    func testQueryTermAtChunkBoundaryAndChunkBudgetArePreserved() throws {
        let store = try ProjectSourceStore(directory: temporary()), project = UUID()
        let text = String(repeating: "x ", count: 997) + "boundarysentinel relevant evidence " + String(repeating: "z ", count: 2_000)
        let source = try store.add(projectID: project, name: "boundary.txt", mimeType: "text/plain", text: text, original: nil)
        let found = try store.search(projectID: project, query: "boundarysentinel")
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { $0.sourceID == source.id && $0.text.utf8.count <= 2_000 })
        XCTAssertTrue(found.contains { $0.text.contains("boundarysentinel") })
    }
    func testInterruptedDeletionRestoresOnlyItsReferencedPayload() throws {
        let directory = try temporary(), project = UUID()
        let record: ProjectSourceRecord
        do {
            let store = try ProjectSourceStore(directory: directory)
            record = try store.add(projectID: project, name: "retained.txt", mimeType: "text/plain", text: "Recoverable private evidence", original: Data([4, 5]))
        }
        let root = directory.appendingPathComponent("project-sources-v2")
        try FileManager.default.moveItem(at: root.appendingPathComponent("payloads/" + record.id.uuidString), to: root.appendingPathComponent("removed-" + record.id.uuidString))
        let reopened = try ProjectSourceStore(directory: directory)
        XCTAssertEqual(try reopened.readOriginal(record.id), Data([4, 5]))
        XCTAssertEqual(try reopened.readText(record.id), "Recoverable private evidence")
    }
    func testCorruptOrRedirectedPayloadCannotBeSubstitutedOnReopen() throws {
        let directory = try temporary(), other = try temporary(), project = UUID()
        let record: ProjectSourceRecord
        do { record = try ProjectSourceStore(directory: directory).add(projectID: project, name: "private.txt", mimeType: "text/plain", text: "Local owner evidence", original: nil) }
        let payload = directory.appendingPathComponent("project-sources-v2/payloads/" + record.id.uuidString)
        try FileManager.default.moveItem(at: payload, to: other.appendingPathComponent("preserved"))
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: other.appendingPathComponent("preserved"))
        XCTAssertThrowsError(try ProjectSourceStore(directory: directory))
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("preserved/text.utf8"), encoding: .utf8), "Local owner evidence")
    }
    func testRenameRetainsIdentityPayloadsCitationsAndReindexesTitle() throws {
        let directory = try temporary(), project = UUID()
        let store = try ProjectSourceStore(directory: directory)
        let text = String(repeating: "Documented travel timetable. ", count: 200)
        let original = Data("Original binary fixture".utf8)
        let before = try store.add(projectID: project, name: "Test", mimeType: "application/octet-stream", text: text, original: original)
        let storedBeforeDate = try XCTUnwrap(store.records(sourceID: before.id).first).importedAt
        let prior = try store.search(projectID: project, query: "Test")
        XCTAssertFalse(prior.isEmpty)
        try store.rename(before.id, projectID: project, name: " fiche-verification ")
        let reopened = try ProjectSourceStore(directory: directory)
        let after = try XCTUnwrap(reopened.records(projectID: project).first)
        XCTAssertEqual(after.name, "fiche-verification"); XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.projectID, before.projectID); XCTAssertEqual(after.mimeType, before.mimeType)
        XCTAssertEqual(after.sourceBytes, before.sourceBytes); XCTAssertEqual(after.textBytes, before.textBytes)
        XCTAssertEqual(after.importedAt, storedBeforeDate); XCTAssertEqual(after.preview, before.preview)
        XCTAssertEqual(after.hasOriginal, before.hasOriginal); XCTAssertEqual(after.useInChat, before.useInChat)
        XCTAssertEqual(try reopened.readText(before.id), text); XCTAssertEqual(try reopened.readOriginal(before.id), original)
        XCTAssertTrue(try reopened.search(projectID: project, query: "Test").isEmpty)
        let found = try reopened.search(projectID: project, query: "verification")
        XCTAssertEqual(found.map(\.citation), prior.map(\.citation))
        XCTAssertEqual(found.map(\.text), prior.map(\.text))
        XCTAssertTrue(found.allSatisfy { $0.name == "fiche-verification" })
    }
    func testRenameKeepsExclusionAndCannotCrossProjectOrProfile() throws {
        let directory = try temporary(), project = UUID(), other = UUID()
        let store = try ProjectSourceStore(directory: directory.appendingPathComponent("owner-a"))
        let source = try store.add(projectID: project, name: "Private CV", mimeType: "text/plain", text: "Retained private evidence", original: Data([3, 4]), enabled: false)
        XCTAssertThrowsError(try store.rename(source.id, projectID: other, name: "Wrong project"))
        let foreign = try ProjectSourceStore(directory: directory.appendingPathComponent("owner-b"))
        XCTAssertThrowsError(try foreign.rename(source.id, projectID: project, name: "Wrong profile"))
        try store.rename(source.id, projectID: project, name: "fiche-verification")
        let after = try XCTUnwrap(store.records(sourceID: source.id).first)
        XCTAssertFalse(after.useInChat)
        XCTAssertTrue(try store.search(projectID: project, query: "verification private").isEmpty)
        XCTAssertThrowsError(try store.readChunk(sourceID: source.id, chunkIndex: 0, projectID: project))
        XCTAssertEqual(try store.readOriginal(source.id), Data([3, 4]))
    }
    func testInvalidRenameLeavesStoredNameAndIndexUnchanged() throws {
        let store = try ProjectSourceStore(directory: temporary()), project = UUID()
        let source = try store.add(projectID: project, name: "Originaltitle", mimeType: "text/plain", text: "Retained evidence", original: nil)
        let baseline = try XCTUnwrap(store.records(sourceID: source.id).first)
        let invalid = ["", " ", "nested/name", "back\\slash", "bad\nname", "null\0name", String(repeating: "x", count: 256), "e" + String(repeating: "\u{301}", count: 600)]
        for name in invalid {
            XCTAssertThrowsError(try store.rename(source.id, projectID: project, name: name))
        }
        XCTAssertEqual(try store.records(sourceID: source.id).first, baseline)
        XCTAssertFalse(try store.search(projectID: project, query: "Originaltitle").isEmpty)
    }
    func testRenameQuotaFailureRollsBackMetadataAndEveryChunkIndex() throws {
        let directory = try temporary(), project = UUID()
        let store = try ProjectSourceStore(directory: directory)
        let source = try store.add(projectID: project, name: "Originaltitle", mimeType: "text/plain", text: String(repeating: "Reference content available. ", count: 2_500), original: nil)
        let baseline = try XCTUnwrap(store.records(sourceID: source.id).first)
        let root = directory.appendingPathComponent("project-sources-v2")
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        var retainedBytes = 0
        for case let file as URL in iterator {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if attributes.isRegularFile == true { retainedBytes += attributes.fileSize ?? 0 }
        }
        let tight = try ProjectSourceStore(directory: directory, quotaBytes: retainedBytes + 4_096)
        XCTAssertThrowsError(try tight.rename(source.id, projectID: project, name: String(repeating: "東京旅館", count: 60))) { error in
            guard case ProjectSourceError.quota = error else { return XCTFail("Expected the final index quota check to roll back the rename") }
        }
        XCTAssertEqual(try tight.records(sourceID: source.id).first, baseline)
        XCTAssertFalse(try tight.search(projectID: project, query: "Originaltitle").isEmpty)
        XCTAssertTrue(try tight.search(projectID: project, query: "東京旅館").isEmpty)
    }
    func testCancelledRenameRetainsOriginalTitleAndPayload() async throws {
        let store = try ProjectSourceStore(directory: temporary()), project = UUID()
        let source = try store.add(projectID: project, name: "Originaltitle", mimeType: "text/plain", text: "Private source evidence", original: Data([5]))
        let baseline = try XCTUnwrap(store.records(sourceID: source.id).first)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try store.rename(source.id, projectID: project, name: "Cancelledtitle")
        }
        do { try await task.value; XCTFail("A cancelled rename must not commit") } catch is CancellationError { }
        XCTAssertEqual(try store.records(sourceID: source.id).first, baseline)
        XCTAssertEqual(try store.readOriginal(source.id), Data([5]))
    }

}
