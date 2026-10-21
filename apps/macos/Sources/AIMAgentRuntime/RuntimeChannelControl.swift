import Foundation

package struct RuntimeChannelControl: Codable, Sendable {
    package enum Action: String, Codable, Sendable { case preview, apply, statuses, reconcile, reconcilePlugin, restart }
    package var action: Action
    package var configuration: Data?
    package var receiptID: String?
    package var confirmedMessageID: Int64?
    package var authorizeResend: Bool?
    package var grantID: UUID?
    package var confirmedRemoteReceiptID: String?
    package init(action: Action, configuration: Data? = nil, receiptID: String? = nil,
                 confirmedMessageID: Int64? = nil, authorizeResend: Bool? = nil, grantID: UUID? = nil, confirmedRemoteReceiptID: String? = nil) {
        self.action = action; self.configuration = configuration; self.receiptID = receiptID
        self.confirmedMessageID = confirmedMessageID; self.authorizeResend = authorizeResend; self.grantID = grantID; self.confirmedRemoteReceiptID = confirmedRemoteReceiptID
    }
}
extension RuntimeChannelRouter {
    package func handleControl(_ data: Data) async throws -> Data {
        guard data.count <= 400_000 else { throw RuntimeChannelError.invalidConfiguration }
        let command = try JSONDecoder().decode(RuntimeChannelControl.self, from: data)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch command.action {
        case .preview:
            guard let config = command.configuration else { throw RuntimeChannelError.invalidConfiguration }
            return try await encoder.encode(previewConfiguration(config))
        case .apply:
            guard let config = command.configuration else { throw RuntimeChannelError.invalidConfiguration }
            try await importConfiguration(config)
        case .statuses: return try await encoder.encode(deliveryStatuses())
        case .reconcile:
            guard let receipt = command.receiptID else { throw RuntimeChannelError.invalidConfiguration }
            try await reconcileTelegram(receiptID: receipt, confirmedMessageID: command.confirmedMessageID, authorizeResend: command.authorizeResend == true)
        case .reconcilePlugin:
            guard let receipt = command.receiptID else { throw RuntimeChannelError.invalidConfiguration }
            try await reconcilePlugin(receiptID: receipt, confirmedRemoteReceiptID: command.confirmedRemoteReceiptID, authorizeResend: command.authorizeResend == true)
        case .restart:
            guard let grant = command.grantID else { throw RuntimeChannelError.invalidConfiguration }
            try await restartChannel(grantID: grant)
        }
        return Data("{}".utf8)
    }
}
