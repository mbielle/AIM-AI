import Foundation
import LocalAuthentication
import Security

public enum BiometricSecretStoreError: Error, Equatable, Sendable {
    case unavailable
    case cancelled
    case invalidated
    case unexpectedStatus(OSStatus)
    case unreadable
}

public struct KeychainBiometricSecretStore: BiometricSecretStoring, Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.aimai.ios.remote-security",
        account: String = "fallback-pin"
    ) {
        self.service = service
        self.account = account
    }

    public func storeBiometricPIN(_ pin: String) throws {
        guard RemoteLockRules.isValidPIN(pin), let data = pin.data(using: .utf8) else {
            throw BiometricSecretStoreError.unreadable
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.biometryCurrentSet],
            &error
        ) else {
            throw BiometricSecretStoreError.unavailable
        }

        try? removeBiometricPIN()
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricSecretStoreError.unexpectedStatus(status)
        }
    }

    public func biometricPIN(reason: String) async throws -> String {
        let service = service
        let account = account
        return try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedCancelTitle = String(localized: "common.cancel")
            context.localizedReason = reason
            var result: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
            ] as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let pin = String(data: data, encoding: .utf8) else {
                    throw BiometricSecretStoreError.unreadable
                }
                return pin
            case errSecUserCanceled, errSecAuthFailed:
                throw BiometricSecretStoreError.cancelled
            case errSecItemNotFound, errSecInteractionNotAllowed:
                throw BiometricSecretStoreError.invalidated
            default:
                throw BiometricSecretStoreError.unexpectedStatus(status)
            }
        }.value
    }

    public func removeBiometricPIN() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BiometricSecretStoreError.unexpectedStatus(status)
        }
    }
}
