import AIMCore
import AIMAgentRuntime
#if DEBUG
import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import AppKit
import ApplicationServices
import Foundation
import Darwin

/// Debug-only live Agent scenarios with a real BYOK model. Each run uses an
/// in-memory conversation database, the user's stored OpenRouter key, a
/// scripted approval policy that allows only the scenario's expected actions,
/// a per-scenario spend cap and a cumulative envelope recorded next to the
/// build. Success is decided by host checks, never by the model's claims.
enum LiveScenarioRunner {
    static var cloudModelID: String { argument("--cloud-model") ?? "z-ai/glm-5.3" }
    static let authorizedCloudModels = Set(["z-ai/glm-5.3", "anthropic/claude-sonnet-5.5"])
    /// `--local-model <id>` runs the scenarios on a local server instead (free, offline);
    /// `--local-base-url` overrides its address (default: oMLX on port 8000).
    static var localModelID: String? { argument("--local-model") }
    static var provider: ChatProvider { localModelID == nil ? .openRouter : .local }
    static var modelID: String { localModelID ?? cloudModelID }

    static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    /// 10 USD, raised to 15 USD by Mathieu on 2026-10-10 for the Round 36 qualification campaign.
    static let envelopeUSD = Decimal(string: "20")! // raised from 15 by Mathieu, 2026-10-10 (Round 36)
    static let defaultScenarioCapUSD = Decimal(string: "1.50")!

    struct Scenario {
        let id: String
        let prompt: String
        let edits: Bool
        let commands: Bool
        let timeout: Duration
        let prepare: (URL) async throws -> Void
        let allow: (PendingToolApproval) -> Bool
        let verify: (URL, Transcript) async -> [String: Any]
    }

    struct Transcript {
        var text = ""
        var tools: [String] = []
        var toolErrors = 0
        var approvals: [[String: Any]] = []
        var failure: String?
        var completed = false
        var missionState: String?
    }

    // MARK: Scenarios

    static func scenario(_ id: String) -> Scenario? {
        switch id {
        case "fixture-background":
            return Scenario(id: id,
                prompt: """
                In the app "AIM Agent Fixture" there are two windows titled "AIM Agent Fixture"; use the larger one, which has an Increment button and a "Count: N" label. Using only the background tools (bg_list_windows, bg_observe_window, bg_click), press Increment until the label reads exactly "Count: 3". Do not bring the app to the front and do not touch any other application. Then report the final count you observed.
                """,
                edits: false, commands: false, timeout: .seconds(300),
                prepare: { _ in
                    guard await FixtureControllerBridge.reset() else { throw LiveScenarioError.fixtureUnavailable }
                },
                allow: { approval in
                    switch approval.toolName {
                    case "bg_list_windows", "bg_observe_window", "desktop_list_windows": return true
                    case "bg_click": return approval.review?.path.hasPrefix("AIM Agent Fixture") == true
                    default: return false
                    }
                },
                verify: { _, transcript in
                    let state = FixtureControllerBridge.state()
                    let count = state?["count"] as? Int ?? -1
                    let activations = state?["activations"] as? Int ?? -1
                    return ["passed": count == 3 && activations == 0 && state?["is_active"] as? Bool == false,
                            "fixture_count": count, "fixture_activations": activations,
                            "answer_mentions_3": transcript.text.contains("3")]
                })
        case "workspace-file":
            return Scenario(id: id,
                prompt: """
                In the selected workspace, create a new file named notes.md whose entire content is the single line: AIM live test ok
                Then read the file back to verify it, and report exactly what you verified.
                """,
                edits: true, commands: false, timeout: .seconds(240),
                prepare: { workspace in
                    try "# Live workspace\n".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                },
                allow: { approval in
                    ["propose_file", "apply_edit", "read_file", "list_dir", "find_files", "search_files"].contains(approval.toolName)
                },
                verify: { workspace, transcript in
                    let content = try? String(contentsOf: workspace.appendingPathComponent("notes.md"), encoding: .utf8)
                    let normalized = content?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ["passed": normalized == "AIM live test ok" && transcript.tools.contains("read_file"),
                            "file_content": content ?? NSNull()]
                })
        case "long-command":
            return Scenario(id: id,
                prompt: """
                In the selected workspace, start the shell command `sleep 3; echo AIM_LONG_DONE` with start_command (not run_command). Use read_command until the command has finished, then report its exit status and its output.
                """,
                edits: false, commands: true, timeout: .seconds(240),
                prepare: { _ in },
                allow: { approval in
                    switch approval.toolName {
                    case "start_command": return approval.arguments["command"]?.contains("AIM_LONG_DONE") == true
                    case "read_command", "stop_command", "list_dir": return true
                    default: return false
                    }
                },
                verify: { _, transcript in
                    ["passed": transcript.tools.contains("start_command") && transcript.tools.contains("read_command") &&
                        transcript.text.contains("AIM_LONG_DONE") && !transcript.tools.contains("run_command"),
                     "reads": transcript.tools.filter { $0 == "read_command" }.count]
                })
        case "mission-check":
            return Scenario(id: id,
                prompt: """
                In the selected workspace, create a file named status.txt whose content is the single word READY. Then make the mission verifiable: define a success check with mission_define_check of kind "command" using the command ["/bin/cat", "status.txt"] and required_text "READY", and verify it with mission_verify_criterion. Report what the host verified.
                """,
                edits: true, commands: false, timeout: .seconds(300),
                prepare: { _ in },
                allow: { approval in
                    switch approval.toolName {
                    case "propose_file", "apply_edit", "read_file", "list_dir", "mission_list_criteria", "mission_verify_criterion":
                        return true
                    case "mission_define_check":
                        return approval.arguments["kind"] == "command" &&
                            approval.arguments["command"]?.contains("status.txt") == true
                    default: return false
                    }
                },
                verify: { workspace, transcript in
                    let content = try? String(contentsOf: workspace.appendingPathComponent("status.txt"), encoding: .utf8)
                    return ["passed": transcript.missionState == AgentMissionState.verified.rawValue &&
                                content?.contains("READY") == true,
                            "mission_state": transcript.missionState ?? NSNull(),
                            "defined_check": transcript.tools.contains("mission_define_check")]
                })
        case "mcp-note":
            return Scenario(id: id,
                prompt: """
                Use the MCP connector named "aimfixture": find its tools, store a note with the text "AIM MCP live" and the tag "qualification", then list the notes to confirm it was stored, and report what you confirmed.
                """,
                edits: false, commands: false, timeout: .seconds(240),
                prepare: { _ in },
                allow: { approval in
                    switch approval.toolName {
                    case "mcp_list_tools", "mcp_read": return true
                    case "mcp_call":
                        return approval.arguments["server"] == "aimfixture" && approval.arguments["tool"] == "add_note"
                    default: return false
                    }
                },
                verify: { _, transcript in
                    var stored = false
                    if let fixture = MCPQualification.fixtureConfiguration(),
                       let data = try? await MCPServerManager.shared.call(server: fixture, tool: "list_notes",
                           argumentsJSON: Data("{}".utf8)) {
                        stored = String(decoding: data, as: UTF8.self).contains("AIM MCP live")
                    }
                    return ["passed": stored && transcript.tools.contains("mcp_call"),
                            "note_on_server": stored]
                })
        case "skill-use":
            // The prompt never names the skill: the model must find it in the catalog.
            return Scenario(id: id,
                prompt: """
                Write the release notes for version 1.4 of this project in the selected workspace. The only change in this release is: faster sync. Report what you wrote.
                """,
                edits: true, commands: false, timeout: .seconds(240),
                prepare: { workspace in
                    let skill = workspace.appendingPathComponent(".aim/skills/release-notes", isDirectory: true)
                    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
                    try """
                    ---
                    name: release-notes
                    description: House format for this project's release notes. Use whenever asked to write or update release notes.
                    ---

                    1. Write the notes to RELEASE_NOTES.md at the workspace root (never another file name).
                    2. The first line must be exactly: # Release <version> · house-format-7
                    3. Write each change on its own line as: - [change] <Change, first letter capitalized>
                    4. Read the file back to confirm the format.
                    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                },
                allow: { approval in
                    ["propose_file", "apply_edit", "read_file", "list_dir", "find_files", "search_files",
                     "skill_view", "skill_read_file"].contains(approval.toolName)
                },
                verify: { workspace, transcript in
                    let content = try? String(contentsOf: workspace.appendingPathComponent("RELEASE_NOTES.md"), encoding: .utf8)
                    let lines = content?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    let formatted = lines.first == "# Release 1.4 · house-format-7" &&
                        lines.contains { $0.lowercased() == "- [change] faster sync" || $0.lowercased() == "- [change] faster sync." }
                    return ["passed": formatted && transcript.tools.contains("skill_view"),
                            "skill_viewed": transcript.tools.contains("skill_view"),
                            "file_content": content ?? NSNull()]
                })
        case "subagent-writer":
            return Scenario(id: id,
                prompt: """
                Delegate this to a writer sub-agent (delegate_task with mode "write"): create a file named CHANGELOG.md at the workspace root whose entire content is the single line: - Added offline mode
                When it finishes, review its changes, merge them if they are correct, then read CHANGELOG.md in the workspace to confirm and report what the sub-agent reported and what you verified.
                """,
                edits: true, commands: false, timeout: .seconds(420),
                prepare: { workspace in
                    try "# Demo\n".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                    for arguments in [["init", "-q", "-b", "main"], ["add", "-A"],
                                      ["-c", "user.name=AIM Fixture", "-c", "user.email=fixture@localhost.invalid",
                                       "commit", "-q", "-m", "initial"]] {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                        process.arguments = arguments
                        process.currentDirectoryURL = workspace
                        try process.run()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw LiveScenarioError.preparation("git \(arguments[0])") }
                    }
                },
                allow: { approval in
                    switch approval.toolName {
                    case "delegate_task": return approval.arguments["mode"] == "write"
                    case "await_subagents", "list_subagents", "review_subagent_changes", "merge_subagent_changes",
                         "read_file", "list_dir", "find_files", "git_status", "git_diff",
                         "propose_file", "apply_edit":
                        return true
                    default: return false
                    }
                },
                verify: { workspace, transcript in
                    let content = try? String(contentsOf: workspace.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
                    let worktrees = (try? FileManager.default.contentsOfDirectory(atPath:
                        SubagentWorkspaceService.defaultRoot.path)) ?? []
                    let usedFlow = ["delegate_task", "review_subagent_changes", "merge_subagent_changes"]
                        .allSatisfy(transcript.tools.contains)
                    // The parent must not have written the file itself.
                    let parentWrote = transcript.tools.contains("apply_edit")
                    return ["passed": content?.trimmingCharacters(in: .whitespacesAndNewlines) == "- Added offline mode" &&
                                usedFlow && !parentWrote,
                            "file_content": content ?? NSNull(), "parent_wrote_itself": parentWrote,
                            "leftover_worktree_groups": worktrees.count]
                })
        case "subagent-research":
            return Scenario(id: id,
                prompt: """
                Deploy exactly two research sub-agents in parallel (delegate_task with profile research). The first finds out what TypeSafe's decision model "Jev" is and what it can do. The second finds what the community has built with decision models like Jev. Each must use web_search and then web_fetch on at most three pages. Wait for both, then give me a short report (about ten lines) with the URLs they read.
                """,
                edits: false, commands: false, timeout: .seconds(600),
                prepare: { _ in },
                allow: { ["delegate_task", "await_subagents", "list_subagents", "message_subagent", "retry_subagent",
                          "recommend_subagent_models", "web_search", "web_fetch"].contains($0.toolName) },
                verify: { _, transcript in
                    let delegations = transcript.tools.filter { $0 == "delegate_task" }.count
                    let broken = transcript.text.contains("invalid or incomplete tool response")
                    return ["passed": delegations == 2 && transcript.tools.contains("await_subagents") && !broken &&
                                transcript.text.contains("http"),
                            "delegations": delegations, "web_calls": transcript.tools.filter { $0.hasPrefix("web_") }.count,
                            "provider_response_refused": broken]
                })
        case "web-research":
            return Scenario(id: id,
                prompt: """
                Using web search, find the official swift.org page announcing the most recent Swift release, read that page, and report the version number and the exact URL you read.
                """,
                edits: false, commands: false, timeout: .seconds(240),
                prepare: { _ in },
                allow: { ["web_search", "web_fetch"].contains($0.toolName) },
                verify: { _, transcript in
                    let version = transcript.text.range(of: #"\b\d+\.\d+(\.\d+)?\b"#, options: .regularExpression) != nil
                    return ["passed": transcript.tools.contains("web_search") && transcript.tools.contains("web_fetch") &&
                                transcript.text.contains("swift.org") && version,
                            "searches": transcript.tools.filter { $0 == "web_search" }.count]
                })
        case "multi-file-refactor":
            return Scenario(id: id,
                prompt: """
                Rename the function greet to welcome everywhere in this workspace (its definition and every call site) as one change, then search the workspace to confirm no call to greet( remains, and report what you changed.
                """,
                edits: true, commands: false, timeout: .seconds(300),
                prepare: { workspace in
                    let source = workspace.appendingPathComponent("src", isDirectory: true)
                    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                    try "func greet(name: String) -> String {\n    \"Hello \\(name)\"\n}\n".write(to: source.appendingPathComponent("greeter.swift"), atomically: true, encoding: .utf8)
                    try "print(greet(name: \"AIM\"))\n".write(to: source.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                    try "assert(greet(name: \"x\") == \"Hello x\")\nassert(greet(name: \"y\").hasSuffix(\"y\"))\n".write(to: source.appendingPathComponent("checks.swift"), atomically: true, encoding: .utf8)
                },
                allow: { ["read_file", "list_dir", "find_files", "search_files", "propose_patch", "propose_edit", "apply_edit"].contains($0.toolName) },
                verify: { workspace, transcript in
                    let files = ["greeter.swift", "main.swift", "checks.swift"].map {
                        (try? String(contentsOf: workspace.appendingPathComponent("src/\($0)"), encoding: .utf8)) ?? ""
                    }
                    let renamed = files.allSatisfy { $0.contains("welcome(") && !$0.contains("greet(") }
                    return ["passed": renamed && transcript.tools.contains("search_files"),
                            "used_patch": transcript.tools.contains("propose_patch"),
                            "edit_proposals": transcript.tools.filter { $0.hasPrefix("propose_") }.count]
                })
        case "fix-and-verify":
            return Scenario(id: id,
                prompt: """
                The tests of this Swift package fail. Find and fix the bug, then verify that the tests pass and report the result.
                """,
                edits: true, commands: true, timeout: .seconds(420),
                prepare: { workspace in
                    let fm = FileManager.default
                    try fm.createDirectory(at: workspace.appendingPathComponent("Sources/Calc"), withIntermediateDirectories: true)
                    try fm.createDirectory(at: workspace.appendingPathComponent("Tests/CalcTests"), withIntermediateDirectories: true)
                    try """
                    // swift-tools-version:5.9
                    import PackageDescription
                    let package = Package(name: "Calc", targets: [
                        .target(name: "Calc"), .testTarget(name: "CalcTests", dependencies: ["Calc"])
                    ])
                    """.write(to: workspace.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
                    try "public func add(_ a: Int, _ b: Int) -> Int {\n    a - b\n}\n"
                        .write(to: workspace.appendingPathComponent("Sources/Calc/Calc.swift"), atomically: true, encoding: .utf8)
                    try "import XCTest\n@testable import Calc\n\nfinal class CalcTests: XCTestCase {\n    func testAdd() { XCTAssertEqual(add(2, 3), 5) }\n}\n"
                        .write(to: workspace.appendingPathComponent("Tests/CalcTests/CalcTests.swift"), atomically: true, encoding: .utf8)
                },
                allow: { ["read_file", "list_dir", "find_files", "search_files", "propose_edit", "propose_patch",
                          "apply_edit", "verify_project", "update_plan", "list_checkpoints"].contains($0.toolName) },
                verify: { workspace, transcript in
                    let source = (try? String(contentsOf: workspace.appendingPathComponent("Sources/Calc/Calc.swift"), encoding: .utf8)) ?? ""
                    let checkpoints = (try? await WorkspaceCheckpointService(workspace: workspace.path).list()) ?? []
                    return ["passed": source.contains("a + b") && transcript.tools.contains("verify_project") &&
                                transcript.text.localizedCaseInsensitiveContains("pass"),
                            "verify_calls": transcript.tools.filter { $0 == "verify_project" }.count,
                            "checkpoints": checkpoints.count, "fixed": source.contains("a + b")]
                })
        case "calculator-agent":
            return Scenario(id: id,
                prompt: """
                Using the Calculator app, which is already open, compute 1234 × 56 and tell me the result Calculator displays. Work in the background with the bg_ tools: do not bring Calculator to the front.
                """,
                edits: false, commands: false, timeout: .seconds(300),
                prepare: { _ in
                    guard await RealAppProbe.launch("com.apple.calculator") != nil else { throw LiveScenarioError.preparation("Calculator") }
                    try? await Task.sleep(for: .seconds(2))
                },
                allow: { ["bg_list_windows", "bg_observe_window", "bg_click", "bg_press_key", "bg_click_sequence"].contains($0.toolName) },
                verify: { _, transcript in
                    let texts = await RealAppProbe.texts(of: "com.apple.calculator")
                    let digits = { (text: String) in text.filter(\.isNumber) }
                    let shown = texts.contains { digits($0) == "69104" }
                    let active = await RealAppProbe.isActive("com.apple.calculator")
                    return ["passed": shown && digits(transcript.text).contains("69104") && !active,
                            "calculator_shows_result": shown, "calculator_activated": active,
                            "clicks": transcript.tools.filter { $0 == "bg_click" }.count]
                })
        case "textedit-agent":
            return Scenario(id: id,
                prompt: """
                In TextEdit, the document notes-for-aim.txt is open. Without bringing TextEdit to the front, use the bg_ tools to add a new last line "- coffee" to the shopping list, keeping the existing lines, then tell me what the document now contains.
                """,
                edits: false, commands: false, timeout: .seconds(300),
                prepare: { workspace in
                    guard !(await RealAppProbe.isRunning("com.apple.TextEdit")) else { throw LiveScenarioError.preparation("close TextEdit first") }
                    let file = workspace.appendingPathComponent("notes-for-aim.txt")
                    try "Shopping list:\n- milk\n- bread".write(to: file, atomically: true, encoding: .utf8)
                    guard await RealAppProbe.launch("com.apple.TextEdit", opening: file) != nil else { throw LiveScenarioError.preparation("TextEdit") }
                    try? await Task.sleep(for: .seconds(2))
                },
                allow: { ["bg_list_windows", "bg_observe_window", "bg_click", "bg_type_text", "bg_set_value", "bg_press_key", "bg_click_sequence"].contains($0.toolName) },
                verify: { _, transcript in
                    let texts = await RealAppProbe.texts(of: "com.apple.TextEdit")
                    let document = texts.first { $0.contains("Shopping list:") } ?? ""
                    let lines = document.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    let active = await RealAppProbe.isActive("com.apple.TextEdit")
                    await RealAppProbe.quit("com.apple.TextEdit")
                    return ["passed": lines.contains("- milk") && lines.contains("- bread") && lines.last == "- coffee" && !active,
                            "document": document, "textedit_activated": active]
                })
        case "mail-send":
            // Opt-in only (not in the default list): a real email to the address given with --mail-to.
            guard let recipient = mailRecipient else { return nil }
            let subject = "AIM Agent test \(ISO8601DateFormatter().string(from: .now))"
            return Scenario(id: id,
                prompt: """
                Using Apple Mail, send a short plain-text test email to \(recipient) from the first configured account (find its account_id and address with mail_accounts). Use exactly this subject: \(subject)
                The body should be two sentences saying this is an automated test sent by the AIM agent and that no reply is needed. Then report which account sent it and the exact status AIM returned.
                """,
                edits: false, commands: false, timeout: .seconds(300),
                prepare: { _ in },
                allow: { approval in
                    switch approval.toolName {
                    case "mail_accounts", "mail_mailboxes", "mail_messages", "mail_search", "mail_get": return true
                    case "mail_send":
                        let to = approval.arguments["to"].flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
                        let others = ["cc", "bcc"].compactMap { approval.arguments[$0] }
                            .flatMap { (try? JSONDecoder().decode([String].self, from: Data($0.utf8))) ?? ["?"] }
                        return to == [recipient] && others.isEmpty && approval.arguments["subject"] == subject
                    default: return false
                    }
                },
                verify: { _, transcript in
                    let sent = transcript.approvals.contains { $0["tool"] as? String == "mail_send" && $0["allowed"] as? Bool == true }
                    return ["passed": sent && transcript.tools.contains("mail_send") && transcript.toolErrors == 0,
                            "subject": subject, "send_approved": sent]
                })
        default:
            return nil
        }
    }

    /// Recipient for "mail-send", from `--mail-to` (never stored in source; redacted from reports).
    static var mailRecipient: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--mail-to"), index + 1 < arguments.count,
              arguments[index + 1].contains("@") else { return nil }
        return arguments[index + 1]
    }

    static let scenarios = ["fixture-background", "workspace-file", "long-command", "mission-check", "mcp-note", "skill-use",
                            "subagent-writer", "web-research", "multi-file-refactor", "fix-and-verify", "subagent-research"]

    // MARK: Running

    @MainActor
    static func run(ids: [String], report: QualificationReport, model: AppModel, scenarioCap: Decimal?) async {
        guard localModelID != nil || authorizedCloudModels.contains(cloudModelID) else {
            report.set("conclusion", "Model outside the approved qualification scope."); return
        }
        let lock: Int32
        var ledgerFile: LiveBudgetFile
        do {
            lock = try LiveBudgetFile.acquireLock()
            do { ledgerFile = try LiveBudgetFile.load() }
            catch { close(lock); throw error }
        } catch {
            report.set("conclusion", "Qualification budget unavailable; no model request admitted."); return
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        // A temporary override: the person's own local-model setting is restored afterwards.
        let savedLocalBase = UserDefaults.standard.string(forKey: "AIMLocalModelBaseURL")
        defer { UserDefaults.standard.set(savedLocalBase, forKey: "AIMLocalModelBaseURL") }
        if let raw = argument("--local-base-url"), let url = URL(string: raw) { LocalModelEndpoint.baseURL = url }
        report.set("model", modelID)
        report.set("provider", provider.rawValue)
        report.set("envelope_usd", "\(envelopeUSD)")
        report.set("spent_before_usd", "\(ledgerFile.confirmedUSD)")
        var results: [String: Any] = [:]
        for id in ids {
            guard let scenario = scenario(id) else {
                results[id] = ["passed": false, "error": "unknown scenario"]
                continue
            }
            let remaining = envelopeUSD - ledgerFile.confirmedUSD - ledgerFile.reservedUSD
            let cap = min(scenarioCap ?? defaultScenarioCapUSD, remaining)
            guard cap > Decimal(string: "0.05")! else {
                results[id] = ["passed": false, "error": "live qualification envelope exhausted"]
                continue
            }
            // Durable worst-case reservation precedes every run. On crash or an
            // uncertain billable result the reservation is retained, never zeroed.
            ledgerFile.reservedUSD += cap
            do { try ledgerFile.save() }
            catch { results[id] = ["passed": false, "error": "budget reservation could not be persisted"]; break }
            let outcome = await runOne(scenario, cap: cap, model: model)
            // unknownAttempts counts unbounded exposure only. An unknown but
            // bounded attempt remains in reservedUSD and must retain this cap.
            if outcome.unknownAttempts == 0 && outcome.reservedUSD == 0 { ledgerFile.reservedUSD -= cap }
            ledgerFile.confirmedUSD += outcome.confirmedUSD
            ledgerFile.unknownAttempts += outcome.unknownAttempts
            ledgerFile.runs.append(["scenario": id, "at": ISO8601DateFormatter().string(from: .now),
                                    "confirmed_usd": "\(outcome.confirmedUSD)", "unknown_attempts": outcome.unknownAttempts,
                                    "native_reserved_usd": "\(outcome.reservedUSD)"])
            do { try ledgerFile.save() }
            catch { report.set("conclusion", "Budget settlement persistence failed; stop qualification."); break }
            results[id] = outcome.fields
            report.set("scenarios", results)
            report.set("spent_after_usd", "\(ledgerFile.confirmedUSD)")
            report.checkpoint()
        }
        let failed = results.filter { ($0.value as? [String: Any])?["passed"] as? Bool != true }.map(\.key).sorted()
        report.set("conclusion", failed.isEmpty ? "all live scenarios passed (\(results.count))" :
            "failed: \(failed.joined(separator: ", "))")
    }

    struct Outcome {
        var fields: [String: Any]
        var confirmedUSD: Decimal
        var unknownAttempts: Int
        var reservedUSD: Decimal = 0
    }

    @MainActor
    private static func runOne(_ scenario: Scenario, cap: Decimal, model: AppModel) async -> Outcome {
        var fields: [String: Any] = ["cap_usd": "\(cap)"]
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("aim-live-\(scenario.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try await scenario.prepare(workspace)
        } catch {
            fields["passed"] = false
            fields["error"] = "preparation failed: \(error)"
            return Outcome(fields: fields, confirmedUSD: 0, unknownAttempts: 0)
        }
        let database: AIMDatabase
        do { database = try AIMDatabase(inMemory: true) } catch {
            fields["passed"] = false
            fields["error"] = "database: \(error)"
            return Outcome(fields: fields, confirmedUSD: 0, unknownAttempts: 0)
        }
        let conversations = SQLiteConversationRepository(database: database)
        let ledger = SQLiteGlobalSpendLedger(database: database)
        do { try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "\(cap)", period: .envelope)) }
        catch {
            fields["passed"] = false
            fields["error"] = "financial policy preparation failed before model send: \(error)"
            return Outcome(fields: fields, confirmedUSD: 0, unknownAttempts: 0)
        }
        let exceptions = SpendExceptionBroker()
        let approvals = ToolApprovalBroker()
        let questions = AgentQuestionBroker()
        let missions = SQLiteAgentMissionRepository(database: database)
        let connectors = SQLiteMCPServerRepository(database: database)
        if scenario.id == "mcp-note", let fixture = MCPQualification.fixtureConfiguration() {
            try? await connectors.save(fixture)
        }
        let runner = ProviderTurnRunner(repository: conversations, secureStore: model.scopedProviderCredentials(),
            approvals: approvals, runRepository: SQLiteWorkspaceRunRepository(database: database),
            questionBroker: questions, missionRepository: missions,
            subagentJobRepository: SQLiteSubagentJobRepository(database: database),
            spendMeter: BillableRequestMeter(ledger: ledger, exceptions: exceptions),
            cuaQualificationRepository: model.cuaQualificationRepository, mcpServerRepository: connectors,
            subagentWorkspaceRepository: SQLiteSubagentWorkspaceRepository(database: database))

        let conversationID = UUID()
        do {
            try await conversations.save(Conversation(id: conversationID, title: "[AIM live] \(scenario.id)",
                mode: .agent, provider: provider, modelID: modelID, workspacePath: workspace.path))
            try await conversations.append(ConversationMessage(conversationID: conversationID, role: .user,
                content: scenario.prompt, sequence: 0))
        } catch {
            fields["passed"] = false
            fields["error"] = "conversation: \(error)"
            return Outcome(fields: fields, confirmedUSD: 0, unknownAttempts: 0)
        }

        let transcript = TranscriptBox()
        // Scripted policy: exact allowed actions only; everything else is denied and recorded.
        let approvalTask = Task {
            for await pending in await approvals.updates() {
                for approval in pending {
                    let allowed = scenario.allow(approval)
                    transcript.record(approval: ["tool": approval.toolName, "allowed": allowed,
                        "review": approval.review.map { "\($0.path) | \($0.before) → \($0.after)" } ?? NSNull()])
                    await approvals.decide(id: approval.id, sessionID: approval.sessionID,
                        decision: allowed ? .allowOnce : .deny)
                }
            }
        }
        // The approved envelope is strict: an unverified cost must not bypass it.
        let spendTask = Task {
            for await pending in await exceptions.updates() {
                for exception in pending { await exceptions.decide(id: exception.id, allow: false) }
            }
        }
        let questionTask = Task {
            for await pending in await questions.updates() {
                for question in pending {
                    await questions.answer(question.id, text: "No further input is available; proceed with what you can verify.")
                }
            }
        }
        let request = AgentRequest(conversationID: conversationID, text: scenario.prompt, modelID: modelID, mode: .agent,
            workspacePath: workspace.path, provider: provider, workspaceToolsEnabled: true,
            workspaceEditsEnabled: scenario.edits, workspaceCommandsEnabled: scenario.commands,
            approvalPolicy: .alwaysAsk, memoryEnabled: false, modelSupportsImages: provider != .local)
        let started = ContinuousClock.now
        let startedAt = Date.now
        let consume = Task {
            do {
                for try await event in runner.run(request) {
                    switch event {
                    case .textDelta(_, let text): transcript.append(text: text)
                    case .toolStartedDetailed(_, _, let name, _), .toolStarted(_, _, let name): transcript.append(tool: name)
                    case .toolFinished(_, _, let isError): if isError { transcript.toolError() }
                    case .failed(_, let diagnostic): transcript.fail(diagnostic.message)
                    case .completed: transcript.complete()
                    default: break
                    }
                }
            } catch {
                transcript.fail(error.localizedDescription)
            }
        }
        let timeout = Task {
            try? await Task.sleep(for: scenario.timeout)
            guard !Task.isCancelled else { return }
            transcript.fail("Scenario deadline exceeded; execution cancelled.")
            consume.cancel()
            await runner.cancel(conversationID: conversationID)
        }
        _ = await consume.value
        timeout.cancel()
        approvalTask.cancel(); spendTask.cancel(); questionTask.cancel()
        await approvals.close(sessionID: conversationID)

        var result = transcript.snapshot()
        result.missionState = try? await missions.latest(conversationID: conversationID)?.state.rawValue
        let verification = await scenario.verify(workspace, result)
        let snapshot = try? await ledger.snapshot(at: .now)
        let confirmed = Decimal(string: snapshot?.confirmedUSD ?? "0") ?? 0
        // Missing/corrupt snapshot retains the complete scenario reservation.
        let reserved = snapshot.flatMap { Decimal(string: $0.reservedUSD) } ?? cap
        fields.merge(verification) { _, new in new }
        fields["passed"] = (verification["passed"] as? Bool == true) && result.failure == nil
        fields["duration_seconds"] = Double((ContinuousClock.now - started).components.seconds)
        fields["tools"] = result.tools
        fields["tool_errors"] = result.toolErrors
        fields["approvals"] = result.approvals
        fields["failure"] = result.failure ?? NSNull()
        fields["answer"] = String(result.text.suffix(1_500))
        fields["confirmed_usd"] = snapshot?.confirmedUSD ?? "unknown"
        fields["unknown_cost_attempts"] = snapshot?.unknownAttempts ?? -1
        fields["reserved_usd"] = snapshot?.reservedUSD ?? "unknown"
        // Billing metadata only (no prompts): which attempt kept a reservation, and why.
        fields["attempts"] = ((try? await ledger.recentAttempts(limit: 100)) ?? []).reversed().map {
            ["feature": $0.feature, "state": $0.state.rawValue, "maximum_usd": $0.maximumUSD ?? "none", "actual_usd": $0.actualUSD ?? "none",
             "at_seconds": Int($0.createdAt.timeIntervalSince(startedAt))] as [String: Any]
        }
        fields["mission_state"] = result.missionState ?? NSNull()
        try? FileManager.default.removeItem(at: workspace)
        if let recipient = mailRecipient, let data = try? JSONSerialization.data(withJSONObject: fields),
           let redacted = try? JSONSerialization.jsonObject(with: Data(String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: recipient, with: "<recipient>").utf8)) as? [String: Any] {
            fields = redacted
        }
        return Outcome(fields: fields, confirmedUSD: confirmed, unknownAttempts: snapshot?.unknownAttempts ?? 1, reservedUSD: reserved)
    }
}

enum LiveScenarioError: Error { case fixtureUnavailable, preparation(String) }

/// Thread-safe accumulation of streamed events.
private final class TranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = LiveScenarioRunner.Transcript()
    func append(text: String) { lock.withLock { value.text += text } }
    func append(tool: String) { lock.withLock { value.tools.append(tool) } }
    func toolError() { lock.withLock { value.toolErrors += 1 } }
    func record(approval: [String: Any]) { lock.withLock { value.approvals.append(approval) } }
    func fail(_ message: String) { lock.withLock { value.failure = value.failure ?? message } }
    func complete() { lock.withLock { value.completed = true } }
    func snapshot() -> LiveScenarioRunner.Transcript { lock.withLock { value } }
}

/// Cumulative live-test spending for this checkout, kept beside the build.
struct LiveBudgetFile {
    var confirmedUSD: Decimal = 0
    var reservedUSD: Decimal = 0
    var unknownAttempts = 0
    var runs: [[String: Any]] = []

    static var url: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("qualification-reports", isDirectory: true)
            .appendingPathComponent("live-budget.json")
    }

    static func acquireLock() throws -> Int32 {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appending(path: "live-budget.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw CocoaError(.fileLocking) }
        return fd
    }

    static func load() throws -> LiveBudgetFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return LiveBudgetFile() }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) < 1_048_576,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let confirmed = Decimal(string: object["confirmed_usd"] as? String ?? ""), confirmed >= 0,
              let unknown = object["unknown_attempts"] as? Int, unknown >= 0,
              let runs = object["runs"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        // Legacy unknown-cost entries had no reservation. Hold the whole envelope
        // until their charges are reconciled rather than permitting new tests.
        let reserved = Decimal(string: object["reserved_usd"] as? String ?? (unknown == 0 ? "0" : "10"))
        guard let reserved, reserved >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        return LiveBudgetFile(confirmedUSD: confirmed, reservedUSD: reserved, unknownAttempts: unknown, runs: runs)
    }

    func save() throws {
        let object: [String: Any] = ["confirmed_usd": "\(confirmedUSD)", "reserved_usd": "\(reservedUSD)", "unknown_attempts": unknownAttempts, "runs": runs]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
        let fd = open(Self.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let parent = open(Self.url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Scheduler/learning probes share the same durable envelope as interactive
/// probes. An incomplete probe retains its complete reservation after restart.
@MainActor
final class LiveBudgetReservation {
    private let descriptor: Int32
    private let cap: Decimal
    private var budget: LiveBudgetFile
    init(cap: Decimal) throws {
        guard LiveScenarioRunner.authorizedCloudModels.contains(LiveScenarioRunner.cloudModelID), cap > 0 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let fd = try LiveBudgetFile.acquireLock()
        do {
            var saved = try LiveBudgetFile.load()
            guard saved.confirmedUSD + saved.reservedUSD + cap <= LiveScenarioRunner.envelopeUSD else { throw CocoaError(.validationNumberTooLarge) }
            saved.reservedUSD += cap
            try saved.save()
            descriptor = fd; self.cap = cap; budget = saved
        } catch { close(fd); throw error }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    func settle(scenario: String, confirmed: Decimal, unknown: Int, reserved: Decimal?) throws -> Decimal {
        guard confirmed >= 0, unknown >= 0, reserved.map({ !$0.isNaN && $0 >= 0 }) ?? true else { throw CocoaError(.validationNumberTooSmall) }
        // Keep the entire scenario cap on any unsettled exposure (including
        // bounded unknown) or an unavailable snapshot. No zero-cost inference.
        if unknown == 0 && reserved == 0 { budget.reservedUSD -= cap }
        budget.confirmedUSD += confirmed; budget.unknownAttempts += unknown
        budget.runs.append(["scenario": scenario, "at": ISO8601DateFormatter().string(from: .now),
            "confirmed_usd": "\(confirmed)", "unknown_attempts": unknown,
            "native_reserved_usd": reserved.map { "\($0)" } ?? "unknown"])
        try budget.save()
        return budget.confirmedUSD
    }
}

/// Host-side checks on real apps for live scenarios: launch without activating,
/// read visible text through AIM's own Accessibility access, quit what a scenario opened.
enum RealAppProbe {
    @MainActor
    static func launch(_ bundleID: String, opening file: URL? = nil) async -> NSRunningApplication? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        if let file { return try? await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration) }
        return try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    @MainActor static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @MainActor static func isActive(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.isActive }
    }

    @MainActor static func quit(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.forceTerminate() }
    }

    /// Values of static texts and text areas in the app's windows (bounded walk).
    @MainActor static func texts(of bundleID: String) -> [String] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var found: [String] = []
        var visited = 0
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 14, visited < 3_000 else { return }
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if ["AXStaticText", "AXTextArea", "AXTextField"].contains(role), let value = attribute(element, kAXValueAttribute) as? String {
                found.append(value)
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] { walk(window, depth: 0) }
        return found
    }
}
#endif
