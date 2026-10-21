import AIMCore
import Foundation

public struct RemoteHostCommandReceipt: Codable, Equatable, Sendable {
    public var command: RemoteHostCommand
    public var accountID: String
    public var completed: Bool
    public var acknowledged: Bool
    public var result: RemoteJSONValue?
    public var error: String?
    public var delivered: Bool
    public var effectStarted: Bool?
    public init(command: RemoteHostCommand, accountID: String) {
        self.command = command; self.accountID = accountID
        completed = false; acknowledged = false; delivered = false
    }
}

public protocol RemoteHostCommandJournal: Sendable {
    func prepare(_ command: RemoteHostCommand, accountID: String) async throws -> RemoteHostCommandReceipt
    func markEffectStarted(_ id: String, accountID: String, machineID: String) async throws -> RemoteHostCommandReceipt
    func complete(_ id: String, accountID: String, machineID: String, result: RemoteJSONValue?, error: String?) async throws -> RemoteHostCommandReceipt
    func acknowledge(_ id: String, accountID: String, machineID: String) async throws -> RemoteHostCommandReceipt
    func delivered(_ id: String, accountID: String, machineID: String) async throws
    func pending(accountID: String, machineID: String) async throws -> [RemoteHostCommandReceipt]
}

public extension RemoteHostCommandJournal {
    func markEffectStarted(_ id: String, accountID: String, machineID: String) async throws -> RemoteHostCommandReceipt {
        throw RemoteHostCommandFailure("journal_effets_indisponible")
    }
}
