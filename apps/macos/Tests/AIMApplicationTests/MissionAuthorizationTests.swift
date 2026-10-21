import AIMApplication
import XCTest

final class MissionAuthorizationTests: XCTestCase {
    func testScopeIsExactAndSensitiveOperationsNeverBecomeBlanketGrants() throws {
        let app = try MissionResource(kind: .application, identifier: "com.apple.TextEdit")
        let folder = try MissionResource(kind: .directory, identifier: "/tmp/aim-fixture")
        let origin = try MissionResource(kind: .webOrigin, identifier: "https://Example.com:443/")
        let recipient = try MissionResource(kind: .recipient, identifier: "User@Example.com")
        XCTAssertEqual(origin.identifier, "https://example.com")
        XCTAssertEqual(recipient.identifier, "user@example.com")
        XCTAssertTrue(folder.contains(try MissionResource(kind: .directory, identifier: "/tmp/aim-fixture/draft")))
        XCTAssertFalse(folder.contains(try MissionResource(kind: .directory, identifier: "/tmp/aim-fixture-other")))
        XCTAssertFalse(origin.contains(try MissionResource(kind: .webOrigin, identifier: "https://other.example.com")))
        XCTAssertFalse(app.contains(try MissionResource(kind: .application, identifier: "com.apple.Safari")))
        XCTAssertThrowsError(try MissionAuthorizationRule(resource: app, operations: [.input, .payment]))
        XCTAssertThrowsError(try MissionResource(kind: .webOrigin, identifier: "https://example.com/path"))
        XCTAssertThrowsError(try MissionResource(kind: .recipient, identifier: "*@example.com"))

        let authorization = MissionAuthorization(missionID: UUID(), revision: 0,
            rules: [try MissionAuthorizationRule(resource: app, operations: [.observe, .input]),
                    try MissionAuthorizationRule(resource: recipient, operations: [.send])],
            createdAt: .now, updatedAt: .now, revokedAt: nil)
        XCTAssertTrue(authorization.covers(.input, target: app))
        XCTAssertTrue(authorization.covers(.send, target: recipient))
        XCTAssertFalse(authorization.covers(.payment, target: app))
        XCTAssertFalse(authorization.covers(.edit, target: app))
        let twoTargets = try MissionToolIntent(needs: [
            MissionPermissionNeed(operation: .observe, target: app),
            MissionPermissionNeed(operation: .send, target: recipient)
        ])
        XCTAssertTrue(authorization.covers(twoTargets))
        let outside = try MissionResource(kind: .recipient, identifier: "Other@Example.com")
        let mixed = try MissionToolIntent(needs: [
            MissionPermissionNeed(operation: .observe, target: app),
            MissionPermissionNeed(operation: .send, target: outside)
        ])
        XCTAssertFalse(authorization.covers(mixed))
        XCTAssertThrowsError(try MissionToolIntent(needs: []))
    }

    func testAuthorizationIsPersistedRevisionedAndRevokedWithoutWideningLegacyMission() async throws {
        let database = try AIMDatabase(inMemory: true)
        let chat = Conversation(title: "Scope", mode: .agent)
        try await SQLiteConversationRepository(database: database).save(chat)
        let repository = SQLiteAgentMissionRepository(database: database)
        let mission = try await repository.beginOrSteer(conversationID: chat.id, message: "Edit fixture")
        let initial = try await repository.authorization(missionID: mission.id)
        XCTAssertNil(initial)
        let folder = try MissionResource(kind: .directory, identifier: "/tmp/aim-fixture")
        let edit = try MissionAuthorizationRule(resource: folder, operations: [.observe, .edit])
        let first = try await repository.replaceAuthorization(missionID: mission.id,
            expectedRevision: nil, rules: [edit])
        XCTAssertEqual(first.revision, 0)
        XCTAssertTrue(first.covers(.edit, target: folder))
        do {
            _ = try await repository.replaceAuthorization(missionID: mission.id,
                expectedRevision: nil, rules: [edit])
            XCTFail("A stale scope update must fail")
        } catch MissionAuthorizationError.conflict {}
        let revoked = try await repository.revokeAuthorization(missionID: mission.id,
            expectedRevision: first.revision)
        XCTAssertEqual(revoked.revision, 1)
        XCTAssertFalse(revoked.covers(.edit, target: folder))
        XCTAssertNotNil(revoked.revokedAt)
        let fetched = try await repository.authorization(missionID: mission.id)
        let reloaded = try XCTUnwrap(fetched)
        XCTAssertEqual(reloaded.missionID, revoked.missionID)
        XCTAssertEqual(reloaded.revision, revoked.revision)
        XCTAssertEqual(reloaded.rules, revoked.rules)
        XCTAssertNotNil(reloaded.revokedAt)
        do {
            _ = try await repository.revokeAuthorization(missionID: mission.id,
                expectedRevision: first.revision)
            XCTFail("A stale revocation must fail")
        } catch MissionAuthorizationError.conflict {}
        let restored = try await repository.replaceAuthorization(missionID: mission.id,
            expectedRevision: revoked.revision, rules: [edit])
        XCTAssertEqual(restored.revision, 2)
        XCTAssertNil(restored.revokedAt)
        XCTAssertTrue(restored.covers(.edit, target: folder))
    }
}
