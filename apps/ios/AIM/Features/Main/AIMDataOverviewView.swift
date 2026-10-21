import AIMCore
import SwiftUI

struct AIMDataOverviewView: View {
    let openDelete: () -> Void
    let service: any CloudContentServicing
    let remoteStore: MainExperienceStore
    let onBack: () -> Void
    let onDeleted: () -> Void
    @State private var file: URL?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Data", back: onBack)
            AIMSettingsForm {
                Section {
                    AIMSettingsAction(title: "Export my data", icon: "square.and.arrow.up") { Task { await export() } }.disabled(busy)
                    AIMSettingsAction(title: "Remote diagnostics", icon: "stethoscope") { Task { file = await remoteStore.diagnosticReportFile() } }
                } footer: { Text("Diagnostics exclude messages and credentials.") }
                if busy { ProgressView() }
                if let file { ShareLink(item: file) { Label("Share file", systemImage: "square.and.arrow.up").foregroundStyle(.primary) } }
                if let error { AIMSettingsMessage(text: error) }
                Section { AIMSettingsAction(title: "Delete account", icon: "person.crop.circle.badge.minus", action: openDelete) }
            }
        }
    }
    private func export() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let data = try await service.exportUserData()
            let target = URL.temporaryDirectory.appending(path: "AIM-export-\(UUID().uuidString).json")
            try data.write(to: target, options: [.atomic, .completeFileProtection]); file = target; error = nil
        } catch { self.error = "Export could not be created. Try again." }
    }
}

struct AIMDeleteAccountView: View {
    let service: any CloudContentServicing
    let userEmail: String
    let onBack: () -> Void
    let onDeleted: () -> Void
    @State private var email = ""
    @State private var confirmation = ""
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?
    private var valid: Bool { !userEmail.isEmpty && email.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(userEmail) == .orderedSame && confirmation == "SUPPRIMER" }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Delete account", back: onBack)
            AIMSettingsForm {
                Section {
                    AIMSettingsTextField(title: "Account email", text: $email, prompt: userEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    AIMSettingsTextField(title: "Confirmation", text: $confirmation, prompt: "SUPPRIMER")
                        .autocorrectionDisabled().textInputAutocapitalization(.characters)
                } footer: { Text("Permanently deletes your AIM account and synchronized data. Enter your email and SUPPRIMER to confirm.") }
                Section { Button("Delete permanently", role: .destructive) { confirming = true }.disabled(!valid || busy) }
                if busy { ProgressView() }
                if let error { AIMSettingsMessage(text: error) }
            }
        }.interactiveDismissDisabled(busy)
        .alert("Permanently delete this account?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task {
                busy = true; defer { busy = false }
                do { try await service.deleteAccount(confirmEmail: email, confirmation: confirmation); onDeleted() }
                catch { self.error = "The account could not be deleted. Try again." }
            } }
        } message: { Text("This cannot be undone.") }
    }
}
