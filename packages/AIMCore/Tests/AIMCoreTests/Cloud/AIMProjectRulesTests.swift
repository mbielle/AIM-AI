import XCTest
@testable import AIMCore

final class AIMProjectRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testFavoriteAndRecentScopesMatchProductRules() {
        let recentFavorite = project("1", "Recent favorite", daysAgo: 5, favorite: true)
        let oldFavorite = project("2", "Old favorite", daysAgo: 45, favorite: true)
        let recentRegular = project("3", "Recent regular", daysAgo: 29, favorite: false)
        let boundaryOld = project("4", "Boundary old", daysAgo: 31, favorite: false)
        let projects = [boundaryOld, recentRegular, oldFavorite, recentFavorite]

        XCTAssertEqual(
            AIMProjectRules.filtered(projects, scope: .favorites, query: "", now: now).map(\.id),
            ["1", "2"]
        )
        XCTAssertEqual(
            Set(AIMProjectRules.filtered(projects, scope: .recent, query: "", now: now).map(\.id)),
            Set(["1", "3"])
        )
    }

    func testSearchMatchesNameOrDescriptionAndTrimsWhitespace() {
        let projects = [
            project("1", "Release notes", description: "Shipping checklist", daysAgo: 2),
            project("2", "Design", description: "Liquid glass exploration", daysAgo: 1),
        ]

        XCTAssertEqual(
            AIMProjectRules.filtered(projects, scope: .all, query: "  glass ", now: now).map(\.id),
            ["2"]
        )
        XCTAssertEqual(
            AIMProjectRules.filtered(projects, scope: .all, query: "release", now: now).map(\.id),
            ["1"]
        )
    }

    private func project(
        _ id: String,
        _ name: String,
        description: String? = nil,
        daysAgo: Int,
        favorite: Bool = false
    ) -> AIMProject {
        let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -daysAgo, to: now)!
        return .init(
            id: id,
            name: name,
            description: description,
            createdAt: date,
            updatedAt: date,
            lastActiveAt: date,
            isStarred: favorite
        )
    }
}
