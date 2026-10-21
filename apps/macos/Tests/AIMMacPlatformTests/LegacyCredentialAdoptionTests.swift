@testable import AIMMacPlatform
import AIMCore
import XCTest

final class LegacyCredentialAdoptionTests: XCTestCase {
    func testReviewIsAttributeOnlyAndCopyReadsOnlyExplicitSelectionPreservingOriginals() throws {
        let backing = AdoptionSecrets(), owner = UUID()
        backing.values = ["openai": Data("owned-api-key".utf8), "anthropic": Data("other-api-key".utf8),
                          "chatgpt": Data("oauth-access".utf8), "chatgpt-session": Data("session".utf8),
                          "plugin-token": Data("token".utf8), "bfl": Data("image-api-key".utf8)]
        let store = ProfileScopedCredentialStore(backing: backing, scope: .init(ownerID: owner))
        let review = try store.reviewLegacyProviderCredentials()
        XCTAssertEqual(review.available, [.provider(.openAI), .provider(.anthropic), .flux])
        XCTAssertTrue(backing.reads.isEmpty, "Review never decrypts a legacy or destination secret")
        XCTAssertEqual(try store.copyLegacyProviderCredentials([.provider(.openAI)], reviewed: review), 1)
        XCTAssertEqual(backing.reads, ["openai"])
        XCTAssertEqual(backing.values[ProfileScopedCredentialStore.prefix(owner) + "openai"], Data("owned-api-key".utf8))
        XCTAssertNil(backing.values[ProfileScopedCredentialStore.prefix(owner) + "anthropic"])
        XCTAssertEqual(backing.values["openai"], Data("owned-api-key".utf8))
        XCTAssertEqual(backing.values["chatgpt-session"], Data("session".utf8))
        XCTAssertEqual(backing.overwritingWrites, 0)
    }

    func testEmptyUnreviewedAndOAuthSelectionIsRejectedWithoutReadingSecrets() throws {
        let backing = AdoptionSecrets(); backing.values["openai"] = Data("key".utf8)
        let store = ProfileScopedCredentialStore(backing: backing, scope: .init(ownerID: UUID()))
        let review = try store.reviewLegacyProviderCredentials()
        for selected: Set<LegacyProviderCredential> in [[], [.provider(.anthropic)], [.provider(.chatgpt)], [.provider(.local)]] {
            XCTAssertThrowsError(try store.copyLegacyProviderCredentials(selected, reviewed: review))
        }
        XCTAssertTrue(backing.reads.isEmpty); XCTAssertEqual(backing.inserts, 0)
    }

    func testExistingDestinationIsKeptAndNewDestinationAfterReviewIsNotOverwritten() throws {
        let backing = AdoptionSecrets(), owner = UUID(), prefix = ProfileScopedCredentialStore.prefix(owner)
        backing.values = ["openai": Data("legacy".utf8), "anthropic": Data("legacy-other".utf8), prefix + "openai": Data("existing".utf8)]
        let store = ProfileScopedCredentialStore(backing: backing, scope: .init(ownerID: owner))
        let review = try store.reviewLegacyProviderCredentials()
        XCTAssertEqual(review.existingDestination, [.provider(.openAI)])
        XCTAssertEqual(review.available, [.provider(.anthropic)])
        backing.values[prefix + "anthropic"] = Data("created-after-review".utf8)
        XCTAssertThrowsError(try store.copyLegacyProviderCredentials([.provider(.anthropic)], reviewed: review))
        XCTAssertTrue(backing.reads.isEmpty)
        XCTAssertEqual(backing.values[prefix + "openai"], Data("existing".utf8))
        XCTAssertEqual(backing.values[prefix + "anthropic"], Data("created-after-review".utf8))
    }

    func testAtomicInsertPreservesAnotherProcessesRacingDestination() throws {
        let backing = AdoptionSecrets(), owner = UUID(), destination = ProfileScopedCredentialStore.prefix(owner) + "openai"
        backing.values["openai"] = Data("legacy".utf8)
        let store = ProfileScopedCredentialStore(backing: backing, scope: .init(ownerID: owner))
        let review = try store.reviewLegacyProviderCredentials()
        backing.beforeInsert = { backing.values[destination] = Data("racing-process-key".utf8) }
        XCTAssertThrowsError(try store.copyLegacyProviderCredentials([.provider(.openAI)], reviewed: review))
        XCTAssertEqual(backing.values[destination], Data("racing-process-key".utf8))
        XCTAssertEqual(backing.values["openai"], Data("legacy".utf8))
        XCTAssertEqual(backing.overwritingWrites, 0)
    }

    func testChangedIdentityOrEpochInvalidatesReviewBeforeLegacyRead() throws {
        let backing = AdoptionSecrets(), first = UUID(), second = UUID(), scope = CredentialStorageScope(ownerID: first)
        backing.values["openai"] = Data("legacy".utf8)
        let store = ProfileScopedCredentialStore(backing: backing, scope: scope)
        let review = try store.reviewLegacyProviderCredentials()
        scope.activate(second)
        XCTAssertThrowsError(try store.copyLegacyProviderCredentials([.provider(.openAI)], reviewed: review))
        scope.activate(first)
        XCTAssertThrowsError(try store.copyLegacyProviderCredentials([.provider(.openAI)], reviewed: review))
        XCTAssertTrue(backing.reads.isEmpty); XCTAssertEqual(backing.inserts, 0)
    }

    func testIdentitySwitchDuringKeychainAuthorizationCannotWriteAnyDestination() throws {
        let backing = AdoptionSecrets(), first = UUID(), second = UUID(), scope = CredentialStorageScope(ownerID: first)
        backing.values["openai"] = Data("legacy".utf8)
        let store = ProfileScopedCredentialStore(backing: backing, scope: scope)
        let review = try store.reviewLegacyProviderCredentials()
        backing.afterRead = { scope.activate(second) }
        XCTAssertThrowsError(try store.copyLegacyProviderCredentials([.provider(.openAI)], reviewed: review))
        XCTAssertEqual(backing.inserts, 0)
        XCTAssertNil(backing.values[ProfileScopedCredentialStore.prefix(first) + "openai"])
        XCTAssertNil(backing.values[ProfileScopedCredentialStore.prefix(second) + "openai"])
        XCTAssertEqual(backing.values["openai"], Data("legacy".utf8))
    }

    func testPartialFailureKeepsEarlierCopyAndEveryOriginal() throws {
        let backing = AdoptionSecrets(), owner = UUID(), prefix = ProfileScopedCredentialStore.prefix(owner)
        backing.values = ["anthropic": Data("first-key".utf8), "openai": Data("second-key".utf8)]
        let store = ProfileScopedCredentialStore(backing: backing, scope: .init(ownerID: owner))
        let review = try store.reviewLegacyProviderCredentials()
        backing.failInsertKey = prefix + "openai"
        XCTAssertThrowsError(try store.copyLegacyProviderCredentials([.provider(.openAI), .provider(.anthropic)], reviewed: review))
        XCTAssertEqual(backing.values[prefix + "anthropic"], Data("first-key".utf8))
        XCTAssertNil(backing.values[prefix + "openai"])
        XCTAssertEqual(backing.values["anthropic"], Data("first-key".utf8))
        XCTAssertEqual(backing.values["openai"], Data("second-key".utf8))
    }

    func testStoreWithoutAtomicInsertFailsClosedAndNeverOverwrites() throws {
        let secrets = AdoptionSecrets(); secrets.values["openai"] = Data("legacy".utf8)
        let backing = MacProviderKeyStore(backing: secrets, inventoryKeys: { ["openai"] })
        let store = ProfileScopedCredentialStore(backing: backing, scope: .init(ownerID: UUID()))
        let review = try store.reviewLegacyProviderCredentials()
        XCTAssertThrowsError(try store.copyLegacyProviderCredentials([.provider(.openAI)], reviewed: review))
        XCTAssertEqual(secrets.overwritingWrites, 0); XCTAssertEqual(secrets.inserts, 0)
    }

    func testDuplicateAtomicInsertInvalidatesAStaleProcessCache() throws {
        let secrets = AdoptionSecrets(), key = "profile.v1.fixture.openai"
        secrets.values[key] = Data("cached-older-key".utf8)
        let backing = MacProviderKeyStore(backing: secrets, inventoryKeys: { Set(secrets.values.keys) },
            insertOnly: { try secrets.insertCredentialIfAbsent($0, forKey: $1) })
        XCTAssertEqual(try backing.readData(forKey: key), Data("cached-older-key".utf8))
        secrets.values[key] = Data("other-process-key".utf8)
        XCTAssertFalse(try backing.insertCredentialIfAbsent(Data("imported-key".utf8), forKey: key))
        XCTAssertEqual(try backing.readData(forKey: key), Data("other-process-key".utf8))
    }
}

/// Test-only store. All tests remain synchronous; callbacks simulate a delayed
/// Keychain result or another process without touching Security.framework data.
private final class AdoptionSecrets: LegacyCredentialBacking, @unchecked Sendable {
    var values: [String: Data] = [:]
    var reads: [String] = []
    var overwritingWrites = 0
    var inserts = 0
    var beforeInsert: (() -> Void)?
    var afterRead: (() -> Void)?
    var failInsertKey: String?
    func credentialKeyNames() throws -> Set<String> { Set(values.keys) }
    func readData(forKey key: String) throws -> Data? { reads.append(key); let data = values[key]; afterRead?(); return data }
    func store(_ data: Data, forKey key: String) throws { overwritingWrites += 1; values[key] = data }
    func removeData(forKey key: String) throws { values[key] = nil }
    func insertCredentialIfAbsent(_ data: Data, forKey key: String) throws -> Bool {
        inserts += 1
        if key == failInsertKey { throw LegacyCredentialAdoptionError.unavailable }
        beforeInsert?()
        guard values[key] == nil else { return false }
        values[key] = data; return true
    }
}
