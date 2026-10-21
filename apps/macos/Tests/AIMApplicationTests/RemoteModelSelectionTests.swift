import AIMCore
import XCTest
@testable import AIMApplication

final class RemoteModelSelectionTests: XCTestCase {
    func testSavedUnavailableModelsKeepTheirReferenceWithoutExecutionAvailability() throws {
        let catalogue = [ChatModel(id: "present", name: "Present")]
        let pin = try FavoriteModel(provider: .anthropic, modelID: "retired", name: "Retired Claude")
        let announcements = RemoteModelCatalogMetadata.announcements(catalogue, provider: .anthropic, favorites: [pin], additions: ["anthropic:missing", "openrouter:other-route"])
        XCTAssertEqual(announcements.count, 3)
        XCTAssertEqual(announcements.first { $0.id == "present" }?.isAvailable, true)
        XCTAssertEqual(announcements.first { $0.id == "missing" }?.isAdded, true)
        XCTAssertEqual(announcements.first { $0.id == "missing" }?.isAvailable, false)
        XCTAssertEqual(announcements.first { $0.id == "retired" }?.name, "Retired Claude")
        XCTAssertEqual(announcements.first { $0.id == "retired" }?.isPinned, true)
        XCTAssertEqual(announcements.first { $0.id == "retired" }?.isAvailable, false)
        let disconnected = RemoteModelCatalogMetadata.announcements([], provider: .anthropic, favorites: [], additions: ["anthropic:missing"], available: false)
        XCTAssertEqual(disconnected.first?.isAvailable, false)
    }

    func testExplicitProviderControlsRouteAndLegacyAmbiguityIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ModelCatalogCache(directory: directory)
        let model = ChatModel(id: "shared-model", name: "Shared")
        try await cache.save([model], for: .openRouter)
        try await cache.save([model], for: .openAI)
        let connected: Set<ChatProvider> = [.openRouter, .openAI]
        let explicit = try await RemoteModelSelection.resolve(modelID: model.id, providerName: ChatProvider.openAI.rawValue, connected: connected, cache: cache)
        XCTAssertEqual(explicit, .openAI)
        do { _ = try await RemoteModelSelection.resolve(modelID: model.id, providerName: nil, connected: connected, cache: cache); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteModelSelectionError, .ambiguous) }
        let legacy = try await RemoteModelSelection.resolve(modelID: model.id, providerName: nil, connected: [.openRouter], cache: cache)
        XCTAssertEqual(legacy, .openRouter)
    }

    func testExplicitUnknownDisconnectedAndMissingCatalogNeverSubstitute() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ModelCatalogCache(directory: directory)
        try await cache.save([ChatModel(id: "shared-model", name: "Shared")], for: .openRouter)
        for name in ["unknown", ChatProvider.openAI.rawValue, ChatProvider.anthropic.rawValue] {
            do { _ = try await RemoteModelSelection.resolve(modelID: "shared-model", providerName: name, connected: [.openRouter, .anthropic], cache: cache); XCTFail() }
            catch { XCTAssertEqual(error as? RemoteModelSelectionError, .unavailable) }
        }
        do { _ = try await RemoteModelSelection.resolve(modelID: "absent", providerName: nil, connected: [.openRouter], cache: cache); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteModelSelectionError, .unavailable) }
    }
    func testRemoteLibraryOnlyIncludesExplicitAddsAndPins() throws {
        let featured = ChatModel(id: "claude-sonnet-5-fixture", name: "Fixture Sonnet")
        let ordinary = ChatModel(id: "older-fixture", name: "Older")
        let pin = try FavoriteModel(provider: .anthropic, modelID: "pinned-fixture", name: "Pinned")
        let values = RemoteModelCatalogMetadata.announcements([featured, ordinary], provider: .anthropic, favorites: [pin], additions: [])
        XCTAssertEqual(values.first { $0.id == featured.id }?.isFeatured, false)
        XCTAssertEqual(values.first { $0.id == featured.id }?.isAdded, false)
        XCTAssertEqual(values.first { $0.id == ordinary.id }?.isAdded, false)
        XCTAssertEqual(values.first { $0.id == "pinned-fixture" }?.isPinned, true)
        XCTAssertEqual(values.first { $0.id == "pinned-fixture" }?.isAvailable, false)
        let disconnected = RemoteModelCatalogMetadata.announcements([featured], provider: .anthropic, favorites: [], additions: [], available: false)
        XCTAssertEqual(disconnected.first?.isAvailable, false)
    }

}
