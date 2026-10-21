import Foundation
import Security

public enum KeychainStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case unexpectedValue
}

protocol KeychainAccessing: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

public struct KeychainSecureStore: SecureStoring, Sendable {
    public static let defaultService = "com.aimai.ios.auth"

    private let service: String
    private let keychain: any KeychainAccessing

    public init(service: String = Self.defaultService) {
        self.init(service: service, keychain: SystemKeychain())
    }

    init(service: String, keychain: any KeychainAccessing) {
        self.service = service
        self.keychain = keychain
    }

    public func store(_ data: Data, forKey key: String) throws {
        try keychain.write(data, service: service, account: key)
    }

    public func readData(forKey key: String) throws -> Data? {
        try keychain.read(service: service, account: key)
    }

    public func removeData(forKey key: String) throws {
        try keychain.remove(service: service, account: key)
    }
}

private struct SystemKeychain: KeychainAccessing {
    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainStoreError.unexpectedValue
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func remove(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
