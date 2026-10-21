import AIMCore
import Foundation

/// The helper writes this account-scoped journal only for executions admitted by the current contract.
/// Historical runs and imported conversation snapshots never acquire inferred execution provenance.
public struct RuntimeConversationContinuity: Codable, Sendable, Equatable {
    public var trackedExecutions: [UUID: UUID] = [:]
    public var executionDeviceIDs: [UUID: [String]] = [:]
    public var responseVersions: [UUID: ConversationResponseVersion] = [:]
    public init() {}
    public static func load(accountID: UUID, store: any SecureStoring) throws -> Self {
        guard let data = try store.readData(forKey: key(accountID)) else { return .init() }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func save(accountID: UUID, store: any SecureStoring) throws {
        try store.store(JSONEncoder().encode(self), forKey: Self.key(accountID))
    }
    private static func key(_ accountID: UUID) -> String { "account-runtime-continuity.v1." + accountID.uuidString }
}
