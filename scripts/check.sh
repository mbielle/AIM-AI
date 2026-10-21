#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
check="${1:-core}"
if [[ "$check" == "audit" ]]; then exec python3 "$repo_dir/scripts/audit-publication.py"; fi
scratch="$(mktemp -d "${TMPDIR:-/private/tmp}/aim-check.XXXXXXXX")"
export CFFIXED_USER_HOME="$scratch/home"
export CLANG_MODULE_CACHE_PATH="$scratch/modules"
export SWIFT_MODULECACHE_PATH="$scratch/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/modules"
export AIM_TEST_INSTALLATION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
mkdir -p "$CFFIXED_USER_HOME/Library/Application Support" "$CLANG_MODULE_CACHE_PATH"
case "$check" in
 core) swift test --package-path "$repo_dir/packages/AIMCore" ;;
 # Targeted regression gate, not full-suite certification. Mail's real system
 # dictionary compile checks are included. The QR rasterization assertion stays
 # explicitly excluded pending verification outside the known nested-renderer
 # sandbox restriction; scanning/pairing still needs separate qualification.
 macos) swift test --package-path "$repo_dir/apps/macos" \
   --scratch-path "$scratch/macos-build" \
   --filter 'LocalModeTests|MacLocalProfileStoreTests|AccountChatSyncTests|AccountAccessTests|MacAccountControllerTests|ComposerDraftNavigationTests|ConversationNavigationTests|ProjectNavigationTests|ChatRegenerationTests|RunCoordinatorTests|ContinuityRemoteBridgeTests|RuntimeRemoteControlTests|StandingApprovalTests|EmbeddedCuaDriverHostTests|MacMailToolTests|MailSenderFormatTests|RemoteHostTests|RemotePairingLinkTests|RemoteHostAttachmentTests|SettingsIntegrationTests|RemoteHostBridgeTests|ProfileScopedCredentialStoreTests|ProviderKeyStoreTests|ProviderKeyAccessTests|LegacyCredentialAdoptionTests|LegacyCredentialAdoptionCoordinatorTests|MacVisualDelegationCoordinatorTests|ToolVisionNavigationTests' \
   --skip 'RemotePairingLinkTests.testQRCodeCarriesOnlyTheOneTimeCode' ;;
 ios-build) xcodebuild build-for-testing -project "$repo_dir/apps/ios/AIM.xcodeproj" -scheme AIM -destination 'generic/platform=iOS Simulator' -derivedDataPath "$scratch/DerivedData" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= ;;
 *) print -u2 'Usage: scripts/check.sh core|macos|ios-build|audit'; exit 2 ;;
esac
