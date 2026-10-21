#if DEBUG
import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// Round 36 capability campaign: real missions (Claude Sonnet 5.5, Auto) for each family of tools,
/// for AIM's agent, Hermes and OpenClaw, driven like a person in the Test bundle. Each mission is
/// capped and recorded in the live envelope; the report is a capability matrix (passed / failed per
/// agent and family, with its cost).
///
/// `--capabilities <group>`: `safe` (nothing visible to the person but a background Calculator
/// window; test items created then deleted), `memory-read` (after an app restart: a new conversation
/// must know what an earlier one memorized; then the test memories are deleted), `intrusive`
/// (announced to the person first: their Chrome on a public page, the real pointer in TextEdit, a
/// link opened). `--only id1,id2` narrows a group.
enum CapabilityQualification {
    struct Outcome {
        var folder: URL
        var answer: String
        var tools: [String]
        var model: AppModel
    }

    struct Mission {
        var id: String
        var engine: AgentEngineID
        var family: String
        var prompt: String
        var cap: Decimal
        /// Each group needs at least one of its tools in the task's journal.
        var required: [[String]]
        /// nil when the mission's own result is right; otherwise why not.
        var check: @MainActor (Outcome) async -> String?
        /// Approvals left to the person at the Mac (the script never decides them).
        var personApproves: Set<String> = []
    }

    /// Never allowed by the scripted person, whatever the mission says.
    static let refused: Set<String> = ["mail_send", "mail_delete", "mail_move", "messages_send", "messages_read", "calendar_update",
                                       "reminders_update", "notes_replace", "notes_append", "trash_file"]
    static let memoryMarker = "ORION-36"

    /// Only the person's own handle, compared on its last nine digits (0785… and +33785… alike).
    static func isSelf(_ recipient: String?) -> Bool {
        func digits(_ text: String?) -> String { String((text ?? "").filter(\.isNumber).suffix(9)) }
        let own = digits(LiveScenarioRunner.argument("--self-handle"))
        return own.count == 9 && digits(recipient) == own
    }
    /// Reports never keep the person's handle.
    static func redacted(_ text: String) -> String {
        guard let handle = LiveScenarioRunner.argument("--self-handle"), !handle.isEmpty else { return text }
        let own = String(handle.filter(\.isNumber).suffix(9))
        var result = text.replacingOccurrences(of: handle, with: "[own number]")
        if own.count == 9 {
            let pattern = own.map(String.init).joined(separator: "[ .-]?")
            result = result.replacingOccurrences(of: "(\\+33[ .-]?|0)?" + pattern, with: "[own number]", options: .regularExpression)
        }
        return result
    }

    static func answer(_ needle: String...) -> @MainActor (Outcome) async -> String? {
        { outcome in
            let folded = outcome.answer.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let missing = needle.filter { !folded.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
            return missing.isEmpty ? nil : "answer lacks " + missing.joined(separator: ", ")
        }
    }

    static func missions(_ group: String) -> [Mission] {
        let calculator = """
        Ouvre l'application Calculatrice avec open_app sans l'activer (activate false), puis travaille en arrière-plan avec \
        les outils bg_ : observe sa fenêtre avec bg_observe_window (include_screenshot true), calcule 12 × 7 en cliquant ses \
        boutons, observe de nouveau et dis le résultat affiché à l'écran. Ne bouge pas le pointeur de la personne.
        """
        switch group {
        case "safe":
            return [
                Mission(id: "aim-web-files", engine: .aim, family: "web + files", prompt: """
                Lis le fichier notes.txt de ce dossier. Cherche sur le web la date de sortie du modèle Jev de TypeSafe AI \
                et lis la page source. Écris un fichier resume.md de trois lignes : le contenu de notes.txt, la date et l'URL lue.
                """, cap: 0.5, required: [["web_search"], ["web_fetch"], ["propose_file", "apply_edit", "write_file"]]) { outcome in
                    let text = (try? String(contentsOf: outcome.folder.appending(path: "resume.md"), encoding: .utf8)) ?? ""
                    return text.contains("Le projet AIM") ? nil : "resume.md missing or without notes.txt content"
                },
                Mission(id: "aim-apple-apps", engine: .aim, family: "Notes, Reminders, Calendar (create + delete)", prompt: """
                Test d'outils, sans rien laisser derrière toi et uniquement dans les éléments de test : crée un rappel intitulé \
                « AIM-TEST-36 rappel » dans la liste de rappels « AIM Test », vérifie qu'il existe puis supprime-le. Crée une \
                note intitulée « AIM-TEST-36 note » dans le dossier Notes « AIM Test », vérifie-la puis supprime-la. Crée un \
                événement « AIM-TEST-36 événement » demain de 9 h à 9 h 15 dans le calendrier « AIM Test », vérifie-le puis \
                supprime-le. Si une liste, un dossier ou un calendrier « AIM Test » manque, n'utilise rien d'autre : dis-le. \
                Termine par une ligne par élément : créé puis supprimé, ou le problème rencontré.
                """, cap: 0.6, required: [["reminders_create"], ["reminders_delete"], ["notes_create"], ["notes_delete"],
                                          ["calendar_create"], ["calendar_delete"]], check: { _ in nil }),
                Mission(id: "aim-read-apps", engine: .aim, family: "Mail, Contacts, Calendar (read)", prompt: """
                Test de lecture, sans rien modifier ni citer de contenu privé : combien de messages compte la boîte de réception \
                de Mail parmi les plus récents que tu peux lister, combien de contacts trouves-tu pour la recherche « Apple », \
                et combien d'événements ai-je aujourd'hui ? Réponds seulement par trois nombres avec leur libellé.
                """, cap: 0.4, required: [["mail_messages", "mail_search", "mail_mailboxes"], ["contacts_search"],
                                          ["calendar_events"]], check: { _ in nil }),
                Mission(id: "aim-script-schedule", engine: .aim, family: "AppleScript + scheduled tasks", prompt: """
                Avec run_applescript, donne le nom du disque de démarrage (tell application "Finder" to get name of startup disk). \
                Puis programme une tâche quotidienne à 7 h intitulée « AIM-TEST-36 tâche » avec la consigne « dire bonjour », \
                vérifie qu'elle est listée, puis annule-la. Réponds en deux lignes.
                """, cap: 0.4, required: [["run_applescript"], ["schedule_task"], ["cancel_scheduled_task"]]) { outcome in
                    let left = ((try? await outcome.model.schedulerRepository.list()) ?? []).filter { $0.title.contains("AIM-TEST-36") && $0.state == .enabled }
                    return left.isEmpty ? nil : "the test task is still scheduled"
                },
                Mission(id: "aim-memory-write", engine: .aim, family: "memory (write)", prompt: """
                Retiens que le nom de code du test AIM est \(memoryMarker). Enregistre aussi avec ton outil mémoire que la couleur \
                du test AIM est le vert émeraude. Réponds en une phrase.
                """, cap: 0.3, required: [["memory_save"]]) { outcome in
                    // "Retiens que…" is captured after the answer, by a light model.
                    for _ in 0..<90 {
                        await outcome.model.loadMemories()
                        if outcome.model.memories.contains(where: { $0.content.contains(memoryMarker) && $0.status == .verified }) { return nil }
                        try? await Task.sleep(for: .seconds(1))
                    }
                    return "the remembered fact was not saved as a reviewed memory"
                },
                Mission(id: "hermes-background-vision", engine: .hermes, family: "background control + screenshots",
                        prompt: calculator, cap: 0.6, required: [["bg_observe_window"], ["bg_click", "bg_click_sequence"]],
                        check: answer("84")),
                Mission(id: "openclaw-background-vision", engine: .openClaw, family: "background control + screenshots",
                        prompt: calculator, cap: 0.7, required: [["bg_observe_window"], ["bg_click", "bg_click_sequence"]],
                        check: answer("84")),
                Mission(id: "hermes-memory-plan", engine: .hermes, family: "memory (write) + plan", prompt: """
                Fais un plan de deux étapes avec update_plan, puis enregistre avec ton outil mémoire que l'outil de test préféré \
                de l'équipe AIM est HERMES-36-MARTEAU, puis marque le plan terminé. Réponds en une phrase.
                """, cap: 0.4, required: [["memory_save"], ["update_plan"]], check: { _ in nil }),
                Mission(id: "openclaw-memory-plan", engine: .openClaw, family: "memory (write) + plan", prompt: """
                Fais un plan de deux étapes avec update_plan, puis enregistre avec ton outil mémoire que le carnet de test de \
                l'équipe AIM s'appelle HERMES-36-CARNET, puis marque le plan terminé. Réponds en une phrase.
                """, cap: 0.5, required: [["memory_save"], ["update_plan"]], check: { _ in nil }),
            ]
        case "memory-read":
            let question = "Quel est le nom de code du test AIM et quelle est la couleur du test AIM ? Réponds en une ligne, sans outil."
            return [AgentEngineID.aim, .hermes, .openClaw].map { engine in
                Mission(id: "\(engine.rawValue)-memory-recall", engine: engine, family: "memory (recall after restart)",
                        prompt: question, cap: 0.3, required: [], check: answer(memoryMarker, "meraude"))
            }
        case "intrusive":
            return [
                Mission(id: "aim-chrome", engine: .aim, family: "the person's Chrome (public page, read only)", prompt: """
                Dans mon Chrome, ouvre https://example.com, lis la page et donne son titre principal. Ne clique sur rien d'autre.
                """, cap: 0.4, required: [["browser_navigate"], ["browser_snapshot", "browser_find"]], check: answer("Example Domain")),
                Mission(id: "aim-desktop-pointer", engine: .aim, family: "real pointer and keyboard (TextEdit)", prompt: """
                Ouvre TextEdit avec un nouveau document vide, puis avec les outils desktop_ (le vrai pointeur) tape exactement \
                « AIM-TEST-36 souris » dans le document et relis la fenêtre pour vérifier. N'enregistre pas le document.
                """, cap: 0.6, required: [["desktop_type", "desktop_set_value", "desktop_click"]], check: { _ in nil }),
                // The person's own handle is given at launch (`--self-handle`), never written in source or reports.
                Mission(id: "aim-imessage", engine: .aim, family: "iMessage send (to the person themself)", prompt: """
                Envoie un iMessage au numéro \(LiveScenarioRunner.argument("--self-handle") ?? "(absent)") avec exactement le texte \
                « AIM-TEST-36 : message de test envoyé par l'agent AIM à ta demande. » N'envoie rien à personne d'autre. \
                Dis-moi ensuite en une phrase si le message est parti.
                """, cap: 0.3, required: [["messages_send"]], check: { _ in nil }),
                // Round 37 hand-over: the person keeps using the mouse; AIM must ask them to hand over
                // control (notification + approval) and wait, never abandon. The person approves.
                Mission(id: "aim-takeover", engine: .aim, family: "take-control request while the person uses the Mac", prompt: """
                Ouvre TextEdit avec un nouveau document vide. Puis, avec le vrai pointeur (desktop_click dans la zone de texte, \
                puis desktop_type), tape exactement « AIM-TEST-37 prise de contrôle ». Relis la fenêtre pour vérifier. \
                N'enregistre pas le document.
                """, cap: 1.2, required: [["desktop_click"], ["desktop_type"]], check: { _ in nil },
                personApproves: ["desktop_click", "desktop_type", "desktop_focus_window", "desktop_press", "desktop_set_value",
                                 "desktop_key", "desktop_move", "desktop_scroll", "desktop_drag"]),
                Mission(id: "aim-open-url", engine: .aim, family: "open a link", prompt: """
                Ouvre le lien https://example.com dans mon navigateur par défaut avec open_url, puis dis-moi que c'est fait.
                """, cap: 0.2, required: [["open_url"]], check: { _ in nil }),
            ]
        default:
            return []
        }
    }

    @MainActor
    static func run(into report: QualificationReport, model candidate: AppModel) async {
        for _ in 0..<60 where AppModel.started == nil { try? await Task.sleep(for: .seconds(1)) }
        let model = AppModel.started ?? candidate
        let group = LiveScenarioRunner.argument("--capabilities") ?? "safe"
        let only = LiveScenarioRunner.argument("--only").map { Set($0.split(separator: ",").map(String.init)) }
        let selected = missions(group).filter { only?.contains($0.id) ?? true }
        let engines = Set(selected.map(\.engine)).filter { $0 != .aim }
        for _ in 0..<90 {
            await model.refreshEngineStatuses()
            let installed = Set(model.engineStatuses.filter(\.isInstalled).map(\.id))
            if model.account.accessUser != nil, engines.allSatisfy(installed.contains) { break }
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: .seconds(3))
        report.set("group", group)
        report.set("signed_in", model.account.accessUser != nil)
        report.set("engines_installed", model.engineStatuses.filter(\.isInstalled).map(\.id.rawValue))
        report.set("memory_probe", await model.memoryProbe())
        report.set("start", model.startDiagnostics)
        report.set("model", LiveScenarioRunner.cloudModelID)
        let savedEngine = model.selectedAgentEngineID
        var results: [[String: Any]] = []
        for mission in selected {
            var fields = await run(mission, model: model)
            fields["id"] = mission.id; fields["agent"] = mission.engine.rawValue; fields["family"] = mission.family
            results.append(fields)
            report.set("missions", results); report.checkpoint()
        }
        if group == "memory-read" { report.set("memory_cleanup", await deleteTestMemories(model)) }
        await model.newConversation()
        model.selectAgentEngine(savedEngine)
        report.set("matrix", results.map { ["agent": $0["agent"] ?? "", "family": $0["family"] ?? "",
                                             "result": ($0["passed"] as? Bool == true) ? "passed" : "failed",
                                             "cost_usd": $0["spent_usd"] ?? "", "why": $0["failure"] ?? ""] })
        let failed = results.filter { $0["passed"] as? Bool != true }.compactMap { $0["id"] as? String }
        report.set("conclusion", failed.isEmpty ? "\(results.count) missions passed" : "failed: " + failed.joined(separator: ", "))
    }

    /// The memories this campaign wrote are removed from the person's memory afterwards.
    @MainActor
    static func deleteTestMemories(_ model: AppModel) async -> [String] {
        await model.loadMemories()
        let markers = [memoryMarker, "émeraude", "emeraude", "HERMES-36"]
        let test = model.memories.filter { item in markers.contains { item.content.localizedCaseInsensitiveContains($0) || item.subjectKey.localizedCaseInsensitiveContains($0) } }
        for item in test { await model.deleteMemory(item.id) }
        return test.map(\.subjectKey)
    }

    @MainActor
    private static func run(_ mission: Mission, model: AppModel) async -> [String: Any] {
        var fields: [String: Any] = ["cap_usd": "\(mission.cap)"]
        if mission.engine != .aim, model.engineStatuses.first(where: { $0.id == mission.engine })?.isInstalled != true {
            fields["passed"] = false; fields["failure"] = "engine not installed"; return fields
        }
        let reservation: LiveBudgetReservation
        do { reservation = try LiveBudgetReservation(cap: mission.cap) }
        catch { fields["passed"] = false; fields["failure"] = "live envelope has no room for this mission"; return fields }
        let folder = FileManager.default.temporaryDirectory.appending(path: "aim-capability-\(mission.id)-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath().standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "Le projet AIM teste ses capacités.".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        } catch { fields["passed"] = false; fields["failure"] = "fixture: \(error)"; return fields }
        defer { try? FileManager.default.removeItem(at: folder) }

        for _ in 0..<120 where model.isSending { try? await Task.sleep(for: .seconds(1)) }
        model.selectMode(.agent)
        await model.newConversation()
        model.selectProvider(.openRouter)
        model.selectModel(LiveScenarioRunner.cloudModelID)
        model.selectAgentEngine(mission.engine)
        model.workspacePath = folder.path
        model.workspaceToolsEnabled = true
        model.workspaceEditsEnabled = true
        model.workspaceCommandsEnabled = false
        model.approvalPolicy = .autoApprove
        let before = (try? await model.spendLedger.snapshot()).flatMap { Decimal(string: $0.countedUSD) } ?? 0
        let started = Date.now
        model.composerText = mission.prompt
        await model.sendComposer()
        for _ in 0..<30 where model.selectedConversationID == nil {
            model.alertMessage = nil
            try? await Task.sleep(for: .seconds(1))
            if model.composerText.isEmpty { model.composerText = mission.prompt }
            await model.sendComposer()
        }
        fields["sent"] = model.selectedConversationID != nil
        if let alert = model.alertMessage { fields["alert"] = alert }
        fields["engine_status"] = model.engineStatuses.first { $0.id == mission.engine }.map { "\($0.state)" } ?? "aim"
        fields["engine_error"] = model.agentInstallErrors[mission.engine] ?? ""
        var approvals: [String] = [], denied: [String] = []
        var stoppedForCap = false
        var state = "unknown", reason = ""
        var sawSending = false, idleSince: Date?
        while Date.now.timeIntervalSince(started) < (mission.personApproves.isEmpty ? 600 : 900) {
            try? await Task.sleep(for: .seconds(1))
            // A turn that ran without a durable task (no execution to watch) ends when the
            // composer is idle again with the answer saved.
            if model.isSending { sawSending = true; idleSince = nil }
            else if sawSending, model.selectedContinuityExecution == nil, model.pendingToolApprovals.isEmpty {
                if idleSince == nil { idleSince = .now }
                if let idleSince, Date.now.timeIntervalSince(idleSince) > 5 { state = "finished-without-task"; break }
            }
            // Auto still asks before some actions (screen, private reads): the scripted person
            // allows the mission's own actions once and refuses anything outward or destructive.
            for approval in model.pendingToolApprovals where model.selectedConversationID != nil
                && !mission.personApproves.contains(approval.toolName) {
                if approval.toolName == "messages_send", Self.isSelf(approval.arguments["to"]) {
                    approvals.append(approval.toolName); await model.decideToolApproval(approval, decision: .allowOnce)
                } else if refused.contains(approval.toolName) {
                    denied.append(approval.toolName); await model.decideToolApproval(approval, decision: .deny)
                } else {
                    approvals.append(approval.toolName); await model.decideToolApproval(approval, decision: .allowOnce)
                }
            }
            let spent = (try? await model.spendLedger.snapshot()).flatMap { Decimal(string: $0.countedUSD) }.map { $0 - before } ?? 0
            if spent > mission.cap { stoppedForCap = true; await model.controlContinuityExecution(.cancel); break }
            // The agent asked the person something: the scripted person does not answer.
            if !model.pendingAgentQuestions.isEmpty { state = "asked-the-person"; break }
            if let execution = model.selectedContinuityExecution {
                state = execution.state.rawValue; reason = execution.reason ?? ""
                if execution.state.isTerminal || [.waitingUser, .blocked, .awaitingReview].contains(execution.state) { break }
            }
        }
        // A task left waiting or blocked would keep the next mission from starting: it is cancelled.
        if let execution = model.selectedContinuityExecution, !execution.state.isTerminal {
            await model.controlContinuityExecution(.cancel)
        }
        for _ in 0..<60 where model.isSending { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(2))
        let conversation = model.selectedConversationID
        await model.selectConversation(conversation)
        let answer = model.messages.last { $0.role == .assistant }?.content ?? ""
        let tools = model.workspaceHistory.filter { $0.run.conversationID == conversation?.uuidString }.flatMap(\.calls).map(\.name)
        let outcome = Outcome(folder: folder, answer: answer, tools: tools, model: model)
        let missing = mission.required.filter { group in !group.contains(where: tools.contains) }.map { $0.joined(separator: "|") }
        var failure = ["accepted", "finished-without-task"].contains(state) ? nil : "task ended \(state) \(reason)"
        if failure == nil, !missing.isEmpty { failure = "tools not used: " + missing.joined(separator: ", ") }
        if failure == nil, stoppedForCap { failure = "stopped at its spending cap" }
        if failure == nil { failure = await mission.check(outcome) }
        // Costs include any memory capture that followed the answer.
        let spent = (try? await model.spendLedger.snapshot()).flatMap { Decimal(string: $0.countedUSD) }.map { $0 - before } ?? mission.cap
        _ = try? reservation.settle(scenario: "capability-" + mission.id, confirmed: max(0, spent), unknown: 0, reserved: 0)
        fields["state"] = state; fields["reason"] = reason
        fields["seconds"] = Int(Date.now.timeIntervalSince(started))
        fields["spent_usd"] = "\(spent)"
        fields["tools"] = tools; fields["approvals"] = approvals; fields["denied"] = denied
        fields["answer"] = redacted(String(answer.suffix(800)))
        fields["passed"] = failure == nil
        if let failure { fields["failure"] = failure }
        return fields
    }
}
#endif
