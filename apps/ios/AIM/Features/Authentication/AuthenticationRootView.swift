import AIMCore
import AuthenticationServices
import SwiftUI

struct AuthenticationContainerView: View {
    let configuration: AppConfiguration
    let uiTestScenario: AppEnvironment.UITestScenario?

    @State private var store: SessionStore?
    @State private var remoteService: (any RemoteServicing)?
    @State private var cloudContentService: (any CloudContentServicing)?
    @State private var accountSessions: (any AccountSessionServicing)?
    @State private var contentSync: (any AccountContentSyncing)?
    @State private var setupError: AuthenticationError?
    @State private var pendingURL: URL?

    var body: some View {
        Group {
            if let store, let remoteService, let cloudContentService {
                AuthenticationRootView(store: store, remoteService: remoteService, cloudContentService: cloudContentService, accountSessions: accountSessions, contentSync: contentSync)
            } else if let setupError {
                AuthenticationFailureView(error: setupError)
            } else {
                ProgressView("auth.loading")
                    .accessibilityIdentifier("authentication-loading")
            }
        }
        .task {
            guard store == nil, setupError == nil else { return }
            do {
                let (newStore, newRemoteService, newCloudContentService, newAccountSessions, newContentSync) = try makeServices()
                accountSessions = newAccountSessions
                contentSync = newContentSync
                store = newStore
                remoteService = newRemoteService
                cloudContentService = newCloudContentService
                await newStore.start()
                if let pendingURL {
                    self.pendingURL = nil
                    await newStore.handleOpenURL(pendingURL)
                }
            } catch let error as AuthenticationError {
                setupError = error
            } catch {
                setupError = .unexpected
            }
        }
        .onOpenURL { url in
            guard let store else {
                pendingURL = url
                return
            }
            Task { await store.handleOpenURL(url) }
        }
    }

    @MainActor
    private func makeServices() throws -> (SessionStore, any RemoteServicing, any CloudContentServicing, (any AccountSessionServicing)?, (any AccountContentSyncing)?) {
        #if DEBUG
        if let uiTestScenario {
            return (
                SessionStore(service: UITestAuthenticationService(scenario: uiTestScenario)),
                UITestRemoteService(scenario: uiTestScenario),
                UITestCloudContentService(), nil, nil
            )
        }
        #endif

        let services = try SupabaseServices(configuration: configuration)
        return (
            SessionStore(service: services.authenticationService()),
            services.remoteService(),
            services.cloudContentService(), services.accountSessionService(), services.accountContentSyncService()
        )
    }
}

private struct AuthenticationRootView: View {
    let store: SessionStore
    let remoteService: any RemoteServicing
    let cloudContentService: any CloudContentServicing
    let accountSessions: (any AccountSessionServicing)?
    let contentSync: (any AccountContentSyncing)?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color(uiColor: .systemBackground)],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()

            switch store.state {
            case .restoring:
                ProgressView("auth.loading")
                    .accessibilityIdentifier("authentication-loading")
            case .signedOut:
                SignedOutView(store: store)
            case let .confirmationRequired(email):
                ConfirmationRequiredView(email: email) {
                    Task { await store.signOut() }
                }
            case let .authenticated(user):
                MainExperienceView(identity: .account(user), sessionStore: store, remoteService: remoteService, cloudContentService: cloudContentService, accountSessions: accountSessions, contentSync: contentSync)
                    .id(user.id)
            case .passwordRecovery:
                PasswordRecoveryView(store: store)
            }
        }
        .overlay(alignment: .top) {
            if let error = store.error {
                AuthenticationErrorBanner(error: error) {
                    store.clearError()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: store.error)
    }
}

private struct SignedOutView: View {
    enum Route {
        case landing
        case signIn
        case signUp
        case forgotPassword
    }

    let store: SessionStore

    @State private var route: Route = .landing
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""
    @State private var resetEmailSent = false

    var body: some View {
        Group {
            if route == .landing {
                landingView
            } else {
                emailAuthenticationView
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("authentication-screen")
    }

    private var landingView: some View {
        VStack(spacing: 0) {
            RotatingHeadlineView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -24)

            providerPanel
                .padding(.horizontal, AIMDesign.universalPanelMargin)
                .padding(.bottom, AIMDesign.universalPanelMargin)
        }
        .background(Color.white)
        .ignoresSafeArea(edges: .bottom)
    }

    private var providerPanel: some View {
        VStack(spacing: 10) {
            ZStack {
                SignInWithAppleButton(.continue) { request in
                    AIMHaptics.impact()
                    guard let hashedNonce = store.beginAppleSignIn() else { return }
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = hashedNonce
                } onCompletion: { result in
                    handleAppleResult(result)
                }
                .signInWithAppleButtonStyle(.white)
                .accessibilityIdentifier("apple-sign-in")

                HStack(spacing: 13) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 22, weight: .medium))
                        .accessibilityHidden(true)
                    Text("auth.continue_apple")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.white)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .frame(height: 48)

            Button {
                AIMHaptics.impact()
                Task { await store.signInWithGoogle() }
            } label: {
                HStack(spacing: 13) {
                    Image("GoogleLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    Text("auth.continue_google")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(ProviderButtonStyle(background: Color(red: 0.15, green: 0.15, blue: 0.16)))
            .accessibilityIdentifier("google-sign-in")

            HStack(spacing: 10) {
                Button("auth.landing_sign_up") {
                    AIMHaptics.selection()
                    route = .signUp
                    store.clearError()
                }
                .buttonStyle(EmailChoiceButtonStyle())
                .accessibilityIdentifier("show-sign-up")

                Button("auth.log_in") {
                    AIMHaptics.selection()
                    route = .signIn
                    store.clearError()
                }
                .buttonStyle(EmailChoiceButtonStyle())
                .accessibilityIdentifier("show-sign-in")
            }
        }
        .disabled(store.isLoading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 34)
        .background(Color.black, in: RoundedRectangle(cornerRadius: AIMDesign.universalPanelRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private var emailAuthenticationView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    route = .landing
                    store.clearError()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .foregroundStyle(.black)
                .accessibilityLabel(Text("auth.back_to_sign_in"))

                Text("auth.authentication")
                    .font(.system(size: 25, weight: .bold, design: .serif))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)

            ScrollView {
                VStack(spacing: 22) {
                    Picker("auth.authentication", selection: emailRouteBinding) {
                        Text("auth.sign_in").tag(Route.signIn)
                        Text("auth.sign_up").tag(Route.signUp)
                    }
                    .pickerStyle(.segmented)

                    if route == .forgotPassword {
                        forgotPasswordForm
                    } else {
                        emailForm
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.white)
    }

    private var emailForm: some View {
        VStack(spacing: 14) {
            if route == .signUp {
                TextField("auth.full_name", text: $fullName)
                    .textContentType(.name)
                    .textFieldStyle(AIMTextFieldStyle())
                    .accessibilityIdentifier("full-name-field")
            }

            TextField("auth.email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .textFieldStyle(AIMTextFieldStyle())
                .accessibilityIdentifier("email-field")

            SecureField("auth.password", text: $password)
                .textContentType(route == .signUp ? .newPassword : .password)
                .textFieldStyle(AIMTextFieldStyle())
                .accessibilityIdentifier("password-field")

            Button {
                Task {
                    if route == .signUp {
                        await store.signUp(email: email, password: password, fullName: fullName)
                    } else {
                        await store.signIn(email: email, password: password)
                    }
                }
            } label: {
                if store.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(route == .signUp ? "auth.sign_up" : "auth.sign_in")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryAuthenticationButtonStyle())
            .disabled(!canSubmitEmail || store.isLoading)
            .accessibilityIdentifier("email-submit")

            if route == .signIn {
                Button("auth.forgot_password") {
                    route = .forgotPassword
                    resetEmailSent = false
                }
            }

            Button(route == .signUp ? "auth.show_sign_in" : "auth.show_sign_up") {
                route = route == .signUp ? .signIn : .signUp
                store.clearError()
            }
            .accessibilityIdentifier(route == .signUp ? "show-sign-in" : "show-sign-up")
        }
    }

    private var forgotPasswordForm: some View {
        VStack(spacing: 16) {
            Text("auth.reset_title")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(resetEmailSent ? "auth.reset_sent" : "auth.reset_body")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !resetEmailSent {
                TextField("auth.email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .textFieldStyle(AIMTextFieldStyle())

                Button("auth.reset_send") {
                    Task {
                        resetEmailSent = await store.requestPasswordReset(email: email)
                    }
                }
                .buttonStyle(PrimaryAuthenticationButtonStyle())
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoading)
            }

            Button("auth.back_to_sign_in") {
                route = .signIn
                store.clearError()
            }
        }
    }

    private var canSubmitEmail: Bool {
        let hasEmail = !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !password.isEmpty
        let hasName = !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasEmail && hasPassword && (route != .signUp || hasName)
    }

    private var emailRouteBinding: Binding<Route> {
        Binding(
            get: { route == .signUp ? .signUp : .signIn },
            set: { newValue in
                route = newValue
                resetEmailSent = false
                store.clearError()
            }
        )
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                store.failAppleSignIn()
                return
            }
            let formattedName = credential.fullName.map {
                PersonNameComponentsFormatter().string(from: $0)
            }
            Task {
                await store.completeAppleSignIn(
                    identityToken: credential.identityToken,
                    fullName: formattedName?.isEmpty == false ? formattedName : nil
                )
            }
        case let .failure(error):
            if let appleError = error as? ASAuthorizationError, appleError.code == .canceled {
                store.cancelAppleSignIn()
            } else {
                store.failAppleSignIn()
            }
        }
    }
}

private struct RotatingHeadlineView: View {
    private let phrases = ["Let's go", "Let's explore", "Let's create", "Let's discover", "Let's imagine"]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var cursorIsVisible = true

    var body: some View {
        HStack(spacing: 2) {
            Text(reduceMotion ? "Let's explore" : (text.isEmpty ? " " : text))
                .font(.system(size: 42, weight: .bold, design: .serif))
                .tracking(-1.1)
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel(Text("AIM.AI"))
                .accessibilityIdentifier("authentication-title")

            Rectangle()
                .fill(Color.black)
                .frame(width: 3, height: 43)
                .opacity(reduceMotion || cursorIsVisible ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 28)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                for phrase in phrases {
                    let characters = Array(phrase)
                    for count in 1 ... characters.count {
                        guard !Task.isCancelled else { return }
                        text = String(characters.prefix(count))
                        AIMHaptics.selection()
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    try? await Task.sleep(for: .milliseconds(1_800))
                    for count in stride(from: characters.count - 1, through: 0, by: -1) {
                        guard !Task.isCancelled else { return }
                        text = String(characters.prefix(count))
                        AIMHaptics.selection()
                        try? await Task.sleep(for: .milliseconds(35))
                    }
                }
            }
        }
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                cursorIsVisible.toggle()
            }
        }
    }
}

private struct ProviderButtonStyle: ButtonStyle {
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(background.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(.rect(cornerRadius: 16))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct EmailChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .serif))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.black)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(red: 0.28, green: 0.28, blue: 0.31), lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: 16))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct AIMTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(uiColor: .separator).opacity(0.55), lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: 12))
    }
}

private struct PrimaryAuthenticationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(Color.black.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(.rect(cornerRadius: 12))
    }
}

private struct ConfirmationRequiredView: View {
    let email: String
    let backToSignIn: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("auth.confirmation_title")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("auth.confirmation_body")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(email)
                .font(.headline)
                .textSelection(.enabled)
            Button("auth.back_to_sign_in", action: backToSignIn)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: 480)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("confirmation-screen")
    }
}

private struct PasswordRecoveryView: View {
    let store: SessionStore
    @State private var newPassword = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("auth.recovery_title")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("auth.recovery_body")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("auth.new_password", text: $newPassword)
                .textContentType(.newPassword)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("new-password-field")
            Button("auth.save_password") {
                Task { await store.updatePassword(newPassword) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(newPassword.isEmpty || store.isLoading)
        }
        .frame(maxWidth: 480)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("password-recovery-screen")
    }
}

private struct AuthenticationErrorBanner: View {
    let error: AuthenticationError
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(error.localizedMessage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("authentication-error")
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("auth.dismiss_error"))
            .accessibilityIdentifier("dismiss-error")
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .shadow(radius: 8, y: 3)
    }
}

private struct AuthenticationFailureView: View {
    let error: AuthenticationError

    var body: some View {
        ContentUnavailableView(
            "auth.failure_title",
            systemImage: "exclamationmark.triangle",
            description: Text(error.localizedMessage)
        )
    }
}

private extension AuthenticationError {
    var localizedMessage: String {
        switch self {
        case .invalidCredentials:
            String(localized: "error.invalid_credentials")
        case .emailNotConfirmed:
            String(localized: "error.email_not_confirmed")
        case .emailAlreadyRegistered:
            String(localized: "error.email_registered")
        case .weakPassword:
            String(localized: "error.weak_password")
        case .networkUnavailable:
            String(localized: "error.network")
        case .invalidCallback:
            String(localized: "error.invalid_callback")
        case .sessionExpired, .missingSession:
            String(localized: "error.session_expired")
        case .providerUnavailable:
            String(localized: "error.provider_unavailable")
        case .missingIdentityToken:
            String(localized: "error.apple_token")
        case .unexpected:
            String(localized: "error.unexpected")
        }
    }
}
