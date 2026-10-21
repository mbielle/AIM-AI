import Foundation
import XCTest
@testable import AIMCore

final class RemoteMirrorKeyCacheTests: XCTestCase {
    func testNewMachineVersionCannotReuseOldEnvelope() {
        let context = context()
        let now = Date()
        let entry = RemoteMirrorKeyCacheEntry(context: context, keys: [1: Data([1])], fetchedAt: now)
        XCTAssertTrue(entry.isUsable(context: context, requiredVersion: 1, now: now))
        XCTAssertFalse(entry.isUsable(context: context, requiredVersion: 2, now: now))
    }
    func testAccountDeviceKeyAndGenerationEachInvalidateCachedKey() {
        let context = context()
        let now = Date()
        let entry = RemoteMirrorKeyCacheEntry(context: context, keys: [1: Data([1])], fetchedAt: now)
        let changed = [
            RemoteMirrorKeyContext(accountID: UUID(), deviceID: context.deviceID, publicKey: context.publicKey, generation: context.generation),
            RemoteMirrorKeyContext(accountID: context.accountID, deviceID: "another", publicKey: context.publicKey, generation: context.generation),
            RemoteMirrorKeyContext(accountID: context.accountID, deviceID: context.deviceID, publicKey: "repaired", generation: context.generation),
            RemoteMirrorKeyContext(accountID: context.accountID, deviceID: context.deviceID, publicKey: context.publicKey, generation: UUID())
        ]
        for value in changed { XCTAssertFalse(entry.isUsable(context: value, requiredVersion: 1, now: now)) }
    }
    func testMissingOrExpiredEnvelopeMustBeFetchedEvenWithoutRealtime() {
        let context = context()
        let now = Date()
        XCTAssertFalse(RemoteMirrorKeyCacheEntry(context: context, keys: [:], fetchedAt: now)
            .isUsable(context: context, requiredVersion: nil, now: now))
        XCTAssertFalse(RemoteMirrorKeyCacheEntry(context: context, keys: [1: Data([1])], fetchedAt: now.addingTimeInterval(-5))
            .isUsable(context: context, requiredVersion: nil, now: now))
    }
    private func context() -> RemoteMirrorKeyContext {
        .init(accountID: UUID(), deviceID: "phone", publicKey: "public", generation: UUID())
    }
}
