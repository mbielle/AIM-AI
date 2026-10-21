import Foundation
import XCTest
@testable import AIMCore

private final class LockMemory: SecureStoring, @unchecked Sendable {
    let mutex = NSLock(); var values: [String: Data] = [:]; var failed = false
    func readData(forKey key: String) throws -> Data? { try mutex.withLock { if failed { throw AppLockError.storage }; return values[key] } }
    func store(_ data: Data, forKey key: String) throws { try mutex.withLock { if failed { throw AppLockError.storage }; values[key] = data } }
    func removeData(forKey key: String) throws { mutex.withLock { _ = values.removeValue(forKey: key) } }
}
@MainActor private final class LockAuthenticator: AppLockAuthenticating {
    var cancelled = false; var calls = 0; var duringAuthentication: (() -> Void)?
    func authenticate(reason: String) async throws { calls += 1; duringAuthentication?(); if cancelled { throw AppLockError.cancelled } }
}
@available(macOS 14.0, iOS 17.0, *)
@MainActor final class AppLockServiceTests: XCTestCase {
    func testToggleRequiresFreshAuthenticationBothWaysAndCancelKeepsSetting() async {
        let auth = LockAuthenticator(), memory = LockMemory(), account = UUID()
        let lock = AppLockService(accountID: account, authenticator: auth, secureStore: memory)
        await lock.setRequired(true); XCTAssertTrue(lock.isRequired); XCTAssertFalse(lock.isLocked)
        auth.cancelled = true; await lock.setRequired(false); XCTAssertTrue(lock.isRequired)
        auth.cancelled = false; await lock.setRequired(false); XCTAssertFalse(lock.isRequired); XCTAssertEqual(auth.calls, 3)
        XCTAssertFalse(AppLockService(accountID: account, authenticator: auth, secureStore: memory).isRequired)
    }
    func testMinuteAwayLocksButInactiveSystemDialogDoesNotLoop() async {
        let auth = LockAuthenticator(), lock = AppLockService(accountID: UUID(), authenticator: LockAuthenticator(), secureStore: LockMemory())
        await lock.setRequired(true)
        let start = Date(timeIntervalSince1970: 100)
        lock.becameInactive(); XCTAssertTrue(lock.isConcealed); lock.becameActive(at: start); XCTAssertFalse(lock.isLocked)
        lock.enteredBackground(at: start); lock.becameActive(at: start.addingTimeInterval(59)); XCTAssertFalse(lock.isLocked)
        lock.enteredBackground(at: start); lock.becameActive(at: start.addingTimeInterval(60)); XCTAssertTrue(lock.isLocked)
        let other = AppLockService(accountID: UUID(), authenticator: auth, secureStore: LockMemory())
        await other.setRequired(true); other.lock()
        auth.duringAuthentication = { other.becameInactive(); other.becameActive() }
        await other.unlock(); XCTAssertFalse(other.isLocked); XCTAssertFalse(other.isConcealed)
    }
    func testRealBackgroundDuringAuthenticationInvalidatesStaleUnlock() async {
        let auth = LockAuthenticator(), lock = AppLockService(accountID: UUID(), authenticator: LockAuthenticator(), secureStore: LockMemory())
        await lock.setRequired(true)
        let protected = AppLockService(accountID: UUID(), authenticator: auth, secureStore: LockMemory())
        await protected.setRequired(true); protected.lock()
        auth.duringAuthentication = {
            protected.enteredBackground(at: Date(timeIntervalSince1970: 100))
            protected.becameActive(at: Date(timeIntervalSince1970: 161))
        }
        await protected.unlock(); XCTAssertTrue(protected.isLocked)
    }
    func testAccountIsolationMigrationAndUnreadableStorageFailClosed() throws {
        let memory = LockMemory(), auth = LockAuthenticator(), account = UUID()
        let lock = AppLockService(accountID: account, authenticator: auth, secureStore: memory)
        try lock.preserveLegacyProtection(true); XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(AppLockService(accountID: UUID(), authenticator: auth, secureStore: memory).isRequired)
        try lock.preserveLegacyProtection(false); XCTAssertTrue(lock.isRequired)
        try memory.store(Data([99]), forKey: "require-system-auth.\(account.uuidString.lowercased())")
        XCTAssertTrue(AppLockService(accountID: account, authenticator: auth, secureStore: memory).isLocked)
        memory.failed = true
        XCTAssertTrue(AppLockService(accountID: account, authenticator: auth, secureStore: memory).isLocked)
    }
}
