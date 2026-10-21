import AIMCore
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var localProfile: LocalProfile?
    @State private var profileError = false
    @State private var direct: AIMDirectConnectionStore?
    @State private var showAccount = false
    @State private var localPresentationID = UUID()

    private var cloudConfiguration: AppConfiguration? {
        if case let .configured(configuration) = environment.state { return configuration }
        return nil
    }

    var body: some View {
        Group {
            #if DEBUG
            if let qa = AIMQAContext.current { AIMQAClientView(context: qa) }
            else { regularContent }
            #else
            regularContent
            #endif
        }
    }

    private var regularContent: some View {
        Group {
            // Authentication fixtures exercise the cloud screens explicitly.
            if let scenario = environment.uiTestScenario, let configuration = cloudConfiguration {
                AuthenticationContainerView(configuration: configuration, uiTestScenario: scenario)
            } else if let localProfile {
                MainExperienceView(identity: .local(localProfile), remoteService: direct.map { $0.service as any RemoteServicing } ?? LocalRemoteService(), directConnection: direct,
                    cloudContentService: LocalContentService(storageID: AppIdentity.local(localProfile).storageID),
                    connectAccount: { showAccount = true })
                    .id(localPresentationID)
            } else if profileError {
                ContentUnavailableView("Local profile unavailable", systemImage: "lock.shield",
                    description: Text("AIM could not securely open this profile. Retry when this iPhone is unlocked. Existing data has been preserved."))
            } else {
                ProgressView("Opening local profile")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .task {
            guard localProfile == nil, environment.uiTestScenario == nil else { return }
            do {
                let profile = try LocalProfile.loadOrCreate(store: KeychainSecureStore())
                direct = try? AIMDirectConnectionStore(profile: profile)
                localProfile = profile
            }
            catch { profileError = true }
        }
        .fullScreenCover(isPresented: $showAccount, onDismiss: { localPresentationID = UUID() }) {
            NavigationStack {
                Group {
                    if let configuration = cloudConfiguration {
                        AuthenticationContainerView(configuration: configuration, uiTestScenario: nil)
                    } else {
                        ContentUnavailableView("Cloud server not configured", systemImage: "network.slash",
                            description: Text("Configure your own server for account sync and cloud Remote. Direct Mac connections and local use do not require a cloud account."))
                    }
                }
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Return to local profile") { showAccount = false } } }
            }
        }
    }
}
