import Foundation
import XCTest
@testable import AIMCore

final class RemoteTransferCryptoTests: XCTestCase {
    private let transferID = "transfert-vecteur-1"
    private let cleartext = Data("Pièce jointe — vecteur ✓".utf8)

    func testOfficialTransferBlockVectorMatchesByteForByte() throws {
        let encrypted = try RemoteTransferCrypto.encryptBlock(
            cleartext,
            key: CryptoVectorSupport.mirrorKey,
            transferID: transferID,
            index: 0,
            total: 1,
            nonce: CryptoVectorSupport.nonce
        )

        XCTAssertEqual(
            encrypted.base64EncodedString(),
            "oKGio6SlpqeoqaqrtnG/hSauItUNDOmnYloiXuSML3XxwycZ7i7EGuxS9EtlxOPzFlp5Cvst7SJ3"
        )
        XCTAssertEqual(
            try RemoteTransferCrypto.decryptBlock(
                encrypted,
                key: CryptoVectorSupport.mirrorKey,
                transferID: transferID,
                index: 0,
                total: 1
            ),
            cleartext
        )
    }

    func testOfficialManifestVectorMatchesByteForByte() throws {
        let manifest = officialManifest
        XCTAssertEqual(String(decoding: manifest.canonicalJSONData(), as: UTF8.self), officialManifestJSON)

        let encrypted = try RemoteTransferCrypto.sealManifest(
            manifest,
            key: CryptoVectorSupport.mirrorKey,
            nonce: CryptoVectorSupport.nonce
        )

        XCTAssertEqual(encrypted, officialEncryptedManifest)
        XCTAssertEqual(
            try RemoteTransferCrypto.openManifest(
                encrypted,
                transferID: transferID,
                keys: [1: CryptoVectorSupport.mirrorKey]
            ),
            manifest
        )
    }

    func testAssemblerRejectsCorruptionMissingBlocksAndExpiredTransfers() throws {
        let encrypted = Data(base64Encoded: "oKGio6SlpqeoqaqrtnG/hSauItUNDOmnYloiXuSML3XxwycZ7i7EGuxS9EtlxOPzFlp5Cvst7SJ3")!
        XCTAssertEqual(
            try RemoteTransferCrypto.assemble(
                manifest: officialManifest,
                blocks: [.init(index: 0, encrypted: encrypted)],
                key: CryptoVectorSupport.mirrorKey,
                now: Date(timeIntervalSince1970: 0)
            ),
            cleartext
        )

        var corrupted = encrypted
        corrupted[20] ^= 1
        XCTAssertThrowsError(
            try RemoteTransferCrypto.assemble(
                manifest: officialManifest,
                blocks: [.init(index: 0, encrypted: corrupted)],
                key: CryptoVectorSupport.mirrorKey,
                now: Date(timeIntervalSince1970: 0)
            )
        ) { error in
            XCTAssertEqual(error as? RemoteTransferError, .unreadableBlock)
        }

        XCTAssertThrowsError(
            try RemoteTransferCrypto.assemble(
                manifest: officialManifest,
                blocks: [],
                key: CryptoVectorSupport.mirrorKey,
                now: Date(timeIntervalSince1970: 0)
            )
        ) { error in
            XCTAssertEqual(error as? RemoteTransferError, .incompleteTransfer)
        }

        XCTAssertThrowsError(
            try RemoteTransferCrypto.assemble(
                manifest: officialManifest,
                blocks: [.init(index: 0, encrypted: encrypted)],
                key: CryptoVectorSupport.mirrorKey,
                now: Date(timeIntervalSince1970: 4_071_000_000)
            )
        ) { error in
            XCTAssertEqual(error as? RemoteTransferError, .expiredTransfer)
        }
    }

    func testMissingBlockCalculationAndStoragePath() throws {
        XCTAssertEqual(RemoteTransferCrypto.missingBlocks(total: 3, present: [2, 2, -1, 9]), [0, 1])
        XCTAssertEqual(
            try RemoteTransferCrypto.storagePath(userID: "user", manifest: officialManifest, index: 0),
            "user/11111111-2222-3333-4444-555555555555/transfert-vecteur-1/000000.bin"
        )
    }

    func testPreparingAnAttachmentEncryptsEveryBlockAndProducesAnAssemblableManifest() throws {
        let data = Data(repeating: 0x41, count: RemoteTransferCrypto.chunkSize + 17)
        let prepared = try RemoteTransferCrypto.prepareAttachment(
            data: data,
            key: CryptoVectorSupport.mirrorKey,
            keyVersion: 4,
            transferID: "prepared-transfer",
            machineID: CryptoVectorSupport.machineID,
            sessionID: "session-1",
            filename: "notes.txt",
            mimeType: "text/plain",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(prepared.manifest.chunkCount, 2)
        XCTAssertEqual(prepared.manifest.clearSize, data.count)
        XCTAssertEqual(prepared.blocks.map(\.index), [0, 1])
        XCTAssertEqual(
            try RemoteTransferCrypto.assemble(
                manifest: prepared.manifest,
                blocks: prepared.blocks,
                key: CryptoVectorSupport.mirrorKey,
                now: Date(timeIntervalSince1970: 1_700_000_001)
            ),
            data
        )
    }

    private var officialManifest: RemoteTransferManifest {
        RemoteTransferManifest(
            transferID: transferID,
            kind: .attachment,
            machineID: CryptoVectorSupport.machineID,
            sessionID: "session-vecteur-1",
            filename: "vecteur.txt",
            mimeType: "text/plain",
            expiresAt: "2099-01-01T00:00:00.000Z",
            version: 1,
            keyVersion: 1,
            clearSize: 29,
            chunkSize: 1_048_576,
            chunkCount: 1,
            sha256: "pwvr3VJGY1JpkfnLIKd457+WL2O3AYmIjBE6SoeS+C0=",
            chunkHashes: ["rHxtgSIiH2f8APipfbDQAR9pyFeOR5IHbWGEx6yu6oo="]
        )
    }

    private var officialManifestJSON: String {
        #"{"transferId":"transfert-vecteur-1","kind":"attachment","machineId":"11111111-2222-3333-4444-555555555555","sessionId":"session-vecteur-1","filename":"vecteur.txt","mime":"text/plain","expiresAt":"2099-01-01T00:00:00.000Z","v":1,"keyVersion":1,"clearSize":29,"chunkSize":1048576,"chunkCount":1,"sha256":"pwvr3VJGY1JpkfnLIKd457+WL2O3AYmIjBE6SoeS+C0=","chunkHashes":["rHxtgSIiH2f8APipfbDQAR9pyFeOR5IHbWGEx6yu6oo="]}"#
    }

    private var officialEncryptedManifest: String {
        "e1.1.oKGio6SlpqeoqaqrnToIXySlcdkHF863JUDiqgLNN2P00jAYsXhD5QvOAHP/R2XTjUk6Uzu+PupoDveYJHMrLQykOFJjM2o9zBnr1f3Yp1USlNXRxdPOKb7j/oj/OYaX9vKqV9pBCq6cr3ihurEenjabuq6r+Spy9u2eW00/D+e6F6EeXKqt1906nGCzdNMLtjfyOgZ70ql0I/2z5rjADpzq2PqYrsmQ2rUaX75sPZ2UByl75ygRABu3zpVYVpH5awiMEqDnDkk18HokdUJu80Lji9TKcHD+ZBQD4WLZ3tgPWeiIw/Fo1Qfk9kUecwgQlU+yWrnqJy0xYi8RKYfzE6sxHOIK3/4DH1YKqCUG5aWMpNeODfA+/wIZVuIIJTJljIzvCJsPY7SJ8+tY9TxkmBEuX76NDHwZxY28fKhgqCc4MInkK5En3f7r20+clXfky0IeQN/qJDrWXbnuEYHDJ8UhUqNzXKT3ShbmLilmzDueUFswn7IhpiiBYYa1mGkCzFRK8sI8DEC0l7WLbprgaMwy70UdF/ZdYuXKnFiiZK6oTrMURdOElRFpRn0zkbYLBwbPuVup/AB5"
    }
}
