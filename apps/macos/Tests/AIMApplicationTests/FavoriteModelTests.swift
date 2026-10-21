import AIMApplication
import XCTest

final class FavoriteModelTests: XCTestCase {
    func testProviderIdentityIsolationAndToggleWithoutDuplicates() throws {
        let direct = try FavoriteModel(provider: .openAI, modelID: "same-model", name: "Direct")
        let router = try FavoriteModel(provider: .openRouter, modelID: "same-model", name: "Router")
        XCTAssertNotEqual(direct.id, router.id)
        let both = try FavoriteModel.toggling(router, in: [direct])
        XCTAssertEqual(both, [direct, router])
        XCTAssertEqual(try FavoriteModel.toggling(direct, in: both), [router])
        XCTAssertEqual(try FavoriteModel.toggling(direct, in: [direct, direct]), [])
    }

    func testFavoritesHaveNoArtificialCountQuotaAndNamesAreBounded() throws {
        let items = try (0..<200).map { try FavoriteModel(provider: .xAI, modelID: "fixture-\($0)", name: "Fixture") }
        let extra = try FavoriteModel(provider: .xAI, modelID: "extra", name: String(repeating: "n", count: 300))
        XCTAssertEqual(extra.name.count, 200)
        XCTAssertEqual(try FavoriteModel.toggling(extra, in: items).count, 201)
        XCTAssertEqual(try FavoriteModel.toggling(items[0], in: items).count, 199)
    }

    func testInvalidIdentifiersRejectedAndManualNameFallback() throws {
        for id in ["", "../model", "model?key=value", "white space", "model\0", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try FavoriteModel(provider: .google, modelID: id, name: "Name"))
        }
        let item = try FavoriteModel(provider: .google, modelID: "models/fixture", name: "")
        XCTAssertEqual(item.name, "models/fixture")
    }

    func testSettingsRoundTripAndBackwardCompatibility() throws {
        var settings = AppSettings()
        let old = try JSONEncoder().encode(settings)
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: old).favoriteModels)
        settings.favoriteModels = [try FavoriteModel(provider: .anthropic, modelID: "fixture", name: "Fixture")]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
