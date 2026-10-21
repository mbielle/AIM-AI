import Foundation
import XCTest
@testable import AIMCore

final class RemoteFieldCryptoTests: XCTestCase {
    private let context = RemoteFieldContext(
        table: "remote_messages",
        column: "content",
        rowID: "message-vecteur-1"
    )

    func testOfficialFieldVectorEncryptsAndDecryptsByteForByte() throws {
        let encrypted = try RemoteCrypto.encryptField(
            "Bonjour — télécommande ✓",
            key: CryptoVectorSupport.mirrorKey,
            version: 1,
            context: context,
            nonce: CryptoVectorSupport.nonce
        )

        XCTAssertEqual(
            encrypted,
            "e1.1.oKGio6SlpqeoqaqrpHcSRyq+cJ+A5RPzc7lpsrMFOn//2iMC+GsGZOM4lCuosXpcH7RvsQdfwjfhIA=="
        )
        XCTAssertEqual(
            try RemoteCrypto.decryptField(
                encrypted,
                keys: [1: CryptoVectorSupport.mirrorKey],
                context: context
            ),
            "Bonjour — télécommande ✓"
        )
    }

    func testEncryptedValueIsBoundToItsTableColumnAndRow() throws {
        let encrypted = try RemoteCrypto.encryptField(
            "secret",
            key: CryptoVectorSupport.mirrorKey,
            version: 1,
            context: context,
            nonce: CryptoVectorSupport.nonce
        )

        XCTAssertThrowsError(
            try RemoteCrypto.decryptField(
                encrypted,
                keys: [1: CryptoVectorSupport.mirrorKey],
                context: RemoteFieldContext(table: "remote_messages", column: "reasoning", rowID: context.rowID)
            )
        ) { error in
            XCTAssertEqual(error as? RemoteCryptoError, .authenticationFailed)
        }
    }

    func testCommandContextIncludesAllRoutingFields() {
        let command = RemoteCommandIdentity(
            id: "command-1",
            type: "user_message",
            sessionID: "session-1",
            machineID: "machine-1"
        )

        XCTAssertEqual(
            command.context(for: .payload).associatedDataString,
            "aim-remote/v1|remote_commands.payload|command-1|user_message|session-1|machine-1"
        )
    }

    func testMalformedValuesAndUnknownVersionsAreRejected() {
        XCTAssertFalse(RemoteCrypto.isEncrypted("not-encrypted"))
        XCTAssertNil(RemoteCrypto.keyVersion(of: "e1.bad.value"))
        XCTAssertThrowsError(
            try RemoteCrypto.decryptField("e1.8.AA==", keys: [:], context: context)
        ) { error in
            XCTAssertEqual(error as? RemoteCryptoError, .unknownKeyVersion(8))
        }
    }
}
