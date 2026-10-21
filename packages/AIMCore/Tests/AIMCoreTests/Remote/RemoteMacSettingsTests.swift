import Foundation
import XCTest
@testable import AIMCore

final class RemoteMacSettingsTests: XCTestCase {
    func testAvailabilitySeparatesPresenceAuthorizationAndCapabilityEvidence() {
        let now = Date()
        func machine(lastSeen: Date? = nil, capabilities: RemoteCapabilities? = nil) -> RemoteMachine {
            .init(id: "mac", name: "Mac", platform: "darwin", appVersion: "2", lastSeenAt: lastSeen ?? now, keyVersion: nil, capabilities: capabilities)
        }
        XCTAssertEqual(RemoteMacSettingsAvailability.resolve(connection: .unpaired, machine: nil, authorized: true, at: now), .pairingRequired)
        XCTAssertEqual(RemoteMacSettingsAvailability.resolve(connection: .paired, machine: nil, authorized: true, at: now), .selectComputer)
        XCTAssertEqual(RemoteMacSettingsAvailability.resolve(connection: .paired, machine: machine(lastSeen: now.addingTimeInterval(-90)), authorized: true, at: now), .offline)
        XCTAssertEqual(RemoteMacSettingsAvailability.resolve(connection: .paired, machine: machine(), authorized: false, at: now), .authorizationRequired)
        XCTAssertEqual(RemoteMacSettingsAvailability.resolve(connection: .paired, machine: machine(), authorized: true, at: now), .synchronizing)
        XCTAssertEqual(RemoteMacSettingsAvailability.resolve(connection: .paired, machine: machine(capabilities: .init()), authorized: true, at: now), .ready)
        XCTAssertEqual(RemoteMacSettingsAvailability.resolve(connection: .paired, machine: machine(capabilities: .init(features: [RemoteCapabilities.Feature.macSettings: false])), authorized: true, at: now), .updateRequired)
    }
    func testBridgeAndVersionFailuresAreDistinctAndResponseIsStrict() throws {
        XCTAssertEqual(RemoteMacSettingsError.classify(RemoteServiceError.commandFailure(.init(code: .bridgeUnresponsive, stage: .acknowledged, diagnosticReference: "TEST"))), .bridgeUnresponsive)
        XCTAssertEqual(RemoteMacSettingsError.classify(RemoteServiceError.commandRejected("unsupported_command")), .updateRequired)
        XCTAssertEqual(RemoteMacSettingsError.classify(RemoteServiceError.commandRejected("unlock_required")), .authorizationRequired)
        let value = RemoteMacSettings(appearance: .system, notifyRemote: true, notifyApprovals: true, notifyQuestions: false)
        XCTAssertEqual(try RemoteMacSettings(json: value.json), value)
        XCTAssertThrowsError(try RemoteMacSettings(json: .object(["appearance": .string("light")])))
    }
}
