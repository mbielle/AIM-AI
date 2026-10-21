@testable import AIMMacPlatform
import AIMAgentKit
import Foundation
import XCTest

/// Response shapes recorded from cua-driver 0.28.2 on AIM's fixture
/// (macOS 26A428, 2 October 2026); tokens and identifiers are representative.
enum CuaRecordedShapes {
    nonisolated(unsafe) static let matchedState: [String: Any] = [
        "content": [["type": "text", "text": "window_id=812 pid=77 elements=3"]],
        "structuredContent": [
            "_note": "Prefer `elements`", "app_name": "AIM Agent Fixture", "background_input": [:] as [String: Any],
            "element_count": 3, "elements_complete": true, "pid": 77, "returned_element_count": 3,
            "snapshot_id": "s0000002a", "total_element_count": 3, "window_id": 812,
            "window_title": "AIM Agent Fixture",
            "tree_markdown": "- [0] AXWindow \"AIM Agent Fixture\"\n  - AXStaticText = \"Count: 0\"",
            "elements": [
                ["actions": ["AXRaise"], "depth": 0, "element_index": 0, "element_token": "s0000002a:0",
                 "label": "AIM Agent Fixture", "role": "AXWindow",
                 "frame": ["x": 160, "y": 204, "width": 560, "height": 552]],
                ["actions": ["AXShowMenu", "AXConfirm"], "depth": 1, "element_index": 2, "element_token": "s0000002a:2",
                 "enabled": true, "label": "Fixture editable text", "parent_index": 0, "role": "AXTextField",
                 "value": "Fixture text", "frame": ["x": 184, "y": 290, "width": 200, "height": 22]],
                ["actions": ["AXPress"], "depth": 1, "element_index": 4, "element_token": "s0000002a:4",
                 "enabled": true, "label": "Increment", "parent_index": 0, "role": "AXButton",
                 "frame": ["x": 184, "y": 360, "width": 90, "height": 24]]
            ] as [[String: Any]]
        ] as [String: Any]
    ]

    nonisolated(unsafe) static let unresolvedState: [String: Any] = [
        "content": [["type": "text", "text": "window_id=813 pid=77 elements=0"]],
        "structuredContent": [
            "_note": "Prefer `elements`", "app_name": "AIM Agent Fixture", "background_input": [:] as [String: Any],
            "degraded": true, "element_count": 0, "elements": [] as [Any],
            "degraded_reason": "ax_window_unresolved: window_id 813 exists and is owned by pid 77, but none of the 3 AXWindow element(s) under that pid reports this CGWindowID."
        ] as [String: Any]
    ]

    nonisolated(unsafe) static let backgroundClick: [String: Any] = [
        "content": [["type": "text", "text": "✅ Performed AXPress on [4] AXButton \"Increment\"."]],
        "structuredContent": ["delivery": ["mode": "background"], "effect": "unverifiable", "route": "accessibility"]
    ]

    nonisolated(unsafe) static let typedText: [String: Any] = [
        "content": [["type": "text", "text": "✅ Inserted 9 char(s)."]],
        "structuredContent": ["delivery": ["delivered_count": 9, "mode": "background"], "effect": "confirmed",
                              "evidence": [["kind": "value_readback"]], "route": "accessibility"] as [String: Any]
    ]

    nonisolated(unsafe) static let refusedKey: [String: Any] = [
        "content": [["type": "text", "text": "Background input refused (same_pid_keyboard_ambiguity)"]],
        "structuredContent": ["delivery": ["mode": "background"], "effect": "refused",
                              "escalation": ["recommended": "accessibility"], "route": "synthetic_events"] as [String: Any]
    ]
}

final class CuaBackgroundWindowAdapterTests: XCTestCase {
    func testMatchedStateParsesActionableElementsAndRejectsForeignTokens() throws {
        let state = try CuaWindowStateParser.parse(CuaRecordedShapes.matchedState, pid: 77, windowID: 812,
            maximumElements: 300)
        XCTAssertTrue(state.isActionable)
        XCTAssertEqual(state.elements.map(\.index), [0, 2, 4])
        XCTAssertEqual(state.elements.last?.frame, CGRect(x: 184, y: 360, width: 90, height: 24))
        XCTAssertThrowsError(try CuaWindowStateParser.parse(CuaRecordedShapes.matchedState, pid: 78,
            windowID: 812, maximumElements: 300))
        var forged = CuaRecordedShapes.matchedState
        var structured = forged["structuredContent"] as! [String: Any]
        var rows = structured["elements"] as! [[String: Any]]
        rows[2]["element_token"] = "s0000002b:4"
        structured["elements"] = rows
        forged["structuredContent"] = structured
        XCTAssertThrowsError(try CuaWindowStateParser.parse(forged, pid: 77, windowID: 812, maximumElements: 300))
    }

    func testDegradedStateIsTypedNotOpaque() throws {
        let state = try CuaWindowStateParser.parse(CuaRecordedShapes.unresolvedState, pid: 77, windowID: 813,
            maximumElements: 300)
        XCTAssertFalse(state.isActionable)
        XCTAssertEqual(state.degradation, .axWindowUnresolved(axWindowCount: 3))
        XCTAssertTrue(state.elements.isEmpty)
    }

    func testActionReportMapsDeliveryAndRefusal() {
        let click = CuaActionReport.parse(CuaRecordedShapes.backgroundClick)
        XCTAssertTrue(click.isBackground)
        XCTAssertEqual(click.route, "accessibility")
        XCTAssertEqual(click.outcome(hostConfirmed: nil), .unverified)
        XCTAssertEqual(click.outcome(hostConfirmed: true), .confirmed)
        XCTAssertEqual(click.outcome(hostConfirmed: false), .suspectedAbsent)
        let typed = CuaActionReport.parse(CuaRecordedShapes.typedText)
        XCTAssertEqual(typed.evidence, ["value_readback"])
        let refused = CuaActionReport.parse(CuaRecordedShapes.refusedKey)
        XCTAssertTrue(refused.refused)
        XCTAssertFalse(refused.deliveredOutsideBackground)
        XCTAssertEqual(refused.outcome(hostConfirmed: nil), .suspectedAbsent)
        var foreground = CuaRecordedShapes.backgroundClick
        foreground["structuredContent"] = ["delivery": ["mode": "foreground"], "effect": "confirmed", "route": "accessibility"]
        let report = CuaActionReport.parse(foreground)
        XCTAssertTrue(report.deliveredOutsideBackground)
        XCTAssertEqual(report.outcome(hostConfirmed: true), .unknown)
    }

    func testExactBackgroundTargetConsumesObservationBeforeCall() async throws {
        let transport = FakeCuaWindowTransport()
        let launchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
            processLaunchedAt: { _ in launchedAt }, foregroundPID: { 42 })
        let observation = try await adapter.observe(pid: 77, windowID: 812)
        XCTAssertEqual(observation.elements.last?.label, "Increment")
        let receipt = try await adapter.clickElement(observationID: observation.id, elementIndex: 4)
        XCTAssertEqual(receipt.outcome, .unverified)
        XCTAssertFalse(receipt.focusChanged)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["get_window_state", "click"])
        let action = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls.last?.arguments)) as? [String: Any])
        XCTAssertEqual(action["delivery_mode"] as? String, "background")
        XCTAssertEqual(action["element_token"] as? String, "s0000002a:4")
        XCTAssertEqual(action["pid"] as? Int, 77)
        XCTAssertEqual(action["window_id"] as? Int, 812)
        do {
            _ = try await adapter.clickElement(observationID: observation.id, elementIndex: 4)
            XCTFail("An observation cannot authorize a second effect")
        } catch CuaBackgroundWindowError.invalidObservation {}
        let finalCalls = await transport.calls
        XCTAssertEqual(finalCalls.count, 2)
    }

    func testDegradedObservationRefusesElementActionsWithoutDriverCall() async throws {
        let transport = FakeCuaWindowTransport()
        await transport.setState(CuaRecordedShapes.unresolvedState)
        let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
            processLaunchedAt: { _ in Date(timeIntervalSince1970: 1) }, foregroundPID: { 42 })
        let observation = try await adapter.observe(pid: 77, windowID: 813)
        do {
            _ = try await adapter.clickElement(observationID: observation.id, elementIndex: 4)
            XCTFail("A degraded snapshot cannot authorize an element action")
        } catch CuaBackgroundWindowError.degraded(.axWindowUnresolved(3)) {}
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["get_window_state"])
    }

    func testTextEntryRequiresPositivelySafeTarget() async throws {
        for safety in [CuaInputSafety.secure, .unresolved] {
            let transport = FakeCuaWindowTransport()
            let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
                processLaunchedAt: { _ in Date(timeIntervalSince1970: 1) }, foregroundPID: { 42 },
                inputSafety: { _, _ in safety })
            let observation = try await adapter.observe(pid: 77, windowID: 812)
            do {
                _ = try await adapter.perform(.typeText(elementIndex: 2, text: "secret"), observationID: observation.id)
                XCTFail("Text entry must fail closed for \(safety)")
            } catch CuaBackgroundWindowError.secureInput {}
            let calls = await transport.calls
            XCTAssertEqual(calls.map(\.name), ["get_window_state"])
        }
        let transport = FakeCuaWindowTransport()
        await transport.setAction(CuaRecordedShapes.typedText)
        let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
            processLaunchedAt: { _ in Date(timeIntervalSince1970: 1) }, foregroundPID: { 42 },
            inputSafety: { _, _ in .safe })
        let observation = try await adapter.observe(pid: 77, windowID: 812)
        let receipt = try await adapter.perform(.typeText(elementIndex: 2, text: "AIM é 日本語"), observationID: observation.id)
        XCTAssertEqual(receipt.outcome, .unverified)
        let sentCalls = await transport.calls
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sentCalls.last?.arguments)) as? [String: Any])
        XCTAssertEqual(sent["text"] as? String, "AIM é 日本語")
        XCTAssertEqual(sent["delivery_mode"] as? String, "background")
    }

    func testRefusedActionIsReportedAsNotPerformed() async throws {
        let transport = FakeCuaWindowTransport()
        await transport.setAction(CuaRecordedShapes.refusedKey)
        let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
            processLaunchedAt: { _ in Date(timeIntervalSince1970: 1) }, foregroundPID: { 42 },
            inputSafety: { _, _ in .safe })
        let observation = try await adapter.observe(pid: 77, windowID: 812)
        let receipt = try await adapter.perform(.pressKey(elementIndex: 2, key: "a"), observationID: observation.id)
        XCTAssertEqual(receipt.outcome, .suspectedAbsent)
        XCTAssertTrue(receipt.report?.refused == true)
    }

    func testPixelActionNeedsValidScreenshotGeometry() async throws {
        let transport = FakeCuaWindowTransport()
        let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
            processLaunchedAt: { _ in Date(timeIntervalSince1970: 1) }, foregroundPID: { 42 })
        let observation = try await adapter.observe(pid: 77, windowID: 812)
        do {
            _ = try await adapter.perform(.clickPixel(x: 10, y: 10), observationID: observation.id)
            XCTFail("No screenshot geometry was observed")
        } catch CuaBackgroundWindowError.pixelsUnavailable {}
    }

    func testUserInTargetProcessSuspendsWithoutSendingAction() async throws {
        let transport = FakeCuaWindowTransport()
        let launchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
            processLaunchedAt: { _ in launchedAt }, foregroundPID: { 77 })
        let observation = try await adapter.observe(pid: 77, windowID: 812)
        do {
            _ = try await adapter.clickElement(observationID: observation.id, elementIndex: 4)
            XCTFail("The user's foreground process has priority")
        } catch CuaBackgroundWindowError.foregroundConflict {}
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.name), ["get_window_state"])
    }

    func testRestartedProcessAndTransportFailureNeverBecomeConfirmed() async throws {
        let transport = FakeCuaWindowTransport()
        let launchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let process = TestProcessIdentity(launchedAt)
        let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
            processLaunchedAt: { _ in process.date }, foregroundPID: { 42 })
        let first = try await adapter.observe(pid: 77, windowID: 812)
        process.date = launchedAt.addingTimeInterval(1)
        do {
            _ = try await adapter.clickElement(observationID: first.id, elementIndex: 4)
            XCTFail("A recycled PID must not be used")
        } catch CuaBackgroundWindowError.staleProcess {}
        let beforeFailure = await transport.calls
        XCTAssertEqual(beforeFailure.map(\.name), ["get_window_state"])

        let second = try await adapter.observe(pid: 77, windowID: 812)
        await transport.setActionFailure(true)
        let receipt = try await adapter.clickElement(observationID: second.id, elementIndex: 4)
        XCTAssertEqual(receipt.outcome, .unknown)
        let finalCalls = await transport.calls
        XCTAssertEqual(finalCalls.filter { $0.name == "click" }.count, 1)
    }

    func testStopInvalidatesAnInFlightActionWithoutClaimingSuccess() async throws {
        let transport = FakeCuaWindowTransport()
        await transport.setPauseAction(true)
        let launchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = CuaBackgroundWindowAdapter(transport: transport, generation: UUID(),
            processLaunchedAt: { _ in launchedAt }, foregroundPID: { 42 })
        let observation = try await adapter.observe(pid: 77, windowID: 812)
        let action = Task {
            try await adapter.clickElement(observationID: observation.id, elementIndex: 4)
        }
        await transport.whenActionStarted()
        await adapter.invalidate()
        do {
            _ = try await adapter.observe(pid: 77, windowID: 812)
            XCTFail("No new observation may race an in-flight action")
        } catch CuaBackgroundWindowError.busy {}
        await transport.resumeAction()
        let receipt = try await action.value
        XCTAssertEqual(receipt.outcome, .unknown)
    }
}

private final class TestProcessIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var date: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

actor FakeCuaWindowTransport: CuaWindowToolCalling {
    struct Call: Sendable {
        let name: String
        let arguments: Data
    }
    private(set) var calls: [Call] = []
    private var failAction = false
    private var pauseAction = false
    private var state: [String: Any] = CuaRecordedShapes.matchedState
    private var actionResult: [String: Any] = CuaRecordedShapes.backgroundClick
    private var pendingAction: CheckedContinuation<Void, Never>?
    private var actionStartWaiters: [CheckedContinuation<Void, Never>] = []

    func setActionFailure(_ value: Bool) { failAction = value }
    func setPauseAction(_ value: Bool) { pauseAction = value }
    func setState(_ value: [String: Any]) { state = value }
    func setAction(_ value: [String: Any]) { actionResult = value }
    func whenActionStarted() async {
        if calls.contains(where: { $0.name != "get_window_state" }) { return }
        await withCheckedContinuation { actionStartWaiters.append($0) }
    }
    func resumeAction() {
        pendingAction?.resume()
        pendingAction = nil
    }

    func callRawTool(_ name: String, arguments: Data) async throws -> Data {
        calls.append(Call(name: name, arguments: arguments))
        if name == "get_window_state" {
            return try JSONSerialization.data(withJSONObject: state)
        }
        let waiters = actionStartWaiters
        actionStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if pauseAction {
            await withCheckedContinuation { pendingAction = $0 }
        }
        if failAction { throw URLError(.networkConnectionLost) }
        return try JSONSerialization.data(withJSONObject: actionResult)
    }
}
