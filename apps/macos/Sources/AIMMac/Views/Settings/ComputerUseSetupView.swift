import AIMMacPlatform
import AppKit
import SwiftUI

/// A separate, movable macOS window. System privacy dialogs remain owned by macOS.
struct ComputerUseSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var requestedAccessibility = false
    @State private var requestedCapture = false

    private let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private let captureURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    private let extensionURL = URL(string: "https://chromewebstore.google.com/detail/playwright-extension/mmlmfjhmonkocbjadbfplnigmagldckm")!

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 68, height: 68)
                    .accessibilityHidden(true)
                Text("Enable AIM Computer Use")
                    .font(.system(size: 26, weight: .semibold))
                Text("Allow AIM to use apps on your Mac when you ask the Agent to perform a task. Each sensitive action still follows your chat permission mode.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 540)
            }
            .padding(.top, 30).padding(.bottom, 26)

            VStack(spacing: 14) {
                permissionRow(.accessibility, title: "Accessibility",
                    detail: "Read and act on app interfaces. Secure password fields are excluded.",
                    icon: accessibilityIcon, requested: requestedAccessibility,
                    settingsURL: accessibilityURL) { requestedAccessibility = true }
                permissionRow(.screenRecording, title: "Screenshots",
                    detail: "Capture a selected window so image-capable models can inspect more than recognized text.",
                    icon: screenshotIcon, requested: requestedCapture,
                    settingsURL: captureURL) { requestedCapture = true }
                BrowserModeRow(extensionURL: extensionURL)
                HStack(spacing: 17) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 30)).frame(width: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Embedded CUA Driver").font(.system(size: 16, weight: .semibold))
                        Text(driverDescription).font(.system(size: 12))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let error = model.cuaDriverError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        #if DEBUG
                        if let result = model.cuaFixtureResult {
                            Text(result).font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("cua-fixture-result")
                        }
                        #endif
                    }
                    Spacer(minLength: 10)
                    VStack(spacing: 8) {
                        Button(model.isCheckingCuaDriver ? "Checking…" : "Check driver") {
                            Task { await model.checkEmbeddedCuaDriver() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!CuaDriverDiagnostics.isBundled || model.isCheckingCuaDriver ||
                                  model.isRunningCuaFixture)
                        #if DEBUG
                        Button(model.isRunningCuaFixture ? "Testing…" : "Test AgentFixture") {
                            Task { await model.runCuaFixtureQualification() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!CuaDriverDiagnostics.isBundled || model.isRunningCuaFixture ||
                                  model.isCheckingCuaDriver)
                        .help("One background click on AIM's disposable AgentFixture only; it never reads or changes personal apps.")
                        #endif
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 15)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You can revoke access in System Settings → Privacy & Security.")
                    if Bundle.main.object(forInfoDictionaryKey: "AIMAdHocSigned") as? Bool == true {
                        Text("This development build has an ad-hoc signature. macOS may require access again after the app is rebuilt; use a stable signing certificate for persistent permissions.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 14)
                Button("Done") { dismissWindow(id: "computer-use") }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 28).padding(.bottom, 26)
        .frame(width: 760)
        .task {
            // AXIsProcessTrustedWithOptions only starts the system prompt. Refresh
            // while visible so a later grant is reflected without reopening AIM.
            while !Task.isCancelled {
                await model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var driverDescription: String {
        guard CuaDriverDiagnostics.isBundled else {
            return "Not bundled in this build. AIM uses its qualified native desktop route."
        }
        guard let report = model.cuaDriverDiagnostic else {
            return "Version-pinned helper available. The check is read-only and does not ask macOS for permissions."
        }
        return "Version \(report.version) · AIM identity and tool schemas verified · " +
            "Accessibility \(report.accessibilityGranted ? "allowed" : "not allowed") · " +
            "Screen Recording \(report.screenRecordingGranted ? "allowed" : "not allowed"). " +
            (report.backgroundPrerequisitesAvailable
             ? "Background actions are offered only for capabilities qualified on this Mac with this driver and macOS build."
             : "Background actions remain disabled.")
    }

    private func permissionRow<Icon: View>(_ kind: MacPermissionKind, title: String,
        detail: String, icon: Icon, requested: Bool, settingsURL: URL,
        onRequest: @escaping () -> Void) -> some View {
        let granted = model.permissionStates[kind] == .granted
        return HStack(spacing: 17) {
            icon.frame(width: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
            } else {
                Button(requested ? "Open Settings" : "Allow") {
                    onRequest()
                    if requested { NSWorkspace.shared.open(settingsURL) }
                    else { Task { await model.requestPermission(kind) } }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    private var accessibilityIcon: some View {
        Image(systemName: "accessibility")
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Color(red: 0.02, green: 0.57, blue: 0.97), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2).padding(3))
            .shadow(color: .blue.opacity(0.2), radius: 3, y: 1)
    }

    private var screenshotIcon: some View {
        Image(systemName: "camera.viewfinder")
            .font(.system(size: 36, weight: .regular))
            .foregroundStyle(.gray)
            .frame(width: 46, height: 46)
    }
}

/// Browser route for Agent runs: a private isolated Chrome or the person's own
/// Chrome through the Playwright extension. The extension token is written to
/// the Keychain and never displayed again.
private struct BrowserModeRow: View {
    let extensionURL: URL
    @State private var mode = AgentBrowserPreferences.mode
    @State private var token = ""
    @State private var tokenSaved = AgentBrowserPreferences.hasExtensionToken
    @State private var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 17) {
            Image(nsImage: NSWorkspace.shared.icon(forFile:
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")?.path
                    ?? "/Applications/Google Chrome.app"))
                .resizable().interpolation(.high).frame(width: 44, height: 44)
                .frame(width: 54)
            VStack(alignment: .leading, spacing: 8) {
                Text("Browser").font(.system(size: 16, weight: .semibold))
                Picker("Browser", selection: $mode) {
                    Text("Isolated Chrome").tag(AgentBrowserMode.isolated)
                    Text("My Chrome (extension)").tag(AgentBrowserMode.extensionConnected)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                .disabled(!AgentBrowserToolService.isBundled)
                .onChange(of: mode) { _, value in AgentBrowserPreferences.mode = value }
                Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if mode == .extensionConnected && AgentBrowserToolService.isBundled {
                    HStack(spacing: 8) {
                        SecureField(tokenSaved ? "Token saved in Keychain" : "Extension token (optional)", text: $token)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .accessibilityLabel("Playwright extension token")
                        Button("Save") { save() }.disabled(token.isEmpty)
                        if tokenSaved { Button("Remove") { remove() } }
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 10)
            Link("Get extension", destination: extensionURL).buttonStyle(.bordered)
                .disabled(!AgentBrowserToolService.isBundled || mode != .extensionConnected)
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    private var description: String {
        guard AgentBrowserToolService.isBundled else {
            return "Browser automation is not bundled in this build."
        }
        switch mode {
        case .isolated:
            return "A visible Chrome window with a temporary profile opens for the run: no saved logins, cookies or extensions. A private session record is kept in AIM's support folder for review."
        case .extensionConnected:
            return "Connect tabs you choose in your Chrome through the Playwright extension. Without a token, Chrome asks you to approve each connection; the token from the extension skips that prompt."
        }
    }

    private func save() {
        do {
            try AgentBrowserPreferences.saveExtensionToken(token)
            token = ""
            tokenSaved = true
            message = "Token saved in the Keychain. It is passed only to AIM's browser helper."
        } catch {
            message = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try AgentBrowserPreferences.removeExtensionToken()
            tokenSaved = false
            message = "Token removed."
        } catch {
            message = error.localizedDescription
        }
    }
}
