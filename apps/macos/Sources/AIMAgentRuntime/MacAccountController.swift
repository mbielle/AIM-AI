import AIMCore
import AIMMacPlatform
import Foundation
import Observation
import Supabase

/// Optional account services. Local execution uses a persistent installation profile;
/// only an authenticated account can access Remote and account synchronization.
@MainActor
@Observable
package final class MacAccountController {
    package private(set) var state: AuthenticationState = .signedOut {
        didSet {
            if let user { rememberVerified(user) }
            publishAccessChange()
        }
    }
    /// Set only while offline with an account confirmed in the last 7 days.
    package private(set) var offlineUser: AuthenticatedUser? { didSet { publishAccessChange() } }
    /// Called whenever the user who may use the app changes (nil when signed out).
    @ObservationIgnored package var onAccessChange: ((AuthenticatedUser?) -> Void)?
    @ObservationIgnored package var onServerRevocation: (() async throws -> Void)?
    private var lastSessionCheck = Date.distantPast
    @ObservationIgnored private var publishedUserID: UUID??
    package private(set) var isBusy = false
    package private(set) var message: String?
    package private(set) var isConfigured: Bool

    package let credentialScope = CredentialStorageScope()
    package private(set) var localProfile: LocalProfile?
    package var identity: AppIdentity? {
        let value = accessUser.map(AppIdentity.account) ?? localProfile.map(AppIdentity.local)
        credentialScope.activate(value?.storageID)
        return value
    }

    private let sharedAccess: Bool
    private let service: (any AuthenticationServicing)?
    /// The signed-in client, shared with the Remote host (one session, one refresh).
    package let supabaseClient: SupabaseClient?
    private let webAuthenticator: any MacWebAuthenticating
    private let callbackDeduplicator = AuthenticationCallbackDeduplicator()
    private var eventTask: Task<Void, Never>?
    private var accessMonitorTask: Task<Void, Never>?
    private var lastNetworkPrivate: Bool?
    private static let logoutKey = "AIMAccountAccessSuspendedV1"
    private static let activeIDKey = "AIMActiveAccountIDV1"
    package static var sharedActiveAccountID: UUID? {
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.synchronize()
        guard !defaults.bool(forKey: logoutKey) else { return nil }
        return defaults.string(forKey: activeIDKey).flatMap(UUID.init(uuidString:))
    }
    private func shareLogin(_ user: AuthenticatedUser) {
        guard sharedAccess else { return }
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.set(user.id.uuidString, forKey: Self.activeIDKey)
        defaults.set(false, forKey: Self.logoutKey); defaults.synchronize()
    }
    private var started = false
    private var localAccessSuspended = false
    private let verifiedStore: (any SecureStoring)?
    private let now: () -> Date

    package init(service: (any AuthenticationServicing)?, webAuthenticator: (any MacWebAuthenticating)? = nil,
         supabaseClient: SupabaseClient? = nil, verifiedStore: (any SecureStoring)? = nil,
         now: @escaping () -> Date = Date.init, sharedAccess: Bool = false,
         localProfileStore: (any SecureStoring)? = nil) {
        let profileStore = localProfileStore ?? KeychainSecureStore(service: AIMInstallationContext.keychainService("com.aimai.macos.local-profile"))
        do {
            if localProfileStore != nil { localProfile = try LocalProfile.loadOrCreate(store: profileStore) }
            else { localProfile = try MacLocalProfileStore.loadOrCreate(store: profileStore) }
        }
        catch { message = "The local profile could not be opened safely. Existing data was preserved." }
        self.sharedAccess = sharedAccess
        self.service = service
        self.supabaseClient = supabaseClient
        self.verifiedStore = verifiedStore
        self.now = now
        self.webAuthenticator = webAuthenticator ?? MacWebAuthenticationSession()
        isConfigured = service != nil
        credentialScope.activate(identity?.storageID)
    }

    package convenience init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
                             secureStoreOverride: (any SecureStoring)? = nil) {
        let url = infoDictionary["AIMSupabaseURL"] as? String ?? ""
        let key = infoDictionary["AIMSupabasePublicKey"] as? String ?? ""
        guard let configuration = try? AppConfiguration(projectURLString: url, publicAPIKey: key) else {
            self.init(service: nil, localProfileStore: secureStoreOverride)
            return
        }
        // The iOS callback and Keychain service must not be reused on macOS.
        let redirect = AuthRedirectPolicy(canonicalScheme: "aimmac", acceptedSchemes: ["aimmac"])
        let store: any SecureStoring = secureStoreOverride ?? CachedAccountSecureStore.shared
        guard let client = try? SupabaseAuthenticationBackend.makeClient(
            configuration: configuration,
            secureStore: store,
            redirectPolicy: redirect
        ) else {
            self.init(service: nil, localProfileStore: secureStoreOverride)
            return
        }
        let backend = SupabaseAuthenticationBackend(client: client)
        self.init(service: AuthenticationService(backend: backend, redirectPolicy: redirect), supabaseClient: client,
                  verifiedStore: store, sharedAccess: secureStoreOverride == nil, localProfileStore: secureStoreOverride)
    }

    /// The account allowed to use the app right now, online or within the offline grace.
    package var sharedSessionSuspended: Bool {
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.synchronize()
        return localAccessSuspended || (sharedAccess && defaults.bool(forKey: Self.logoutKey))
    }
    package var accessUser: AuthenticatedUser? {
        guard sharedAccess else { return localAccessSuspended ? nil : user ?? offlineUser }
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.synchronize()
        guard !localAccessSuspended, !defaults.bool(forKey: Self.logoutKey) else { return nil }
        let candidate = user ?? offlineUser
        if let expected = defaults.string(forKey: Self.activeIDKey).flatMap(UUID.init(uuidString:)), candidate?.id != expected { return nil }
        return candidate
    }

    private func rememberVerified(_ user: AuthenticatedUser) {
        guard !localAccessSuspended, !AIMNetworkPrivacyPolicy.isEnabled else { return }
        offlineUser = nil
        VerifiedAccount.write(user, at: now(), to: verifiedStore)
    }

    private func publishAccessChange() {
        credentialScope.activate(identity?.storageID)
        let id = accessUser?.id
        guard publishedUserID != .some(id) else { return }
        publishedUserID = .some(id)
        onAccessChange?(accessUser)
    }

    package var user: AuthenticatedUser? {
        switch state {
        case .authenticated(let user), .passwordRecovery(let user): user
        default: nil
        }
    }

    package func start() async {
        guard !started, let service else { return }
        started = true
        accessMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.applyNetworkPrivacy()
                await self?.checkServerSession()
                self?.publishAccessChange()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        state = .restoring
        observeEvents(service)
        await applyNetworkPrivacy()
        do {
            let restored = try await service.restoreSession()
            if case .restoring = state { state = restored }
        } catch {
            if case .restoring = state {
                // Offline with an expired token: the account confirmed here recently keeps
                // working; the client refreshes it (tokenRefreshed) when the network returns.
                if case .networkUnavailable = error as? AuthenticationError,
                   let user = AccountAccessPolicy.offlineUser(VerifiedAccount.read(from: verifiedStore), now: now()) {
                    offlineUser = user
                } else {
                    message = Self.description(for: error)
                }
                state = .signedOut
            }
        }
    }
    private func checkServerSession() async {
        guard !AIMNetworkPrivacyPolicy.isEnabled, let user, let client = supabaseClient,
              now().timeIntervalSince(lastSessionCheck) >= 20 else { return }
        lastSessionCheck = now()
        let sessions = AccountSessionService(client: client)
        do { try await sessions.register(device: Host.current().localizedName ?? "Mac", platform: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString) }
        catch AccountServiceError.revoked {
            guard self.user?.id == user.id else { return }
            localAccessSuspended = true // Block new UI admissions before awaiting cleanup.
            do {
                guard let onServerRevocation else { throw AccountServiceError.unavailable }
                try await onServerRevocation()
                try await sessions.acknowledgeLocalStop()
            } catch { message = "Session disconnected. Task stop confirmation is still pending." }
            await signOut()
        } catch { /* Offline or server update pending: keep local data and never infer a revoke. */ }
    }

    private func observeEvents(_ service: any AuthenticationServicing) {
        eventTask = Task { [weak self] in
            for await event in service.events() {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }
    package func applyNetworkPrivacy() async {
        let enabled = AIMNetworkPrivacyPolicy.isEnabled
        guard lastNetworkPrivate != enabled else { return }
        lastNetworkPrivate = enabled
        if enabled {
            await supabaseClient?.auth.stopAutoRefresh()
            try? await AIMNativeRealtime.closeAll()
            eventTask?.cancel(); eventTask = nil
            if user == nil, !localAccessSuspended, let verified = VerifiedAccount.read(from: verifiedStore) {
                offlineUser = AuthenticatedUser(id: verified.id, email: verified.email, fullName: verified.fullName)
            }
        } else {
            await supabaseClient?.auth.startAutoRefresh()
            if eventTask == nil, let service { observeEvents(service) }
        }
    }
    private func networkLoginAllowed() -> Bool {
        guard !AIMNetworkPrivacyPolicy.isEnabled else {
            message = AIMNetworkPrivacyError.networkDisabled.localizedDescription; return false
        }
        return true
    }

    package func signIn(email: String, password: String) async {
        guard networkLoginAllowed() else { return }
        guard let service, !isBusy else { return }
        localAccessSuspended = false
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let value = try await service.signIn(email: email, password: password)
            guard !localAccessSuspended else { return }
            shareLogin(value); state = .authenticated(value)
        }
        catch { message = Self.description(for: error) }
    }

    package func signUp(email: String, password: String, fullName: String) async {
        guard !AIMInstallationContext.isQualification else {
            message = "Use the usual AIM app for sign-up links."; return
        }
        guard networkLoginAllowed() else { return }
        guard let service, !isBusy else { return }
        localAccessSuspended = false
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let result = try await service.signUp(email: email, password: password, fullName: fullName)
            guard !localAccessSuspended else { return }
            switch result {
            case .authenticated(let user): shareLogin(user); state = .authenticated(user)
            case .confirmationRequired(let email): state = .confirmationRequired(email: email)
            }
        } catch { message = Self.description(for: error) }
    }

    package func requestPasswordReset(email: String) async {
        guard !AIMInstallationContext.isQualification else {
            message = "Use the usual AIM app for password reset links."; return
        }
        guard networkLoginAllowed() else { return }
        guard let service, !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await service.requestPasswordReset(email: email)
            message = "If this address has an account, a reset link has been sent."
        } catch { message = Self.description(for: error) }
    }

    package func signInWithGoogle() async {
        guard networkLoginAllowed() else { return }
        guard let service, !isBusy else { return }
        localAccessSuspended = false
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let authorizationURL = try service.googleAuthorizationURL()
            let callback = try await webAuthenticator.authenticate(at: authorizationURL, callbackScheme: "aimmac")
            guard callback.scheme?.lowercased() == "aimmac", callback.host?.lowercased() == "auth-callback" else {
                throw AuthenticationError.invalidCallback
            }
            await handleCallback(callback)
        } catch MacWebAuthenticationError.cancelled {
            // Explicit user cancellation is not an account error.
        } catch {
            message = Self.description(for: error)
        }
    }

    package func updatePassword(_ password: String) async {
        guard networkLoginAllowed() else { return }
        guard let service, !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let result = try await service.updatePassword(password)
            guard !localAccessSuspended else { return }
            state = result
        }
        catch { message = Self.description(for: error) }
    }

    package func handleCallback(_ url: URL) async {
        guard networkLoginAllowed() else { return }
        guard url.scheme?.lowercased() == "aimmac", url.host?.lowercased() == "auth-callback", let service else { return }
        guard await callbackDeduplicator.claim(url) else { return }
        message = nil
        do {
            let result = try await service.handleCallback(url)
            guard !localAccessSuspended else { return }
            if case .authenticated(let user) = result { shareLogin(user) }
            state = result
        }
        catch {
            await callbackDeduplicator.release(url)
            message = Self.description(for: error)
        }
    }

    package func signOut() async {
        localAccessSuspended = true
        let defaults = AIMInstallationContext.sharedPreferences
        if sharedAccess { defaults.set(true, forKey: Self.logoutKey); defaults.synchronize() }
        VerifiedAccount.remove(from: verifiedStore); offlineUser = nil; state = .signedOut
        guard let service else { return }
        while isBusy {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        isBusy = true
        defer { isBusy = false }
        await service.signOut()
        VerifiedAccount.remove(from: verifiedStore)
        offlineUser = nil
        state = .signedOut
        message = nil
    }

    package func dismissConfirmation() {
        if case .confirmationRequired = state { state = .signedOut }
    }

    private func apply(_ event: AuthenticationEvent) {
        guard !AIMNetworkPrivacyPolicy.isEnabled else { return }
        switch event {
        case .initialSession:
            // The local session may be expired; `restoreSession()` decides (refreshing it if needed).
            break
        case .signedIn(let user), .tokenRefreshed(let user), .userUpdated(let user):
            if !localAccessSuspended { state = .authenticated(user) }
        case .passwordRecovery(let user): if !localAccessSuspended { state = .passwordRecovery(user) }
        case .signedOut:
            // A session ended elsewhere (revoked refresh token) also ends the offline grace.
            offlineUser = nil
            state = .signedOut
        }
    }

    isolated deinit { eventTask?.cancel(); accessMonitorTask?.cancel() }

    private static func description(for error: Error) -> String {
        switch error as? AuthenticationError {
        case .invalidCredentials: "Email or password is incorrect."
        case .emailNotConfirmed: "Confirm your email address before signing in."
        case .emailAlreadyRegistered: "An account already uses this email address."
        case .weakPassword: "Choose a stronger password."
        case .networkUnavailable: "The network is unavailable. Try again when connected."
        case .invalidCallback: "This sign-in link is invalid or belongs to another device."
        case .sessionExpired, .missingSession: "Your session expired. Please sign in again."
        case .providerUnavailable: "This sign-in method is unavailable."
        case .none where error is MacWebAuthenticationError: "Could not open the sign-in browser. Please try again."
        default: "The account request could not be completed. Please try again."
        }
    }
}
