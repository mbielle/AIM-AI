import AIMCore
import AppKit
import SwiftUI

/// Local work opens directly. Sign-in is an optional settings flow.
struct AccessGateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.access {
        case .granted: RootView()
        case .restoring: AuthBackdrop { AuthLoadingView() }
        case .signInRequired: AuthBackdrop { SignInView() }
        case .notConfigured: AuthBackdrop { AuthUnavailableView() }
        }
    }
}

struct AuthBackdrop<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            AIMTheme.background(scheme).ignoresSafeArea()
            ScrollView {
                content.frame(width: 360).padding(.vertical, 64).frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct AuthLoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            AIMLogoView(size: 56)
            ProgressView().controlSize(.small)
            Text("Restoring your session…").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(minHeight: 420)
        .accessibilityElement(children: .combine)
    }
}

private struct AuthUnavailableView: View {
    var body: some View {
        VStack(spacing: 16) {
            AIMLogoView(size: 56)
            Text("AIM could not open the local profile").font(AIMTypography.title(26))
            Text("The profile could not be read from secure storage. Existing conversations and keys have been preserved.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(minHeight: 420)
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var screen: Screen = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @FocusState private var focus: Field?

    private enum Screen: Equatable { case signIn, signUp, reset }
    private enum Field: Hashable { case name, email, password }

    var body: some View {
        VStack(spacing: 0) {
            AIMLogoView(size: 56).padding(.bottom, 22)
            if case .confirmationRequired(let address) = model.account.state {
                confirmation(address)
            } else {
                form
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("authentication-screen")
        .onAppear { focus = .email }
    }

    @ViewBuilder private var form: some View {
        Text(heading).font(AIMTypography.title(30)).multilineTextAlignment(.center)
        Text(subheading).font(.system(size: 14)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8).padding(.bottom, 28)
        if screen != .reset {
            Button { Task { await model.account.signInWithGoogle() } } label: {
                HStack(spacing: 10) {
                    GoogleMark().frame(width: 18, height: 18)
                    Text("Continue with Google").font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.inputBorder(scheme)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.account.isBusy)
            HStack(spacing: 12) {
                Rectangle().fill(AIMTheme.cardBorder(scheme)).frame(height: 1)
                Text("OR").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Rectangle().fill(AIMTheme.cardBorder(scheme)).frame(height: 1)
            }
            .padding(.vertical, 20)
        }
        VStack(spacing: 10) {
            if screen == .signUp {
                TextField("Name", text: $name).textFieldStyle(AuthFieldStyle()).focused($focus, equals: .name)
                    .textContentType(.name)
            }
            TextField("Email address", text: $email).textFieldStyle(AuthFieldStyle()).focused($focus, equals: .email)
                .textContentType(.emailAddress).onSubmit { if screen == .reset { submit() } else { focus = .password } }
            if screen != .reset {
                SecureField("Password", text: $password).textFieldStyle(AuthFieldStyle()).focused($focus, equals: .password)
                    .textContentType(screen == .signUp ? .newPassword : .password).onSubmit(submit)
            }
        }
        if let message = model.account.message {
            SettingsNotice(message, tone: model.account.message?.hasPrefix("If this address") == true ? .success : .error)
                .padding(.top, 12)
        }
        Button(action: submit) {
            HStack(spacing: 8) {
                if model.account.isBusy { ProgressView().controlSize(.small).tint(scheme == .dark ? .black : .white) }
                Text(actionTitle).font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity).frame(height: 44)
            .foregroundStyle(scheme == .dark ? Color.black : .white)
            .background(scheme == .dark ? Color.white : Color(red: 0.09, green: 0.09, blue: 0.09),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(canSubmit ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!canSubmit).keyboardShortcut(.defaultAction)
        .padding(.top, 16)
        HStack(spacing: 6) {
            switch screen {
            case .signIn:
                Text("No account?").foregroundStyle(.secondary)
                link("Create one") { go(.signUp) }
            case .signUp:
                Text("Already have an account?").foregroundStyle(.secondary)
                link("Sign in") { go(.signIn) }
            case .reset:
                link("Back to sign in") { go(.signIn) }
            }
        }
        .font(.system(size: 13)).padding(.top, 20)
        if screen == .signIn {
            link("Forgot password?") { go(.reset) }.font(.system(size: 13)).padding(.top, 8)
        }
        Text("Your conversations and API keys stay on this Mac.")
            .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.top, 36)
    }

    private func confirmation(_ address: String) -> some View {
        VStack(spacing: 10) {
            Text("Check your email").font(AIMTypography.title(30))
            Text("We sent a confirmation link to \(address). Open it on this Mac, then come back to AIM.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back to sign in") { model.account.dismissConfirmation(); go(.signIn) }
                .buttonStyle(.settings).padding(.top, 18)
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).foregroundStyle(AIMTheme.toggleOn)
    }

    private var heading: String {
        switch screen { case .signIn: "Welcome back"; case .signUp: "Create your account"; case .reset: "Reset your password" }
    }
    private var subheading: String {
        switch screen {
        case .signIn: "Sign in for account sync and Remote. Local work remains available."
        case .signUp: "One account for AIM on your Mac, iPhone and the web."
        case .reset: "Enter your email and we'll send you a link to choose a new password."
        }
    }
    private var actionTitle: String {
        switch screen { case .signIn: "Continue"; case .signUp: "Create account"; case .reset: "Send reset link" }
    }
    private var canSubmit: Bool {
        !model.account.isBusy && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (screen == .reset || !password.isEmpty)
    }

    private func go(_ next: Screen) {
        screen = next
        password = ""
        focus = next == .signUp ? .name : .email
    }

    private func submit() {
        guard canSubmit else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        let fullName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            switch screen {
            case .signIn: await model.account.signIn(email: address, password: secret)
            case .signUp: await model.account.signUp(email: address, password: secret, fullName: fullName)
            case .reset: await model.account.requestPasswordReset(email: address)
            }
            password = ""
        }
    }
}

private struct AuthFieldStyle: TextFieldStyle {
    @Environment(\.colorScheme) private var scheme

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 14)).focusEffectDisabled()
            .padding(.horizontal, 14).frame(height: 44)
            .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.inputBorder(scheme)))
    }
}

/// Google's “G” (falls back to a plain letter).
private struct GoogleMark: View {
    // A bitmap (Lobe Icons): SVG drawing can crash on some macOS versions.
    private static let image: NSImage? = Bundle.module.url(forResource: "logo-google", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
        } else {
            Text("G").font(.system(size: 15, weight: .bold)).foregroundStyle(.blue).accessibilityHidden(true)
        }
    }
}
