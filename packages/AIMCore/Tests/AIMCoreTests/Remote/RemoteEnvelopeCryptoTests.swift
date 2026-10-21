import Foundation
import XCTest
@testable import AIMCore

final class RemoteEnvelopeCryptoTests: XCTestCase {
    func testOfficialEnvelopeVectorWrapsAndOpensMirrorKeyByteForByte() throws {
        let deviceKey = try RemoteDevicePrivateKey(rawRepresentation: CryptoVectorSupport.devicePrivateKey)
        XCTAssertEqual(deviceKey.publicKeyBase64, CryptoVectorSupport.devicePublicKey)

        let envelope = try RemoteCrypto.wrapMirrorKey(
            CryptoVectorSupport.mirrorKey,
            devicePublicKeyBase64: CryptoVectorSupport.devicePublicKey,
            machineID: CryptoVectorSupport.machineID,
            deviceID: CryptoVectorSupport.deviceID,
            version: 1,
            ephemeralPrivateKey: CryptoVectorSupport.ephemeralPrivateKey,
            nonce: CryptoVectorSupport.nonce
        )

        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.keyVersion, 1)
        XCTAssertEqual(envelope.ephemeralPublicKey, "BIaZAzt4X4rQYBlpAFxjm5kskew24ZexvkSTkNwRNmxO3ABXEcZ2ElJOiaKCGPYICbBHWHeDunjlnL89Jjnh5Ug=")
        XCTAssertEqual(envelope.nonce, "oKGio6Slpqeoqaqr")
        XCTAssertEqual(envelope.ciphertext, "C+aWV8JFpLiipcwcJmOjVJv/4WFgoU6BEinp6STdyfsY2LKO86g0vnScodetdjkf")

        XCTAssertEqual(
            try RemoteCrypto.openEnvelope(
                envelope,
                devicePrivateKey: deviceKey,
                machineID: CryptoVectorSupport.machineID,
                deviceID: CryptoVectorSupport.deviceID
            ),
            CryptoVectorSupport.mirrorKey
        )
    }

    func testEnvelopeCannotBeMovedToAnotherDevice() throws {
        let deviceKey = try RemoteDevicePrivateKey(rawRepresentation: CryptoVectorSupport.devicePrivateKey)
        let envelope = RemoteKeyEnvelope(
            version: 1,
            keyVersion: 1,
            ephemeralPublicKey: "BIaZAzt4X4rQYBlpAFxjm5kskew24ZexvkSTkNwRNmxO3ABXEcZ2ElJOiaKCGPYICbBHWHeDunjlnL89Jjnh5Ug=",
            nonce: "oKGio6Slpqeoqaqr",
            ciphertext: "C+aWV8JFpLiipcwcJmOjVJv/4WFgoU6BEinp6STdyfsY2LKO86g0vnScodetdjkf"
        )

        XCTAssertThrowsError(
            try RemoteCrypto.openEnvelope(
                envelope,
                devicePrivateKey: deviceKey,
                machineID: CryptoVectorSupport.machineID,
                deviceID: "another-device"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteCryptoError, .authenticationFailed)
        }
    }
}
