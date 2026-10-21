import AIMCore
import SwiftUI

struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirmSignOut = false
    @State private var showSignIn = false
    @State private var showLocalCopy = false

    var body: some View {
        let user = AuthenticatedUserSummary(model.account.accessUser)
        SettingsPage("Account", subtitle: "AIM works locally without an account, including direct Mac–iPhone pairing. Sign in only for account synchronization and cloud Remote.") {
            if model.account.offlineUser != nil {
                SettingsNotice("Offline: AIM keeps working with the account last confirmed on this Mac for up to 7 days.", tone: .warning)
            }
            if model.account.accessUser == nil {
                SettingsGroup("Local profile") {
                    SettingsRow("Working on this Mac", description: "Local conversations stay on this Mac and are not uploaded when you sign in.") {
                        SettingsStatus(text: "Local", color: .green)
                    }
                    SettingsRow("Optional account", description: model.account.isConfigured ? "Connect your own account backend for synchronization and cloud Remote." : "No account backend is configured in this build.") {
                        Button("Sign in…") { showSignIn = true }.buttonStyle(.settings).disabled(!model.account.isConfigured)
                    }
                }
            } else {
            SettingsGroup {
                SettingsRow(title: user.name, description: user.email ?? "No email", leading: { AccountAvatar(initial: user.initial, size: 44) }) {
                    SettingsStatus(text: model.account.offlineUser == nil ? "Signed in" : "Offline",
                                   color: model.account.offlineUser == nil ? .green : .orange)
                }
                if let email = model.account.accessUser?.email {
                    SettingsRow("Email") {
                        Text(email).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                SettingsRow("Local conversation copies", description: "Review local histories and choose which ones to copy into this account. Originals are preserved.") {
                    Button("Review local conversations…") { showLocalCopy = true }.buttonStyle(.settings).disabled(model.account.isBusy)
                }
                SettingsRow("Sign out on this Mac", description: "Return to the local profile. Account conversations and keys stay on this Mac.") {
                    Button("Sign out…") { confirmSignOut = true }.buttonStyle(.settings).disabled(model.account.isBusy)
                }
            }
            }
            if case .passwordRecovery = model.account.state {
                SettingsGroup("Set a new password") {
                    SettingsRow("New password") {
                        SecureField("New password", text: $password).textFieldStyle(.settings).frame(width: 220)
                        Button("Save") {
                            let newPassword = password
                            Task { await model.account.updatePassword(newPassword); password = "" }
                        }.buttonStyle(.settingsPrimary).disabled(password.isEmpty || model.account.isBusy)
                    }
                }
            }
            if let message = model.account.message { SettingsNotice(message) }
        }
        .sheet(isPresented: $showLocalCopy) { LocalHistoryCopyView() }
        .sheet(isPresented: $showSignIn) {
            VStack {
                HStack { Spacer(); Button("Done") { showSignIn = false } }.padding()
                AuthBackdrop { SignInView() }
            }.frame(width: 480, height: 650)
            .onChange(of: model.account.accessUser?.id) { _, id in if id != nil { showSignIn = false } }
        }
        .confirmationDialog("Sign out of AIM on this Mac?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { Task { await model.account.signOut() } }
        } message: {
            Text("Account tasks stop and Remote disconnects. You can continue working with your separate local profile.")
        }
    }
}
