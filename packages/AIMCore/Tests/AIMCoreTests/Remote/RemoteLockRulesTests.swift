import XCTest
@testable import AIMCore

final class RemoteLockRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPINTokenAndBackgroundRulesMatchReference() {
        XCTAssertTrue(RemoteLockRules.isValidPIN("123456"))
        XCTAssertFalse(RemoteLockRules.isValidPIN("12345"))
        XCTAssertFalse(RemoteLockRules.isValidPIN("12a456"))
        XCTAssertTrue(RemoteLockRules.isExpired(token: nil, now: now))
        XCTAssertFalse(RemoteLockRules.isExpired(token: token(minutes: 60), now: now))
        XCTAssertTrue(RemoteLockRules.isExpired(token: token(minutes: -1), now: now))
        XCTAssertEqual(RemoteLockRules.backgroundTimeout, 15 * 60)
        XCTAssertFalse(RemoteLockRules.shouldRelock(hiddenSince: now.addingTimeInterval(-14 * 60), now: now))
        XCTAssertTrue(RemoteLockRules.shouldRelock(hiddenSince: now.addingTimeInterval(-15 * 60), now: now))
        XCTAssertFalse(RemoteLockRules.applies(to: .chat))
        XCTAssertTrue(RemoteLockRules.applies(to: .code))
        XCTAssertTrue(RemoteLockRules.applies(to: .agent))
    }

    func testLockStepAndDisableProofMatchReference() {
        XCTAssertEqual(RemoteLockRules.step(server: nil, token: nil, now: now), .loading)
        XCTAssertEqual(RemoteLockRules.step(server: .init(ok: false, error: "device_not_paired"), token: nil, now: now), .notPaired)
        XCTAssertEqual(RemoteLockRules.step(server: .init(ok: true, passkeys: 0, hasPIN: false), token: nil, now: now), .configuration)
        XCTAssertEqual(RemoteLockRules.step(server: .init(ok: true, passkeys: 0, hasPIN: true), token: nil, now: now), .locked)
        XCTAssertEqual(RemoteLockRules.step(server: .init(ok: true, passkeys: 1, hasPIN: true), token: token(minutes: 30), now: now), .unlocked)
        XCTAssertEqual(RemoteLockRules.step(server: .init(ok: true, passkeys: 0, hasPIN: true, lockedUntil: now.addingTimeInterval(900)), token: nil, now: now), .blocked)
        XCTAssertEqual(RemoteLockRules.step(server: .init(ok: true, passkeys: 1, hasPIN: true, lockedUntil: now.addingTimeInterval(900)), token: nil, now: now), .locked)
        XCTAssertEqual(RemoteLockRules.step(server: .init(ok: true, passkeys: 0, hasPIN: true, enabled: false), token: nil, now: now), .unlocked)
        XCTAssertTrue(RemoteLockRules.requiresUnlockToDisable(server: .init(ok: true, passkeys: 0, hasPIN: true), token: nil, now: now))
        XCTAssertFalse(RemoteLockRules.requiresUnlockToDisable(server: .init(ok: true, passkeys: 0, hasPIN: true), token: token(minutes: 30), now: now))
        XCTAssertEqual(RemoteLockRules.remainingMinutes(until: now.addingTimeInterval(61), now: now), 2)
    }

    func testInMemoryVaultRelocksAfterFifteenMinutesOnly() {
        let vault = RemoteUnlockVault()
        vault.setToken(token(minutes: 600))
        vault.applicationDidEnterBackground(at: now)
        vault.applicationWillEnterForeground(at: now.addingTimeInterval(5 * 60))
        XCTAssertNotNil(vault.token)
        vault.applicationDidEnterBackground(at: now.addingTimeInterval(6 * 60))
        vault.applicationWillEnterForeground(at: now.addingTimeInterval(21 * 60))
        XCTAssertNil(vault.token)
    }

    private func token(minutes: Double) -> RemoteUnlockToken {
        .init(value: "token", expiresAt: now.addingTimeInterval(minutes * 60))
    }
}
