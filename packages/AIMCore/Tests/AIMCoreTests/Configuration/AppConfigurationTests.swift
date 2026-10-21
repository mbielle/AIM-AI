import Foundation
import XCTest
@testable import AIMCore

final class AppConfigurationTests: XCTestCase {
    private let projectURL = "https://example.supabase.co"
    private let anonJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiJ9.signature"
    private let serviceRoleJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.signature"
    private let appleClientSecretJWT = "eyJhbGciOiJFUzI1NiJ9.eyJhdWQiOiJodHRwczovL2FwcGxlaWQuYXBwbGUuY29tIiwic3ViIjoiY29tLmFpbWFpLndlYi5hdXRoIn0.signature"

    func testAcceptsHTTPSProjectURLAndLegacyAnonKey() throws {
        let configuration = try AppConfiguration(
            projectURLString: projectURL,
            publicAPIKey: anonJWT
        )

        XCTAssertEqual(configuration.projectURL.absoluteString, projectURL)
        XCTAssertEqual(configuration.publicAPIKey, anonJWT)
    }

    func testRejectsMissingConfiguration() {
        XCTAssertThrowsError(
            try AppConfiguration(projectURLString: "", publicAPIKey: "")
        ) { error in
            XCTAssertEqual(error as? ConfigurationError, .missingProjectURL)
        }
    }

    func testRejectsNonHTTPSProjectURL() {
        XCTAssertThrowsError(
            try AppConfiguration(projectURLString: "http://example.supabase.co", publicAPIKey: anonJWT)
        ) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidProjectURL)
        }
    }

    func testRejectsPersonalAccessToken() {
        XCTAssertThrowsError(
            try AppConfiguration(projectURLString: projectURL, publicAPIKey: "sbp_personal")
        ) { error in
            XCTAssertEqual(error as? ConfigurationError, .privilegedKeyForbidden)
        }
    }

    func testRejectsSecretKey() {
        XCTAssertThrowsError(
            try AppConfiguration(projectURLString: projectURL, publicAPIKey: "sb_secret_private")
        ) { error in
            XCTAssertEqual(error as? ConfigurationError, .privilegedKeyForbidden)
        }
    }

    func testRejectsLegacyServiceRoleJWT() {
        XCTAssertThrowsError(
            try AppConfiguration(projectURLString: projectURL, publicAPIKey: serviceRoleJWT)
        ) { error in
            XCTAssertEqual(error as? ConfigurationError, .privilegedKeyForbidden)
        }
    }

    func testRejectsJWTThatIsNotALegacyAnonKey() {
        XCTAssertThrowsError(
            try AppConfiguration(projectURLString: projectURL, publicAPIKey: appleClientSecretJWT)
        ) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidPublicAPIKey)
        }
    }

    func testRejectsUnknownNonJWTKey() {
        XCTAssertThrowsError(
            try AppConfiguration(projectURLString: projectURL, publicAPIKey: "not-a-supabase-key")
        ) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidPublicAPIKey)
        }
    }

    func testAcceptsPublishableKey() throws {
        let configuration = try AppConfiguration(
            projectURLString: projectURL,
            publicAPIKey: "sb_publishable_public"
        )

        XCTAssertEqual(configuration.publicAPIKey, "sb_publishable_public")
    }

    func testRejectsURLCredentialsEvenWhenPasswordIsEmpty() throws {
        for password in ["fixture", ""] {
            var components = try XCTUnwrap(URLComponents(string: projectURL))
            components.user = "fixture"
            components.password = password
            XCTAssertThrowsError(try AppConfiguration(
                projectURLString: try XCTUnwrap(components.string), publicAPIKey: anonJWT
            )) { XCTAssertEqual($0 as? ConfigurationError, .invalidProjectURL) }
        }
    }

    func testRejectsNonOriginComponentsAndInvalidPorts() {
        for suffix in ["/rest/v1", "/auth/v1", "?", "?credential=fixture", "#", "#fragment", ":0", ":65536"] {
            XCTAssertThrowsError(try AppConfiguration(
                projectURLString: projectURL + suffix, publicAPIKey: anonJWT
            ), suffix) { XCTAssertEqual($0 as? ConfigurationError, .invalidProjectURL) }
        }
    }

    func testAcceptsCustomHTTPSOriginWithExplicitPortAndRootSlash() throws {
        let configuration = try AppConfiguration(
            projectURLString: "https://backend.example:8443/", publicAPIKey: anonJWT
        )
        XCTAssertEqual(configuration.projectURL.absoluteString, "https://backend.example:8443/")
    }
}
