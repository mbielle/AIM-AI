@testable import AIMMacPlatform
import AIMAgentKit
import AIMApplication
import Foundation
import XCTest

final class AgentCuaToolServiceTests: XCTestCase {
    override func setUp() { ScreenLockState.overrideForTesting = false }
    override func tearDown() { ScreenLockState.overrideForTesting = nil }

    private func state() throws -> CuaWindowState {
        try CuaWindowStateParser.parse(CuaRecordedShapes.matchedState, pid: 77, windowID: 812, maximumElements: 300)
    }

    func testOnlyQualifiedCapabilitiesBecomeTools() {
        XCTAssertTrue(AgentCuaToolService.tools(for: [], modelSeesImages: true).isEmpty)
        XCTAssertTrue(AgentCuaToolService.tools(for: [.axClick], modelSeesImages: true).isEmpty,
            "Nothing is offered without a qualified observation")
        XCTAssertEqual(AgentCuaToolService.tools(for: [.observe, .axClick], modelSeesImages: false),
            ["bg_list_windows", "bg_observe_window", "bg_click", "bg_click_sequence"])
        XCTAssertEqual(AgentCuaToolService.tools(for: [.observe, .typeText, .scroll], modelSeesImages: false),
            ["bg_list_windows", "bg_observe_window", "bg_type_text", "bg_scroll"])
        XCTAssertFalse(AgentCuaToolService.tools(for: [.observe, .pixelClick], modelSeesImages: false).contains("bg_click"),
            "Pixel clicks need a route that sees the screenshot")
        XCTAssertTrue(AgentCuaToolService.tools(for: [.observe, .pixelClick], modelSeesImages: true).contains("bg_click"))
    }

    func testAfterAnActionOnlyChangesAreReported() throws {
        let before = try state()
        var changed = CuaRecordedShapes.matchedState
        var structured = changed["structuredContent"] as! [String: Any]
        structured["tree_markdown"] = "- [0] AXWindow \"AIM Agent Fixture\"\n  - AXStaticText = \"Count: 1\""
        var elements = structured["elements"] as! [[String: Any]]
        elements[1]["value"] = "Fixture text AIM"
        structured["elements"] = elements
        changed["structuredContent"] = structured
        let after = try CuaWindowStateParser.parse(changed, pid: 77, windowID: 812, maximumElements: 300)
        let summary = AgentCuaToolService.changeSummary(from: before, to: after, observationID: "obs-2")
        XCTAssertTrue(summary.contains("observation_id obs-2"))
        XCTAssertTrue(summary.contains("Count: 1"), summary)
        XCTAssertTrue(summary.contains("“Fixture text AIM”"), summary)
        XCTAssertFalse(summary.contains("Increment"), "unchanged elements are not repeated")
        let same = AgentCuaToolService.changeSummary(from: before, to: before, observationID: "obs-3")
        XCTAssertTrue(same.contains("No visible change detected"))
    }

    func testClickSequencesNeedUniqueLabelledElements() throws {
        let state = try state()
        let ok = ToolRequest(name: "bg_click_sequence", arguments: ["observation_id": "o", "element_indices": "[4, 4]"], risk: .computerAction)
        XCTAssertEqual(try AgentCuaToolService.sequenceIndices(ok, state: state), [4, 4])
        for form in ["[\"4\", \"4\"]", "4, 4"] {
            let request = ToolRequest(name: "bg_click_sequence", arguments: ["observation_id": "o", "element_indices": form], risk: .computerAction)
            XCTAssertEqual(try AgentCuaToolService.sequenceIndices(request, state: state), [4, 4], form)
        }
        for bad in ["[]", "[99]", "not json", "[\(Array(repeating: "4", count: 21).joined(separator: ","))]"] {
            let request = ToolRequest(name: "bg_click_sequence", arguments: ["observation_id": "o", "element_indices": bad], risk: .computerAction)
            XCTAssertThrowsError(try AgentCuaToolService.sequenceIndices(request, state: state), bad)
        }
    }

    func testArgumentMappingBindsElementsOfTheCurrentObservation() throws {
        let state = try state()
        func request(_ name: String, _ arguments: [String: String]) -> ToolRequest {
            ToolRequest(name: name, arguments: arguments, risk: .computerAction)
        }
        XCTAssertEqual(try AgentCuaToolService.action(for: request("bg_click", ["element_index": "4"]),
            state: state, pixelAllowed: false), .click(elementIndex: 4))
        XCTAssertThrowsError(try AgentCuaToolService.action(for: request("bg_click", ["element_index": "9"]),
            state: state, pixelAllowed: false), "Unknown elements are refused")
        XCTAssertThrowsError(try AgentCuaToolService.action(for: request("bg_click", ["x": "10", "y": "12"]),
            state: state, pixelAllowed: false), "Pixel clicks require qualification and an image route")
        XCTAssertEqual(try AgentCuaToolService.action(for: request("bg_click", ["x": "10", "y": "12"]),
            state: state, pixelAllowed: true), .clickPixel(x: 10, y: 12))
        XCTAssertEqual(try AgentCuaToolService.action(for: request("bg_type_text", ["element_index": "2", "text": "é"]),
            state: state, pixelAllowed: false), .typeText(elementIndex: 2, text: "é"))
        XCTAssertThrowsError(try AgentCuaToolService.action(for: request("bg_scroll", ["element_index": "2", "direction": "sideways"]),
            state: state, pixelAllowed: false))
        XCTAssertThrowsError(try AgentCuaToolService.action(for: request("bg_press_key", ["element_index": "2", "key": "cmd+q"]),
            state: state, pixelAllowed: false), "Modifier chords are not a qualified capability")
        XCTAssertEqual(AgentCuaToolService.capability(for: .scrollPixel(x: 1, y: 1, direction: "down", amount: 3)), .scroll)
    }

    func testActionsWithoutAnObservationAreRefusedBeforeAnyDriverStart() async {
        let service = AgentCuaToolService(qualified: [.observe: "digest", .axClick: "digest"], modelSeesImages: false,
            leases: CuaTargetLeaseCoordinator())
        let result = await service.execute(ToolRequest(name: "bg_click",
            arguments: ["observation_id": "made-up", "element_index": "4"], risk: .computerAction))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.actionOutcome, .suspectedAbsent, "Nothing was sent")
        let intent = try? await service.missionIntent(for: ToolRequest(name: "bg_type_text",
            arguments: ["observation_id": "made-up", "element_index": "2", "text": "x"], risk: .computerAction))
        XCTAssertNil(intent ?? nil, "A forged observation never yields an automatic mission grant")
    }

    func testLeasesAndPersonPriority() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock { now }
        let coordinator = CuaTargetLeaseCoordinator(clock: { clock.read() })
        let first = UUID(), second = UUID()
        try await coordinator.acquire(pid: 77, owner: first)
        do {
            try await coordinator.acquire(pid: 77, owner: second)
            XCTFail("Two runs must not act on one app concurrently")
        } catch CuaTargetLeaseCoordinator.LeaseError.heldByAnotherRun {}
        try await coordinator.acquire(pid: 78, owner: second)
        await coordinator.release(owner: first)
        try await coordinator.acquire(pid: 77, owner: second)

        let observedAt = clock.read()
        now = now.addingTimeInterval(5)
        clock.set(now)
        let before = await coordinator.humanInterventionSince(observedAt, pid: 77)
        XCTAssertFalse(before)
        await coordinator.recordActivation(pid: 77)
        let after = await coordinator.humanInterventionSince(observedAt, pid: 77)
        XCTAssertTrue(after, "Activating the target after observation is human intervention")
        await coordinator.markHumanConflict(pid: 77)
        let conflict = await coordinator.hasHumanConflict(pid: 77)
        XCTAssertTrue(conflict)
        await coordinator.clearHumanConflict(pid: 77)
        let cleared = await coordinator.hasHumanConflict(pid: 77)
        XCTAssertFalse(cleared)

        now = now.addingTimeInterval(60)
        clock.set(now)
        let expired = await coordinator.holder(of: 78)
        XCTAssertNil(expired, "Leases expire when not renewed")
    }

    func testQualificationRecordsAreScopedToTheExactKey() async throws {
        let database = try AIMDatabase(inMemory: true)
        let repository = SQLiteCuaQualificationRepository(database: database)
        let key = CuaQualificationKey(driverVersion: "0.28.2", driverSHA256: "abc", osBuild: "26A428",
            adapterContract: CuaRuntimeIdentity.adapterContract)
        try await repository.record(CuaQualificationRecord(key: key, capability: .observe, schemaDigest: "d1",
            qualifiedAt: .now, evidence: "{}"))
        try await repository.record(CuaQualificationRecord(key: key, capability: .axClick, schemaDigest: "d1",
            qualifiedAt: .now, evidence: "{}"))
        let qualified = try await repository.qualified(for: key)
        XCTAssertEqual(Set(qualified.keys), [.observe, .axClick])
        let otherBuild = CuaQualificationKey(driverVersion: "0.28.2", driverSHA256: "abc", osBuild: "26A429",
            adapterContract: key.adapterContract)
        let none = try await repository.qualified(for: otherBuild)
        XCTAssertTrue(none.isEmpty, "A different macOS build needs its own qualification")
        try await repository.disqualify(.axClick, for: key, reason: "foreground delivery")
        let remaining = try await repository.qualified(for: key)
        XCTAssertEqual(Set(remaining.keys), [.observe])
        try await repository.record(CuaQualificationRecord(key: key, capability: .axClick, schemaDigest: "d1",
            qualifiedAt: .now, evidence: "{}"))
        let requalified = try await repository.qualified(for: key)
        XCTAssertEqual(Set(requalified.keys), [.observe, .axClick])
    }

    func testLockedScreenIsReportedBeforeAnyDriverWork() async {
        ScreenLockState.overrideForTesting = true
        let service = AgentCuaToolService(qualified: [.observe: "s", .axClick: "s"], modelSeesImages: false)
        let result = await service.execute(ToolRequest(name: "bg_list_windows", arguments: [:], risk: .computerRead))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.metadata["screen_locked"], "true")
        XCTAssertEqual(result.actionOutcome, .suspectedAbsent)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ initial: () -> Date) { value = initial() }
    func read() -> Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }

}
