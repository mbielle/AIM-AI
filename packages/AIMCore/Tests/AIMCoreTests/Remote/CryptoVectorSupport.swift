import Foundation

enum CryptoVectorSupport {
    static let mirrorKey = data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    static let nonce = data(hex: "a0a1a2a3a4a5a6a7a8a9aaab")
    static let machineID = "11111111-2222-3333-4444-555555555555"
    static let deviceID = "66666666-7777-8888-9999-000000000000"
    static let devicePrivateKey = data(base64URL: "QLa1kbW5xwryMfYFaMc5snixcxbi7A6qd-lnOXE3lVM")
    static let ephemeralPrivateKey = data(base64URL: "bxC-1ifO0wAtXh5fc3yOsbiYnRjnGmsGRs5LlZPX6ug")
    static let devicePublicKey = "BPnX2zgsn+egG+DFoF1eqRsdW7hgz3TzBg7fXE8lj/IUGNXTeUFSljUkhAOi8MLMNfUisH1v1eQ9TGmycCjuH/I="

    static func data(hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        })
    }

    static func data(base64URL: String) -> Data {
        var value = base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)!
    }
}
