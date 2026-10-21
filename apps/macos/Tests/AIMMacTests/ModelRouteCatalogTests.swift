import AIMCore
import AIMApplication
import XCTest
@testable import AIMMac

final class ModelRouteCatalogTests: XCTestCase {
    @MainActor
    func testLibraryStartsEmptyAndOnlyExplicitAddsOrPinsAppear() throws {
        let store = ModelPickerStore()
        let first = ChatModel(id: "anthropic/claude-opus-5-fixture", name: "Fixture Opus")
        let second = ChatModel(id: "openai/gpt-6-fixture", name: "Fixture GPT")
        store.catalogs = [.openRouter: [first, second]]
        store.update(query: "", tab: .mine, providerFilter: nil, connected: [.openRouter], favorites: [], added: [])
        XCTAssertTrue(store.sections.isEmpty, "A catalog is not a personal library")
        XCTAssertFalse(store.hasSavedModels)
        store.update(query: "", tab: .add, providerFilter: nil, connected: [.openRouter], favorites: [], added: [])
        XCTAssertEqual(store.sections.flatMap(\.items).count, 2)
        XCTAssertTrue(store.sections.flatMap(\.items).allSatisfy { !$0.inSelection })
        store.update(query: "", tab: .mine, providerFilter: nil, connected: [.openRouter], favorites: [], added: ["openrouter:" + first.id])
        XCTAssertEqual(store.sections.flatMap(\.items).map(\.name), [ModelIdentity.displayName(first, via: .openRouter)])
        let pin = try FavoriteModel(provider: .openRouter, modelID: second.id, name: second.name)
        store.update(query: "", tab: .mine, providerFilter: nil, connected: [.openRouter], favorites: [pin], added: [])
        XCTAssertEqual(store.sections.flatMap(\.items).count, 1)
        XCTAssertTrue(store.sections.flatMap(\.items).first?.pinned == true)
        store.update(query: "", tab: .mine, providerFilter: nil, connected: [.openRouter], favorites: [], added: [])
        XCTAssertTrue(store.sections.isEmpty, "Removing the last selection must not restore defaults")
    }

    @MainActor
    func testDisconnectedCachedRouteAndLegacyFavoriteStayOnOneCard() throws {
        let store = ModelPickerStore(), owner = UUID()
        let direct = ChatModel(id: "claude-opus-5-5", name: "Claude Opus 5.5")
        let router = ChatModel(id: "anthropic/claude-opus-5.5", name: "Anthropic: Claude Opus 5.5")
        store.catalogs = [.anthropic: [direct], .openRouter: [router]]
        let favorite = try FavoriteModel(provider: .anthropic, modelID: direct.id, name: direct.name)
        store.update(query: "", tab: .mine, providerFilter: nil, connected: [.openRouter], favorites: [favorite], added: [], accountID: owner)
        let card = try XCTUnwrap(store.sections.flatMap(\.items).first)
        XCTAssertEqual(store.sections.flatMap(\.items).count, 1)
        XCTAssertEqual(card.entry.routes.count, 2)
        XCTAssertTrue(card.pinned)
        XCTAssertEqual(card.entry.provider, .openRouter)
        let key = CanonicalModelRouting.preferenceKey(account: owner, target: "mac:local", model: card.entry.id)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        store.setPreferredRoute(.anthropic, for: card.entry.id)
        XCTAssertEqual(store.sections.flatMap(\.items).first?.entry.provider, .anthropic)
        store.update(query: "", tab: .mine, providerFilter: nil, connected: [], favorites: [favorite], added: [], accountID: owner)
        XCTAssertEqual(store.sections.flatMap(\.items).count, 1)
        XCTAssertEqual(store.sections.flatMap(\.items).first?.entry.routes.count, 2)
    }
}
