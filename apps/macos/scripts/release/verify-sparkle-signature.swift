import CryptoKit
import Darwin
import Foundation

func reject(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

// Public-key verification only: no Keychain, Apple service or private key.
let args = CommandLine.arguments
guard args.count == 5, let key = Data(base64Encoded: args[2]),
      let signature = Data(base64Encoded: args[3]), let length = Int(args[4]), length >= 0 else {
    reject("Usage: verifier file public-key signature signed-byte-length")
}
let bytes = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
guard length <= bytes.count else { reject("Signed length exceeds file") }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
guard publicKey.isValidSignature(signature, for: bytes.prefix(length)) else {
    reject("Invalid Sparkle Ed25519 signature")
}
print("Ed25519 signature valid")
