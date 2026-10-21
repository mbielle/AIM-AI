import CryptoKit
import Foundation
import Security

public enum SecureNonceError: Error, Equatable, Sendable {
    case invalidLength
    case randomGenerationFailed(OSStatus)
}

public struct SecureNonceGenerator: Sendable {
    public static let allowedCharacters = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._"
    )

    public init() {}

    public func generate(length: Int = 32) throws -> String {
        guard length > 0 else {
            throw SecureNonceError.invalidLength
        }

        let characters = Self.allowedCharacters
        let upperBound = UInt8.max - UInt8.max % UInt8(characters.count)
        var result = String()
        result.reserveCapacity(length)

        while result.count < length {
            var randomBytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            guard status == errSecSuccess else {
                throw SecureNonceError.randomGenerationFailed(status)
            }

            for byte in randomBytes where byte < upperBound {
                result.append(characters[Int(byte) % characters.count])
                if result.count == length {
                    break
                }
            }
        }

        return result
    }

    public static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
