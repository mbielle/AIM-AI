#if DEBUG
import AIMAgentKit
import AIMApplication
import Foundation

/// End-to-end check of the model-facing background tools on the fixture,
/// without a model: listing, observation, actions, person priority, leases
/// and stale observations, each verified against the fixture's state file.
public enum CuaToolServiceQualification {
    public static func run(into report: QualificationReport, qualified: [CuaCapability: String]) async {
        guard qualified[.observe] != nil, qualified[.axClick] != nil else {
            report.set("conclusion", "Run cua-ladder first: observe and ax_click must be qualified for this driver and macOS build.")
            return
        }
        guard let initial = await FixtureController.perform("reset") else {
            report.set("conclusion", "The fixture is not running.")
            return
        }
        guard !initial.isActive else {
            report.set("conclusion", "The fixture is the active app (someone is using it); bring another app forward and rerun.")
            return
        }
        let service = AgentCuaToolService(qualified: qualified, modelSeesImages: true)
        report.set("offered_tools", service.supportedTools.sorted())
        var cases: [String: Bool] = [:]
        func call(_ name: String, _ arguments: [String: String], risk: ToolRisk = .computerAction) async -> ToolResult {
            await service.execute(ToolRequest(name: name, arguments: arguments, risk: risk))
        }

        let listed = await call("bg_list_windows", [:], risk: .computerRead)
        let ref = fixtureWindowRef(listed.content)
        cases["list_contains_fixture"] = ref != nil
        guard let ref else {
            report.set("list_excerpt", String(listed.content.prefix(1_000)))
            report.set("cases", cases)
            report.set("conclusion", "The fixture main window was not listed.")
            await service.closeSession()
            return
        }

        // Observe, then click Increment by element index.
        var observation = await call("bg_observe_window", ["window_ref": ref], risk: .computerRead)
        var parsed = parse(observation.content)
        cases["observe_actionable"] = parsed?.actionable == true
        if let parsed, let increment = parsed.index(label: "Increment") {
            let before = FixtureController.read()?.count ?? -1
            let click = await call("bg_click", ["observation_id": parsed.id, "element_index": String(increment)])
            let after = await FixtureController.waitFor { $0.count == before + 1 }
            cases["click_effect"] = after != nil && !click.isError
            cases["click_returns_fresh_observation"] = click.metadata["observation_id"] != nil
            report.set("click_result", ["outcome": click.metadata["action_outcome"] ?? "", "route": click.metadata["driver_route"] ?? "",
                                        "is_error": click.isError])
            // The previous observation was consumed by the click.
            let stale = await call("bg_click", ["observation_id": parsed.id, "element_index": String(increment)])
            let unchanged = FixtureController.read()?.count == before + 1
            cases["stale_observation_refused"] = stale.isError && unchanged
        }

        // Type into the editable text element.
        if qualified[.typeText] != nil {
            observation = await call("bg_observe_window", ["window_ref": ref], risk: .computerRead)
            parsed = parse(observation.content)
            if let parsed, let field = parsed.index(label: "Fixture editable text") {
                let typed = await call("bg_type_text", ["observation_id": parsed.id, "element_index": String(field),
                                                        "text": " AIM"])
                let after = await FixtureController.waitFor { $0.text.contains(" AIM") }
                cases["type_effect"] = after != nil && !typed.isError
            }
            observation = await call("bg_observe_window", ["window_ref": ref], risk: .computerRead)
            parsed = parse(observation.content)
            if let parsed, let secure = parsed.index(label: "Fixture secure field") {
                let refused = await call("bg_type_text", ["observation_id": parsed.id, "element_index": String(secure),
                                                          "text": "secret"])
                cases["secure_field_refused"] = refused.isError && FixtureController.read()?.secureLength == 0
            }
        }

        // The person activates the fixture after AIM observed it: nothing is sent,
        // and the next action on that app requires a person (no mission intent).
        observation = await call("bg_observe_window", ["window_ref": ref], risk: .computerRead)
        parsed = parse(observation.content)
        if let parsed, let increment = parsed.index(label: "Increment") {
            await CuaTargetLeaseCoordinator.shared.recordActivation(pid: initial.pid)
            let before = FixtureController.read()?.count ?? -1
            let blocked = await call("bg_click", ["observation_id": parsed.id, "element_index": String(increment)])
            try? await Task.sleep(for: .milliseconds(500))
            cases["human_priority_blocks"] = blocked.isError && FixtureController.read()?.count == before
            let next = await call("bg_observe_window", ["window_ref": ref], risk: .computerRead)
            if let nextParsed = parse(next.content) {
                let intent = try? await service.missionIntent(for: ToolRequest(name: "bg_type_text",
                    arguments: ["observation_id": nextParsed.id, "element_index": "0", "text": "x"], risk: .computerAction))
                cases["human_conflict_requires_person"] = intent == nil
            }
            await CuaTargetLeaseCoordinator.shared.clearHumanConflict(pid: initial.pid)
        }

        // Another run holding the target's lease prevents concurrent input.
        observation = await call("bg_observe_window", ["window_ref": ref], risk: .computerRead)
        parsed = parse(observation.content)
        if let parsed, let increment = parsed.index(label: "Increment") {
            let other = UUID()
            try? await CuaTargetLeaseCoordinator.shared.acquire(pid: initial.pid, owner: other)
            let before = FixtureController.read()?.count ?? -1
            let contended = await call("bg_click", ["observation_id": parsed.id, "element_index": String(increment)])
            cases["lease_prevents_concurrent_input"] = contended.isError && FixtureController.read()?.count == before
            await CuaTargetLeaseCoordinator.shared.release(owner: other)
        }

        await service.closeSession()
        let final = await FixtureController.perform("reset")
        report.set("fixture_became_active_during_run", final?.isActive == true || (final?.activations ?? 0) > 0)
        report.set("cases", cases)
        let failed = cases.filter { !$0.value }.map(\.key).sorted()
        report.set("conclusion", failed.isEmpty ? "all cases passed (\(cases.count))" : "failed: \(failed.joined(separator: ", "))")
    }

    struct Observation {
        let id: String
        let actionable: Bool
        let elements: [[String: Any]]

        func index(label: String) -> Int? {
            elements.first { $0["label"] as? String == label }?["index"] as? Int
        }
    }

    static func parse(_ content: String) -> Observation? {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["observation_id"] as? String else { return nil }
        return Observation(id: id, actionable: object["actionable"] as? Bool ?? false,
            elements: object["elements"] as? [[String: Any]] ?? [])
    }

    static func fixtureWindowRef(_ content: String) -> String? {
        guard let json = content.split(separator: "\n").first, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = object["windows"] as? [[String: Any]] else { return nil }
        // The main fixture window is the widest of the two identically titled windows.
        return windows.filter { $0["title"] as? String == "AIM Agent Fixture" }
            .max { (($0["bounds"] as? [String: Double])?["width"] ?? 0) < (($1["bounds"] as? [String: Double])?["width"] ?? 0) }?["window_ref"] as? String
    }
}
#endif
