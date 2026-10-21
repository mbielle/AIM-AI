import AIMMacPlatform
import SwiftUI

struct LegacyCredentialAdoptionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var review: LegacyCredentialAdoptionCoordinator.Review?
    @State private var selected: Set<LegacyProviderCredential> = []
    @State private var busy = false
    @State private var confirm = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review previously saved provider keys").font(.title2)
            Text("Only select keys that you own and authorize this profile to use. The original key owner cannot be inferred. Copying makes selected keys available to Chat, Code, Agent and image generation in this profile; it does not run a provider request. Existing destination keys are never overwritten. Legacy originals stay in Keychain.")
                .font(.callout).foregroundStyle(.secondary)
            if let review {
                Text("Destination: \(review.destination)").font(.callout).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(review.credentials.available.sorted(by: { $0.name < $1.name })) { item in
                            Toggle(item.name, isOn: Binding(get: { selected.contains(item) }, set: { value in
                                if value { selected.insert(item) } else { selected.remove(item) }
                            })).disabled(busy)
                        }
                        ForEach(review.credentials.existingDestination.sorted(by: { $0.name < $1.name })) { item in
                            Text("\(item.name): this profile already has a key; it will be kept.").foregroundStyle(.secondary)
                        }
                        if review.credentials.available.isEmpty { Text("No eligible legacy API keys are available to copy.").foregroundStyle(.secondary) }
                    }
                }
            } else if busy { ProgressView("Checking key names…") }
            Text("ChatGPT/OAuth sessions, plugin/channel tokens and unknown keys are excluded. Reconnect those accounts for this profile. Key values are never displayed. macOS may request Keychain authorization only after you confirm selected copies.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Refresh review") { Task { await load() } }.disabled(busy)
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
                Button("Copy \(selected.count) selected…") { confirm = true }
                    .disabled(busy || selected.isEmpty || review == nil).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 720, height: 540)
        .task { await load() }
        .onChange(of: model.account.identity?.storageID) { _, _ in review = nil; selected = []; dismiss() }
        .confirmationDialog("Authorize the selected keys for this destination?", isPresented: $confirm) {
            Button("Copy selected keys") { Task { await copy() } }
        } message: {
            if let review { Text("\(review.destination)\nProviders: \(selected.map(\.name).sorted().joined(separator: ", ")). Legacy originals are preserved and existing destination keys are kept.") }
        }
    }
    private func load() async {
        busy = true; defer { busy = false }
        selected = []; message = nil; review = nil
        do { review = try await model.legacyCredentialAdoption.review() }
        catch { message = "Legacy keys could not be reviewed safely. No secrets were copied. You can reconnect providers manually." }
    }
    private func copy() async {
        guard let review else { return }
        busy = true; defer { busy = false }
        do {
            let count = try await model.legacyCredentialAdoption.copy(selected, reviewed: review)
            selected = []; self.review = nil
            message = "\(count) selected keys copied to the reviewed profile. Legacy originals are preserved. Refresh review to see remaining keys."
        } catch {
            selected = []; self.review = nil
            message = "Copy stopped: the profile changed, a destination key already exists, or Keychain access failed. Legacy originals and existing destination keys are preserved. Any earlier completed copies are kept. Refresh review before retrying."
        }
    }
}
