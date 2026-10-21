import SwiftUI

struct AnthropicOutputSettingsView: View {
    @Environment(AppModel.self) private var model
    let modelID: String
    var maximum: Int? = nil
    @State private var value = ""
    @State private var saving = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(modelID).font(.caption).textSelection(.enabled)
            Text("Automatic uses the model’s published output capacity. An optional limit applies to future turns in Chat, Code and Agent.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Output tokens").font(.caption)
                TextField("Automatic", text: $value).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Anthropic output tokens")
                Button("Apply") { save(reset: false) }
                    .disabled(saving || (Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) <= 0)
                Button("Automatic") { save(reset: true) }.disabled(saving)
            }
            Text(maximum.map { "Published capacity: \($0.formatted()) tokens. Larger responses may cost more." } ?? "AIM reads the exact model descriptor before sending when its capacity is absent from the catalog.")
                .font(.caption).foregroundStyle(.secondary)
            if let status { Text(status).font(.caption).textSelection(.enabled) }
        }.padding(.top, 8)
        .onAppear { value = model.settings.anthropicOutputTokensByModel?[modelID].map(String.init) ?? "" }
    }

    private func save(reset: Bool) {
        let tokens = reset ? nil : Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard reset || (tokens ?? 0) > 0 else { return }
        saving = true; status = nil
        Task {
            do {
                try await model.setAnthropicOutputTokens(tokens, modelID: modelID)
                value = tokens.map(String.init) ?? ""
                status = reset ? "Automatic restored." : "Saved for this model."
            } catch { status = "Could not save this setting. The previous value was retained." }
            saving = false
        }
    }
}
