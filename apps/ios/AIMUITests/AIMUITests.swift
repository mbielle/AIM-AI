import XCTest

final class AIMUITests: XCTestCase {
    @MainActor
    private func openNativeModelPicker(_ app: XCUIApplication) {
        let button = app.buttons["native-chat-model-button"]
        if !button.isHittable {
            let launcher = app.buttons["native-chat-message-field-launcher"]
            XCTAssertTrue(launcher.waitForExistence(timeout: 3))
            launcher.tap()
        }
        let ready = NSPredicate(format: "hittable == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: button)], timeout: 5), .completed)
        button.tap()
    }

    @MainActor
    func testDirectConnectionUsesFocusedPairingAndKeepsInvalidManualLinkLocal() {
        verifyDirectConnectionPanel(language: "en", dark: false, largeText: false)
    }

    @MainActor
    func testDirectConnectionFrenchDarkLargeText() {
        verifyDirectConnectionPanel(language: "fr", dark: true, largeText: true)
    }

    @MainActor
    private func verifyDirectConnectionPanel(language: String, dark: Bool, largeText: Bool) {
        let app = makeApp(language: language)
        app.launchEnvironment["AIM_UI_TEST_CONFIGURATION"] = "missing"
        app.launchArguments += ["-aim.appearance", dark ? "dark" : "light"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["native-chat-status"].waitForExistence(timeout: 10))
        app.buttons["native-chat-status"].tap()
        let connection = app.buttons[language == "fr" ? "Gérer les Mac" : "Manage Macs"]
        XCTAssertTrue(app.buttons[language == "fr" ? "Cet iPhone" : "This iPhone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.collectionViews.firstMatch.buttons["Choose model"].exists)
        keepScreenshot(named: "execution-device-menu-" + language, app: app)
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        connection.tap()
        let panel = app.descendants(matching: .any)["direct-computer-connections"].firstMatch
        if !panel.waitForExistence(timeout: 5), connection.exists, connection.isHittable {
            // Native menu presentation can consume a tap during its opening animation.
            connection.tap()
        }
        guard panel.waitForExistence(timeout: 5) else { XCTFail("Connection panel did not open"); return }
        let add = app.buttons["direct-add-mac"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["direct-pairing-link"].exists)
        keepScreenshot(named: "direct-connection-focused-home-" + language, app: app)
        add.tap()
        let manual = app.buttons["direct-manual-pairing"]
        let pairingForm = app.collectionViews["direct-pairing-form"]
        for _ in 0..<8 where !manual.exists || !manual.isHittable { pairingForm.swipeUp() }
        XCTAssertTrue(manual.waitForExistence(timeout: 5)); manual.tap()
        let field = app.textFields["direct-pairing-link"].exists ? app.textFields["direct-pairing-link"] : app.textViews["direct-pairing-link"]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText("invalid-link")
        app.buttons[language == "fr" ? "Vérifier ce Mac" : "Verify this Mac"].tap()
        let invalid = app.descendants(matching: .any)["direct-invalid-code"].firstMatch
        XCTAssertTrue(invalid.waitForExistence(timeout: 3))
        // A SwiftUI Label can expose a non-hittable accessibility container even
        // when its text is visible; visibility is geometric, not a tap target.
        for _ in 0..<8 where !app.frame.intersects(invalid.frame) { pairingForm.swipeUp() }
        XCTAssertFalse(invalid.frame.isEmpty)
        XCTAssertTrue(app.frame.intersects(invalid.frame))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["direct-confirm-mac"].exists)
        keepScreenshot(named: "direct-connection-invalid-manual-link-" + language, app: app)
    }

    @MainActor
    func testDirectScannerRepeatedPresentationAndDismissalOnSimulator() {
        let app = makeApp(language: "en")
        app.launchEnvironment["AIM_UI_TEST_CONFIGURATION"] = "missing"
        app.launch()
        XCTAssertTrue(app.buttons["native-chat-status"].waitForExistence(timeout: 10))
        app.buttons["native-chat-status"].tap()
        let connection = app.buttons["Manage Macs"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5)); connection.tap()
        let panel = app.descendants(matching: .any)["direct-computer-connections"].firstMatch
        if !panel.waitForExistence(timeout: 5), connection.exists, connection.isHittable { connection.tap() }
        guard panel.waitForExistence(timeout: 5) else { XCTFail("Connection panel did not open"); return }
        for _ in 0..<5 {
            app.buttons["direct-add-mac"].tap()
            let close = app.buttons["direct-close-pairing"]
            XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
            XCTAssertTrue(app.buttons["direct-add-mac"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.state, .runningForeground)
        }
        keepScreenshot(named: "direct-scanner-repeated-dismissal", app: app)
    }

    @MainActor
    func testLegacyOAuthNoticeDoesNotDisableNativeMCP() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchArguments += ["-AIMPrivateApplicationModeEnabled", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 10))
        app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        let plugins = app.buttons["settings-plugins-row"]
        for _ in 0..<8 where !plugins.isHittable { root.swipeUp() }
        XCTAssertTrue(plugins.isHittable); plugins.tap()
        let form = app.descendants(matching: .any)["settings-page-form"]
        let native = app.buttons["Add HTTPS connector"]
        for _ in 0..<6 where !native.isHittable { form.swipeUp() }
        XCTAssertTrue(native.isEnabled)
        let manage = app.buttons["Manage web accounts"]
        for _ in 0..<6 where !manage.isHittable { form.swipeDown() }
        XCTAssertTrue(manage.isHittable); manage.tap()
        let add = app.buttons["add-connector-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); XCTAssertFalse(add.isEnabled)
        XCTAssertTrue(app.staticTexts["legacy-oauth-broker-unconfigured"].exists)
    }

    @MainActor
    func testLocalLaunchDoesNotRequireAuthentication() {
        let app = XCUIApplication()
        app.launchEnvironment["AIM_UI_TEST_CONFIGURATION"] = "missing"
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["apple-sign-in"].exists)
        app.buttons["main-menu-button"].tap()
        app.buttons["profile-menu"].tap()
        let connect = app.buttons["settings-connect-account"]
        let root = app.descendants(matching: .any)["settings-root-screen"]
        for _ in 0..<12 where !connect.isHittable { root.swipeUp() }
        XCTAssertTrue(connect.isHittable)
        XCTAssertFalse(app.buttons["settings-logout-button"].exists)
    }

    @MainActor
    func testLocalProfileShowsReviewedCopyWorkflow() {
        let app = makeApp(language: "en")
        app.launchEnvironment["AIM_UI_TEST_CONFIGURATION"] = "missing"
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 10))
        app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        let row = app.buttons["settings-importData-row"]
        for _ in 0..<10 where !row.isHittable { root.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.staticTexts["Copy profile data"].waitForExistence(timeout: 5))
        let export = app.buttons["profile-copy-export"]
        XCTAssertTrue(export.exists); XCTAssertFalse(export.isEnabled)
        let choose = app.buttons["profile-copy-choose-file"]
        let form = app.descendants(matching: .any)["settings-page-form"]
        for _ in 0..<8 where !choose.isHittable { form.swipeUp() }
        XCTAssertTrue(choose.isHittable)
    }

    @MainActor
    func testVoiceMemoryAndProviderUsageDetailsInBothThemes() {
        for theme in ["light", "dark"] {
            let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
            app.launchArguments += ["-aim.appearance", theme]
            app.launch()
            XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
            app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
            let root = app.descendants(matching: .any)["settings-root-screen"]
            XCTAssertTrue(root.waitForExistence(timeout: 3))
            for page in ["memory", "voice", "usage"] {
                let row = app.buttons["settings-\(page)-row"]
                for _ in 0..<10 where !row.isHittable { root.swipeUp() }
                if !row.isHittable { for _ in 0..<10 where !row.isHittable { root.swipeDown() } }
                XCTAssertTrue(row.isHittable, page); row.tap()
                let form = app.descendants(matching: .any)["settings-page-form"]
                XCTAssertTrue(form.waitForExistence(timeout: 3))
                if page == "memory" {
                    let summary = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Memory summary")).firstMatch
                    XCTAssertTrue(summary.waitForExistence(timeout: 3)); summary.tap()
                    XCTAssertTrue(app.staticTexts["settings-page-title"].waitForExistence(timeout: 3))
                    keepScreenshot(named: "final-\(theme)-memory-summary", app: app)
                    app.buttons["settings-page-back"].tap()
                } else if page == "voice" {
                    XCTAssertTrue(app.buttons["Preview voice"].exists)
                    let history = app.buttons["Dictation history"]
                    for _ in 0..<10 where !history.isHittable { form.swipeUp() }
                    XCTAssertTrue(history.isHittable); history.tap()
                    XCTAssertTrue(app.staticTexts["No saved dictation yet."].waitForExistence(timeout: 3))
                    keepScreenshot(named: "final-\(theme)-dictation-history", app: app)
                    app.buttons["settings-page-back"].tap()
                } else {
                    let account = app.staticTexts["ChatGPT plan"]
                    for _ in 0..<10 where !account.isHittable { form.swipeUp() }
                    XCTAssertTrue(account.isHittable)
                    XCTAssertTrue(app.staticTexts["Plan usage unavailable"].exists)
                    keepScreenshot(named: "final-\(theme)-provider-account-usage", app: app)
                }
                XCTAssertFalse(app.keyboards.firstMatch.exists)
                app.buttons["settings-page-back"].tap()
                XCTAssertTrue(root.waitForExistence(timeout: 3))
            }
        }
    }

    @MainActor
    func testRefonteProfileAndConnectorSubpagesInBothThemes() {
        for theme in ["light", "dark"] {
            let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
            app.launchArguments += ["-aim.appearance", theme]
            app.launch()
            XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
            app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
            let root = app.descendants(matching: .any)["settings-root-screen"]
            XCTAssertTrue(root.waitForExistence(timeout: 3))
            let profile = app.buttons["settings-profile-row"]
            for _ in 0..<6 where !profile.isHittable { root.swipeUp() }
            XCTAssertTrue(profile.isHittable); profile.tap()
            let form = app.descendants(matching: .any)["settings-page-form"]
            let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Day details")).firstMatch
            for _ in 0..<6 where !day.isHittable { form.swipeUp() }
            XCTAssertTrue(day.isHittable)
            let previousY = day.frame.minY
            keepScreenshot(named: "completion-\(theme)-profile-activity", app: app)
            day.tap()
            XCTAssertTrue(app.staticTexts["Requests and tasks"].waitForExistence(timeout: 3))
            keepScreenshot(named: "completion-\(theme)-profile-day", app: app)
            app.buttons["settings-page-back"].tap()
            XCTAssertTrue(day.waitForExistence(timeout: 3)); XCTAssertEqual(day.frame.minY, previousY, accuracy: 12)
            let earlier = app.buttons["Import earlier activity"]
            for _ in 0..<6 where !earlier.isHittable { form.swipeUp() }
            XCTAssertTrue(earlier.isHittable); earlier.tap()
            XCTAssertTrue(app.buttons["Refresh preview"].waitForExistence(timeout: 3))
            keepScreenshot(named: "completion-\(theme)-activity-import", app: app)
            app.buttons["settings-page-back"].tap(); app.buttons["settings-page-back"].tap()
            let connectors = app.buttons["settings-plugins-row"]
            for _ in 0..<6 where !connectors.isHittable { root.swipeDown() }
            XCTAssertTrue(connectors.isHittable); connectors.tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Permissions")).firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Allow verified reads"].waitForExistence(timeout: 3))
            keepScreenshot(named: "completion-\(theme)-connector-permissions", app: app)
            app.buttons["settings-page-back"].tap()
            app.buttons["Add HTTPS connector"].tap()
            let name = app.textFields["Name on this device"]
            XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap(); name.typeText("Unsaved test connection")
            keepScreenshot(named: "completion-\(theme)-connector-editor", app: app)
            app.buttons["settings-page-back"].tap()
            XCTAssertTrue(app.alerts["Save connection?"].waitForExistence(timeout: 3))
            app.alerts["Save connection?"].buttons["Keep editing"].tap()
            XCTAssertEqual(name.value as? String, "Unsaved test connection")
            app.buttons["settings-page-back"].tap(); app.alerts["Save connection?"].buttons["Discard"].tap()
            XCTAssertTrue(app.buttons["Add HTTPS connector"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
        }
    }

    @MainActor
    func testRefonteSettingsPagesLightAndInternalProviderDraft() {
        inspectRefonteSettings(theme: "light", checkDraft: true)
    }

    @MainActor
    func testRefonteSettingsPagesDark() {
        inspectRefonteSettings(theme: "dark", checkDraft: false)
    }

    @MainActor
    func testRefonteCriticalPagesWithLargeText() {
        inspectRefonteSettings(theme: "dark", checkDraft: false, pages: ["general", "configuration", "profile"], largeText: true)
    }

    @MainActor
    func testGeneralSettingsAccessibleDescriptionsAndTouchTargets() throws {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        let row = app.buttons["settings-general-row"]
        for _ in 0..<6 where !row.isHittable { root.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.buttons["settings-page-back"].waitForExistence(timeout: 3))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion])
    }

    @MainActor
    func testRefonteDataPrivacyAndAboutInBothThemes() {
        for theme in ["light", "dark"] {
            inspectRefonteSettings(theme: theme, checkDraft: false, pages: ["privacy", "data", "about"])
        }
    }

    @MainActor
    private func inspectRefonteSettings(theme: String, checkDraft: Bool, pages: [String] = ["personalization", "memory", "plugins", "general", "notifications", "appearance", "voice", "configuration", "importData", "providers", "selectedMac", "profile", "usage", "security"], largeText: Bool = false) {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchArguments += ["-aim.appearance", theme]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        let captureTheme = theme + (largeText ? "-large-text" : "")
        keepScreenshot(named: "settings-\(captureTheme)-root", app: app)
        for page in pages {
            let row = app.buttons["settings-\(page)-row"]
            for _ in 0..<(largeText ? 12 : 6) where !row.isHittable { root.swipeUp() }
            if !row.isHittable { for _ in 0..<(largeText ? 12 : 6) where !row.isHittable { root.swipeDown() } }
            XCTAssertTrue(row.isHittable, page)
            guard row.isHittable else { return }
            row.tap()
            XCTAssertTrue(app.buttons["settings-page-back"].waitForExistence(timeout: 3), page)
            if largeText {
                let title = app.staticTexts["settings-page-title"]
                XCTAssertTrue(title.exists, page)
                XCTAssertLessThan(title.frame.maxY, app.frame.height * 0.25, "The measured header must leave room for scrollable content at accessibility text sizes")
                XCTAssertTrue(app.buttons["settings-page-back"].isHittable)
            }
            XCTAssertFalse(app.keyboards.firstMatch.exists, "The composer must stay unfocused in \(page)")
            keepScreenshot(named: "settings-\(captureTheme)-\(page)", app: app)
            if page == "data" {
                XCTAssertFalse(app.buttons["Delete permanently"].exists)
                app.buttons["Delete account"].tap()
                XCTAssertTrue(app.buttons["Delete permanently"].waitForExistence(timeout: 3))
                XCTAssertFalse(app.buttons["Delete permanently"].isEnabled)
                keepScreenshot(named: "settings-\(theme)-delete-confirmation", app: app)
                app.buttons["settings-page-back"].tap()
            }
            if page == "providers", checkDraft {
                let provider = app.buttons["provider-openrouter-row"]
                if !provider.isHittable { app.descendants(matching: .any)["settings-page-form"].swipeUp() }
                XCTAssertTrue(provider.isHittable); provider.tap()
                let key = app.secureTextFields["provider-key-field"]
                XCTAssertTrue(key.waitForExistence(timeout: 3)); key.tap(); key.typeText("unsaved-fixture")
                keepScreenshot(named: "settings-light-provider-key-editor", app: app)
                app.buttons["settings-page-back"].tap()
                XCTAssertTrue(app.alerts["Unsaved key"].waitForExistence(timeout: 3))
                app.alerts["Unsaved key"].buttons["Keep editing"].tap()
                XCTAssertTrue(key.exists)
                app.buttons["settings-page-back"].tap(); app.alerts["Unsaved key"].buttons["Discard"].tap()
                XCTAssertTrue(app.buttons["provider-openrouter-row"].waitForExistence(timeout: 3))
            }
            app.buttons["settings-page-back"].tap()
            XCTAssertTrue(root.waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testGlobalLockRemovesComposerAndAccessibilityUntilAuthentication() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5)); app.buttons["main-menu-button"].tap()
        app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        if !app.buttons["settings-security-row"].isHittable { root.swipeUp() }
        app.buttons["settings-security-row"].tap()
        let toggle = app.switches["settings-require-face-id"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3)); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Lock now"].waitForExistence(timeout: 3)); app.buttons["Lock now"].tap()
        XCTAssertTrue(app.buttons["Unlock AIM"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textViews["native-chat-message-field"].exists)
        XCTAssertFalse(app.buttons["main-menu-button"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        keepScreenshot(named: "global-lock-no-protected-hierarchy", app: app)
        app.buttons["Unlock AIM"].tap()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCancelledSystemAuthenticationCannotEnableProtection() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_CANCEL_SYSTEM_AUTH"] = "1"; app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5)); app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        if !app.buttons["settings-security-row"].isHittable { root.swipeUp() }
        app.buttons["settings-security-row"].tap()
        let toggle = app.switches["settings-require-face-id"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3)); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Authentication was cancelled."].waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "0"); XCTAssertFalse(app.buttons["Lock now"].exists)
    }

    @MainActor
    func testNativePanelsWithDarkThemeAndLargeText() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchArguments += ["-aim.appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["native-chat-status"].waitForExistence(timeout: 5)); app.buttons["native-chat-status"].tap()
        app.buttons["Manage Macs"].tap()
        let panel = app.descendants(matching: .any)["settings-computer-connections"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3)); XCTAssertFalse(app.keyboards.firstMatch.exists)
        keepScreenshot(named: "connection-dark-large-text", app: app)
        XCTAssertTrue(app.buttons["settings-close-button"].isHittable); app.buttons["settings-close-button"].tap()
    }

    @MainActor
    func testNativeConnectionShortcutDismissesComposerAndExpandsBeforePairing() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launch()
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5)); launcher.tap()
        let field = app.textViews["native-chat-message-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["native-chat-status"].tap()
        app.buttons["Manage Macs"].tap()
        let panel = app.descendants(matching: .any)["settings-computer-connections"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let keyboardGone = NSPredicate(format: "exists == false")
        expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 3)
        keepScreenshot(named: "native-connection-compact", app: app)
        let compactY = panel.frame.minY
        app.buttons["add-computer-connection"].tap()
        let pairingPage = app.descendants(matching: .any)["pair-computer-screen"]
        XCTAssertTrue(pairingPage.waitForExistence(timeout: 3))
        XCTAssertLessThan(pairingPage.frame.minY, compactY - 50)
        app.buttons["pair-computer-manually"].tap()
        let pairingInput = app.alerts.textFields.firstMatch
        XCTAssertTrue(pairingInput.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertLessThan(pairingInput.frame.maxY, app.keyboards.firstMatch.frame.minY)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(pairingPage.exists)
        keepScreenshot(named: "native-connection-pairing-expanded", app: app)
    }

    @MainActor
    func testConnectionFromSettingsStaysLargeAndSecurityHasOnlySystemLock() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5)); app.buttons["main-menu-button"].tap()
        XCTAssertTrue(app.buttons["profile-menu"].waitForExistence(timeout: 3)); app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        XCTAssertTrue(root.waitForExistence(timeout: 3)); let rootY = root.frame.minY
        app.buttons["settings-connection-row"].tap()
        let panel = app.descendants(matching: .any)["settings-computer-connections"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3)); XCTAssertLessThanOrEqual(panel.frame.minY, rootY + 25)
        keepScreenshot(named: "native-connection-settings-large", app: app)
        app.buttons["settings-page-back"].tap()
        let security = app.buttons["settings-security-row"]
        if !security.isHittable { root.swipeUp() }
        security.tap()
        XCTAssertTrue(app.switches["settings-require-face-id"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.secureTextFields["Existing six-digit PIN"].exists)
        XCTAssertFalse(app.buttons["Change PIN"].exists)
        keepScreenshot(named: "native-security-system-lock", app: app)
    }

    @MainActor
    func testKeyboardLabAccessoryModalMediaContinuity() { exerciseMediaGeometry(strategy: "AccModal") }

    @MainActor
    func testKeyboardLabElevatedHighMediaContinuity() { exerciseMediaGeometry(strategy: "ElevatedHigh") }

    @MainActor
    func testKeyboardLabElevatedOverrideMediaContinuity() { exerciseMediaGeometry(strategy: "ElevatedOverride") }

    @MainActor
    func testKeyboardLabElevatedOverrideNumberContinuity() {
        exerciseNumberKeyplane(strategy: "NonKey", elevatedVariant: "override")
    }

    @MainActor
    func testKeyboardLabElevatedMediaContinuity() { exerciseMediaGeometry(strategy: "Elevated") }

    @MainActor
    func testKeyboardLabElevatedNumberContinuity() {
        exerciseNumberKeyplane(strategy: "NonKey", elevated: true)
    }

    @MainActor
    func testKeyboardLabOwnedWindowFrameMovesKeyboard() {
        exerciseNumberKeyplane(strategy: "NonKey", windowMotion: "frame")
    }

    @MainActor
    func testKeyboardLabOwnedWindowTransformMovesKeyboard() {
        exerciseNumberKeyplane(strategy: "NonKey", windowMotion: "transform")
    }

    @MainActor
    func testKeyboardLabNativeOverFullMediaContinuity() { exerciseMediaGeometry(strategy: "OverFull") }

    @MainActor
    func testKeyboardLabNativeOverCurrentMediaContinuity() { exerciseMediaGeometry(strategy: "OverCurrent") }

    @MainActor
    func testKeyboardLabNativeFormMediaContinuity() { exerciseMediaGeometry(strategy: "Form") }

    @MainActor
    func testKeyboardLabModeHintSnapshotPreservesNumberKeyplane() {
        exerciseNumberKeyplane(strategy: "Snapshot", contextIdentifier: true, modeHint: true)
    }

    @MainActor
    func testKeyboardLabRetainedNativeCancelledGesture() {
        exerciseNativeCancelledGesture(contextIdentifier: true, retainResponder: true)
    }

    @MainActor
    func testKeyboardLabContextIDSnapshotPreservesNumberKeyplane() {
        exerciseNumberKeyplane(strategy: "Snapshot", contextIdentifier: true)
    }

    @MainActor
    func testKeyboardLabContextIDNativeCancelledGesture() {
        exerciseNativeCancelledGesture(contextIdentifier: true)
    }

    @MainActor
    func testKeyboardLabOverlapMediaGeometryAndContinuity() { exerciseMediaGeometry(strategy: "Overlap") }

    @MainActor
    func testKeyboardLabContextPreviewReceivesActualTap() {
        let app = XCUIApplication()
        app.launchEnvironment["AIM_KEYBOARD_LAB"] = "1"
        app.launchEnvironment["AIM_KEYBOARD_CONTEXT_PROBE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["lab-focus"].waitForExistence(timeout: 5))
        app.buttons["lab-focus"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.keyboards.keys["more"].tap()
        XCTAssertTrue(app.keyboards.keys["1"].waitForExistence(timeout: 2))
        app.buttons["lab-media"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["lab-capture"].waitForExistence(timeout: 3))
        keepScreenshot(named: "context-preview-before-physical-tap", app: app)
        // Native previews expose a different/offscreen accessibility frame.
        // This device-only diagnostic targets the rendered button observed in
        // the 390 x 844 screenshot, NOT the misleading accessibility frame.
        guard abs(app.frame.width - 390) < 1, abs(app.frame.height - 844) < 1 else {
            XCTFail("Reinspect the preview screenshot before targeting another screen size")
            return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 195, dy: 567)).tap()
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Captures: 1"), object: app.staticTexts["lab-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [captured], timeout: 3), .completed)
        keepScreenshot(named: "context-preview-after-physical-tap", app: app)
        let trace = XCTAttachment(string: app.staticTexts["lab-status"].value as? String ?? "No journal")
        trace.name = "context-physical-tap-events"
        trace.lifetime = .keepAlways
        add(trace)
    }
    @MainActor
    func testKeyboardLabAccessoryMediaGeometryAndContinuity() { exerciseMediaGeometry(strategy: "Acc") }
    @MainActor
    func testKeyboardLabNativeCancelledGesture() {
        exerciseNativeCancelledGesture(contextIdentifier: false)
    }

    @MainActor
    private func exerciseNativeCancelledGesture(contextIdentifier: Bool, retainResponder: Bool = false) {
        let app = XCUIApplication()
        app.launchEnvironment["AIM_KEYBOARD_LAB"] = "1"
        app.launchEnvironment["AIM_KEYBOARD_NATIVE_GESTURE"] = "1"
        if contextIdentifier { app.launchEnvironment["AIM_KEYBOARD_CONTEXT_ID"] = "1" }
        if retainResponder { app.launchEnvironment["AIM_KEYBOARD_NATIVE_RETAIN"] = "1" }
        app.launch()
        XCTAssertTrue(app.buttons["lab-focus"].waitForExistence(timeout: 5))
        app.buttons["lab-focus"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.keyboards.keys["more"].tap()
        XCTAssertTrue(app.keyboards.keys["1"].waitForExistence(timeout: 2))
        keepScreenshot(named: "native-cancel-before", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.45))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(app.buttons["lab-focus"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.keys["1"].exists)
        let journal = app.staticTexts["lab-status"].value as? String ?? "No journal"
        let trace = XCTAttachment(string: journal)
        trace.name = "native-cancel-keyboard-events"
        trace.lifetime = .keepAlways
        add(trace)
        XCTAssertTrue(journal.contains("willDisappear interactive=true"), "Must exercise a real native interactive transition")
        XCTAssertTrue(journal.contains("interaction cancelled=true"), "Must genuinely cancel the transition")
        keepScreenshot(named: "native-cancel-after", app: app)
    }
    @MainActor
    func testKeyboardLabNonKeyMediaGeometryAndContinuity() { exerciseMediaGeometry(strategy: "NonKey") }

    @MainActor
    func testKeyboardLabNonKeyPreservesNumberKeyplane() { exerciseNumberKeyplane(strategy: "NonKey") }
    @MainActor
    func testKeyboardLabNavPreservesNumberKeyplane() { exerciseNumberKeyplane(strategy: "Nav") }

    @MainActor
    func testKeyboardLabPopoverPreservesNumberKeyplane() { exerciseNumberKeyplane(strategy: "Popover") }

    @MainActor
    func testKeyboardLabNavMediaReceivesActualTap() { exerciseKeyboardLab(snapshot: false, strategy: "Nav") }

    @MainActor
    func testKeyboardLabPopoverMediaReceivesActualTap() { exerciseKeyboardLab(snapshot: false, strategy: "Popover") }

    @MainActor
    func testKeyboardLabPopoverMediaGeometryAndContinuity() {
        exerciseMediaGeometry(strategy: "Popover")
    }

    @MainActor
    func testKeyboardLabCustomMediaGeometryAndContinuity() {
        exerciseMediaGeometry(strategy: "Custom")
    }

    @MainActor
    func testKeyboardLabCustomPreservesNumberKeyplane() {
        exerciseNumberKeyplane(strategy: "Custom")
    }

    @MainActor
    private func exerciseMediaGeometry(strategy: String) {
        let app = XCUIApplication()
        app.launchEnvironment["AIM_KEYBOARD_LAB"] = "1"
        let nativeModal = ["OverFull", "OverCurrent", "Form"].contains(strategy)
        if strategy == "Elevated" { app.launchEnvironment["AIM_KEYBOARD_ELEVATED_PROBE"] = "1" }
        if strategy == "ElevatedHigh" { app.launchEnvironment["AIM_KEYBOARD_ELEVATED_PROBE"] = "high" }
        if strategy == "ElevatedOverride" { app.launchEnvironment["AIM_KEYBOARD_ELEVATED_PROBE"] = "override" }
        if nativeModal { app.launchEnvironment["AIM_KEYBOARD_NATIVE_MODAL"] = strategy }
        if strategy == "Acc" || strategy == "AccModal" { app.launchEnvironment["AIM_KEYBOARD_ACCESSORY_PROBE"] = "1" }
        if strategy == "AccModal" { app.launchEnvironment["AIM_KEYBOARD_ACCESSORY_MODAL"] = "1" }
        if strategy == "Overlap" { app.launchEnvironment["AIM_POPOVER_OVERLAP_PROBE"] = "1" }
        app.launch()
        XCTAssertTrue(app.buttons["lab-focus"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons[nativeModal ? "Retain" : strategy == "AccModal" ? "Acc" : strategy.hasPrefix("Elevated") ? "NonKey" : strategy == "Overlap" ? "Popover" : strategy].tap()
        app.buttons["lab-focus"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.keyboards.keys["more"].tap()
        XCTAssertTrue(app.keyboards.keys["1"].waitForExistence(timeout: 2))
        let screen = app.frame
        let keyboardKeysFrame = app.keyboards.firstMatch.frame
        // XCTest's keyboard element omits the bottom globe/dictation region.
        // This portrait probe uses a docked keyboard; include that visible
        // region down to the physical screen bottom, not just the key rows.
        let keyboardFrame = CGRect(x: keyboardKeysFrame.minX, y: keyboardKeysFrame.minY,
                                   width: keyboardKeysFrame.width, height: screen.maxY - keyboardKeysFrame.minY)
        let draft = app.textViews["lab-editor"].value as? String
        app.buttons["lab-media"].tap()
        XCTAssertTrue(app.buttons["lab-capture"].waitForExistence(timeout: 3))
        let panel = app.otherElements["lab-panel"].firstMatch.frame
        keepScreenshot(named: "lab-\(strategy)-media-geometry", app: app)
        if nativeModal {
            XCTAssertTrue(app.keyboards.keys["1"].exists, "The original numeric keyboard must remain present during native media presentation")
        }
        XCTAssertEqual(panel.minX - screen.minX, 8, accuracy: 1)
        XCTAssertEqual(screen.maxX - panel.maxX, 8, accuracy: 1)
        XCTAssertEqual(screen.maxY - panel.maxY, 8, accuracy: 1)
        XCTAssertEqual(panel.height, min(600, (screen.height * 0.7).rounded()), accuracy: 1)
        // Occluded accessibility buttons may report an empty frame. Tap the
        // intended physical location, independent of accessibility hit testing:
        // 24 pt bottom inset plus half the lab button's 44 pt height.
        let target = CGPoint(x: panel.midX, y: panel.maxY - 46)
        let geometry = XCTAttachment(string: "screen=\(screen) keyRows=\(keyboardKeysFrame) dockedRegion=\(keyboardFrame) panel=\(panel) target=\(target)")
        geometry.name = "\(strategy)-coordinate-spaces"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertTrue(keyboardFrame.contains(target),
                      "Capture must lie in the ORIGINAL keyboard area, not merely above it")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.x - screen.minX, dy: target.y - screen.minY)).tap()
        XCTAssertTrue(app.keyboards.keys["1"].waitForExistence(timeout: 3), "Media return must preserve the numeric keyplane")
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Captures: 1"), object: app.staticTexts["lab-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [captured], timeout: 3), .completed)
        XCTAssertEqual(app.textViews["lab-editor"].value as? String, draft, "The media tap must not type through into the draft")
        keepScreenshot(named: "lab-\(strategy)-media-geometry-return", app: app)
        let trace = XCTAttachment(string: app.staticTexts["lab-status"].value as? String ?? "No journal accessible")
        trace.name = "\(strategy)-keyboard-events"
        trace.lifetime = .keepAlways
        add(trace)
    }

    /// Acceptance probes, not mocks: a failure is a rejected strategy. Screenshots
    /// must additionally establish whether a snapshot contains keyboard pixels.
    @MainActor
    func testKeyboardLabUIKitMediaReceivesActualTap() {
        exerciseKeyboardLab(snapshot: false)
    }

    @MainActor
    func testKeyboardLabSnapshotMediaReceivesActualTap() {
        exerciseKeyboardLab(snapshot: true)
    }

    @MainActor
    func testKeyboardLabSnapshotPreservesNumberKeyplane() {
        exerciseNumberKeyplane(strategy: "Snapshot")
    }

    @MainActor
    func testKeyboardLabRetainPreservesNumberKeyplane() {
        exerciseNumberKeyplane(strategy: "Retain")
    }

    @MainActor
    func testKeyboardLabInputPreservesNumberKeyplane() {
        exerciseNumberKeyplane(strategy: "Input")
    }

    @MainActor
    func testKeyboardLabWindowPreservesNumberKeyplane() {
        exerciseNumberKeyplane(strategy: "Window")
    }

    @MainActor
    func testKeyboardLabWindowMediaReceivesActualTap() {
        exerciseKeyboardLab(snapshot: false, strategy: "Window")
    }

    @MainActor
    func testKeyboardLabRetainMediaReceivesActualTap() {
        exerciseKeyboardLab(snapshot: false, strategy: "Retain")
    }

    @MainActor
    func testKeyboardLabInputMediaReceivesActualTap() {
        exerciseKeyboardLab(snapshot: false, strategy: "Input")
    }

    @MainActor
    private func exerciseNumberKeyplane(strategy: String, contextIdentifier: Bool = false, modeHint: Bool = false, windowMotion: String? = nil, elevated: Bool = false, elevatedVariant: String? = nil) {
        let app = XCUIApplication()
        app.launchEnvironment["AIM_KEYBOARD_LAB"] = "1"
        if contextIdentifier { app.launchEnvironment["AIM_KEYBOARD_CONTEXT_ID"] = "1" }
        if modeHint { app.launchEnvironment["AIM_KEYBOARD_MODE_HINT"] = "1" }
        if let windowMotion { app.launchEnvironment["AIM_KEYBOARD_WINDOW_MOTION"] = windowMotion }
        if elevated { app.launchEnvironment["AIM_KEYBOARD_ELEVATED_PROBE"] = "1" }
        if let elevatedVariant { app.launchEnvironment["AIM_KEYBOARD_ELEVATED_PROBE"] = elevatedVariant }
        app.launch()
        XCTAssertTrue(app.buttons["lab-focus"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons[strategy].tap()
        app.buttons["lab-focus"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.keyboards.keys["more"].tap()
        XCTAssertTrue(app.keyboards.keys["1"].waitForExistence(timeout: 2))
        let initialKeyboardFrame = app.keyboards.firstMatch.frame
        let screenWidth = app.frame.width
        keepScreenshot(named: "lab-\(strategy)-number-before", app: app)
        app.buttons["lab-sidebar"].tap()
        XCTAssertTrue(app.buttons["lab-back"].waitForExistence(timeout: 3))
        keepScreenshot(named: "lab-\(strategy)-number-sidebar", app: app)
        if windowMotion != nil {
            XCTAssertEqual(app.keyboards.firstMatch.frame.minX, initialKeyboardFrame.minX + screenWidth * 0.77, accuracy: 2,
                           "The live keyboard must follow the app-owned window, not remain across the sidebar")
        }
        app.buttons["lab-back"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        keepScreenshot(named: "lab-\(strategy)-number-restored", app: app)
        XCTAssertTrue(app.keyboards.keys["1"].exists, "Reject \(strategy) if restoring resets the keyplane")
        let trace = XCTAttachment(string: app.staticTexts["lab-status"].value as? String ?? "No journal accessible")
        trace.name = "\(strategy)-keyboard-events"
        trace.lifetime = .keepAlways
        add(trace)
    }

    @MainActor
    private func exerciseKeyboardLab(snapshot: Bool, strategy: String? = nil) {
        let probe = strategy ?? (snapshot ? "Snapshot" : "UIKit")
        let app = XCUIApplication()
        app.launchEnvironment["AIM_KEYBOARD_LAB"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["lab-focus"].waitForExistence(timeout: 5))
        if snapshot { app.segmentedControls.buttons["Snapshot"].tap() }
        if let strategy { app.segmentedControls.buttons[strategy].tap() }
        app.buttons["lab-focus"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let editor = app.textViews["lab-editor"]
        let draft = editor.value as? String
        keepScreenshot(named: "lab-\(probe)-before", app: app)
        app.buttons["lab-sidebar"].tap()
        XCTAssertTrue(app.buttons["lab-back"].waitForExistence(timeout: 3))
        keepScreenshot(named: "lab-\(probe)-sidebar", app: app)
        app.buttons["lab-back"].tap()
        XCTAssertTrue(app.buttons["lab-media"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        keepScreenshot(named: "lab-\(probe)-restored", app: app)
        app.buttons["lab-media"].tap()
        XCTAssertTrue(app.buttons["lab-capture"].waitForExistence(timeout: 3))
        keepScreenshot(named: "lab-\(probe)-media", app: app)
        // Coordinate tap intentionally bypasses XCTest's accessibility scrolling:
        // the foreground recipient must really be our media command, not a key.
        app.buttons["lab-capture"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let captured = NSPredicate(format: "label CONTAINS %@", "Captures: 1")
        let captureExpectation = XCTNSPredicateExpectation(predicate: captured, object: app.staticTexts["lab-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [captureExpectation], timeout: 3), .completed)
        XCTAssertEqual(editor.value as? String, draft)
        keepScreenshot(named: "lab-\(probe)-after-tap", app: app)
    }

    @MainActor
    func testNewChatAutofocusesAndComposerSwipeDismissesKeyboard() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["creation-mode-chat"].exists)
        XCTAssertTrue(app.buttons["creation-mode-code"].exists)
        XCTAssertTrue(app.buttons["creation-mode-agent"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        let composer = app.descendants(matching: .any)["new-chat-composer"]
        XCTAssertTrue(composer.exists)
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(
                forDuration: 0.05,
                thenDragTo: composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            )

        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testSidebarVerticalPanScrollsWithoutOpeningConversation() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()

        let sidebar = app.scrollViews["sidebar-scroll"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        let first = app.buttons["sidebar-session-ui-test-session"]
        let initialY = first.frame.minY
        sidebar.swipeUp()
        XCTAssertLessThan(first.frame.minY, initialY - 20, "The first vertical gesture must scroll immediately")

        let lastConversation = app.buttons["sidebar-session-ui-test-chat-14"]
        for _ in 0..<4 where lastConversation.frame.maxY > sidebar.frame.maxY - 100 { sidebar.swipeUp() }
        XCTAssertTrue(lastConversation.waitForExistence(timeout: 2))
        XCTAssertLessThan(lastConversation.frame.maxY, sidebar.frame.maxY - 80)
        XCTAssertFalse(app.descendants(matching: .any)["conversation-screen"].exists)
        // XCTest considers the untransformed keyboard bounds occluding this
        // row. Exercise an actual screen tap to verify input routing instead.
        lastConversation.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["conversation-screen"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCheckpointAVisualReference() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        keepScreenshot(named: "checkpoint-a-new-chat", app: app)

        app.buttons["main-menu-button"].tap()
        XCTAssertTrue(app.buttons["new-chat-button"].waitForExistence(timeout: 2))
        keepScreenshot(named: "checkpoint-a-sidebar", app: app)
    }

    @MainActor
    func testFullWidthSwipeOpensAndClosesTheSidebar() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        let menu = app.buttons["main-menu-button"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let originalX = menu.frame.midX
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45)))
        let profileMenu = app.buttons["profile-menu"]
        let sidebarOpen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: profileMenu)
        XCTAssertEqual(XCTWaiter.wait(for: [sidebarOpen], timeout: 3), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45)))
        let sidebarClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [sidebarClosed], timeout: 4), .completed)
        XCTAssertEqual(menu.frame.midX, originalX, accuracy: 2)
        XCTAssertFalse(profileMenu.isHittable)
    }

    @MainActor
    func testOpeningSidebarFromFocusedComposerMovesKeyboardAndPreservesInput() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5)); launcher.tap()
        let editor = app.textViews["native-chat-message-field"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        editor.typeText("Keep this draft")
        app.keyboards.keys["more"].tap()
        let draft = editor.value as? String
        let originalY = app.keyboards.firstMatch.frame.minY
        app.buttons["main-menu-button"].tap()
        XCTAssertTrue(app.buttons["profile-menu"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.keyboards.count, 1)
        XCTAssertGreaterThan(app.keyboards.firstMatch.frame.minX, app.frame.width * 0.5)
        XCTAssertEqual(app.keyboards.firstMatch.frame.minY, originalY, accuracy: 2)
        keepScreenshot(named: "floating-sidebar-keyboard", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.82)).tap()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.keyboards.firstMatch.frame.minX, 0, accuracy: 2)
        XCTAssertTrue(app.keyboards.keys["1"].exists)
        XCTAssertEqual(editor.value as? String, draft)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.40))
        start.press(forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.40)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertGreaterThan(app.keyboards.firstMatch.frame.minX, app.frame.width * 0.5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.82))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.82)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(app.keyboards.firstMatch.frame.minX, 0, accuracy: 2)
        XCTAssertTrue(app.keyboards.keys["1"].exists)
        app.keyboards.keys["1"].tap()
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix("1"))
    }

    @MainActor
    func testFastSidebarRoundTripsRestoreKeyboardPosition() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        launcher.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4))
                .press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.4)), withVelocity: .fast, thenHoldForDuration: 0.1)
            XCTAssertGreaterThan(app.keyboards.firstMatch.frame.minX, app.frame.width * 0.5)
            // The close cover intentionally hides the card's buttons from AX
            // while open (their reported rect is zero). Check the keyboard's
            // settled position here; frame-by-frame alignment is a video check.
            keepScreenshot(named: "fast-sidebar-open", app: app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.82))
                .press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.82)), withVelocity: .fast, thenHoldForDuration: 0.1)
            XCTAssertEqual(app.keyboards.firstMatch.frame.minX, 0, accuracy: 2)
        }
        keepScreenshot(named: "fast-sidebar-round-trip", app: app)
    }

    @MainActor
    func testCancelledSidebarGesturePreservesComposerFocus() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()

        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5)); launcher.tap()
        let screen = app
        let editor = app.textViews["native-chat-message-field"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))

        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.42))
        let cancelled = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.42))
        start.press(forDuration: 0.2, thenDragTo: cancelled, withVelocity: .slow, thenHoldForDuration: 0.3)

        XCTAssertFalse(app.buttons["profile-menu"].isHittable)
        XCTAssertEqual(app.keyboards.count, 1)
        XCTAssertTrue(editor.exists)
    }

    @MainActor
    func testRound21SettingsHeaderStaysReachableWhileContentScrollsBehind() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        let voice = app.buttons["settings-voice-row"]
        for _ in 0..<6 where !voice.isHittable { root.swipeUp() }
        voice.tap()
        let title = app.staticTexts["settings-page-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3)); let frame = title.frame
        app.descendants(matching: .any)["settings-page-form"].swipeUp()
        XCTAssertEqual(title.frame, frame)
        XCTAssertTrue(app.buttons["settings-page-back"].isHittable)
        keepScreenshot(named: "round21-settings-scrolled-fade", app: app)
    }

    @MainActor
    func testMissingConfigurationAllowsLocalUseAndExplainsOptionalCloud() {
        let app = makeApp(language: "en")
        app.launchEnvironment["AIM_UI_TEST_CONFIGURATION"] = "missing"
        app.launch()

        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 10))
        app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
        let connect = app.buttons["settings-connect-account"]
        let root = app.descendants(matching: .any)["settings-root-screen"]
        for _ in 0..<12 where !connect.isHittable { root.swipeUp() }
        XCTAssertTrue(connect.isHittable); connect.tap()
        XCTAssertTrue(app.staticTexts["Cloud server not configured"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSignedOutScreenIsAvailableInEnglish() {
        let app = makeApp(scenario: "signedOut", language: "en")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["authentication-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["authentication-title"].exists)
        let appleSignInButton = app.buttons["apple-sign-in"]
        XCTAssertTrue(appleSignInButton.exists)
        XCTAssertTrue(appleSignInButton.isHittable)
        XCTAssertTrue(app.buttons["google-sign-in"].exists)
        XCTAssertTrue(app.buttons["show-sign-up"].exists)
        XCTAssertTrue(app.buttons["show-sign-in"].exists)
        XCTAssertFalse(app.textFields["email-field"].exists)
    }

    @MainActor
    func testSignedOutScreenIsAvailableInFrench() {
        let app = makeApp(scenario: "signedOut", language: "fr")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["authentication-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["authentication-title"].exists)
    }

    @MainActor
    func testAuthenticatedShellSupportsDarkModeAndLargeText() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_COLOR_SCHEME"] = "dark"
        app.launchEnvironment["AIM_UI_TEST_DYNAMIC_TYPE"] = "accessibility5"
        app.launch()

        XCTAssertTrue(app.staticTexts["ui-test-swiftui-type-size"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["ui-test-swiftui-type-size"].label, "accessibility5")
        XCTAssertTrue(app.descendants(matching: .any)["authenticated-shell"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-title"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-composer"].exists)
        XCTAssertTrue(app.buttons["main-menu-button"].exists)
        XCTAssertFalse(app.buttons["machine-status"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["aim-mascot"].exists)
        keepScreenshot(named: "checkpoint-a-new-chat-dark-large-text", app: app)
        app.buttons["main-menu-button"].tap()
        XCTAssertTrue(app.buttons["profile-menu"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["sidebar-search"].exists)
        XCTAssertTrue(app.buttons["sidebar-library"].exists)
        XCTAssertTrue(app.buttons["sidebar-personalization"].exists)
        XCTAssertTrue(app.buttons["sidebar-code"].exists)
        XCTAssertTrue(app.buttons["sidebar-agent"].exists)
        XCTAssertTrue(app.buttons["sidebar-projects"].exists)
        XCTAssertTrue(app.buttons["new-chat-button"].exists)
        keepScreenshot(named: "checkpoint-a-sidebar-dark-large-text", app: app)
    }

    @MainActor
    func testOfflineDraftRemainsEditableAndSendShowsConnectionStatus() {
        let app = makeApp(scenario: "authenticatedOffline", language: "en")
        app.launch()
        let editor = app.textViews["new-chat-message-field"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Keep my offline draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["new-chat-send-button"].tap()
        XCTAssertTrue(app.staticTexts["computer-state"].waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "Keep my offline draft")
        keepScreenshot(named: "offline-draft-preserved", app: app)
    }

    @MainActor
    func testRefinedEffortAndSidebarAppearance() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        let effort = app.buttons["new-chat-effort-button"]
        XCTAssertTrue(effort.waitForExistence(timeout: 5))
        effort.tap()
        XCTAssertTrue(app.descendants(matching: .any)["effort-selector"].waitForExistence(timeout: 3))
        keepScreenshot(named: "refined-effort-selector", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        app.buttons["main-menu-button"].tap()
        app.scrollViews["sidebar-scroll"].swipeUp()
        keepScreenshot(named: "sidebar-progressive-header-blur", app: app)
    }

    @MainActor
    func testEffortDraggingKeepsDrawerClosedAndPanelBounded() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        let button = app.buttons["new-chat-effort-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let panel = app.descendants(matching: .any)["effort-selector"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let track = app.descendants(matching: .any)["effort-track"]
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertLessThan(panel.frame.height, 200)
        XCTAssertLessThanOrEqual(panel.frame.width, 332)
        XCTAssertEqual(app.keyboards.firstMatch.frame.minX, 0, accuracy: 2)
        XCTAssertTrue(track.buttons.allElementsBoundByIndex.last?.isSelected == true)
        keepScreenshot(named: "effort-dragged", app: app)
    }

    @MainActor
    func testMarkdownHorizontalScrollingDoesNotOpenSidebar() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_MARKDOWN"] = "1"
        app.launch()
        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-session-ui-test-session"].tap()
        let table = app.scrollViews["markdown-table-scroll"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        table.swipeLeft()
        XCTAssertTrue(app.staticTexts["END_OF_TABLE"].isHittable)
        table.swipeRight()
        XCTAssertFalse(app.buttons["profile-menu"].isHittable)
        let code = app.scrollViews["markdown-code-scroll"]
        code.swipeLeft()
        code.swipeRight()
        XCTAssertFalse(app.buttons["profile-menu"].isHittable)
        keepScreenshot(named: "markdown-scrollable", app: app)
    }

    @MainActor
    func testExistingOfflineConversationCanQueueAndCancelMessage() {
        let app = makeApp(scenario: "authenticatedOffline", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-session-ui-test-session"].tap()
        let editor = app.textViews["conversation-message-field"]
        if app.buttons["conversation-message-field-launcher"].exists {
            app.buttons["conversation-message-field-launcher"].tap()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("Queued offline UI test")
        app.buttons["conversation-send-button"].tap()
        let queue = app.buttons["queue-message-button"]
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        queue.tap()
        XCTAssertTrue(app.staticTexts["Waiting for connection"].waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "")
        keepScreenshot(named: "offline-queued-message", app: app)
        let cancel = app.buttons["Cancel pending message"].firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Waiting for connection"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testOfflineComputerStatusMovesIntoHeaderPopover() {
        let app = makeApp(scenario: "authenticatedOffline", language: "en")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["computer-state"].exists)
        let status = app.buttons["new-chat-header-status"]
        XCTAssertEqual(status.value as? String, "The computer is offline.")
        let titleFrame = app.staticTexts["new-chat-title"].frame
        status.tap()
        XCTAssertTrue(app.staticTexts["computer-state"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["computer-state"].label, "The computer is offline.")
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertFalse(app.buttons["new-chat-send-button"].isEnabled)
        XCTAssertEqual(app.staticTexts["new-chat-title"].frame, titleFrame)
        keepScreenshot(named: "new-chat-offline-status-popover", app: app)
    }

    @MainActor
    func testUnpairedAccountOpensPairingSettingsAndCanDismissIt() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["settings-computer-connections"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["pairing-code-field"].exists)
        XCTAssertTrue(app.buttons["add-computer-connection"].exists)
        app.buttons["settings-close-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.alerts.count, 0)
    }

    @MainActor
    func testInitialRemoteFailureOffersRetryInStatusPopover() {
        let app = makeApp(scenario: "authenticatedRemoteFailure", language: "en")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["computer-state"].exists)
        app.buttons["new-chat-header-status"].tap()
        XCTAssertTrue(app.staticTexts["computer-state"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["retry-remote-button"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings-computer-connections"].exists)
        app.buttons["retry-remote-button"].tap()
        XCTAssertTrue(app.staticTexts["computer-state"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.alerts.count, 0)
        keepScreenshot(named: "new-chat-retry-status-popover", app: app)
    }

    @MainActor
    func testHeaderStatusSupportsDarkModeAndLargeText() {
        let app = makeApp(scenario: "authenticatedOffline", language: "fr")
        app.launchEnvironment["AIM_UI_TEST_COLOR_SCHEME"] = "dark"
        app.launchEnvironment["AIM_UI_TEST_DYNAMIC_TYPE"] = "accessibility5"
        app.launch()
        XCTAssertTrue(app.staticTexts["ui-test-swiftui-type-size"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["ui-test-swiftui-type-size"].label, "accessibility5")
        let status = app.buttons["new-chat-header-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.isHittable)
        status.tap()
        let description = app.staticTexts["computer-state"]
        XCTAssertTrue(description.waitForExistence(timeout: 3))
        XCTAssertTrue(description.isHittable)
        XCTAssertGreaterThan(description.frame.height, 80, "The text must actually render at the injected accessibility size")
        XCTAssertLessThanOrEqual(description.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(description.frame.maxY, app.frame.maxY)
        keepScreenshot(named: "new-chat-status-dark-large-text", app: app)
    }

    @MainActor
    func testProfilePillOpensTheUniversalSettingsPanel() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))

        app.buttons["main-menu-button"].tap()
        XCTAssertTrue(app.buttons["profile-menu"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.45)
        app.buttons["profile-menu"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["settings-root-screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["settings-connection-row"].exists)
        XCTAssertTrue(app.buttons["settings-appearance-row"].exists)
        XCTAssertTrue(app.buttons["settings-typography-row"].exists)
        XCTAssertTrue(app.buttons["settings-language-row"].exists)
        XCTAssertTrue(app.buttons["settings-close-button"].exists)
        XCTAssertFalse(app.buttons["settings-info-button"].exists)
    }

    @MainActor
    func testUnifiedNativeChatPresentationAndModelPickerInBothThemes() {
        for theme in ["light", "dark"] {
            let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
            app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
            app.launchArguments += ["-aim.appearance", theme]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["chat-user-bubble"].firstMatch.waitForExistence(timeout: 5))
            let copy = app.buttons["chat-copy-response"].firstMatch
            XCTAssertTrue(copy.exists); copy.tap()
            XCTAssertTrue(app.buttons["native-chat-message-field-launcher"].exists)
            XCTAssertFalse(app.textViews["native-chat-message-field"].exists)
            keepScreenshot(named: "unified-native-chat-\(theme)", app: app)

            openNativeModelPicker(app)
            XCTAssertTrue(app.descendants(matching: .any)["model-selection-sheet"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.segmentedControls.buttons["Added models"].isSelected)
            XCTAssertTrue(app.descendants(matching: .any)["model-search-field"].exists)
            XCTAssertTrue(app.staticTexts["Pinned"].exists)
            XCTAssertTrue(app.staticTexts["Anthropic"].exists)
            keepScreenshot(named: "unified-native-models-added-\(theme)", app: app)
            app.buttons["model-info-openrouter:anthropic/claude-sonnet-4-6"].tap()
            XCTAssertTrue(app.buttons["model-details-back"].waitForExistence(timeout: 3))
            keepScreenshot(named: "unified-native-model-details-\(theme)", app: app)
            app.buttons["model-details-back"].tap()
            XCTAssertTrue(app.segmentedControls.buttons["Added models"].isSelected)
            if !app.staticTexts["OpenAI"].exists { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(app.staticTexts["OpenAI"].exists)
            app.segmentedControls.buttons["Full catalog"].tap()
            XCTAssertTrue(app.segmentedControls.buttons["Full catalog"].isSelected)
            keepScreenshot(named: "unified-native-models-catalog-\(theme)", app: app)
            app.buttons["Close"].tap()
            XCTAssertTrue(app.buttons["native-chat-message-field-launcher"].waitForExistence(timeout: 3))
            app.buttons["native-chat-message-field-launcher"].tap()
            XCTAssertTrue(app.textViews["native-chat-message-field"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            keepScreenshot(named: "unified-native-chat-expanded-\(theme)", app: app)
            app.terminate()
        }
    }

    @MainActor
    func testNativeConversationFloatingHeaderAndComposerKeyboardRoundTrip() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        let menu = app.buttons["main-menu-button"]
        let status = app.buttons["native-chat-status"]
        let actions = app.buttons["native-chat-actions"]
        let launcher = app.buttons["native-chat-message-field-launcher"]
        let bubble = app.descendants(matching: .any)["chat-user-bubble"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isHittable)
        XCTAssertEqual(status.frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertLessThan(menu.frame.midX, status.frame.midX)
        XCTAssertGreaterThan(actions.frame.midX, status.frame.midX)
        XCTAssertFalse(app.buttons["creation-mode-chat"].exists)
        XCTAssertFalse(app.buttons["creation-mode-code"].exists)
        XCTAssertFalse(app.buttons["creation-mode-agent"].exists)
        let compactBottom = app.descendants(matching: .any)["native-chat-composer"].frame.maxY
        let initialBubbleY = bubble.frame.minY
        let compactComposerTop = app.descendants(matching: .any)["native-chat-composer"].frame.minY
        let headerY = [menu.frame.midY, status.frame.midY, actions.frame.midY]
        keepScreenshot(named: "floating-native-conversation-compact", app: app)

        for cycle in 0..<2 {
            XCTAssertTrue(launcher.waitForExistence(timeout: 3)); launcher.tap()
            XCTAssertTrue(app.textViews["native-chat-message-field"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            let composer = app.descendants(matching: .any)["native-chat-composer"]
            let aboveKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                composer.frame.maxY <= app.keyboards.firstMatch.frame.minY + 5
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [aboveKeyboard], timeout: 3), .completed)
            XCTAssertEqual(status.frame.midX, app.frame.midX, accuracy: 2)
            for (index, button) in [menu, status, actions].enumerated() {
                XCTAssertEqual(button.frame.midY, headerY[index], accuracy: 2,
                               "The keyboard must move the composer without translating the floating header")
            }
            // The fixture starts at the tail. A small upward adjustment is
            // necessary when its last actions and trailing spacing would be
            // covered by the expanded composer; this is not a layout jump.
            let newlyOccludedHeight = max(0, compactComposerTop - composer.frame.minY)
            XCTAssertLessThanOrEqual(initialBubbleY - bubble.frame.minY, newlyOccludedHeight + 4,
                                     "Following the tail must not scroll farther than the newly occluded viewport")
            XCTAssertLessThanOrEqual(bubble.frame.minY, initialBubbleY + 4)
            XCTAssertLessThanOrEqual(app.buttons["chat-copy-response"].firstMatch.frame.maxY, composer.frame.minY)
            keepScreenshot(named: "floating-native-conversation-keyboard-\(cycle)", app: app)
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05,
                       thenDragTo: composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
            XCTAssertTrue(launcher.waitForExistence(timeout: 3))
            let compactRestored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(composer.frame.maxY - compactBottom) < 3
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [compactRestored], timeout: 3), .completed)
            XCTAssertEqual(bubble.frame.minY, initialBubbleY, accuracy: 4)
        }
        launcher.tap()
        let editor = app.textViews["native-chat-message-field"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let draft = "Keep my native Chat draft.\nAnd its second line."
        editor.typeText(draft)
        openNativeModelPicker(app)
        let models = app.descendants(matching: .any)["model-selection-sheet"]
        XCTAssertTrue(models.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let closeModels = app.buttons["model-picker-close"]
        XCTAssertTrue(closeModels.waitForExistence(timeout: 3)); closeModels.tap()
        XCTAssertTrue(models.waitForNonExistence(timeout: 3))
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, draft)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, draft)
        keepScreenshot(named: "floating-native-draft-restored", app: app)
    }

    @MainActor
    func testNativeReadingPositionAwayFromTailSurvivesKeyboardRoundTrip() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launchEnvironment["AIM_UI_TEST_LONG_NATIVE_CHAT"] = "1"
        app.launch()
        let timeline = app.scrollViews["immersive-conversation-scroll"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 3))
        // Move into older messages, rather than asserting a fixed position
        // while following the tail above an opening keyboard.
        timeline.swipeDown(); timeline.swipeDown()
        let paragraphs = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading marker "))
        guard let anchor = paragraphs.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.minY > 120 && $0.frame.minY < app.frame.height * 0.45
        }) else {
            XCTFail("The long fixture must expose an older paragraph above the keyboard region")
            return
        }
        let anchorText = anchor.label
        let readingY = anchor.frame.minY
        let retainedParagraph = app.staticTexts.matching(NSPredicate(format: "label == %@", anchorText)).firstMatch
        let status = app.buttons["native-chat-status"]
        let headerY = status.frame.midY
        keepScreenshot(named: "floating-reading-position-before-keyboard", app: app)
        launcher.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(retainedParagraph.exists)
        XCTAssertEqual(retainedParagraph.frame.minY, readingY, accuracy: 4,
                       "Opening the composer must not return an older reading position to the latest answer")
        XCTAssertEqual(status.frame.midY, headerY, accuracy: 2)
        let composer = app.descendants(matching: .any)["native-chat-composer"]
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 5)
        keepScreenshot(named: "floating-reading-position-with-keyboard", app: app)
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05,
                   thenDragTo: composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(launcher.waitForExistence(timeout: 3))
        XCTAssertEqual(retainedParagraph.frame.minY, readingY, accuracy: 4)
        XCTAssertEqual(status.frame.midY, headerY, accuracy: 2)
    }

    @MainActor
    func testModelPickerBlocksSidebarAndPlusFocusesCatalogueSearch() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        let menu = app.buttons["main-menu-button"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let originalMenuX = menu.frame.midX
        openNativeModelPicker(app)
        let panel = app.descendants(matching: .any)["model-selection-sheet"]
        let list = app.scrollViews["model-picker-list"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        for (start, end) in [(0.08, 0.90), (0.90, 0.08)] {
            list.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
                .press(forDuration: 0.05,
                       thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)))
            XCTAssertTrue(panel.exists)
            XCTAssertFalse(app.buttons["profile-menu"].isHittable,
                           "A horizontal gesture in a modal must not reveal the underlying sidebar")
        }
        let add = app.buttons["model-picker-add-models"]
        let providers = app.buttons["model-picker-providers"]
        XCTAssertGreaterThanOrEqual(add.frame.width, 44)
        XCTAssertGreaterThanOrEqual(providers.frame.width, 44)
        add.tap()
        XCTAssertTrue(app.segmentedControls.buttons["Full catalog"].isSelected)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let search = app.textFields["model-search-field"]
        search.typeText("Sonnet\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["OpenRouter reference"].exists)
        app.buttons["model-option-anthropic:claude-sonnet-4-6"].tap()
        XCTAssertTrue(app.buttons["model-details-back"].waitForExistence(timeout: 3))
        keepScreenshot(named: "floating-model-detail-before-edge-back", app: app)
        edgeBack(in: app)
        XCTAssertTrue(app.buttons["model-details-back"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(search.value as? String, "Sonnet")
        XCTAssertTrue(app.segmentedControls.buttons["Full catalog"].isSelected)
        add.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "The plus action must also focus search when the catalogue is already open")
        search.typeText("\n")
        keepScreenshot(named: "floating-model-picker-compact-rows", app: app)
        app.buttons["Close"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(menu.isHittable)
        XCTAssertEqual(menu.frame.midX, originalMenuX, accuracy: 2)
        XCTAssertFalse(app.buttons["profile-menu"].isHittable,
                       "The retained sidebar hierarchy must remain inaccessible behind the centered conversation")
    }

    @MainActor
    func testRemoteDeviceMenuGroupsTargetsAndModelPickerNamesTheMac() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        let status = app.buttons["native-chat-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5)); status.tap()
        XCTAssertTrue(app.buttons["This iPhone"].waitForExistence(timeout: 3))
        let mac = app.buttons["Mac de Mathieu"]
        XCTAssertTrue(mac.exists)
        XCTAssertFalse(app.collectionViews.firstMatch.buttons["Choose model"].exists)
        keepScreenshot(named: "execution-device-menu-with-mac", app: app)
        mac.tap()
        let remoteStatus = app.buttons["new-chat-header-status"]
        XCTAssertTrue(remoteStatus.waitForExistence(timeout: 5)); remoteStatus.tap()
        XCTAssertTrue(app.buttons["execution-device-iphone"].waitForExistence(timeout: 3))
        let activeMac = app.buttons["execution-device-mac-ui-test-machine"]
        XCTAssertTrue(activeMac.exists)
        keepScreenshot(named: "execution-device-menu-remote", app: app)
        activeMac.tap()
        let launcher = app.buttons["new-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 3)); launcher.tap()
        let model = app.buttons["new-chat-model-button"]
        XCTAssertTrue(model.waitForExistence(timeout: 3)); model.tap()
        let device = app.staticTexts["model-picker-execution-device"].firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 3))
        XCTAssertEqual(device.label, "On Mac de Mathieu")
        XCTAssertTrue(app.buttons["model-option-openai:gpt-5.6-sol"].exists)
        keepScreenshot(named: "remote-model-picker-execution-device", app: app)
    }

    @MainActor
    func testModelPickerSegmentsRespondToSingleTapsWithoutChangingActiveModel() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-chat-actions"].waitForExistence(timeout: 5))
        openNativeModelPicker(app)
        let added = app.segmentedControls.buttons["Added models"]
        let catalog = app.segmentedControls.buttons["Full catalog"]
        let online = app.segmentedControls.buttons["Online"]
        let local = app.segmentedControls.buttons["Local · Mac"]
        XCTAssertTrue(added.waitForExistence(timeout: 3))
        let device = app.staticTexts["model-picker-execution-device"].firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 3))
        XCTAssertTrue(device.label.contains("iPhone"), "The picker must identify the device whose provider keys will be used")
        // Each selection gets exactly one short tap, never a retry or long press.
        // Assert the filtered content too: a highlighted segment alone does not
        // prove that the picker changed its displayed execution adapter.
        for _ in 0..<4 {
            catalog.tap()
            XCTAssertTrue(catalog.isSelected)
            local.tap()
            XCTAssertTrue(local.isSelected)
            XCTAssertTrue(app.staticTexts["No local model announced by the selected Mac"].waitForExistence(timeout: 2))
            added.tap()
            XCTAssertTrue(added.isSelected)
            online.tap()
            XCTAssertTrue(online.isSelected)
            XCTAssertTrue(app.buttons["model-info-openrouter:anthropic/claude-sonnet-4-6"].waitForExistence(timeout: 2))
        }
        // The same controls must remain responsive after editing the search.
        let search = app.textFields["model-search-field"]
        search.tap()
        search.typeText("Sonnet\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        catalog.tap()
        XCTAssertTrue(catalog.isSelected)
        local.tap()
        XCTAssertTrue(local.isSelected)
        online.tap()
        XCTAssertTrue(online.isSelected)
        added.tap()
        XCTAssertTrue(added.isSelected)
        XCTAssertEqual(search.value as? String, "Sonnet")
        app.buttons["Close"].tap()
        app.buttons["native-chat-message-field-launcher"].tap()
        XCTAssertTrue(app.buttons["native-chat-model-button"].label.contains("GPT-4.1"),
                      "Browsing execution or library filters must not change the active model")
    }

    @MainActor
    func testModelPickerFloatingControlsSupportLargeTextInBothThemes() {
        for theme in ["light", "dark"] {
            let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
            app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
            app.launchArguments += ["-aim.appearance", theme,
                                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            XCTAssertTrue(app.buttons["native-chat-actions"].waitForExistence(timeout: 5))
            openNativeModelPicker(app)
            let panel = app.descendants(matching: .any)["model-selection-sheet"]
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            let searchControl = app.descendants(matching: .any)["model-search-control"]
            let search = app.textFields["model-search-field"]
            let add = app.buttons["model-picker-add-models"]
            let providers = app.buttons["model-picker-providers"]
            XCTAssertTrue(searchControl.waitForExistence(timeout: 3))
            XCTAssertTrue(search.isHittable)
            for control in [searchControl, add, providers] {
                XCTAssertTrue(control.isHittable)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44)
                XCTAssertGreaterThanOrEqual(control.frame.width, 44)
                XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
            }
            // The visible capsule, including its left edge outside the text
            // field, must activate the search editor.
            searchControl.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            search.typeText("\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
            app.segmentedControls.buttons["Full catalog"].tap()
            let list = app.scrollViews["model-picker-list"]
            let lastModel = app.buttons["model-option-openrouter:openai/gpt-4.1"]
            XCTAssertTrue(list.waitForExistence(timeout: 3))
            for _ in 0..<12 {
                if lastModel.isHittable && lastModel.frame.maxY < add.frame.minY - 4 { break }
                list.swipeUp()
            }
            XCTAssertTrue(lastModel.isHittable)
            XCTAssertLessThan(lastModel.frame.maxY, add.frame.minY - 4,
                              "The last model must be reachable above the floating footer at large text sizes")
            XCTAssertTrue(add.isHittable)
            XCTAssertTrue(providers.isHittable)
            let modelY = lastModel.frame.minY
            keepScreenshot(named: "floating-model-picker-large-\(theme)-last-row", app: app)
            lastModel.tap()
            XCTAssertTrue(app.buttons["model-details-back"].waitForExistence(timeout: 3))
            keepScreenshot(named: "floating-model-detail-large-\(theme)", app: app)
            edgeBack(in: app)
            XCTAssertTrue(app.buttons["model-details-back"].waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.segmentedControls.buttons["Full catalog"].isSelected)
            XCTAssertTrue(lastModel.isHittable)
            XCTAssertEqual(lastModel.frame.minY, modelY, accuracy: 12)
            XCTAssertTrue(add.isHittable)
            XCTAssertTrue(providers.isHittable)
            let filter = app.buttons["Filter providers"]
            XCTAssertTrue(filter.isHittable)
            filter.tap()
            let allProviders = app.buttons["All providers"]
            XCTAssertTrue(allProviders.waitForExistence(timeout: 3))
            let filterMenu = app.collectionViews.firstMatch
            for _ in 0..<4 where !allProviders.isHittable { filterMenu.swipeDown() }
            XCTAssertTrue(allProviders.isHittable)
            allProviders.tap()
            XCTAssertTrue(panel.exists)
            XCTAssertTrue(app.segmentedControls.buttons["Full catalog"].isSelected)
            XCTAssertTrue(lastModel.isHittable)
            XCTAssertEqual(lastModel.frame.minY, modelY, accuracy: 12)
            app.buttons["Close"].tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testSettingsEdgeBackRestoresRootAndProtectsDirtyProviderKey() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["profile-menu"].tap()
        let root = app.descendants(matching: .any)["settings-root-screen"]
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        let general = app.buttons["settings-general-row"]
        for _ in 0..<6 where !general.isHittable { root.swipeUp() }
        XCTAssertTrue(general.isHittable)
        let generalY = general.frame.minY
        general.tap()
        XCTAssertTrue(app.buttons["settings-page-back"].waitForExistence(timeout: 3))
        edgeBack(in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        XCTAssertEqual(general.frame.minY, generalY, accuracy: 12)

        let providers = app.buttons["settings-providers-row"]
        for _ in 0..<6 where !providers.isHittable { root.swipeUp() }
        XCTAssertTrue(providers.isHittable); providers.tap()
        let provider = app.buttons["provider-openrouter-row"]
        XCTAssertTrue(provider.waitForExistence(timeout: 3)); provider.tap()
        let key = app.secureTextFields["provider-key-field"]
        XCTAssertTrue(key.waitForExistence(timeout: 3)); key.tap(); key.typeText("unsaved-fixture")
        let draft = key.value as? String
        edgeBack(in: app)
        let prompt = app.alerts["Unsaved key"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        keepScreenshot(named: "settings-dirty-provider-edge-back", app: app)
        prompt.buttons["Keep editing"].tap()
        XCTAssertTrue(key.exists)
        XCTAssertEqual(key.value as? String, draft)
        edgeBack(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 3)); prompt.buttons["Discard"].tap()
        XCTAssertTrue(provider.waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        edgeBack(in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 3))
    }

    @MainActor
    private func edgeBack(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.45))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    @MainActor
    func testModelCatalogDetailsAndLibraryActionsDoNotChangeTheActiveModel() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-chat-status"].waitForExistence(timeout: 5))
        openNativeModelPicker(app)
        XCTAssertTrue(app.segmentedControls.buttons["Added models"].waitForExistence(timeout: 3))
        app.buttons["model-info-openrouter:anthropic/claude-sonnet-4-6"].tap()
        XCTAssertTrue(app.buttons["model-details-back"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["$1.25 / 1M"].exists)
        keepScreenshot(named: "unified-model-details-from-added", app: app)
        app.buttons["model-details-back"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Added models"].isSelected)
        app.segmentedControls.buttons["Full catalog"].tap()
        let search = app.textFields["model-search-field"]
        search.tap(); search.typeText("Sonnet\n")
        app.buttons["model-option-anthropic:claude-sonnet-4-6"].tap()
        XCTAssertTrue(app.buttons["model-details-back"].waitForExistence(timeout: 3))
        let libraryAction = app.buttons["model-details-add"]
        XCTAssertEqual(libraryAction.label, "Remove model")
        libraryAction.tap()
        XCTAssertEqual(libraryAction.label, "Add model")
        libraryAction.tap()
        XCTAssertEqual(libraryAction.label, "Remove model")
        keepScreenshot(named: "unified-model-details-from-catalog", app: app)
        app.buttons["model-details-back"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Full catalog"].isSelected)
        app.buttons["Close"].tap()
        app.buttons["native-chat-message-field-launcher"].tap()
        let selectedModel = app.buttons["native-chat-model-button"]
        XCTAssertTrue(selectedModel.waitForExistence(timeout: 3))
        XCTAssertTrue(selectedModel.label.contains("GPT-4.1"))
        selectedModel.tap()
        XCTAssertTrue(app.segmentedControls.buttons["Added models"].waitForExistence(timeout: 3))
        app.buttons["model-option-anthropic:claude-sonnet-4-6"].tap()
        if app.buttons["native-chat-message-field-launcher"].waitForExistence(timeout: 3) { app.buttons["native-chat-message-field-launcher"].tap() }
        XCTAssertTrue(selectedModel.waitForExistence(timeout: 3))
        XCTAssertTrue(selectedModel.label.contains("Claude Sonnet 4.6"))
    }

    @MainActor
    func testSidebarConversationOpensTheNativeRemoteTimeline() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))

        app.buttons["main-menu-button"].tap()
        let sidebarSession = app.buttons["sidebar-session-ui-test-session"]
        XCTAssertTrue(sidebarSession.waitForExistence(timeout: 2))
        let sidebarReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: sidebarSession)
        XCTAssertEqual(XCTWaiter.wait(for: [sidebarReady], timeout: 3), .completed)
        sidebarSession.tap()
        let sidebarClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sidebarSession)
        XCTAssertEqual(XCTWaiter.wait(for: [sidebarClosed], timeout: 3), .completed)

        XCTAssertTrue(app.descendants(matching: .any)["conversation-screen"].waitForExistence(timeout: 3))
        let conversationSettled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.descendants(matching: .any)["conversation-screen"].frame
            return abs(frame.minX) < 1 && frame.maxX <= app.frame.width + 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [conversationSettled], timeout: 3), .completed)
        XCTAssertTrue(app.staticTexts["Où en est le projet ?"].exists)
        let bubble = app.descendants(matching: .any)["chat-user-bubble"].firstMatch
        XCTAssertLessThan(bubble.frame.minY, app.frame.height * 0.45, "Short remote transcripts start at the top, not above the composer")
        XCTAssertTrue(app.staticTexts["Le socle natif est prêt."].exists)
        XCTAssertTrue(app.buttons["conversation-send-button"].exists)
        let connectionIndicator = app.descendants(matching: .any)["conversation-header-status"]
        XCTAssertTrue(connectionIndicator.exists)
        XCTAssertEqual(connectionIndicator.value as? String, "Computer online")
        XCTAssertTrue(app.descendants(matching: .any)["chat-user-bubble"].firstMatch.exists)
        XCTAssertTrue(app.buttons["chat-copy-response"].firstMatch.exists)
        let executionTarget = app.buttons["conversation-select-execution-target"]
        if executionTarget.exists {
            let targetHittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: executionTarget)
            XCTAssertEqual(XCTWaiter.wait(for: [targetHittable], timeout: 3), .completed)
            executionTarget.tap()
        }

        app.buttons["conversation-message-field-launcher"].tap()
        XCTAssertTrue(app.textViews["conversation-message-field"].waitForExistence(timeout: 2))
        app.textViews["conversation-message-field"].tap()
        let modelButton = app.buttons["conversation-model-button"]
        let modelButtonHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: modelButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [modelButtonHittable], timeout: 2), .completed)
        modelButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model-selection-sheet"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testRunningRemoteTranscriptHasOneTextStatusAndStartsNearTop() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_REMOTE_RUNNING"] = "1"
        app.launch()
        let deviceStatus = app.buttons["native-chat-status"]
        XCTAssertTrue(deviceStatus.waitForExistence(timeout: 5)); deviceStatus.tap()
        let mac = app.buttons["Mac de Mathieu"]
        XCTAssertTrue(mac.waitForExistence(timeout: 3)); mac.tap()
        XCTAssertTrue(app.buttons["new-chat-header-status"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        let row = app.buttons["sidebar-session-ui-test-session"]
        XCTAssertTrue(row.waitForExistence(timeout: 3)); row.tap()
        let status = app.staticTexts["conversation-progress"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "conversation-progress").count, 1)
        XCTAssertEqual(status.label, "Syncing…")
        XCTAssertEqual(app.progressIndicators.count, 0)
        XCTAssertEqual(app.buttons["conversation-send-button"].label, "Stop response")
        let bubble = app.descendants(matching: .any)["chat-user-bubble"].firstMatch
        XCTAssertLessThan(bubble.frame.minY, app.frame.height * 0.45)
        keepScreenshot(named: "remote-single-status-top-alignment", app: app)
    }

    @MainActor
    func testNewChatFirstMessageCreatesAndOpensTheRemoteConversation() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))

        app.textViews["new-chat-message-field"].tap()
        app.textViews["new-chat-message-field"].typeText("Hello from iPhone")
        app.buttons["new-chat-send-button"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["conversation-screen"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testNewChatPlusMenuExposesMediaFilesConnectorsAndContext() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-chat-message-field-launcher"].waitForExistence(timeout: 5))
        app.buttons["native-chat-message-field-launcher"].tap()

        app.buttons["native-chat-attachment-button"].tap()

        let menu = app.descendants(matching: .any)["composer-plus-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        let surface = app.descendants(matching: .any)["composer-plus-overlay"]
        XCTAssertEqual(surface.frame.width, 248, accuracy: 1)
        XCTAssertEqual(menu.frame.width, 248, accuracy: 1) // Scroll container includes its content insets.
        XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Photos"].exists)
        XCTAssertTrue(app.buttons["Camera"].exists)
        XCTAssertTrue(app.buttons["Connectors"].exists)
        XCTAssertTrue(app.buttons["Context"].exists)
        XCTAssertEqual(app.keyboards.count, 1)
    }

    @MainActor
    func testPlusMenuStaysBoundedAndOverlapsKeyboardAcrossRepeatedOpenings() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["native-chat-message-field-launcher"].waitForExistence(timeout: 5))
        app.buttons["native-chat-message-field-launcher"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            app.buttons["native-chat-attachment-button"].tap()
            let menu = app.descendants(matching: .any)["composer-plus-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 3))
            XCTAssertLessThan(menu.frame.height, 340)
            XCTAssertLessThanOrEqual(menu.frame.width, 286.5)
            XCTAssertGreaterThan(menu.frame.maxY, app.keyboards.firstMatch.frame.minY)
            keepScreenshot(named: "bounded-plus-over-keyboard", app: app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.3)).tap()
            XCTAssertTrue(menu.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.keyboards.firstMatch.exists)
        }
    }

    @MainActor
    func testOpeningPhotosFromFocusedComposerKeepsFocusAndRestoresKeyboard() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))

        let editor = app.textViews["new-chat-message-field"]
        editor.tap()
        XCTAssertEqual(app.keyboards.count, 1)
        app.buttons["new-chat-attachment-button"].tap()
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 2))
        XCTAssertTrue(photos.isHittable)
        photos.tap()

        let panel = app.descendants(matching: .any)["composer-media-overlay"]
        XCTAssertTrue(panel.waitForExistence(timeout: 4))
        XCTAssertEqual(app.keyboards.count, 1)
        XCTAssertTrue(editor.exists)
        XCTAssertEqual(panel.frame.minX, 8, accuracy: 2)
        XCTAssertEqual(app.frame.maxX - panel.frame.maxX, 8, accuracy: 2)
        XCTAssertEqual(app.frame.maxY - panel.frame.maxY, 8, accuracy: 2)
        XCTAssertEqual(panel.frame.height, min(600, (app.frame.height * 0.70).rounded()), accuracy: 2)
        XCTAssertTrue(panel.frame.intersects(app.keyboards.firstMatch.frame))

        app.buttons["fake-photo-0"].tap()
        app.buttons["fake-photo-1"].tap()
        let addButton = app.buttons["photos-primary-button"]
        XCTAssertEqual(addButton.label, "Add 2")

        addButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(panel.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["new-chat-attachment-remove-0"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["new-chat-attachment-remove-1"].exists)
    }

    @MainActor
    func testSimulatedCameraUsesTheUniversalMediaGeometryAndClosesAfterCapture() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        app.buttons["new-chat-attachment-button"].tap()
        app.buttons["Camera"].tap()

        let panel = app.descendants(matching: .any)["composer-media-overlay"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertEqual(panel.frame.minX, 8, accuracy: 2)
        XCTAssertEqual(app.frame.maxX - panel.frame.maxX, 8, accuracy: 2)
        XCTAssertEqual(app.frame.maxY - panel.frame.maxY, 8, accuracy: 2)
        XCTAssertTrue(app.buttons["Back"].exists)
        XCTAssertTrue(app.buttons["Camera options"].exists)
        XCTAssertEqual(app.keyboards.count, 1)

        XCTAssertTrue(app.buttons["camera-capture-button"].exists)
        app.buttons["camera-capture-button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["new-chat-attachment-remove-0"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testWelcomeTitleUsesVisibleComposerBoundary() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        let title = app.staticTexts["new-chat-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["computer-state"].waitForNonExistence(timeout: 5))
        let header = app.buttons["main-menu-button"]
        let composer = app.descendants(matching: .any)["new-chat-composer"]
        let editor = app.textViews["new-chat-message-field"]
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let originalHeader = header.frame
        let originalTitleY = title.frame.midY
        XCTAssertEqual(title.frame.midY, (header.frame.maxY + composer.frame.minY) / 2, accuracy: 3)
        // Keyboard AX bounds can exclude the prediction strip. Assert no
        // overlap here; use the screenshot to inspect the actual top edge.
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY)
        keepScreenshot(named: "welcome-before-multiline", app: app)
        editor.typeText("First line\nSecond line\nThird line")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertLessThan(title.frame.midY, originalTitleY - 8)
        XCTAssertEqual(title.frame.midY, (header.frame.maxY + composer.frame.minY) / 2, accuracy: 3)
        XCTAssertEqual(header.frame, originalHeader)
        keepScreenshot(named: "welcome-visible-composer-boundary", app: app)
    }

    @MainActor
    func testComposerGrowsPastTwoLinesWithoutClippingTheThirdLine() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5)); launcher.tap()
        let editor = app.textViews["native-chat-message-field"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let initialHeight = editor.frame.height
        let composer = app.descendants(matching: .any)["native-chat-composer"]
        XCTAssertGreaterThanOrEqual(initialHeight, 34)
        XCTAssertGreaterThanOrEqual(editor.frame.minY, composer.frame.minY)
        XCTAssertLessThanOrEqual(editor.frame.maxY, composer.frame.maxY)
        editor.typeText("First line\nSecond line\nThird line")
        let grown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editor.frame.height > initialHeight + 18
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [grown], timeout: 3), .completed)
        XCTAssertTrue((editor.value as? String)?.contains("Third line") == true)
        XCTAssertLessThanOrEqual(editor.frame.maxY, composer.frame.maxY)
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 5)
        keepScreenshot(named: "floating-native-three-lines", app: app)
    }

    @MainActor
    func testSearchFindsAndOpensARemoteConversation() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))

        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-search"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["search-screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["search-result-ui-test-code-session"].exists)
        app.buttons["search-result-ui-test-code-session"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["conversation-screen"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testRound21SearchAndRecentsHaveIndependentPersistentFilters() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        let recent = app.buttons["recent-conversation-filter"]
        XCTAssertTrue(recent.waitForExistence(timeout: 3)); recent.tap()
        app.buttons["conversation-filter-kind-all"].tap()
        app.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.8)).tap()
        XCTAssertTrue(app.buttons["sidebar-session-ui-test-code-session"].exists)
        recent.tap(); app.buttons["conversation-filter-kind-chat"].tap()
        app.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.8)).tap()
        XCTAssertFalse(app.buttons["sidebar-session-ui-test-code-session"].exists)
        app.buttons["sidebar-search"].tap()
        let searchFilter = app.buttons["search-conversation-filter"]
        XCTAssertTrue(searchFilter.waitForExistence(timeout: 3)); searchFilter.tap()
        app.buttons["conversation-filter-kind-all"].tap()
        app.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.3)).tap()
        XCTAssertTrue(app.buttons["search-result-ui-test-code-session"].exists)
        searchFilter.tap(); app.buttons["conversation-filter-kind-code"].tap()
        app.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.3)).tap()
        XCTAssertFalse(app.buttons["search-result-ui-test-session"].exists)
        keepScreenshot(named: "round21-search-code-filter", app: app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        XCTAssertFalse(app.buttons["sidebar-session-ui-test-code-session"].exists)
        app.buttons["sidebar-search"].tap()
        XCTAssertTrue(app.buttons["search-result-ui-test-code-session"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["search-result-ui-test-session"].exists)
        // Restore the fixture defaults without resetting app data.
        app.buttons["search-conversation-filter"].tap(); app.buttons["conversation-filter-kind-all"].tap()
        app.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.3)).tap()
        app.buttons["close-conversation-search"].tap()
        recent.tap(); app.buttons["conversation-filter-kind-all"].tap()
        app.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.8)).tap()
    }

    @MainActor
    func testCodeDestinationShowsRealSessionsAndCreationFlow() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))

        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-code"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["code-sessions-screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["machine-filter-all"].exists)
        XCTAssertTrue(app.buttons["machine-filter-ui-test-machine"].exists)
        XCTAssertFalse(app.buttons["add-remote-device-button"].exists)
        XCTAssertTrue(app.buttons["session-row-ui-test-code-session"].exists)
        app.buttons["new-code-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["new-code-screen"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAgentCreationUsesContextChipsAndTheSharedComposer() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))

        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-agent"].tap()
        XCTAssertTrue(app.buttons["new-agent-button"].waitForExistence(timeout: 3))
        app.buttons["new-agent-button"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["new-agent-screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["new-remote-folder-button"].exists)
        XCTAssertTrue(app.buttons["new-remote-engine-button"].exists)
        XCTAssertTrue(app.textViews["conversation-message-field"].exists)
        XCTAssertTrue(app.buttons["conversation-permission-button"].exists)

        app.textViews["conversation-message-field"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["conversation-model-button"].exists)
    }

    @MainActor
    func testProfileSettingsLoadEditableProductFields() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        XCTAssertTrue(app.buttons["profile-menu"].waitForExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.45)
        app.buttons["profile-menu"].tap()
        XCTAssertTrue(app.buttons["settings-profile-row"].waitForExistence(timeout: 3))
        app.buttons["settings-profile-row"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["profile-settings-screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["profile-full-name-field"].exists)
        XCTAssertTrue(app.textFields["profile-preferred-name-field"].exists)
        XCTAssertTrue(app.buttons["profile-save-button"].exists)
    }

    @MainActor
    func testCodeConversationExpandsComposerAndShowsPermissions() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))

        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-code"].tap()
        XCTAssertTrue(app.buttons["session-row-ui-test-code-session"].waitForExistence(timeout: 3))
        app.buttons["session-row-ui-test-code-session"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["conversation-screen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["conversation-permission-button"].exists)
        app.buttons["conversation-message-field-launcher"].tap()
        XCTAssertTrue(app.textViews["conversation-message-field"].waitForExistence(timeout: 2))
        app.textViews["conversation-message-field"].tap()
        XCTAssertTrue(app.buttons["conversation-permission-button"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["conversation-model-button"].exists)
        XCTAssertTrue(app.buttons["conversation-effort-button"].exists)
    }

    @MainActor
    func testConversationStatusDotShowsConversationAndComputerDetails() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-session-ui-test-session"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["conversation-screen"].waitForExistence(timeout: 3))

        app.descendants(matching: .any)["conversation-header-status"].tap()

        XCTAssertTrue(app.staticTexts["Préparer le lancement AIM.AI"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Mac de Mathieu"].exists)
    }

    @MainActor
    func testSidebarConversationLongPressOffersSelectionAndDeletion() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()

        let conversation = app.buttons["sidebar-session-ui-test-session"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 2))
        conversation.press(forDuration: 0.8)

        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Delete"].exists)
        select.tap()
        XCTAssertEqual(app.staticTexts["sidebar-selection-count"].label, "1")
        app.buttons["sidebar-selection-actions"].tap()
        XCTAssertTrue(app.buttons["sidebar-selection-delete"].exists)
        XCTAssertTrue(app.buttons["Move to project"].exists)
        app.buttons["Move to project"].tap()
        XCTAssertTrue(app.buttons["New project"].waitForExistence(timeout: 3))
        keepScreenshot(named: "bulk-project-picker", app: app)
        app.buttons["New project"].tap()
        let alert = app.alerts["New project"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        alert.textFields.firstMatch.typeText("UI bulk project")
        alert.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["sidebar-selection-count"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testCodeConversationSwipeBackReturnsToSessionList() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-code"].tap()
        XCTAssertTrue(app.buttons["session-row-ui-test-code-session"].waitForExistence(timeout: 3))
        app.buttons["session-row-ui-test-code-session"].tap()
        let conversation = app.descendants(matching: .any)["conversation-screen"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 3))

        conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.45))
            .press(
                forDuration: 0.05,
                thenDragTo: conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45))
            )

        XCTAssertTrue(app.descendants(matching: .any)["code-sessions-screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["session-row-ui-test-code-session"].exists)
    }

    @MainActor
    func testSwipingOnCodeSessionRowDoesNotOpenConversation() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat-screen"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-code"].tap()
        let row = app.buttons["session-row-ui-test-code-session"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))

        row.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            )

        XCTAssertTrue(app.buttons["profile-menu"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)["conversation-screen"].exists)
    }

    @MainActor
    func testPersonalizationShowsExistingConnectorAndToolPermissions() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["sidebar-personalization"].tap()
        let row = app.buttons["web-account-row-ui-connector"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -100)))
        XCTAssertFalse(app.staticTexts["search_pages"].exists, "Scrolling from a row must cancel its activation")
        let form = app.descendants(matching: .any)["shared-connector-directory"]
        if !row.isHittable { form.swipeDown() }
        // Horizontal and slow diagonal motion do not necessarily begin the
        // vertical scroll view's pan, but must still cancel row activation.
        for delta in [CGVector(dx: -70, dy: 0), CGVector(dx: 45, dy: -35)] {
            let origin = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            origin.press(forDuration: 0.25, thenDragTo: origin.withOffset(delta))
            XCTAssertFalse(app.staticTexts["search_pages"].exists, "Any drag must fail the account tap")
        }
        // Bring the row fully below the floating header after the diagonal scroll.
        form.swipeDown()
        row.tap()
        XCTAssertTrue(app.staticTexts["search_pages"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["web-account-detail-title-ui-connector"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "personalization-floating-title").count, 1)
        XCTAssertFalse(app.staticTexts["Manage web accounts"].isHittable)
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 2)); XCTAssertTrue(row.isHittable)
    }

    @MainActor
    func testNativeProjectSourcesAddTextAndCancelFiles() {
        let app = projectQualificationApp()
        app.launch()
        createProject("Sources " + UUID().uuidString.prefix(6), in: app)
        XCTAssertTrue(app.staticTexts["project-chats-empty-title"].exists)
        XCTAssertTrue(app.staticTexts["project-chats-empty-body"].exists)
        XCTAssertTrue(app.buttons["project-chat-add-context"].exists)
        app.buttons["project-tab-sources"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["project-sources-empty"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["native-chat-message-field-launcher"].exists)
        keepScreenshot(named: "project-sources-empty", app: app)

        app.buttons["project-document-add"].tap()
        XCTAssertTrue(app.buttons["project-source-files"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["project-source-drive"].isEnabled)
        XCTAssertFalse(app.buttons["project-source-slack"].isEnabled)
        keepScreenshot(named: "project-source-add-options", app: app)
        app.buttons["project-source-files"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        // Files may cold-launch its system provider process while other targets compile.
        // Keep this OS-picker allowance separate from the app UI waits below.
        XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.tap()
        XCTAssertTrue(app.buttons["project-document-add"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["project-sources-empty"].exists)

        app.buttons["project-document-add"].tap(); app.buttons["project-source-text"].tap()
        let title = app.textFields["project-text-source-name"]
        XCTAssertTrue(title.waitForExistence(timeout: 3)); title.tap(); title.typeText("Blue notebook")
        let content = app.textViews["project-text-source-content"]
        content.tap(); content.typeText("Qualification reference: the blue notebook contains the project outline.")
        app.buttons["project-text-source-add"].tap()
        let source = app.buttons["Blue notebook.txt"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["project-sources-empty"].exists)
        source.tap()
        XCTAssertTrue(app.staticTexts["Qualification reference: the blue notebook contains the project outline."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Available to this project"].exists)
        keepScreenshot(named: "project-source-text-preview", app: app)
        app.buttons["project-source-preview-close"].tap()
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        let sourceIdentifier = source.identifier
        app.buttons["project-tab-chats"].tap()
        XCTAssertTrue(app.staticTexts["project-chats-empty-title"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["project-chat-add-context"].exists)
        app.buttons["project-tab-sources"].tap()

        // Renaming keeps the retained text and source identity; it is not a new import.
        let actions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-source-actions-")).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 3)); actions.tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-source-rename-")).firstMatch.tap()
        let rename = app.textFields["project-source-rename-name"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3)); rename.tap()
        let oldName = rename.value as? String ?? ""
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count) + "fiche-verification.txt")
        app.buttons["project-source-rename-save"].tap()
        let renamed = app.buttons["fiche-verification.txt"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 3)); XCTAssertFalse(source.exists)
        XCTAssertEqual(renamed.identifier, sourceIdentifier)
        renamed.tap()
        XCTAssertTrue(app.staticTexts["Qualification reference: the blue notebook contains the project outline."].waitForExistence(timeout: 5))
        app.buttons["project-source-preview-close"].tap()

        // Exclusion affects retrieval, not the fact that this project already has a source.
        actions.tap(); app.buttons["Exclude from context"].tap()
        XCTAssertTrue(renamed.waitForExistence(timeout: 3))
        app.buttons["project-tab-chats"].tap()
        XCTAssertTrue(app.staticTexts["project-chats-empty-title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["project-chats-empty-body"].exists)
        XCTAssertFalse(app.buttons["project-chat-add-context"].exists)
        keepScreenshot(named: "project-context-hint-hidden-with-excluded-source", app: app)
        app.buttons["project-tab-sources"].tap(); renamed.tap()
        XCTAssertTrue(app.staticTexts["Qualification reference: the blue notebook contains the project outline."].waitForExistence(timeout: 5))
        app.buttons["project-source-preview-close"].tap()
    }

    @MainActor
    func testProjectHomeScopesChatsAndKeepsComposerOnBothTabs() {
        let app = projectQualificationApp()
        app.launchEnvironment["AIM_UI_TEST_PROJECT_HOME"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["sidebar-projects"].tap()
        app.staticTexts["Project Home Fixture"].tap()
        let scoped = app.descendants(matching: .any)["project-chat-E16A719B-AFE5-4B99-8198-6CD3C3A71422"]
        XCTAssertTrue(scoped.waitForExistence(timeout: 3))
        XCTAssertTrue(scoped.label.contains("test 45 La suite de la réponse reste lisible."))
        XCTAssertFalse(app.descendants(matching: .any)["project-chat-date-E16A719B-AFE5-4B99-8198-6CD3C3A71422"].exists)
        XCTAssertFalse(app.staticTexts["project-chats-empty-title"].exists)
        XCTAssertFalse(app.staticTexts["project-chats-empty-body"].exists)
        XCTAssertFalse(app.buttons["project-chat-add-context"].exists)
        XCTAssertFalse(app.staticTexts["Outside project conversation"].exists)
        XCTAssertTrue(app.buttons["native-chat-message-field-launcher"].exists)
        keepScreenshot(named: "project-home-scoped-chats", app: app)

        app.buttons["project-tab-sources"].tap()
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 3))
        let headerY = app.staticTexts["project-home-title"].frame.midY
        launcher.tap()
        let editor = app.textViews["native-chat-message-field"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3)); editor.typeText("A project draft without sending")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let composer = app.descendants(matching: .any)["native-chat-composer"]
        let aboveKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            composer.frame.maxY <= app.keyboards.firstMatch.frame.minY + 5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [aboveKeyboard], timeout: 3), .completed)
        XCTAssertEqual(app.staticTexts["project-home-title"].frame.midY, headerY, accuracy: 2)
        keepScreenshot(named: "project-sources-keyboard-dock", app: app)
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.05,
            thenDragTo: composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        app.buttons["project-tab-chats"].tap()
        scoped.tap()
        XCTAssertTrue(app.buttons["native-chat-actions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["project-tab-sources"].exists)
    }

    @MainActor
    func testProjectEditsAndPinRemainAfterReopening() {
        let app = projectQualificationApp()
        app.launch()
        createProject("Edit " + UUID().uuidString.prefix(6), in: app)
        app.buttons["project-home-actions"].tap(); app.buttons["Edit project"].tap()
        let field = app.textFields["project-name-editor"]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap()
        let prior = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: prior.count) + "Renamed project")
        let projectMemory = app.buttons["project-memory-project-only"]
        if !projectMemory.isHittable { app.swipeUp() }
        projectMemory.tap(); app.buttons["project-name-save"].tap()
        XCTAssertTrue(app.staticTexts["project-home-title"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["project-home-title"].label, "Renamed project")

        app.buttons["project-home-actions"].tap(); app.buttons["Project instructions"].tap()
        let instructions = app.textViews["project-instructions-editor"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 3)); instructions.tap()
        instructions.typeText("Keep answers concise and cite project sources.")
        app.buttons["project-instructions-save"].tap()
        app.buttons["project-home-actions"].tap(); app.buttons["Pin project"].tap()
        app.buttons["project-home-back"].tap()
        app.staticTexts["Renamed project"].firstMatch.tap()
        app.buttons["project-home-actions"].tap()
        XCTAssertTrue(app.buttons["Unpin project"].waitForExistence(timeout: 3))
        app.buttons["Edit project"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3)); XCTAssertEqual(field.value as? String, "Renamed project")
        XCTAssertTrue(projectMemory.isSelected)
        keepScreenshot(named: "project-edited-memory", app: app)
        app.buttons["Cancel"].firstMatch.tap()
        app.buttons["project-home-actions"].tap(); app.buttons["Project instructions"].tap()
        XCTAssertTrue(instructions.waitForExistence(timeout: 3))
        XCTAssertEqual(instructions.value as? String, "Keep answers concise and cite project sources.")
        app.buttons["Cancel"].firstMatch.tap()
        app.buttons["project-home-actions"].tap(); app.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Your chats will be kept outside the project")).firstMatch.waitForExistence(timeout: 3))
        keepScreenshot(named: "project-delete-confirmation", app: app)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["project-home-actions"].exists)
    }

    @MainActor
    private func projectQualificationApp() -> XCUIApplication {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launchArguments += ["-AIMPrivateApplicationModeEnabled", "YES"]
        return app
    }

    @MainActor
    private func createProject(_ name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["sidebar-projects"].tap()
        app.buttons["native-new-project"].tap()
        let field = app.textFields["project-name-editor"]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText(name)
        app.buttons["project-name-save"].tap()
        XCTAssertTrue(app.buttons["project-home-actions"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["project-home-title"].label, name)
    }

    @MainActor
    func testLoadingStateIsVisible() {
        let app = makeApp(scenario: "loading", language: "en")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["authentication-loading"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmailErrorAndConfirmationFlow() {
        let app = makeApp(scenario: "signedOut", language: "en")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["authentication-screen"].waitForExistence(timeout: 5))

        app.buttons["show-sign-in"].tap()
        XCTAssertTrue(app.textFields["email-field"].waitForExistence(timeout: 5))
        app.textFields["email-field"].tap()
        app.textFields["email-field"].typeText("person@example.com")
        app.secureTextFields["password-field"].tap()
        app.secureTextFields["password-field"].typeText("incorrect")
        app.buttons["email-submit"].tap()

        XCTAssertTrue(app.staticTexts["authentication-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["authentication-error"].label, "Email or password is incorrect.")

        app.buttons["dismiss-error"].tap()
        app.buttons["show-sign-up"].tap()
        app.textFields["full-name-field"].tap()
        app.textFields["full-name-field"].typeText("Ada Lovelace")
        app.buttons["email-submit"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["confirmation-screen"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPasswordRecoveryScreenFromColdLaunch() {
        let app = makeApp(scenario: "recovery", language: "en")
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["password-recovery-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["new-password-field"].exists)
    }

    @MainActor
    func testComputerSelectionLivesInStatusPopoverAndPersistsAcrossModes() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_MULTIPLE_COMPUTERS"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["new-chat-header-status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["new-chat-computer-selection"].exists)
        app.buttons["new-chat-header-status"].tap()
        let selection = app.buttons["new-chat-computer-selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3)); selection.tap()
        XCTAssertTrue(app.buttons["Second Mac"].waitForExistence(timeout: 3)); app.buttons["Second Mac"].tap()
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        XCTAssertTrue(selection.label.contains("Second Mac") || (selection.value as? String)?.contains("Second Mac") == true)
        keepScreenshot(named: "v14-computer-status-menu", app: app)
        app.staticTexts["new-chat-title"].tap()
        app.buttons["creation-mode-code"].tap()
        XCTAssertTrue(app.buttons["new-remote-header-status"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["new-remote-computer-selection"].exists)
        app.buttons["new-remote-header-status"].tap()
        let codeSelection = app.buttons["new-remote-computer-selection"]
        XCTAssertTrue(codeSelection.waitForExistence(timeout: 3))
        XCTAssertTrue(codeSelection.label.contains("Second Mac") || (codeSelection.value as? String)?.contains("Second Mac") == true)
        codeSelection.tap(); app.buttons["Mac de Mathieu"].tap()
    }

    @MainActor
    func testCodeAndAgentComposerRemainAboveKeyboardWithoutExperimentalCard() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["sidebar-code"].tap()
        XCTAssertTrue(app.buttons["new-code-button"].waitForExistence(timeout: 3)); app.buttons["new-code-button"].tap()
        XCTAssertTrue(app.textViews["conversation-message-field"].waitForExistence(timeout: 3))
        for mode in ["code", "agent"] {
            if mode == "agent" { app.buttons["creation-mode-agent"].tap() }
            let field = app.textViews["conversation-message-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["Try experimental continuity"].exists)
            let model = app.buttons["conversation-model-button"]
            XCTAssertTrue(model.isHittable)
            XCTAssertLessThanOrEqual(model.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            keepScreenshot(named: "v14-" + mode + "-keyboard", app: app)
        }
    }

    @MainActor
    func testSecurityPresetsAndCustomSectionsCanBeSaved() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_SECURITY_POLICY"] = "1"; app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5)); app.buttons["main-menu-button"].tap()
        XCTAssertTrue(app.buttons["profile-menu"].waitForExistence(timeout: 3)); app.buttons["profile-menu"].tap()
        XCTAssertTrue(app.buttons["settings-security-row"].waitForExistence(timeout: 3)); app.buttons["settings-security-row"].tap()
        let presets = app.buttons["remote-protection-preset"]
        XCTAssertTrue(presets.waitForExistence(timeout: 3)); presets.tap()
        XCTAssertTrue(app.buttons["None"].waitForExistence(timeout: 3)); XCTAssertTrue(app.buttons["All sections"].exists)
        app.buttons["Custom"].tap()
        XCTAssertTrue(app.switches["remote-protection-chat"].waitForExistence(timeout: 3)); app.switches["remote-protection-chat"].tap()
        let save = app.buttons["save-remote-protection"]
        if !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isEnabled); save.tap()
        keepScreenshot(named: "v14-custom-security", app: app)
    }

    @MainActor
    func testClosingUnlockGateCannotExposeProtectedChat() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchEnvironment["AIM_UI_TEST_SECURITY_POLICY"] = "lockedAll"; app.launch()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5)); app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Unlock protected sections"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["main-menu-button"].exists)
        XCTAssertFalse(app.textViews["new-chat-message-field"].exists)
        keepScreenshot(named: "v14-locked-chat-after-cancel", app: app)
    }

    @MainActor
    func testRound20ProjectsSearchAndPersonalizationBothThemes() {
        for theme in ["light", "dark"] {
            let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
            app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
            app.launchEnvironment["AIM_UI_TEST_LIBRARY_MEDIA"] = "1"
            app.launchArguments += ["-aim.appearance", theme]
            app.launch()
            XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
            app.buttons["main-menu-button"].tap(); app.buttons["sidebar-projects"].tap()
            XCTAssertTrue(app.buttons["native-new-project"].waitForExistence(timeout: 3))
            keepScreenshot(named: "round20-projects-\(theme)", app: app)
            app.buttons["native-new-project"].tap()
            let name = app.textFields["Project name"]
            XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap(); name.typeText("Mobile project")
            app.buttons["Save"].tap()
            XCTAssertTrue(app.staticTexts["Mobile project"].waitForExistence(timeout: 3))
            keepScreenshot(named: "round20-project-row-\(theme)", app: app)
            app.buttons["Open menu"].firstMatch.tap(); app.buttons["sidebar-library"].tap()
            let firstTile = app.buttons["Wide image"].firstMatch
            let secondTile = app.buttons["Portrait image"].firstMatch
            XCTAssertTrue(firstTile.waitForExistence(timeout: 3)); XCTAssertTrue(secondTile.exists)
            XCTAssertEqual(firstTile.frame.width, firstTile.frame.height, accuracy: 1)
            XCTAssertEqual(secondTile.frame.width, secondTile.frame.height, accuracy: 1)
            XCTAssertLessThanOrEqual(firstTile.frame.maxX, secondTile.frame.minX)
            keepScreenshot(named: "round20-library-squares-\(theme)", app: app)
            app.buttons["cloud-content-back"].tap(); app.buttons["sidebar-search"].tap()
            let search = app.textFields["conversation-search-field"]
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            search.tap(); search.typeText("AIM")
            keepScreenshot(named: "round20-search-keyboard-\(theme)", app: app)
            app.buttons["close-conversation-search"].tap()
            XCTAssertTrue(app.buttons["sidebar-personalization"].waitForExistence(timeout: 3)); app.buttons["sidebar-personalization"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["personalization-screen"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["Manage web accounts"].exists)
            keepScreenshot(named: "round20-connectors-\(theme)", app: app)
            app.segmentedControls.buttons["Skills"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["skills-screen"].waitForExistence(timeout: 3))
            keepScreenshot(named: "round20-skills-\(theme)", app: app)
        }
    }

    @MainActor
    func testRound21PlusFirstTouchWithAndWithoutKeyboardPreservesDraft() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        let plus = app.buttons["native-chat-attachment-button"]
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        plus.tap()
        let menu = app.descendants(matching: .any)["composer-plus-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "First compact touch must present the menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3)).tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 3))
        XCTAssertTrue(launcher.isHittable)
        launcher.tap()
        let editor = app.textViews["native-chat-message-field"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let draft = "Keep this draft\nAnd the second line"
        editor.typeText(draft)
        for _ in 0..<3 {
            plus.tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 3), "First touch while focused must present the menu")
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3)).tap()
            XCTAssertTrue(menu.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            XCTAssertEqual(editor.value as? String, draft)
        }
        let composer = app.descendants(matching: .any)["native-chat-composer"]
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertFalse(launcher.exists, "A nonempty draft stays expanded after dismissal")
        XCTAssertEqual(editor.value as? String, draft)
        keepScreenshot(named: "round21-plus-draft-keyboard-dismissed", app: app)
    }

    @MainActor
    func testRound21CodeAgentComposerKeepsOuterMarginsAndReachableControls() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-code"].tap()
        XCTAssertTrue(app.buttons["new-code-button"].waitForExistence(timeout: 3))
        app.buttons["new-code-button"].tap()
        for mode in ["code", "agent"] {
            if mode == "agent" { app.buttons["creation-mode-agent"].tap() }
            let screen = app.descendants(matching: .any)["new-\(mode)-screen"]
            XCTAssertTrue(screen.waitForExistence(timeout: 3))
            let field = app.textViews["conversation-message-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            for identifier in ["conversation-attachment-button", "conversation-permission-button", "conversation-model-button", "conversation-send-button"] {
                let button = app.buttons[identifier]
                XCTAssertTrue(button.exists)
                XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 16, identifier)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 16, identifier)
                XCTAssertLessThanOrEqual(button.frame.maxY, app.keyboards.firstMatch.frame.minY + 5, identifier)
                XCTAssertGreaterThanOrEqual(button.frame.height, 43.9, identifier)
                XCTAssertEqual(button.frame.midY, app.buttons["conversation-attachment-button"].frame.midY, accuracy: 2, identifier)
            }
            let model = app.buttons["conversation-model-button"], effort = app.buttons["conversation-effort-button"]
            let lastModelControl = effort.exists ? effort : model
            if effort.exists { XCTAssertLessThanOrEqual(model.frame.maxX, effort.frame.minX + 0.1) }
            XCTAssertLessThanOrEqual(lastModelControl.frame.maxX, app.buttons["mic"].frame.minX + 0.1)
            XCTAssertLessThanOrEqual(app.buttons["conversation-permission-button"].frame.maxX, model.frame.minX + 0.1)
            keepScreenshot(named: "round21-\(mode)-composer-margins", app: app)
        }
    }

    @MainActor
    func testRound22ComposerSingleRowWithLargeTextAndDarkTheme() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launchArguments += ["-aim.appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["sidebar-code"].tap(); app.buttons["new-code-button"].tap()
        for mode in ["code", "agent"] {
            if mode == "agent" { app.buttons["creation-mode-agent"].tap() }
            let plus = app.buttons["conversation-attachment-button"]
            XCTAssertTrue(plus.waitForExistence(timeout: 3))
            for id in ["conversation-permission-button", "conversation-model-button", "mic", "conversation-send-button"] {
                let button = app.buttons[id]
                XCTAssertTrue(button.exists, id)
                XCTAssertEqual(button.frame.midY, plus.frame.midY, accuracy: 2, id)
                XCTAssertGreaterThanOrEqual(button.frame.width, 43.9, id)
                XCTAssertGreaterThanOrEqual(button.frame.minX, 16, id)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 16, id)
            }
            let model = app.buttons["conversation-model-button"], effort = app.buttons["conversation-effort-button"]
            if effort.exists { XCTAssertLessThanOrEqual(model.frame.maxX, effort.frame.minX + 0.1) }
            XCTAssertLessThanOrEqual((effort.exists ? effort : model).frame.maxX, app.buttons["mic"].frame.minX + 0.1)
            keepScreenshot(named: "round22-\(mode)-large-dark", app: app)
        }
    }

    @MainActor
    func testRound22NativeChatPlusRestoresPhotosAndCameraWithKeyboard() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any)["native-chat-composer"]
        XCTAssertEqual(composer.frame.minX, 28, accuracy: 1)
        XCTAssertEqual(app.frame.maxX - composer.frame.maxX, 28, accuracy: 1)
        launcher.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.frame.minX, 16, accuracy: 1)
        XCTAssertEqual(app.frame.maxX - composer.frame.maxX, 16, accuracy: 1)
        let plus = app.buttons["native-chat-attachment-button"]
        plus.tap()
        for name in ["Files", "Photos", "Camera", "Connectors", "Context"] { XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 2), name) }
        XCTAssertFalse(app.buttons["Continue toward a goal"].exists)
        app.buttons["Photos"].tap()
        XCTAssertTrue(app.buttons["fake-photo-0"].waitForExistence(timeout: 3))
        app.buttons["fake-photo-0"].tap(); app.buttons["fake-photo-1"].tap()
        app.buttons["photos-primary-button"].tap()
        XCTAssertTrue(app.buttons["native-chat-attachment-remove-1"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        plus.tap(); XCTAssertTrue(app.buttons["Camera"].waitForExistence(timeout: 2)); app.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["camera-capture-button"].waitForExistence(timeout: 3))
        app.buttons["camera-capture-button"].tap()
        XCTAssertTrue(app.buttons["native-chat-attachment-remove-2"].waitForExistence(timeout: 4))
        let remove = app.buttons["native-chat-attachment-remove-2"]
        XCTAssertGreaterThanOrEqual(remove.frame.width, 52)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 52)
        // Hit the transparent corner, outside the visible glyph. It must remove
        // the attachment rather than opening its underlying preview.
        remove.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertFalse(app.buttons["native-chat-attachment-remove-2"].exists)
        let strip = app.scrollViews["native-chat-attachment-strip"]
        XCTAssertTrue(strip.exists)
        XCTAssertEqual(strip.frame.height, 112, accuracy: 1)
        let editor = app.textViews["native-chat-message-field"]
        XCTAssertTrue(editor.isHittable, "Three attachments must leave the editor visible above the controls")
        XCTAssertLessThanOrEqual(editor.frame.maxY, app.buttons["native-chat-attachment-button"].frame.minY)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        keepScreenshot(named: "round22-native-inputs-camera-photos", app: app)
    }

    @MainActor
    func testRound23PhotosDoesNotExpandUnfocusedEmptyComposer() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launch()
        let composer = app.descendants(matching: .any)["native-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let before = composer.frame
        app.buttons["native-chat-attachment-button"].tap()
        app.buttons["Photos"].tap()
        XCTAssertTrue(app.buttons["fake-photo-0"].waitForExistence(timeout: 3))
        XCTAssertEqual(composer.frame.height, before.height, accuracy: 1)
        XCTAssertEqual(composer.frame.minY, before.minY, accuracy: 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        keepScreenshot(named: "round23-photos-compact-stable", app: app)
    }

    @MainActor
    func testRound22AgentPickerAndModeSpecificPlusActions() {
        let app = makeApp(scenario: "authenticated", language: "en")
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap(); app.buttons["sidebar-agent"].tap()
        app.buttons["new-agent-button"].tap()
        XCTAssertTrue(app.buttons["new-remote-engine-button"].waitForExistence(timeout: 3))
        app.buttons["new-remote-engine-button"].tap()
        for id in ["aim", "hermes", "openclaw"] { XCTAssertTrue(app.buttons["remote-agent-" + id].waitForExistence(timeout: 3), id) }
        app.buttons["remote-agent-aim"].tap()
        app.buttons["conversation-attachment-button"].tap()
        for name in ["Files", "Photos", "Camera", "Connectors", "Context", "Continue toward a goal"] { XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 2), name) }
        keepScreenshot(named: "round22-agent-plus-actions", app: app)
    }

    @MainActor
    private func makeApp(scenario: String? = nil, language: String) -> XCUIApplication {
        let app = XCUIApplication()
        if let scenario {
            app.launchEnvironment["AIM_UI_TEST_SCENARIO"] = scenario
        }
        app.launchEnvironment["AIM_UI_TEST_FAKE_CAMERA"] = "1"
        app.launchEnvironment["AIM_UI_TEST_FAKE_PHOTOS"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "fr" ? "fr_FR" : "en_US",
        ]
        return app
    }

    @MainActor
    private func keepScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension AIMUITests {
    @MainActor
    func testRound24LongComposerKeepsBoundedHeightAndStableKeyboardAnchor() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launchEnvironment["AIM_COMPOSER_TRACE"] = "1"
        app.launch()
        let launcher = app.buttons["native-chat-message-field-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5)); launcher.tap()
        let editor = app.textViews["native-chat-message-field"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let paragraph = String(repeating: "Long pasted text with a stable cursor. ", count: 35)
        editor.typeText(paragraph)
        let composer = app.descendants(matching: .any)["native-chat-composer"]
        XCTAssertLessThanOrEqual(editor.frame.height, 197)
        XCTAssertEqual(composer.frame.minX, 16, accuracy: 1)
        XCTAssertEqual(composer.frame.maxX, app.frame.maxX - 16, accuracy: 1)
        XCTAssertEqual(editor.value as? String, paragraph)
        let stable = composer.frame
        for _ in 0..<5 {
            XCTAssertEqual(composer.frame.height, stable.height, accuracy: 1)
            XCTAssertEqual(composer.frame.minY, stable.minY, accuracy: 1)
            XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 5)
        }
        editor.typeText("END")
        XCTAssertTrue((editor.value as? String)?.hasSuffix("END") == true)
        XCTAssertLessThanOrEqual(editor.frame.height, 197)
        let plus = app.buttons["conversation-attachment-button"]
        if plus.exists { XCTAssertTrue(plus.isHittable) }
        keepScreenshot(named: "round24-long-composer-stable", app: app)
    }
}

extension AIMUITests {
    @MainActor
    func testRound24SourcesAndActionsOpenPanelsWithoutRawDescriptions() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launchEnvironment["AIM_UI_TEST_SOURCES_ACTIONS"] = "1"
        app.launch()
        // Older answers without a timeline fold their actions above the answer.
        let work = app.buttons["turn-work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5)); work.tap()
        let tool = app.buttons["turn-tool-fixture:search"]
        XCTAssertTrue(tool.waitForExistence(timeout: 3)); tool.tap()
        XCTAssertTrue(app.navigationBars["Actions"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["actual search query"].waitForExistence(timeout: 3))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["actual search output"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "NativeWebSearchActivity(")).firstMatch.exists)
        keepScreenshot(named: "round24-action-input-output", app: app)
        app.buttons["Close"].tap()
        let sources = app.buttons["Sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 3)); sources.tap()
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Example source"].exists)
        XCTAssertTrue(app.staticTexts["example.com"].exists)
        keepScreenshot(named: "round24-structured-sources", app: app)
    }
}

extension AIMUITests {
    @MainActor
    func testRound25TimelineFoldsWorkAndScrollsLongToolGroups() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launchEnvironment["AIM_UI_TEST_TIMELINE"] = "1"
        app.launch()
        let work = app.buttons["turn-work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        XCTAssertTrue(work.label.contains("Worked for 1 min 12 s"))
        XCTAssertFalse(app.staticTexts["I’ll check the official announcements first."].exists, "intermediate text stays folded")
        keepScreenshot(named: "round25-timeline-folded", app: app)
        work.tap()
        let reasoning = app.buttons["turn-reasoning"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 3))
        XCTAssertEqual(reasoning.label, "Provider reasoning text")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "official documentation first.")).firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Thought for")).count, 0,
                       "The provider detail never repeats the global duration")
        let group = app.buttons["turn-tool-group"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.label.contains("Searched 7 times"))
        group.tap()
        XCTAssertTrue(app.buttons["turn-tool-web:fixture0"].waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(app.buttons["turn-tool-web:fixture0"].frame.height, 44)
        keepScreenshot(named: "round25-timeline-unfolded", app: app)
        app.buttons["turn-tool-web:fixture0"].tap()
        XCTAssertTrue(app.navigationBars["Actions"].waitForExistence(timeout: 3))
        // The touched action is unfolded: its output exists only inside the panel.
        XCTAssertTrue(app.staticTexts["Decisions API"].waitForExistence(timeout: 3))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["3 results"].waitForExistence(timeout: 3))
        keepScreenshot(named: "round25-timeline-tool-detail", app: app)
    }
}

extension AIMUITests {
    @MainActor
    func testRound26CitationPillOpensSourcesOnTheCitedSite() {
        let app = makeApp(scenario: "authenticatedUnpaired", language: "en")
        app.launchEnvironment["AIM_UI_TEST_NATIVE_CHAT"] = "1"
        app.launchEnvironment["AIM_UI_TEST_TIMELINE"] = "1"
        app.launch()
        let pill = app.links.matching(NSPredicate(format: "label CONTAINS %@", "openai.com")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the [1] reference is shown as a domain pill")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "[1]")).firstMatch.exists)
        keepScreenshot(named: "round26-citation-pill", app: app)
        pill.tap()
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["source-row-developers.openai.com"].waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(app.buttons["source-row-developers.openai.com"].frame.height, 44)
        keepScreenshot(named: "round26-sources-panel", app: app)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["message-sources"].waitForExistence(timeout: 3))
    }
}

extension AIMUITests {
    @MainActor
    func testPendingInteractionDockStaysPinnedInBothThemes() {
        for theme in ["light", "dark"] {
            let app = makeApp(scenario: "authenticated", language: "fr")
            app.launchEnvironment["AIM_UI_TEST_PENDING_INTERACTION"] = "approval"
            app.launchArguments += ["-aim.appearance", theme]
            app.launch()
            XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
            app.buttons["main-menu-button"].tap()
            app.buttons["sidebar-session-ui-test-session"].tap()
            let allow = app.buttons["pending-approval-allow"]
            XCTAssertTrue(allow.waitForExistence(timeout: 5))
            let originalY = allow.frame.minY
            let timeline = app.scrollViews["immersive-conversation-scroll"]
            XCTAssertTrue(timeline.exists)
            timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
            XCTAssertEqual(allow.frame.minY, originalY, accuracy: 3)
            XCTAssertGreaterThanOrEqual(allow.frame.height, 44)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Ouvrir TextEdit sur le Mac de test")).firstMatch.exists)
            XCTAssertFalse(app.staticTexts["open_app"].exists)
            keepScreenshot(named: "pending-dock-approval-\(theme)", app: app)
            let field = app.textViews["conversation-message-field"]
            app.buttons["conversation-message-field-launcher"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            if field.exists {
                field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
                XCTAssertLessThan(allow.frame.maxY, app.keyboards.firstMatch.frame.minY)
                keepScreenshot(named: "pending-dock-keyboard-\(theme)", app: app)
            }
            allow.tap()
            XCTAssertTrue(allow.exists, "Pending card must remain while approval acknowledgement is unconfirmed")
        }
    }

    @MainActor
    func testPendingQuestionDockOpensAnswerSheet() {
        for theme in ["light", "dark"] {
            let app = makeApp(scenario: "authenticated", language: "fr")
            app.launchEnvironment["AIM_UI_TEST_PENDING_INTERACTION"] = "question"
            app.launchArguments += ["-aim.appearance", theme]
            app.launch()
            XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
            app.buttons["main-menu-button"].tap()
            app.buttons["sidebar-session-ui-test-session"].tap()
            let answer = app.buttons["answer-agent-questions"]
            XCTAssertTrue(answer.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(answer.frame.height, 44)
            XCTAssertFalse(app.staticTexts["ask_user"].exists)
            keepScreenshot(named: "pending-dock-question-\(theme)", app: app)
            answer.tap()
            XCTAssertTrue(app.staticTexts["Quelle application souhaitez-vous utiliser ?"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["TextEdit"].exists)
            keepScreenshot(named: "pending-dock-question-sheet-\(theme)", app: app)
        }
    }

    @MainActor
    func testPendingApprovalDockWithAccessibilityText() {
        let app = makeApp(scenario: "authenticated", language: "fr")
        app.launchEnvironment["AIM_UI_TEST_PENDING_INTERACTION"] = "approval"
        app.launchArguments += ["-aim.appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["main-menu-button"].waitForExistence(timeout: 5))
        app.buttons["main-menu-button"].tap()
        app.buttons["sidebar-session-ui-test-session"].tap()
        let allow = app.buttons["pending-approval-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        XCTAssertTrue(allow.isHittable)
        XCTAssertGreaterThanOrEqual(allow.frame.height, 44)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Ouvrir TextEdit sur le Mac de test")).firstMatch.exists)
        keepScreenshot(named: "pending-dock-accessibility-text", app: app)
    }
}


/// Real app/controller/RPC pilot. No fake Remote service and no model API call.
/// Activated only by the isolated app driver; ordinary CI never needs a Mac host.
final class AIMQAPilotUITests: XCTestCase {
    @MainActor
    private func configuredApp(fault: Bool = false) throws -> XCUIApplication {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let runID = env["AIM_QA_RUN_ID"], let invite = env["AIM_QA_INVITE"],
              let catalog = env["AIM_QA_EXPECTED_CATALOG"] else {
            throw XCTSkip("Run scripts/qa/app_pilot.py to prepare a separate Mac host")
        }
        let app = XCUIApplication()
        app.launchEnvironment["AIM_QA_RUN_ID"] = runID
        app.launchEnvironment["AIM_QA_INVITE"] = invite
        app.launchEnvironment["AIM_QA_EXPECTED_CATALOG"] = catalog
        if fault { app.launchEnvironment["AIM_QA_FAULT"] = "catalog-mismatch" }
        app.launch()
        XCTAssertTrue(app.buttons["qa-verify"].waitForExistence(timeout: 15))
        wait(app.staticTexts["qa-client-status"], label: "QA client ready", seconds: 50)
        return app
    }

    @MainActor
    private func wait(_ element: XCUIElement, label: String, seconds: TimeInterval = 30) {
        let expected = NSPredicate(format: "label == %@", label)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: element)], timeout: seconds), .completed)
    }

    @MainActor
    private func waitDirectConnection(_ app: XCUIApplication) {
        // ICE may select a host candidate on a globally addressed interface.
        // Record its actual route; same-host simulator does not qualify Internet.
        let expected = NSPredicate(format: "label IN %@", ["Direct · local network", "Direct · peer to peer"])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: app.staticTexts["qa-connection-state"])], timeout: 30), .completed)
    }

    @MainActor
    func testReadCatalogAndReconnectAcrossLaunches() throws {
        let app = try configuredApp()
        if app.staticTexts["qa-pair-id"].label == "unpaired" {
            app.buttons["qa-pair"].tap()
            let paired = NSPredicate(format: "label != %@ AND label != %@", "unpaired", "")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: paired, object: app.staticTexts["qa-pair-id"])], timeout: 50), .completed)
            wait(app.staticTexts["qa-client-status"], label: "QA client ready", seconds: 5)
        }
        let pair = app.staticTexts["qa-pair-id"].label
        XCTAssertNotEqual(pair, "unpaired")
        waitDirectConnection(app)
        app.buttons["qa-verify"].tap()
        wait(app.staticTexts["qa-read-result"], label: "read-ok")
        wait(app.staticTexts["qa-catalog-result"], label: "catalog-ok")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["qa-verify"].waitForExistence(timeout: 15))
        wait(app.staticTexts["qa-client-status"], label: "QA client ready", seconds: 50)
        XCTAssertEqual(app.staticTexts["qa-pair-id"].label, pair)
        waitDirectConnection(app)
        app.buttons["qa-verify"].tap()
        wait(app.staticTexts["qa-catalog-result"], label: "catalog-ok")
        app.buttons["qa-disconnect"].tap()
        wait(app.staticTexts["qa-connection-state"], label: "Not connected")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["qa-verify"].waitForExistence(timeout: 15))
        wait(app.staticTexts["qa-client-status"], label: "QA client ready", seconds: 50)
        XCTAssertEqual(app.staticTexts["qa-pair-id"].label, pair)
        wait(app.staticTexts["qa-connection-state"], label: "Not connected")
        app.buttons["qa-reconnect"].tap()
        waitDirectConnection(app)
        app.buttons["qa-verify"].tap()
        wait(app.staticTexts["qa-catalog-result"], label: "catalog-ok")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "isolated-app-pilot-no-invitation"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testInjectedCatalogMismatchIsDiagnosed() throws {
        let app = try configuredApp(fault: true)
        waitDirectConnection(app)
        app.buttons["qa-verify"].tap()
        wait(app.staticTexts["qa-read-result"], label: "read-ok")
        wait(app.staticTexts["qa-client-status"], label: "Catalog mismatch")
        XCTAssertEqual(app.staticTexts["qa-catalog-result"].label, "catalog-pending")
    }
}


/// Physical camera exercise, never selected by the simulator suite.
final class AIMPhysicalScannerUITests: XCTestCase {
    @MainActor
    func testRealScannerTenOpenCloseCyclesAndForegroundReturn() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A simulator cannot qualify the physical camera")
        #else
        guard ProcessInfo.processInfo.environment["AIM_QA_PHYSICAL_SCANNER"] == "1" else {
            throw XCTSkip("An authorized physical session and separate QA app are required")
        }
        let app = XCUIApplication()
        app.launchEnvironment["AIM_UI_TEST_CONFIGURATION"] = "missing"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // No AIM_UI_TEST_FAKE_CAMERA: this uses AVCaptureSession on the iPhone.
        let monitor = addUIInterruptionMonitor(withDescription: "QA camera consent") { alert in
            let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
            guard text.contains("camera") || text.contains("caméra") else { return false }
            for label in ["Allow", "OK", "Autoriser"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        app.launch()
        XCTAssertTrue(app.buttons["native-chat-status"].waitForExistence(timeout: 15))
        app.buttons["native-chat-status"].tap()
        let manage = app.buttons["Manage Macs"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5)); manage.tap()
        let add = app.buttons["direct-add-mac"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let pairs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "direct-computer-"))
        let before = pairs.count
        for iteration in 0..<10 {
            add.tap()
            let close = app.buttons["direct-close-pairing"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            if iteration % 2 == 1 { RunLoop.current.run(until: Date().addingTimeInterval(2)) }
            if iteration == 5 {
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(close.waitForExistence(timeout: 5))
            }
            close.tap()
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertEqual(pairs.count, before)
        }
        // This checks responsiveness and pairing preservation. Verify camera
        // shutdown through capture diagnostics/physical observation separately.
        #endif
    }
}
