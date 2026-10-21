import AIMApplication
import XCTest

final class ActivityPrivacyPolicyTests: XCTestCase {
    func testJournalIsOptInAndDefaultsToThirtyDays() {
        let settings = ActivitySettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.retentionDays, 30)
    }

    func testPrivateAndSensitiveActivityIsExcluded() {
        let settings = ActivitySettings(isEnabled: true)
        XCTAssertTrue(ActivityPrivacyPolicy.shouldExclude(
            application: "Google Chrome",
            title: "Incognito",
            url: "https://example.com",
            isPrivate: true,
            settings: settings
        ))
        XCTAssertTrue(ActivityPrivacyPolicy.shouldExclude(
            application: "Safari",
            title: "Checkout",
            url: "https://checkout.stripe.com/payment",
            isPrivate: false,
            settings: settings
        ))
        XCTAssertTrue(ActivityPrivacyPolicy.shouldExclude(
            application: "1Password",
            title: "Vault",
            url: nil,
            isPrivate: false,
            settings: settings
        ))
    }

    func testOrdinaryWorkAppIsAllowedButBrowserIsNot() {
        XCTAssertFalse(ActivityPrivacyPolicy.shouldExclude(
            application: "Xcode",
            title: "Swift documentation",
            url: nil,
            isPrivate: false,
            settings: ActivitySettings(isEnabled: true)
        ))
        XCTAssertTrue(ActivityPrivacyPolicy.shouldExclude(
            application: "Safari",
            title: "Swift documentation",
            url: "https://developer.apple.com/documentation/swift",
            isPrivate: false,
            settings: ActivitySettings(isEnabled: true)
        ))
    }
}
