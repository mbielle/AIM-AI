import XCTest
@testable import AIMCore

final class SecureNonceGeneratorTests: XCTestCase {
    func testNonceHasRequestedLengthAndAllowedCharacters() throws {
        let nonce = try SecureNonceGenerator().generate(length: 48)

        XCTAssertEqual(nonce.count, 48)
        XCTAssertTrue(nonce.allSatisfy(SecureNonceGenerator.allowedCharacters.contains))
    }

    func testConsecutiveNoncesDiffer() throws {
        let generator = SecureNonceGenerator()

        XCTAssertNotEqual(try generator.generate(), try generator.generate())
    }

    func testSHA256KnownVector() {
        XCTAssertEqual(
            SecureNonceGenerator.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testRejectsInvalidLength() {
        XCTAssertThrowsError(try SecureNonceGenerator().generate(length: 0)) { error in
            XCTAssertEqual(error as? SecureNonceError, .invalidLength)
        }
    }
}
