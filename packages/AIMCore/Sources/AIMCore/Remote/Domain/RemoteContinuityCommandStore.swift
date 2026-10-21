import CryptoKit
import Foundation

public struct RemoteContinuityCommandReceipt: Codable, Equatable, Sendable {
    public let commandID: String
    public let createdAt: Date
    public var submitted: Bool
    public var acknowledged: Bool
    public var result: RemoteJSONValue?
    public var terminalError: String?
    public var wirePayload: RemoteJSONValue?
    public var publicationComplete: Bool?
    public init(commandID: String = UUID().uuidString.lowercased(), createdAt: Date = .now) {
        self.commandID = commandID; self.createdAt = createdAt; submitted = false; acknowledged = false
    }
}
public enum RemoteContinuityCommandRules {
    public static func shouldBeginNewGesture(_ receipt: RemoteContinuityCommandReceipt,
                                            continuousCreation: Bool) -> Bool {
        if receipt.terminalError == "execution_outcome_unknown" { return false }
        if receipt.terminalError != nil { return true }
        guard receipt.result != nil else { return false }
        return !continuousCreation || receipt.publicationComplete == true
    }
}
/// Account/device scoped Keychain journal; timeouts never allocate a second admission.
public struct RemoteContinuityCommandStore: Sendable {
    private let secureStore: any SecureStoring
    public init(secureStore: any SecureStoring) { self.secureStore = secureStore }
    public static func key(accountID: UUID, deviceID: String, commandKey: String) -> String {
        let bytes = Data((accountID.uuidString + "/" + deviceID + "/" + commandKey).utf8)
        return "continuity.command." + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public func load(key: String) throws -> RemoteContinuityCommandReceipt? {
        try secureStore.readData(forKey: key).map { try JSONDecoder().decode(RemoteContinuityCommandReceipt.self, from: $0) }
    }
    public func save(_ receipt: RemoteContinuityCommandReceipt, key: String) throws {
        try secureStore.store(JSONEncoder().encode(receipt), forKey: key + ".receipt." + receipt.commandID)
        try secureStore.store(JSONEncoder().encode(receipt), forKey: key)
    }
    public func receipt(commandID: String, key: String) throws -> RemoteContinuityCommandReceipt? {
        try secureStore.readData(forKey: key + ".receipt." + commandID).map { try JSONDecoder().decode(RemoteContinuityCommandReceipt.self, from: $0) }
    }
}
