import AIMCore
import XCTest

final class RemotePeerContractTests: XCTestCase {
    private func fixture() throws -> (RemotePeerPrivateIdentity, RemotePeerPrivateIdentity, RemotePeerPair, RemotePeerGrant) {
        let origin = RemotePeerPrivateIdentity(machineID: UUID()), worker = RemotePeerPrivateIdentity(machineID: UUID())
        let pair = try RemotePeerPair(id: UUID(), accountID: UUID(), origin: origin.publicIdentity,
            worker: worker.publicIdentity, accepted: true, revoked: false, expiresAt: .now.addingTimeInterval(3600))
        let grant = RemotePeerGrant(id: UUID(), pairID: pair.id, accountID: pair.accountID,
            originMachineID: origin.machineID, workerMachineID: worker.machineID, parentExecutionID: UUID(),
            childExecutionID: UUID(), childConversationID: UUID(), workspaceID: "chosen-project",
            actions: [.start, .snapshot, .budget], allowedToolNames: ["read_file", "list_dir"],
            provider: "fixture", modelID: "fixture", budgetAuthorization: Data("{}".utf8), expiresAt: pair.expiresAt)
        return (origin, worker, pair, grant)
    }
    func testGrantSignatureSurvivesDecodingSets() throws {
        let (origin, _, pair, grant) = try fixture()
        let signed = try origin.sign(grant)
        let encoded = try RemotePeerCoding.encode(signed)
        let restored = try RemotePeerCoding.decode(RemotePeerSignedGrant.self, encoded)
        XCTAssertEqual(encoded, try RemotePeerCoding.encode(restored))
        XCTAssertNoThrow(try RemotePeerPrivateIdentity.verify(restored, origin: pair.origin))
    }
    func testAEADRejectsChangedCommandContext() throws {
        let (origin, worker, pair, grant) = try fixture()
        let request = RemotePeerRequest(commandID: UUID(), action: .start, grant: try origin.sign(grant), payload: Data("private-prompt".utf8))
        let packet = try origin.seal(request, pair: pair, to: worker.machineID, commandID: request.commandID, kind: .request)
        XCTAssertEqual(try worker.open(RemotePeerRequest.self, packet: packet, pair: pair), request)
        let changed = RemotePeerPacket(pairID: packet.pairID, accountID: packet.accountID, from: packet.from,
            to: packet.to, commandID: UUID(), kind: packet.kind, ciphertext: packet.ciphertext, signature: packet.signature)
        XCTAssertThrowsError(try worker.open(RemotePeerRequest.self, packet: changed, pair: pair))
    }
    func testManifestRefusesEscapesAndFileDirectoryCollision() throws {
        let (_, _, _, grant) = try fixture()
        for path in ["../escape", "/absolute", "a//b", "a/./b", "a\\b"] {
            XCTAssertThrowsError(try RemotePeerArtifactManifest.validatePath(path))
        }
        let emptyHash = RemotePeerArtifactManifest.hash(Data())
        let files = [RemotePeerArtifactFile(path: "file", size: 0, sha256: emptyHash, chunks: []),
                     RemotePeerArtifactFile(path: "file/nested", size: 0, sha256: emptyHash, chunks: [])]
        let manifest = RemotePeerArtifactManifest(transferID: UUID(), grantID: grant.id, childExecutionID: grant.childExecutionID, files: files)
        XCTAssertThrowsError(try manifest.validate(grant: grant))
    }
}
