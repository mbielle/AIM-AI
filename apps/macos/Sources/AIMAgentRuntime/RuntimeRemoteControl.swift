import AIMCore
import AIMMacPlatform
import Foundation

/// Local signed app/helper control only. No machine secrets or PIN enter this wire.
package struct RuntimeRemoteControl: Codable, Sendable {
    package enum Action: String, Codable, Sendable { case status, setEnabled, pairingCode, devices, revoke, diagnostics }
    package let version: Int
    package let action: Action
    package let enabled: Bool?
    package let deviceID: String?
    package init(action: Action, enabled: Bool? = nil, deviceID: String? = nil) {
        version = 1; self.action = action; self.enabled = enabled; self.deviceID = deviceID
    }
    package func validate() throws {
        guard version == 1 else { throw RuntimeRemoteControlError.invalidRequest }
        switch action {
        case .setEnabled: guard enabled != nil, deviceID == nil else { throw RuntimeRemoteControlError.invalidRequest }
        case .revoke:
            guard enabled == nil, let deviceID, !deviceID.isEmpty, deviceID.utf8.count <= 128 else { throw RuntimeRemoteControlError.invalidRequest }
        default: guard enabled == nil, deviceID == nil else { throw RuntimeRemoteControlError.invalidRequest }
        }
    }
}
package enum RuntimeRemoteControlError: Error { case invalidRequest, unauthorized, unavailable }
package struct RuntimeRemoteState: Codable, Sendable {
    package let version: Int
    package let accountID: UUID?
    package let enabled: Bool
    package let hostAvailable: Bool
    package let status: RemoteHost.Status
    package var devices: [RemoteHostDevice]
    package var pairingCode: RemotePairingCode?
    package var diagnosticReport: RemoteDiagnosticReport?
    package init(accountID: UUID?, enabled: Bool, hostAvailable: Bool, status: RemoteHost.Status,
                 devices: [RemoteHostDevice] = [], pairingCode: RemotePairingCode? = nil, diagnosticReport: RemoteDiagnosticReport? = nil) {
        version = 1; self.accountID = accountID; self.enabled = enabled; self.hostAvailable = hostAvailable
        self.status = status; self.devices = devices; self.pairingCode = pairingCode; self.diagnosticReport = diagnosticReport
    }
}
