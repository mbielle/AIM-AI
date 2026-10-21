@testable import AIMMac
import AIMApplication
import AIMCore
import AIMMacPlatform
import XCTest

@MainActor
final class LegacyCredentialAdoptionCoordinatorTests: XCTestCase {
    func testReviewedLocalDestinationAndCopyUseOnlyInjectedBackgroundStore() async throws {
        let backing = CoordinatorAdoptionSecrets()
        let model = AppModel(database: try AIMDatabase(inMemory: true), providerStore: backing)
        let owner = try XCTUnwrap(model.account.identity?.storageID)
        let review = try await model.legacyCredentialAdoption.review()
        XCTAssertTrue(review.destination.contains("Local profile"))
        XCTAssertTrue(review.destination.contains(owner.uuidString))
        XCTAssertEqual(review.credentials.available, [.provider(.openAI)])
        let count = try await model.legacyCredentialAdoption.copy([.provider(.openAI)], reviewed: review)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(backing.value("openai"), Data("legacy-fixture-key".utf8))
        XCTAssertEqual(backing.value(ProfileScopedCredentialStore.prefix(owner) + "openai"), Data("legacy-fixture-key".utf8))
        XCTAssertTrue(backing.readThreads.allSatisfy { !$0 })
        _ = await model.prepareForTermination()
    }

    func testIdentityChangeWhileAuthorizationIsPendingRejectsAsyncCompletion() async throws {
        let backing = CoordinatorAdoptionSecrets()
        let model = AppModel(database: try AIMDatabase(inMemory: true), providerStore: backing)
        let owner = try XCTUnwrap(model.account.identity?.storageID)
        let review = try await model.legacyCredentialAdoption.review()
        let started = expectation(description: "selected legacy key awaits authorization")
        backing.blockLegacyRead(started: { started.fulfill() })
        let copy = Task { try await model.legacyCredentialAdoption.copy([.provider(.openAI)], reviewed: review) }
        await fulfillment(of: [started], timeout: 2)
        model.account.credentialScope.activate(UUID())
        backing.release()
        do { _ = try await copy.value; XCTFail("An identity change must invalidate the reviewed copy") }
        catch {}
        XCTAssertNil(backing.value(ProfileScopedCredentialStore.prefix(owner) + "openai"))
        XCTAssertEqual(backing.value("openai"), Data("legacy-fixture-key".utf8))
        _ = await model.prepareForTermination()
    }
}

private final class CoordinatorAdoptionSecrets: LegacyCredentialBacking, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var values = ["openai": Data("legacy-fixture-key".utf8)]
    private var threads: [Bool] = []
    private var started: (@Sendable () -> Void)?
    var readThreads: [Bool] { lock.withLock { threads } }
    func value(_ key: String) -> Data? { lock.withLock { values[key] } }
    func blockLegacyRead(started: @escaping @Sendable () -> Void) { lock.withLock { self.started = started } }
    func release() { gate.signal() }
    func credentialKeyNames() throws -> Set<String> { lock.withLock { Set(values.keys) } }
    func readData(forKey key: String) throws -> Data? {
        let callback = lock.withLock { threads.append(Thread.isMainThread); return key == "openai" ? started : nil }
        if let callback { callback(); gate.wait() }
        return value(key)
    }
    func store(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func removeData(forKey key: String) throws { lock.withLock { values[key] = nil } }
    func insertCredentialIfAbsent(_ data: Data, forKey key: String) throws -> Bool {
        lock.withLock { guard values[key] == nil else { return false }; values[key] = data; return true }
    }
}
