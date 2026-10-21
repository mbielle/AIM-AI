import AIMAgentRuntime
import AIMCore
import AIMMacPlatform
import Foundation

@MainActor
final class LegacyCredentialAdoptionCoordinator {
    struct Review: Sendable {
        let credentials: LegacyCredentialReview
        let destination: String
    }
    private let account: MacAccountController
    private let store: ProfileScopedCredentialStore
    private let didCopy: @MainActor () async -> Void

    init(account: MacAccountController, store: ProfileScopedCredentialStore,
         didCopy: @escaping @MainActor () async -> Void) {
        self.account = account; self.store = store; self.didCopy = didCopy
    }
    func review() async throws -> Review {
        guard let identity = account.identity else { throw CredentialScopeError.unavailable }
        let captured = account.credentialScope.snapshot(), store = store
        let destination = identity.isLocal ? "Local profile · \(identity.storageID.uuidString)"
            : "AIM account · \(identity.authenticatedUser?.email ?? "") · \(identity.storageID.uuidString)"
        let result: LegacyCredentialReview = try await offMain { try store.reviewLegacyProviderCredentials() }
        guard account.identity?.storageID == identity.storageID, account.credentialScope.snapshot() == captured,
              result.scope == captured else { throw CredentialScopeError.changed }
        return .init(credentials: result, destination: destination)
    }
    func copy(_ selected: Set<LegacyProviderCredential>, reviewed: Review) async throws -> Int {
        guard account.identity?.storageID == reviewed.credentials.scope.ownerID,
              account.credentialScope.snapshot() == reviewed.credentials.scope else { throw CredentialScopeError.changed }
        let store = store
        let count = try await offMain { try store.copyLegacyProviderCredentials(selected, reviewed: reviewed.credentials) }
        guard account.identity?.storageID == reviewed.credentials.scope.ownerID,
              account.credentialScope.snapshot() == reviewed.credentials.scope else { throw CredentialScopeError.changed }
        await didCopy()
        guard account.credentialScope.snapshot() == reviewed.credentials.scope else { throw CredentialScopeError.changed }
        return count
    }
    private func offMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result(catching: operation)) }
        }
    }
}
