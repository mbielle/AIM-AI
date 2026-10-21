import Foundation
import Supabase

public final class SupabaseServices: Sendable {
    private let client: SupabaseClient
    private let remoteSecureStore: any SecureStoring
    private let projectURL: URL

    public init(
        configuration: AppConfiguration,
        authenticationSecureStore: any SecureStoring = KeychainSecureStore(),
        remoteSecureStore: any SecureStoring = KeychainSecureStore(service: "com.aimai.ios.remote")
    ) throws {
        guard let redirectURL = AuthRedirectPolicy().canonicalURL else {
            throw AuthenticationError.invalidCallback
        }
        client = SupabaseClient(
            supabaseURL: configuration.projectURL,
            supabaseKey: configuration.publicAPIKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storage: SupabaseAuthLocalStorage(secureStore: authenticationSecureStore),
                    redirectToURL: redirectURL,
                    storageKey: SupabaseAuthStorageConfiguration.sessionKey,
                    flowType: .pkce,
                    autoRefreshToken: !AIMNetworkPrivacyPolicy.isEnabled,
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(session: AIMManagedNetworkSession.shared)
            )
        )
        AIMNativeRealtime.register(client: client, projectURL: configuration.projectURL, publicKey: configuration.publicAPIKey)
        self.remoteSecureStore = remoteSecureStore
        projectURL = configuration.projectURL
    }

    public func authenticationService() -> AuthenticationService {
        AuthenticationService(backend: SupabaseAuthenticationBackend(client: client))
    }

    public func remoteService() -> any RemoteServicing {
        SupabaseRemoteService(client: client, secureStore: remoteSecureStore, relayURL: projectURL)
    }

    public func accountSessionService() -> any AccountSessionServicing { AccountSessionService(client: client) }

    public func accountContentSyncService() -> any AccountContentSyncing { AccountContentSyncService(client: client) }

    public func cloudContentService() -> any CloudContentServicing {
        SupabaseCloudContentService(client: client)
    }
}
