import XCTest

@MainActor final class AIMProjectNavigationUITests: XCTestCase {
    private func app(budgetError: Bool = false, estimatedBudget: Bool = false, projectCitation: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIM_UI_TEST_SCENARIO"] = "authenticatedUnpaired"
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launchEnvironment["AIM_UI_TEST_PROJECT_HOME"] = "1"
        app.launchEnvironment["AIM_UI_TEST_FAKE_CAMERA"] = "1"
        app.launchEnvironment["AIM_UI_TEST_FAKE_PHOTOS"] = "1"
        if budgetError { app.launchEnvironment["AIM_UI_TEST_WEB_BUDGET_ERROR"] = "1" }
        if estimatedBudget { app.launchEnvironment["AIM_UI_TEST_ESTIMATED_WEB_BUDGET"] = "1" }
        if projectCitation { app.launchEnvironment["AIM_UI_TEST_PROJECT_CITATION"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AIMPrivateApplicationModeEnabled", "YES"]
        app.launch()
        return app
    }
    private func openProject(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-projects"].tap()
        app.staticTexts["Project Home Fixture"].tap()
        XCTAssertTrue(app.buttons["project-home-actions"].waitForExistence(timeout: 3))
    }
    private func openConversation(_ app: XCUIApplication) {
        openProject(app)
        app.descendants(matching: .any)["project-chat-E16A719B-AFE5-4B99-8198-6CD3C3A71422"].tap()
        XCTAssertTrue(app.buttons["native-chat-project-back"].waitForExistence(timeout: 5))
    }
    private func swipeBack(_ app: XCUIApplication, short: Bool = false) {
        let screen = app.windows.firstMatch
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.42))
        let end = screen.coordinate(withNormalizedOffset: CGVector(dx: short ? 0.10 : 0.86, dy: 0.42))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }
    func testSwipeBackFollowsProjectHierarchyAndShortDragKeepsConversation() {
        let app = app(); openConversation(app)
        swipeBack(app, short: true)
        XCTAssertTrue(app.buttons["native-chat-project-back"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["project-home-actions"].exists)
        XCTAssertTrue(app.staticTexts["Can you help me plan the next AIM update?"].exists)
        swipeBack(app)
        XCTAssertTrue(app.buttons["project-home-actions"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["project-tab-sources"].exists)
        XCTAssertFalse(app.buttons["profile-menu"].isHittable)
        swipeBack(app)
        XCTAssertTrue(app.buttons["native-new-project"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["project-home-actions"].exists)
        XCTAssertFalse(app.buttons["profile-menu"].isHittable)
        swipeBack(app)
        XCTAssertTrue(app.buttons["profile-menu"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["profile-menu"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "project-hierarchical-back-sidebar"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testProjectCitationShowsReadableFileInsteadOfInternalLocator() {
        let app = app(projectCitation: true); openConversation(app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Test.txt")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "source:a47bf229")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "chunk 0")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "readable-project-citation"; shot.lifetime = .keepAlways; add(shot)
    }
    func testResponseInformationIsAvailableFromCompactActions() {
        let app = app(projectCitation: true); openConversation(app)
        let information = app.buttons["chat-response-information"]
        XCTAssertTrue(information.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Costs are estimates when available, not a provider invoice."].exists)
        XCTAssertFalse(app.staticTexts["Unreported web-search fees are excluded from this estimate."].exists)
        information.tap()
        XCTAssertTrue(app.staticTexts["Response information"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Costs are estimates when available, not a provider invoice."].exists)
        XCTAssertTrue(app.staticTexts["Unreported web-search fees are excluded from this estimate."].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "compact-response-information"; shot.lifetime = .keepAlways; add(shot)
    }
    func testEstimatedWebBudgetKeepsDisclosureInSettingsInsteadOfComposer() {
        let app = app(estimatedBudget: true)
        XCTAssertTrue(app.textViews["native-chat-message-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["native-chat-web-budget-estimate"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["native-chat-error-notice"].exists)
        XCTAssertEqual(app.textViews["native-chat-message-field"].value as? String, "Synthetic budgeted question")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "estimated-web-budget-coverage"; shot.lifetime = .keepAlways; add(shot)
    }
    func testTopErrorCanBeDismissedWithoutMovingComposerOrLosingKeyboardDraft() {
        let app = app(budgetError: true)
        let field = app.textViews["native-chat-message-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let before = field.frame
        let dismiss = app.buttons["native-chat-error-dismiss"]
        XCTAssertLessThan(dismiss.frame.maxY, before.minY)
        dismiss.tap()
        XCTAssertTrue(app.descendants(matching: .any)["native-chat-error-notice"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(field.frame.minY, before.minY, accuracy: 2)
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertEqual(field.value as? String, "Synthetic budgeted question")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "top-error-composer-keyboard-preserved"; shot.lifetime = .keepAlways; add(shot)
    }
    func testErrorExpandsInlineWithoutAnInfoPopoverAndPreservesDraft() {
        let app = app(budgetError: true)
        let field = app.textViews["native-chat-message-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let notice = app.descendants(matching: .any)["native-chat-error-notice"]
        let collapsedHeight = notice.frame.height
        XCTAssertFalse(app.buttons["native-chat-error-details"].exists)
        let expand = app.buttons["native-chat-error-expand"]
        XCTAssertEqual(expand.value as? String, "Collapsed")
        expand.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(expand.value as? String, "Expanded")
        XCTAssertGreaterThan(notice.frame.height, collapsedHeight)
        XCTAssertEqual(field.value as? String, "Synthetic budgeted question")
        XCTAssertTrue(app.buttons["native-chat-disable-web-search"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "inline-error-expanded-keyboard-dismissed"; shot.lifetime = .keepAlways; add(shot)
        expand.tap()
        XCTAssertEqual(expand.value as? String, "Collapsed")
        XCTAssertEqual(notice.frame.height, collapsedHeight, accuracy: 2)
        XCTAssertEqual(field.value as? String, "Synthetic budgeted question")
    }
    func testBackButtonsMatchSwipeHierarchy() {
        let app = app(); openConversation(app)
        app.buttons["native-chat-project-back"].tap()
        XCTAssertTrue(app.buttons["project-home-actions"].waitForExistence(timeout: 3))
        app.buttons["project-home-back"].tap()
        XCTAssertTrue(app.buttons["native-new-project"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["project-home-actions"].exists)
    }
    func testBudgetNoticeHasOneRecoveryActionAndDoesNotSend() {
        let app = app(budgetError: true)
        let notice = app.descendants(matching: .any)["native-chat-error-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "native-chat-disable-web-search").count, 1)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "web-budget-explicit-recovery"; before.lifetime = .keepAlways; add(before)
        app.buttons["native-chat-disable-web-search"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.textViews["native-chat-message-field"].value as? String, "Synthetic budgeted question")
        XCTAssertTrue(app.buttons["main-menu-button"].exists)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "web-budget-draft-preserved"; after.lifetime = .keepAlways; add(after)
        // The separate unit tests prove budget/model preservation and zero requests;
        // this test only qualifies the actual recovery control and its presentation.
    }
}
