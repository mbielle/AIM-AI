import AIMCore
import Foundation
import Observation

struct BundleConfigurationLoader {
    func load(from values: [String: Any]) throws -> AppConfiguration {
        try AppConfiguration(
            projectURLString: values["AIMSupabaseURL"] as? String ?? "",
            publicAPIKey: values["AIMSupabasePublicKey"] as? String ?? ""
        )
    }
}

/// Operator opt-in for an externally maintained legacy web-account broker.
/// A Supabase URL alone does not imply that this optional service exists.
struct LegacyCloudCapabilities {
    let oauthBrokerConfigured: Bool
    init(values: [String: Any]) {
        if let value = values["AIMLegacyOAuthBrokerConfigured"] as? Bool { oauthBrokerConfigured = value }
        else if let value = values["AIMLegacyOAuthBrokerConfigured"] as? String {
            oauthBrokerConfigured = ["yes", "true", "1"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } else { oauthBrokerConfigured = false }
    }
}

@MainActor
@Observable
final class AppEnvironment {
    enum UITestScenario: String, Sendable {
        case signedOut
        case authenticated
        case authenticatedOffline
        case authenticatedUnpaired
        case authenticatedRemoteFailure
        case loading
        case recovery
    }

    enum State: Equatable {
        case configured(AppConfiguration)
        case misconfigured(ConfigurationError)
    }

    let state: State
    let uiTestScenario: UITestScenario?
    let legacyOAuthBrokerConfigured: Bool

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        legacyOAuthBrokerConfigured = LegacyCloudCapabilities(values: infoDictionary).oauthBrokerConfigured
        if processEnvironment["AIM_UI_TEST_CONFIGURATION"] == "missing" {
            uiTestScenario = nil
            state = .misconfigured(.missingProjectURL)
            return
        }

        #if DEBUG
        if
            let rawScenario = processEnvironment["AIM_UI_TEST_SCENARIO"],
            let scenario = UITestScenario(rawValue: rawScenario)
        {
            uiTestScenario = scenario
            do {
                state = .configured(
                    try AppConfiguration(
                        projectURLString: "https://example.supabase.co",
                        publicAPIKey: "sb_publishable_ui_test"
                    )
                )
            } catch let error as ConfigurationError {
                state = .misconfigured(error)
            } catch {
                state = .misconfigured(.invalidProjectURL)
            }
            return
        }
        #endif

        uiTestScenario = nil
        do {
            state = .configured(try BundleConfigurationLoader().load(from: infoDictionary))
        } catch let error as ConfigurationError {
            state = .misconfigured(error)
        } catch {
            state = .misconfigured(.invalidProjectURL)
        }
    }
}
