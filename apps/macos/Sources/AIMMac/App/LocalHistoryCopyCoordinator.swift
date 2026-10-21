import AIMApplication
import AIMAgentRuntime
import AIMCore
import Foundation

/// Coordinates the optional reviewed transfer without exposing AppModel's
/// repositories or coupling the account-copy rules to the settings view.
@MainActor
final class LocalHistoryCopyCoordinator {
    private let account: MacAccountController
    private let sync: AccountChatSync
    private let refresh: @MainActor () async throws -> Void

    init(account: MacAccountController, sync: AccountChatSync,
         refresh: @escaping @MainActor () async throws -> Void) {
        self.account = account; self.sync = sync; self.refresh = refresh
    }

    func preview() async throws -> AccountChatSync.LocalCopyPreview {
        guard let profile = account.localProfile, let owner = account.accessUser?.id else { throw AccountServiceError.revoked }
        return try await sync.previewLocalCopy(profile: profile, accountID: owner,
            currentAccount: { [weak account] in await account?.accessUser?.id })
    }

    func copy(_ preview: AccountChatSync.LocalCopyPreview, selectedIDs: Set<UUID>) async throws -> Int {
        guard account.accessUser?.id == preview.accountID else { throw AccountServiceError.revoked }
        let count = try await sync.copyLocalToAccount(preview, selectedIDs: selectedIDs,
            currentAccount: { [weak account] in await account?.accessUser?.id })
        guard account.accessUser?.id == preview.accountID else { throw AccountServiceError.revoked }
        try await refresh()
        return count
    }
}
