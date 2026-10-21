import AIMCore
import SwiftUI

struct ConfigurationErrorView: View {
    let error: ConfigurationError

    var body: some View {
        ContentUnavailableView {
            Label("configuration.title", systemImage: "gear.badge.questionmark")
                .accessibilityIdentifier("configuration-error-title")
        } description: {
            Text(messageKey)
        } actions: {
            Text("configuration.instructions")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var messageKey: LocalizedStringKey {
        switch error {
        case .missingProjectURL, .missingPublicAPIKey:
            "configuration.missing"
        case .invalidProjectURL:
            "configuration.invalid_url"
        case .privilegedKeyForbidden:
            "configuration.forbidden_key"
        case .invalidPublicAPIKey:
            "configuration.invalid_key"
        }
    }
}
