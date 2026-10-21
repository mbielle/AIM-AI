import AIMApplication
import XCTest

final class ModelCatalogPresentationTests: XCTestCase {
    func testOpenRouterModelUsesCreatorAndShortComposerName() {
        let model = ChatModel(id: "anthropic/claude-opus-5", name: "Anthropic: Claude Opus 5")
        XCTAssertEqual(ModelIdentity.creator(for: model, via: .openRouter), "anthropic")
        XCTAssertEqual(ModelIdentity.displayName(model, via: .openRouter), "Claude Opus 5")
    }

    func testRecentUsesDatesAndOmitsSnapshotsWithoutChangingCatalog() {
        let models = [
            ChatModel(id: "vendor/old-99", name: "Old", created: 1),
            ChatModel(id: "vendor/new-2", name: "New", created: 3),
            ChatModel(id: "vendor/new-2-2026-09-01", name: "Snapshot", created: 4),
            ChatModel(id: "vendor/undated", name: "Undated")
        ]
        XCTAssertEqual(ModelCatalogPresentation.recent(models).map(\.id), ["vendor/new-2", "vendor/old-99", "vendor/undated"])
        XCTAssertEqual(models.count, 4)
    }

    func testCatalogCacheKeepsStaleModelsForOfflineUse() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "aim-catalog-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ModelCatalogCache(directory: directory)
        let models = [ChatModel(id: "anthropic/claude-opus-5", name: "Claude Opus 5")]
        try await cache.save(models, for: .openRouter, at: Date(timeIntervalSinceNow: -26 * 60 * 60))
        let newInstance = ModelCatalogCache(directory: directory)
        let cached = await newInstance.cached(.openRouter)
        let fresh = await newInstance.isFresh(.openRouter)
        XCTAssertEqual(cached?.map(\.id), models.map(\.id))
        XCTAssertFalse(fresh)
    }
    func testCatalogPublicationRevisionAdvancesOnSaveAndDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ModelCatalogCache(directory: directory)
        let initial = await cache.revision
        XCTAssertEqual(initial, 0)
        try await cache.save([ChatModel(id: "fixture-model", name: "Fixture")], for: .anthropic)
        let saved = await cache.revision
        XCTAssertGreaterThan(saved, initial)
        _ = await cache.cached(.anthropic)
        let afterRead = await cache.revision
        XCTAssertEqual(saved, afterRead, "Reading must not create endless remote refreshes")
        await cache.invalidate(.anthropic)
        let removed = await cache.revision
        XCTAssertGreaterThan(removed, saved)
        let models = await cache.cached(.anthropic)
        XCTAssertNil(models)
    }

}
