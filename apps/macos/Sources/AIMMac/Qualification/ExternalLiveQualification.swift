#if DEBUG
import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// A real mission through Hermes or OpenClaw, driven like a person would in the test bundle:
/// Agent mode, the engine selected, a disposable folder, Auto approvals, one message. It checks
/// that the engine used AIM's tools (web and files), that its actions are visible, and that the
/// task ends without a person. Each mission is capped and recorded in the live envelope.
enum ExternalLiveQualification {
    /// `--delegate`: the engine's own sub-agents (Hermes) do two searches in parallel.
    static let delegatePrompt = """
    Lis le fichier notes.txt de ce dossier. Puis délègue deux sous-agents en parallèle : le premier cherche sur le web \
    la date de sortie du modèle Jev de TypeSafe AI, le second cherche le montant de la levée de fonds seed de TypeSafe AI. \
    Avec leurs rapports, écris un fichier resume.md de trois lignes : le contenu de notes.txt, la date, le montant. \
    Termine par une phrase qui dit ce que tu as fait.
    """
    static let prompt = """
    Lis le fichier notes.txt de ce dossier. Puis cherche sur le web la date de sortie du modèle Jev de TypeSafe AI. \
    Écris ensuite un fichier resume.md de trois lignes : le contenu de notes.txt, la date trouvée et l'URL de ta source. \
    Termine par une phrase qui dit ce que tu as fait.
    """

    @MainActor
    static func run(into report: QualificationReport, model candidate: AppModel) async {
        // Drive the model the window started, which owns the durable runtime and the agents.
        for _ in 0..<60 where AppModel.started == nil { try? await Task.sleep(for: .seconds(1)) }
        let model = AppModel.started ?? candidate
        let arguments = ProcessInfo.processInfo.arguments
        let engines = (arguments.firstIndex(of: "--engines").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "hermes,openclaw")
            .split(separator: ",").compactMap { AgentEngineID(rawValue: String($0)) }
        let cap = Decimal(string: LiveScenarioRunner.argument("--spend-cap-usd") ?? "0.8") ?? 0.8
        let delegate = arguments.contains("--delegate")
        // The app finishes starting (engines, account, runtime) before the scripted person types.
        for _ in 0..<90 {
            await model.refreshEngineStatuses()
            let installed = Set(model.engineStatuses.filter(\.isInstalled).map(\.id))
            if model.account.accessUser != nil, engines.allSatisfy(installed.contains) { break }
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: .seconds(3))
        report.set("engines_seen", model.engineStatuses.filter(\.isInstalled).map(\.id.rawValue))
        report.set("signed_in", model.account.accessUser != nil)
        report.set("start", model.startDiagnostics)
        if let paths = try? ApplicationPaths() {
            let installer = UpstreamAgentInstaller(root: paths.applicationSupport.appending(path: "Agents"))
            var direct: [String: String] = ["root": paths.applicationSupport.path]
            for engine in engines {
                do { direct[engine.rawValue] = try await installer.installation(engine).map { "\($0.version) update=\($0.updateAvailable)" } ?? "nil" }
                catch { direct[engine.rawValue] = "error: \(error.localizedDescription)" }
            }
            report.set("installer_direct", direct)
        }
        report.set("install_errors", model.agentInstallErrors.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value })
        report.set("statuses", model.engineStatuses.map { "\($0.id.rawValue):\($0.state):\($0.isInstalled)" })
        let savedEngine = model.selectedAgentEngineID
        var results: [String: Any] = [:]
        for engine in engines {
            results[engine.rawValue] = await mission(engine, cap: cap, model: model, delegate: delegate)
            report.set("engines", results); report.checkpoint()
        }
        await model.newConversation()
        model.selectAgentEngine(savedEngine)
        let failed = results.filter { ($0.value as? [String: Any])?["passed"] as? Bool != true }.map(\.key).sorted()
        report.set("conclusion", failed.isEmpty ? "external missions passed (\(results.count))" : "failed: " + failed.joined(separator: ", "))
    }

    @MainActor
    private static func mission(_ engine: AgentEngineID, cap: Decimal, model: AppModel, delegate: Bool) async -> [String: Any] {
        let prompt = delegate ? delegatePrompt : prompt
        var fields: [String: Any] = ["cap_usd": "\(cap)"]
        guard model.engineStatuses.first(where: { $0.id == engine })?.isInstalled == true else {
            fields["passed"] = false; fields["error"] = "engine not installed"; return fields
        }
        let reservation: LiveBudgetReservation
        do { reservation = try LiveBudgetReservation(cap: cap) }
        catch { fields["passed"] = false; fields["error"] = "live envelope has no room for this mission"; return fields }
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-external-\(engine.rawValue)-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath().standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "Le projet AIM teste un agent externe.".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        } catch { fields["passed"] = false; fields["error"] = "fixture: \(error)"; return fields }
        defer { try? FileManager.default.removeItem(at: folder) }

        for _ in 0..<120 where model.isSending { try? await Task.sleep(for: .seconds(1)) }
        model.selectMode(.agent)
        await model.newConversation()
        model.selectProvider(.openRouter)
        model.selectModel(LiveScenarioRunner.cloudModelID)
        model.selectAgentEngine(engine)
        model.workspacePath = folder.path
        model.workspaceToolsEnabled = true
        model.workspaceEditsEnabled = true
        model.workspaceCommandsEnabled = false
        model.approvalPolicy = .autoApprove
        let before = (try? await model.spendLedger.snapshot()).flatMap { Decimal(string: $0.countedUSD) } ?? 0
        let started = Date.now
        model.composerText = prompt
        await model.sendComposer()
        // The previous answer may still be saving: like a person, wait and press Send again.
        for _ in 0..<30 where model.selectedConversationID == nil {
            model.alertMessage = nil
            try? await Task.sleep(for: .seconds(1))
            if model.composerText.isEmpty { model.composerText = prompt }
            await model.sendComposer()
        }
        fields["sent"] = model.selectedConversationID != nil
        if let alert = model.alertMessage { fields["alert"] = alert }
        var approvals: [String] = []
        var stoppedForCap = false
        var state = "unknown", reason = ""
        while Date.now.timeIntervalSince(started) < 600 {
            try? await Task.sleep(for: .seconds(1))
            // Auto still asks for some actions; the scripted person allows them once and records which.
            for approval in model.pendingToolApprovals where model.selectedConversationID != nil {
                approvals.append(approval.toolName)
                await model.decideToolApproval(approval, decision: .allowOnce)
            }
            let spent = (try? await model.spendLedger.snapshot()).flatMap { Decimal(string: $0.countedUSD) }.map { $0 - before } ?? 0
            if spent > cap { stoppedForCap = true; await model.controlContinuityExecution(.cancel); break }
            if let execution = model.selectedContinuityExecution {
                state = execution.state.rawValue; reason = execution.reason ?? ""
                if execution.state.isTerminal || [.waitingUser, .blocked, .awaitingReview].contains(execution.state) { break }
            }
        }
        try? await Task.sleep(for: .seconds(2))
        let spent = (try? await model.spendLedger.snapshot()).flatMap { Decimal(string: $0.countedUSD) }.map { $0 - before } ?? cap
        _ = try? reservation.settle(scenario: "external-" + engine.rawValue, confirmed: max(0, spent), unknown: 0, reserved: 0)
        // The turn finishes saving, then the conversation is reopened as a person would see it
        // (actions are projected from the task's journal).
        for _ in 0..<60 where model.isSending { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(2))
        let conversation = model.selectedConversationID
        await model.selectConversation(conversation)
        let assistant = model.messages.last { $0.role == .assistant }
        // What the conversation lists under the answer: the task's action journal.
        let tools = model.workspaceHistory.filter { $0.run.conversationID == conversation?.uuidString }.flatMap(\.calls).map(\.name)
        let summary = (try? String(contentsOf: folder.appending(path: "resume.md"), encoding: .utf8)) ?? ""
        fields["state"] = state; fields["reason"] = reason
        fields["seconds"] = Int(Date.now.timeIntervalSince(started))
        fields["spent_usd"] = "\(spent)"; fields["stopped_for_cap"] = stoppedForCap
        fields["tools"] = tools; fields["approvals"] = approvals
        fields["answer"] = String((assistant?.content ?? "").suffix(1_200))
        fields["resume_md"] = String(summary.prefix(600))
        // The engine's sub-agents, as the Sub-agents panel shows them.
        var children: [SubagentSnapshot] = []
        if let conversation { children = await model.subagents(conversationID: conversation) }
        fields["subagents"] = children.map { ["title": $0.title, "state": $0.state.rawValue, "model": $0.modelID ?? "",
                                              "journal_entries": $0.entries.count, "result": String(($0.result ?? "").prefix(300))] as [String: Any] }
        let delegated = children.count >= 2 && children.allSatisfy { $0.state == .accepted && !($0.result ?? "").isEmpty }
        fields["passed"] = state == "accepted" && summary.contains("Le projet AIM") && !stoppedForCap
            && (delegate ? delegated && tools.contains("delegate_task") : tools.contains("web_search"))
        return fields
    }
}
#endif
