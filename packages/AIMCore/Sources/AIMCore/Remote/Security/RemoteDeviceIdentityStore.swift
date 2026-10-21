import Foundation

struct RemoteDeviceIdentity: Sendable {
    let deviceID: String
    let secret: String
    let privateKey: RemoteDevicePrivateKey?
}

struct RemotePreparedIdentity: Sendable {
    let deviceID: String
    let secret: String
    let privateKey: RemoteDevicePrivateKey

    var publicKey: String { privateKey.publicKeyBase64 }
}

struct RemoteDeviceIdentityStore: Sendable {
    private enum Key {
        static let deviceID = "device-id"
        static let secret = "device-secret"
        static let privateKey = "device-private-key"
    }

    private let secureStore: any SecureStoring

    init(secureStore: any SecureStoring) {
        self.secureStore = secureStore
    }

    func identity() throws -> RemoteDeviceIdentity {
        let storedDeviceID = try text(for: Key.deviceID)
        let deviceID: String
        if let storedDeviceID, UUID(uuidString: storedDeviceID) != nil {
            deviceID = storedDeviceID
        } else {
            deviceID = try createDeviceID()
        }

        let storedSecret = try text(for: Key.secret)
        let secret = if let storedSecret, storedSecret.count >= 32 {
            storedSecret
        } else {
            try createSecret()
        }

        let privateKey: RemoteDevicePrivateKey?
        if let data = try secureStore.readData(forKey: Key.privateKey) {
            do {
                privateKey = try RemoteDevicePrivateKey(rawRepresentation: data)
            } catch {
                // A key written by an interrupted/older build must lead to a
                // normal repair flow, never make every Remote request fail.
                try secureStore.removeData(forKey: Key.privateKey)
                privateKey = nil
            }
        } else {
            privateKey = nil
        }
        return .init(deviceID: deviceID, secret: secret, privateKey: privateKey)
    }

    func preparePairing() throws -> RemotePreparedIdentity {
        let current = try identity()
        return .init(deviceID: current.deviceID, secret: current.secret, privateKey: RemoteDevicePrivateKey())
    }

    func commit(_ prepared: RemotePreparedIdentity) throws {
        try secureStore.store(prepared.privateKey.rawRepresentation, forKey: Key.privateKey)
    }

    private func createDeviceID() throws -> String {
        let value = UUID().uuidString.lowercased()
        try secureStore.store(Data(value.utf8), forKey: Key.deviceID)
        return value
    }

    private func createSecret() throws -> String {
        var generator = SystemRandomNumberGenerator()
        let value = (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        try secureStore.store(Data(value.utf8), forKey: Key.secret)
        return value
    }

    private func text(for key: String) throws -> String? {
        guard let data = try secureStore.readData(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
