import AIMCore
import AIMApplication
import SwiftUI

/// Per-provider backup model: when the chosen model is unavailable or
/// overloaded, an Agent run continues on this one (same provider and key).
struct FallbackModelsView: View {
    @State private var values: [ChatProvider: String] = [:]
    private let providers: [ChatProvider] = [.openRouter, .anthropic, .openAI, .google, .xAI, .deepSeek]

    var body: some View {
        SettingsGroup("Backup models", description: "If the selected model is unavailable, rate limited for too long or overloaded, Agent runs continue with the backup model of the same provider. Leave empty to stop instead.") {
            ForEach(providers, id: \.self) { provider in
                SettingsRow(title: provider.name, leading: { ProviderLogo(provider: provider, size: 22).frame(width: 28) }) {
                    TextField(placeholder(provider), text: Binding(
                        get: { values[provider] ?? "" },
                        set: { value in
                            values[provider] = value
                            ModelFallbackPreferences.setFallback(value, for: provider)
                        }))
                    .textFieldStyle(.settings).frame(width: 260)
                    .accessibilityLabel("\(provider.name) backup model")
                }
            }
        }
        .onAppear {
            for provider in providers { values[provider] = ModelFallbackPreferences.fallback(for: provider) ?? "" }
        }
    }

    private func placeholder(_ provider: ChatProvider) -> String {
        switch provider {
        case .openRouter: "anthropic/claude-haiku-4.5"
        case .anthropic: "claude-haiku-4-5"
        case .openAI: "gpt-5-mini"
        case .google: "gemini-2.5-flash"
        case .xAI: "grok-3-mini"
        default: "deepseek-chat"
        }
    }
}
