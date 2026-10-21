import AIMCore
import XCTest
@testable import AIM

final class BundleConfigurationLoaderTests: XCTestCase {
    func testLegacyOAuthBrokerRequiresExplicitOperatorCapability() {
        XCTAssertFalse(LegacyCloudCapabilities(values: [:]).oauthBrokerConfigured)
        XCTAssertFalse(LegacyCloudCapabilities(values: ["AIMSupabaseURL": "https://example.supabase.co"]).oauthBrokerConfigured)
        XCTAssertFalse(LegacyCloudCapabilities(values: ["AIMLegacyOAuthBrokerConfigured": "NO"]).oauthBrokerConfigured)
        XCTAssertFalse(LegacyCloudCapabilities(values: ["AIMLegacyOAuthBrokerConfigured": "$(AIM_LEGACY_OAUTH_BROKER_CONFIGURED)"]).oauthBrokerConfigured)
        XCTAssertTrue(LegacyCloudCapabilities(values: ["AIMLegacyOAuthBrokerConfigured": "YES"]).oauthBrokerConfigured)
        XCTAssertTrue(LegacyCloudCapabilities(values: ["AIMLegacyOAuthBrokerConfigured": true]).oauthBrokerConfigured)
    }

    func testLoadsInjectedConfiguration() throws {
        let configuration = try BundleConfigurationLoader().load(from: [
            "AIMSupabaseURL": "https://example.supabase.co",
            "AIMSupabasePublicKey": "sb_publishable_test",
        ])

        XCTAssertEqual(configuration.projectURL.absoluteString, "https://example.supabase.co")
        XCTAssertEqual(configuration.publicAPIKey, "sb_publishable_test")
    }

    func testEmptyDictionaryReportsMissingConfiguration() {
        XCTAssertThrowsError(try BundleConfigurationLoader().load(from: [:])) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingProjectURL)
        }
    }
}
