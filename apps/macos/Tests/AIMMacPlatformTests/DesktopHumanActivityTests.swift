@testable import AIMMacPlatform
import XCTest

final class DesktopHumanActivityTests: XCTestCase {
    func testAIMEventsDoNotRevokeASequenceButHumanEventsDo() throws {
        let state = DesktopHumanActivityState()
        let token = DesktopInputCancellationToken()
        let id = state.register(token)

        state.observe(eventTag: DesktopAgentEventMarker.value)
        XCTAssertNoThrow(try token.check())

        state.observe(eventTag: nil)
        XCTAssertThrowsError(try token.check()) { error in
            guard case DesktopInputError.humanIntervention = error else {
                return XCTFail("Expected human intervention, got \(error)")
            }
        }
        state.unregister(id)
        XCTAssertFalse(state.hasActiveSequences)
    }

    func testUnregisteredTokenIsUnaffectedAndStopWins() throws {
        let state = DesktopHumanActivityState()
        let detached = DesktopInputCancellationToken()
        let id = state.register(detached)
        state.unregister(id)
        state.observe(eventTag: nil)
        XCTAssertNoThrow(try detached.check())

        let stopped = DesktopInputCancellationToken()
        _ = state.register(stopped)
        stopped.cancel()
        state.observe(eventTag: nil)
        XCTAssertThrowsError(try stopped.check()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRevocationPreventsPostingAnotherAgentEvent() {
        let token = DesktopInputCancellationToken()
        token.revokeForHumanInput()
        var posted = false
        XCTAssertThrowsError(try token.postIfActive { posted = true })
        XCTAssertFalse(posted)
    }

    func testThePersonUsingTheMacLeadsToAHandOverNotAnAbandonedTask() {
        // Round 37: the agent calls the action again and AIM asks the person to hand over control.
        for error in [DesktopInputError.personActive, .humanIntervention] {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("hand over control"), text)
            XCTAssertTrue(text.contains("Do not abandon the task"), text)
        }
    }
}
