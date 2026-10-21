import Foundation
import XCTest
@testable import AIMCore

final class RemoteProtectionPolicyTests: XCTestCase {
    func testPresetsAndStrictRelayContract() throws {
        for preset in [RemoteProtectionPreset.none, .codeAgent, .all] {
            let policy = RemoteProtectionPolicy(revision: 0, protectedModes: preset.modes)
            XCTAssertEqual(policy.preset, preset)
            XCTAssertEqual(try JSONDecoder().decode(RemoteProtectionPolicy.self, from: JSONEncoder().encode(policy)), policy)
        }
        XCTAssertEqual(RemoteProtectionPolicy(revision: 7, protectedModes: [.chat, .chat]).preset, .custom)
        for body in [
            #"{"version":2,"revision":1,"protected_modes":[],"unlock_authorized":false}"#,
            #"{"version":1,"revision":-1,"protected_modes":[],"unlock_authorized":false}"#,
            #"{"version":1,"revision":1,"protected_modes":["chat","chat"],"unlock_authorized":false}"#,
            #"{"version":1,"revision":1,"protected_modes":["unknown"],"unlock_authorized":false}"#,
            #"{"version":1,"revision":1,"protected_modes":[]}"#
        ] { XCTAssertThrowsError(try JSONDecoder().decode(RemoteProtectionPolicy.self, from: Data(body.utf8))) }
    }
}
