import XCTest
@testable import AIMCore

final class RemoteLayoutRulesTests: XCTestCase {
    func testDrawerGeometryMatchesTheMobileReference() {
        XCTAssertEqual(RemoteDrawerRules.width(containerWidth: 390), 343.2, accuracy: 0.001)
        XCTAssertEqual(RemoteDrawerRules.width(containerWidth: 430), 352, accuracy: 0.001)
        XCTAssertEqual(RemoteDrawerRules.width(containerWidth: 1_024), 352, accuracy: 0.001)

        XCTAssertEqual(RemoteDrawerRules.offset(isOpen: false, dragTranslation: 0, containerWidth: 390), 0)
        XCTAssertEqual(RemoteDrawerRules.offset(isOpen: false, dragTranslation: 120, containerWidth: 390), 120)
        XCTAssertEqual(RemoteDrawerRules.offset(isOpen: true, dragTranslation: -90, containerWidth: 390), 253.2, accuracy: 0.001)
        XCTAssertEqual(RemoteDrawerRules.offset(isOpen: true, dragTranslation: 80, containerWidth: 390), 343.2, accuracy: 0.001)
        XCTAssertEqual(RemoteDrawerRules.progress(offset: 171.6, containerWidth: 390), 0.5, accuracy: 0.001)

        XCTAssertTrue(RemoteDrawerRules.shouldOpen(currentlyOpen: false, translation: 100, predictedTranslation: 150, containerWidth: 390))
        XCTAssertFalse(RemoteDrawerRules.shouldOpen(currentlyOpen: false, translation: 40, predictedTranslation: 60, containerWidth: 390))
        XCTAssertFalse(RemoteDrawerRules.shouldOpen(currentlyOpen: true, translation: -100, predictedTranslation: -180, containerWidth: 390))
        XCTAssertTrue(RemoteDrawerRules.shouldOpen(currentlyOpen: true, translation: -30, predictedTranslation: -40, containerWidth: 390))
    }

    func testMobileSheetBoundsGeometryAndScrimMatchReference() {
        XCTAssertEqual(RemoteSheetRules.bottomMargin(safeBottom: 0, mobile: true), 8)
        XCTAssertEqual(RemoteSheetRules.bottomMargin(safeBottom: 34, mobile: true), 8)
        XCTAssertEqual(RemoteSheetRules.bottomMargin(safeBottom: 34, mobile: false), 50)

        let bounds = RemoteSheetRules.bounds(
            viewportHeight: 844,
            safeTop: 47,
            bottomGap: 8,
            compactRatio: 0.44
        )
        XCTAssertEqual(bounds, .init(expandedTop: 47, compactTop: 465, closedTop: 852))
        XCTAssertEqual(
            RemoteSheetRules.bounds(viewportHeight: 844, safeTop: 47, bottomGap: 8, compactRatio: 0.44, contentHeight: 200).compactTop,
            636
        )
        XCTAssertEqual(RemoteSheetRules.geometry(top: 465, bounds: bounds), .init(top: 465, translationY: 0, inset: 8, bottom: 8, bottomRadius: 32))
        XCTAssertEqual(RemoteSheetRules.geometry(top: 20, bounds: bounds), .init(top: 47, translationY: 0, inset: 0, bottom: 0, bottomRadius: 0))
        XCTAssertEqual(RemoteSheetRules.geometry(top: 256, bounds: bounds), .init(top: 256, translationY: 0, inset: 4, bottom: 4, bottomRadius: 16))
        XCTAssertEqual(RemoteSheetRules.geometry(top: 665, bounds: bounds), .init(top: 465, translationY: 200, inset: 8, bottom: 8, bottomRadius: 32))
        XCTAssertEqual(RemoteSheetRules.scrimOpacity(top: 852, bounds: bounds, dark: false), 0)
        XCTAssertEqual(RemoteSheetRules.scrimOpacity(top: 465, bounds: bounds, dark: false), 0.06)
        XCTAssertEqual(RemoteSheetRules.scrimOpacity(top: 47, bounds: bounds, dark: false), 0.2)
        XCTAssertEqual(RemoteSheetRules.scrimOpacity(top: 465, bounds: bounds, dark: true), 0.18)
        XCTAssertEqual(RemoteSheetRules.scrimOpacity(top: 47, bounds: bounds, dark: true), 0.4)
        XCTAssertEqual(RemoteSheetRules.scrimOpacity(top: 256, bounds: bounds, dark: false), 0.13)
    }

    func testContinuousSheetGestureSharesMovementWithScrollContent() {
        let bounds = RemoteSheetRules.bounds(viewportHeight: 844, safeTop: 47, bottomGap: 8, compactRatio: 0.44)
        XCTAssertEqual(RemoteSheetRules.axis(dx: 2, dy: 3), .undecided)
        XCTAssertEqual(RemoteSheetRules.axis(dx: -30, dy: 8), .horizontal)
        XCTAssertEqual(RemoteSheetRules.axis(dx: 3, dy: -12), .vertical)
        XCTAssertEqual(RemoteSheetRules.axis(dx: 5, dy: 5), .vertical)
        XCTAssertEqual(
            RemoteSheetRules.distribute(top: 465, scrollTop: 0, scrollMax: 500, delta: -120, bounds: bounds),
            .init(top: 345, scrollTop: 0)
        )
        XCTAssertEqual(
            RemoteSheetRules.distribute(top: 100, scrollTop: 0, scrollMax: 500, delta: -120, bounds: bounds),
            .init(top: 47, scrollTop: 67)
        )
        XCTAssertEqual(
            RemoteSheetRules.distribute(top: 47, scrollTop: 80, scrollMax: 500, delta: 50, bounds: bounds),
            .init(top: 47, scrollTop: 30)
        )
        XCTAssertEqual(
            RemoteSheetRules.distribute(top: 47, scrollTop: 30, scrollMax: 500, delta: 50, bounds: bounds),
            .init(top: 67, scrollTop: 0)
        )
        XCTAssertEqual(RemoteSheetRules.recentVelocity(points: [.init(time: 0, value: 400), .init(time: 60, value: 340)], now: 60), -1000)
        XCTAssertEqual(RemoteSheetRules.recentVelocity(points: [.init(time: 0, value: 400), .init(time: 60, value: 340)], now: 200), 0)
        XCTAssertEqual(RemoteSheetRules.destination(top: 210, velocityY: -600, bounds: .init(expandedTop: 47, compactTop: 457, closedTop: 860)), .expanded)
        XCTAssertEqual(RemoteSheetRules.destination(top: 720, velocityY: 900, bounds: .init(expandedTop: 47, compactTop: 457, closedTop: 860)), .closed)
    }

    func testComposerSwipeTitlesAndLanguageMatchReference() {
        let idle = RemoteComposerInput(focused: false, text: "", hasAttachments: false, hasActiveSecondaryState: false)
        XCTAssertEqual(RemoteComposerRules.state(for: idle), .compact)
        XCTAssertEqual(RemoteComposerRules.state(for: .init(focused: true, text: "", hasAttachments: false, hasActiveSecondaryState: false)), .expanded)
        XCTAssertEqual(RemoteComposerRules.state(for: .init(focused: false, text: "  \n", hasAttachments: false, hasActiveSecondaryState: false)), .compact)
        XCTAssertEqual(RemoteComposerRules.state(for: .init(focused: false, text: "Corrige le test", hasAttachments: false, hasActiveSecondaryState: false)), .expanded)
        XCTAssertEqual(RemoteComposerRules.state(for: .init(focused: false, text: "", hasAttachments: true, hasActiveSecondaryState: false)), .expanded)
        XCTAssertEqual(RemoteComposerRules.newSessionConfiguration, .init(largePrompt: false, initialLayout: true, expandedAtRest: true))

        XCTAssertEqual(RemoteSwipeRules.returnPath(from: "/code/session/abc"), "/code")
        XCTAssertEqual(RemoteSwipeRules.returnPath(from: "/agent/nouvelle"), "/agent")
        XCTAssertNil(RemoteSwipeRules.returnPath(from: "/chat/session/abc"))
        XCTAssertEqual(RemoteSwipeRules.action(sidebarOpen: false, canGoBack: true, deltaX: 90, fast: false, threshold: 70), .back)
        XCTAssertEqual(RemoteSwipeRules.action(sidebarOpen: false, canGoBack: false, deltaX: 90, fast: false, threshold: 70), .openSidebar)
        XCTAssertEqual(RemoteSwipeRules.action(sidebarOpen: false, canGoBack: true, deltaX: 40, fast: true, threshold: 70), .back)
        XCTAssertNil(RemoteSwipeRules.action(sidebarOpen: false, canGoBack: true, deltaX: 20, fast: false, threshold: 70))
        XCTAssertEqual(RemoteSwipeRules.action(sidebarOpen: true, canGoBack: true, deltaX: -90, fast: false, threshold: 70), .closeSidebar)

        for mode in RemoteMode.allCases {
            XCTAssertEqual(RemoteCreationTitles.keys(for: mode).count, 5)
            XCTAssertEqual(RemoteCreationTitles.key(for: mode, draw: 0), RemoteCreationTitles.keys(for: mode)[0])
            XCTAssertEqual(RemoteCreationTitles.key(for: mode, draw: 0.9999), RemoteCreationTitles.keys(for: mode)[4])
        }
        XCTAssertEqual(InterfaceLanguage.defaultLanguage(preferred: ["fr-FR", "en-US"]), .french)
        XCTAssertEqual(InterfaceLanguage.defaultLanguage(preferred: ["de-DE", "fr-CH"]), .french)
        XCTAssertEqual(InterfaceLanguage.defaultLanguage(preferred: ["es-ES"]), .english)
    }
}
