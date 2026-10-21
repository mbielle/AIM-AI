import AppKit
import Foundation

/// Debug-only, one-click field qualification against AIM's disposable fixture.
/// It never gives the model access to the driver or acts on another app.
public enum CuaFixtureQualification {
    public static func report() async -> Data {
        var fields: [String: Any] = [
            "driver_version": EmbeddedCuaDriverHost.qualifiedVersion,
            "bundle": Bundle.main.bundleURL.path,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "qualified": false,
            "scope": "background AX click on com.aimai.macos.agent-fixture only"
        ]
        do {
            let prerequisites = try await CuaDriverDiagnostics().probe()
            fields["host_identity_verified"] = prerequisites.hostIdentityVerified
            fields["accessibility_granted"] = prerequisites.accessibilityGranted
            fields["screen_recording_granted"] = prerequisites.screenRecordingGranted
            guard prerequisites.backgroundPrerequisitesAvailable else {
                fields["reason"] = "The signed AIM host lacks a required permission or identity check."
                return encode(fields)
            }
            let inventory = await MacAccessibilityService().inventory()
            let fixturePIDs = Set(inventory.applications.filter {
                $0.bundleID == "com.aimai.macos.agent-fixture"
            }.map(\.pid))
            guard fixturePIDs.count == 1, let pid = fixturePIDs.first,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else {
                fields["reason"] = "Run the fixture in the background and keep another application frontmost."
                return encode(fields)
            }
            let candidates = inventory.windows.filter { $0.ownerPID == pid }
            fields["candidate_window_ids"] = candidates.map { Int($0.id) }
            guard !candidates.isEmpty else {
                fields["reason"] = "The dedicated fixture has no discoverable window."
                return encode(fields)
            }

            guard let executable = HostBundleResources.resourceURL?
                .appendingPathComponent("CuaDriver/cua-driver") else {
                fields["reason"] = "The pinned driver is absent."
                return encode(fields)
            }
            let host = EmbeddedCuaDriverHost(executable: executable)
            let connection = try await host.start()
            let client: PlaywrightMCPClient
            do {
                client = try PlaywrightMCPClient(cuaDriver: executable,
                    socketPath: connection.socketPath,
                    hostBundleID: Bundle.main.bundleIdentifier ?? "")
            } catch {
                await host.stop()
                throw error
            }
            do {
                try await client.initialize()
                let names = try await client.listTools()
                guard names.isSuperset(of: ["get_window_state", "click"]),
                      hasFields(client.inputSchema(for: "get_window_state"),
                                ["pid", "window_id", "include_screenshot"]),
                      hasFields(client.inputSchema(for: "click"),
                                ["target", "element_token", "delivery_mode"]) else {
                    fields["reason"] = "The pinned driver action schemas are incompatible."
                    client.stop(); await host.stop()
                    return encode(fields)
                }
                let adapter = CuaBackgroundWindowAdapter(
                    transport: CuaMCPTransport(client: client), generation: connection.generation)
                var matches: [(CuaWindowObservation, Int, Int)] = []
                var inspected: [[String: Any]] = []
                for candidate in candidates {
                    let observation: CuaWindowObservation
                    do {
                        observation = try await adapter.observe(pid: pid, windowID: Int(candidate.id))
                    } catch {
                        inspected.append(["window_id": Int(candidate.id),
                            "error": String(describing: error)])
                        continue
                    }
                    let buttons = observation.elements.filter {
                        $0.role == "AXButton" && $0.label == "Increment"
                    }
                    let counters = observation.elements.compactMap { element in
                        [element.label, element.value].compactMap { $0 }.compactMap(counter).first
                    }
                    inspected.append(["window_id": Int(candidate.id),
                        "elements": observation.elements.count,
                        "increment_buttons": buttons.count,
                        "counters": counters.count])
                    if buttons.count == 1, let before = counters.first {
                        matches.append((observation, buttons[0].index, before))
                    }
                }
                fields["inspected_windows"] = inspected
                guard matches.count == 1, let selected = matches.first else {
                    if let first = candidates.first {
                        do {
                            let raw = try await client.callRawTool("get_window_state", arguments: [
                                "pid": Int(pid), "window_id": Int(first.id),
                                "include_screenshot": false, "max_elements": 300])
                            fields["first_response_error"] = raw["isError"] as? Bool ?? false
                            fields["first_response_keys"] = raw.keys.sorted()
                            let structured = (raw["structuredContent"] as? [String: Any]) ?? [:]
                            fields["first_structured_keys"] = structured.keys.sorted()
                            fields["first_degraded"] = structured["degraded"] ?? NSNull()
                            fields["first_degraded_reason"] = structured["degraded_reason"] ?? NSNull()
                            fields["first_element_count"] = structured["element_count"] ?? NSNull()
                            fields["first_elements_type"] = String(describing: type(of: structured["elements"] as Any))
                            if let elements = structured["elements"] as? [[String: Any]],
                               let first = elements.first {
                                fields["first_element_keys"] = first.keys.sorted()
                            }
                            if let content = raw["content"] as? [[String: Any]],
                               let message = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                                fields["first_response_text"] = String(message.prefix(500))
                            }
                        } catch {
                            fields["first_response_error_detail"] = String(describing: error)
                        }
                    }
                    fields["reason"] = "The fixture button and counter were not uniquely identified: " +
                        "\(matches.count) matching windows, \(inspected.count) inspected."
                    client.stop(); await host.stop()
                    return encode(fields)
                }
                // The last observation wins in CUA's snapshot cache. Refresh
                // the chosen window immediately before its one permitted click.
                let fresh = try await adapter.observe(pid: pid, windowID: selected.0.windowID)
                guard let button = fresh.elements.first(where: {
                    $0.role == "AXButton" && $0.label == "Increment"
                }), let before = fresh.elements.compactMap({ element in
                    [element.label, element.value].compactMap { $0 }.compactMap(counter).first
                }).first, before == selected.2 else {
                    fields["reason"] = "The fixture changed before the action."
                    client.stop(); await host.stop()
                    return encode(fields)
                }
                let receipt = try await adapter.clickElement(
                    observationID: fresh.id, elementIndex: button.index)
                fields["action_outcome"] = receipt.outcome.rawValue
                fields["focus_changed"] = receipt.focusChanged
                fields["attempted"] = true
                let after = try await adapter.observe(pid: pid, windowID: fresh.windowID)
                let afterCount = after.elements.compactMap { element in
                    [element.label, element.value].compactMap { $0 }.compactMap(counter).first
                }.first
                fields["effect_verified"] = afterCount == before + 1
                fields["qualified"] = receipt.outcome == .unverified &&
                    !receipt.focusChanged && afterCount == before + 1
                if fields["qualified"] as? Bool != true {
                    fields["reason"] = "The fixture count or foreground app did not confirm background delivery."
                }
                client.stop(); await host.stop()
                return encode(fields)
            } catch {
                client.stop(); await host.stop()
                throw error
            }
        } catch {
            fields["reason"] = error.localizedDescription
            return encode(fields)
        }
    }

    private static func hasFields(_ schema: Data?, _ keys: Set<String>) -> Bool {
        guard let schema, let object = try? JSONSerialization.jsonObject(with: schema) as? [String: Any],
              let properties = object["properties"] as? [String: Any] else { return false }
        return keys.isSubset(of: Set(properties.keys))
    }

    private static func counter(_ text: String) -> Int? {
        guard text.hasPrefix("Count: ") else { return nil }
        return Int(text.dropFirst(7))
    }

    private static func encode(_ fields: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: fields,
            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
