import Foundation
import XCTest
@testable import AIMCore

final class AccountTaskTimelineTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)
    func testParentWaitIsNotIdleWhileChildWorksAndTaskEndsAfterChild() {
        let root = UUID(), child = UUID()
        let timeline = AccountTaskTimeline(rootID: root, startedAt: start, nodeIDs: [root,child], transitions: [
            .init(nodeID: child, at: start.addingTimeInterval(5), state: .running),
            .init(nodeID: root, at: start.addingTimeInterval(10), state: .waiting),
            .init(nodeID: child, at: start.addingTimeInterval(20), state: .waiting),
            .init(nodeID: child, at: start.addingTimeInterval(40), state: .running),
            .init(nodeID: root, at: start.addingTimeInterval(50), state: .finished),
            .init(nodeID: child, at: start.addingTimeInterval(60), state: .finished),
            .init(nodeID: root, at: start.addingTimeInterval(90), state: .finished)
        ], now: start.addingTimeInterval(100))
        XCTAssertEqual(timeline.completedAt, start.addingTimeInterval(60))
        XCTAssertEqual(timeline.waitingSeconds, 20)
    }
    func testMissingDescendantCompletionCannotBecomeMeasuredTask() {
        let root = UUID(), child = UUID()
        let timeline = AccountTaskTimeline(rootID: root, startedAt: start, nodeIDs: [root,child], transitions: [
            .init(nodeID: root, at: start.addingTimeInterval(20), state: .finished)
        ], now: start.addingTimeInterval(50))
        XCTAssertNil(timeline.completedAt)
    }
    func testSimultaneousChildWaitsAreNotAddedTwice() {
        let root = UUID(), a = UUID(), b = UUID()
        let events: [AccountTaskTransition] = [
            .init(nodeID: a, at: start, state: .running), .init(nodeID: b, at: start, state: .running),
            .init(nodeID: root, at: start.addingTimeInterval(10), state: .waiting),
            .init(nodeID: a, at: start.addingTimeInterval(10), state: .waiting),
            .init(nodeID: b, at: start.addingTimeInterval(10), state: .waiting),
            .init(nodeID: a, at: start.addingTimeInterval(20), state: .finished),
            .init(nodeID: b, at: start.addingTimeInterval(30), state: .finished),
            .init(nodeID: root, at: start.addingTimeInterval(30), state: .finished)]
        let timeline = AccountTaskTimeline(rootID: root, startedAt: start, nodeIDs: [root,a,b], transitions: events, now: start.addingTimeInterval(30))
        XCTAssertEqual(timeline.waitingSeconds, 20)
    }
}
