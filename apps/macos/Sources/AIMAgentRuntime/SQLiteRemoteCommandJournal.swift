import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

package actor SQLiteRemoteCommandJournal: RemoteHostCommandJournal {
    private let store: RemoteReceiptStore
    package init(database: AIMDatabase, owner: UUID) { store = RemoteReceiptStore(database: database, owner: owner) }
    package func prepare(_ command: RemoteHostCommand, accountID: String) throws -> RemoteHostCommandReceipt {
        if let data = try store.load(id: command.id, accountID: accountID, machineID: command.machine_id) {
            let saved = try JSONDecoder().decode(RemoteHostCommandReceipt.self, from: data)
            guard saved.command == command else { throw ExecutionStoreError.commandConflict }
            return saved
        }
        let receipt = RemoteHostCommandReceipt(command: command, accountID: accountID)
        try write(receipt, previous: nil); return receipt
    }
    package func markEffectStarted(_ id: String, accountID: String, machineID: String) throws -> RemoteHostCommandReceipt {
        try mutate(id, accountID: accountID, machineID: machineID) { receipt in
            guard !receipt.completed else { throw ExecutionStoreError.invalidTransition }
            receipt.effectStarted = true
        }
    }
    package func complete(_ id: String, accountID: String, machineID: String,
                          result: RemoteJSONValue?, error: String?) throws -> RemoteHostCommandReceipt {
        try mutate(id, accountID: accountID, machineID: machineID) { receipt in
            guard !receipt.completed else {
                guard receipt.result == result, receipt.error == error else { throw ExecutionStoreError.commandConflict }; return
            }
            receipt.completed = true; receipt.result = result; receipt.error = error
        }
    }
    package func acknowledge(_ id: String, accountID: String, machineID: String) throws -> RemoteHostCommandReceipt {
        try mutate(id, accountID: accountID, machineID: machineID) { receipt in
            guard receipt.completed else { throw ExecutionStoreError.invalidTransition }; receipt.acknowledged = true
        }
    }
    package func delivered(_ id: String, accountID: String, machineID: String) throws {
        _ = try mutate(id, accountID: accountID, machineID: machineID) { receipt in
            guard receipt.acknowledged else { throw ExecutionStoreError.invalidTransition }; receipt.delivered = true
        }
    }
    package func pending(accountID: String, machineID: String) throws -> [RemoteHostCommandReceipt] {
        try store.pending(accountID: accountID, machineID: machineID).map { try JSONDecoder().decode(RemoteHostCommandReceipt.self, from: $0) }
    }
    private func mutate(_ id: String, accountID: String, machineID: String,
                        _ body: (inout RemoteHostCommandReceipt) throws -> Void) throws -> RemoteHostCommandReceipt {
        guard let bytes = try store.load(id: id, accountID: accountID, machineID: machineID) else { throw ExecutionStoreError.notFound }
        var receipt = try JSONDecoder().decode(RemoteHostCommandReceipt.self, from: bytes)
        try body(&receipt); try write(receipt, previous: bytes); return receipt
    }
    private func write(_ receipt: RemoteHostCommandReceipt, previous: Data?) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try store.save(id: receipt.command.id, accountID: receipt.accountID, machineID: receipt.command.machine_id,
                       payload: encoder.encode(receipt), replacing: previous, delivered: receipt.delivered)
    }
}
