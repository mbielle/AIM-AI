#if DEBUG
import AppKit
import Foundation

/// Reads the disposable fixture's own state file and sends it qualification
/// commands. The state file is ground truth independent of AX and the driver.
struct FixtureState: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let number: Int
        let title: String
        let frame: CGRect
        let visible: Bool
        let miniaturized: Bool
        let onActiveSpace: Bool
    }

    let pid: Int32
    let count: Int
    let text: String
    let secureLength: Int
    let slider: Double
    let firstVisibleRow: Int
    let lastKey: String
    let activations: Int
    let keyWindowChanges: Int
    let deminiaturizations: Int
    let unhides: Int
    let isActive: Bool
    let isHidden: Bool
    let windows: [Window]
    let writtenAt: Double

    var invariantSignature: String {
        "activations=\(activations) key=\(keyWindowChanges) demin=\(deminiaturizations) unhide=\(unhides) active=\(isActive)"
    }

    var summary: [String: Any] {
        ["count": count, "text": text, "secure_length": secureLength, "slider": slider,
         "first_visible_row": firstVisibleRow, "last_key": lastKey, "activations": activations,
         "key_window_changes": keyWindowChanges, "is_active": isActive, "is_hidden": isHidden]
    }
}

enum FixtureController {
    static let commandNotification = Notification.Name("com.aimai.macos.agent-fixture.command")

    static var statePath: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aim-agent-fixture", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    static func read() -> FixtureState? {
        guard let data = try? Data(contentsOf: statePath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int else { return nil }
        let windows = (object["windows"] as? [[String: Any]] ?? []).map { row in
            FixtureState.Window(number: row["number"] as? Int ?? 0, title: row["title"] as? String ?? "",
                frame: CGRect(x: row["x"] as? Double ?? 0, y: row["y"] as? Double ?? 0,
                              width: row["width"] as? Double ?? 0, height: row["height"] as? Double ?? 0),
                visible: row["visible"] as? Bool ?? false, miniaturized: row["miniaturized"] as? Bool ?? false,
                onActiveSpace: row["on_active_space"] as? Bool ?? false)
        }
        return FixtureState(pid: Int32(pid), count: object["count"] as? Int ?? -1,
            text: object["text"] as? String ?? "", secureLength: object["secure_length"] as? Int ?? -1,
            slider: object["slider"] as? Double ?? -1, firstVisibleRow: object["first_visible_row"] as? Int ?? -1,
            lastKey: object["last_key"] as? String ?? "", activations: object["activations"] as? Int ?? -1,
            keyWindowChanges: object["key_window_changes"] as? Int ?? -1,
            deminiaturizations: object["deminiaturizations"] as? Int ?? -1,
            unhides: object["unhides"] as? Int ?? -1, isActive: object["is_active"] as? Bool ?? false,
            isHidden: object["is_hidden"] as? Bool ?? false, windows: windows,
            writtenAt: object["written_at"] as? Double ?? 0)
    }

    static func send(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(commandNotification, object: nil,
            userInfo: ["command": command], deliverImmediately: true)
    }

    /// Sends a command and waits for the fixture to rewrite its state.
    static func perform(_ command: String, timeout: Duration = .seconds(3)) async -> FixtureState? {
        let before = read()?.writtenAt ?? 0
        send(command)
        return await waitFor(timeout: timeout) { $0.writtenAt > before }
    }

    static func waitFor(timeout: Duration = .seconds(3),
                        _ condition: (FixtureState) -> Bool) async -> FixtureState? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let state = read(), condition(state) { return state }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return read().flatMap { condition($0) ? $0 : nil }
    }
}
#endif

#if DEBUG
/// Narrow public access for app-level live scenarios: reset the fixture and
/// read its state file. Fixture-only; never another application.
public enum FixtureControllerBridge {
    public static func reset() async -> Bool { await FixtureController.perform("reset") != nil }

    public static func state() -> [String: Any]? {
        guard let state = FixtureController.read() else { return nil }
        var summary = state.summary
        summary["pid"] = Int(state.pid)
        return summary
    }
}
#endif
