#if DEBUG
import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import Foundation

/// Live, billable check of the learning loop's judgment with the real model:
/// a run where the person corrected a skill-governed task must yield an
/// improved version of that skill; a routine run must yield nothing.
/// Proposals go to a temporary skills folder, never the person's own.
enum SkillLearningQualification {
    @MainActor
    static func run(into report: QualificationReport, model: AppModel) async {
        guard let reservation = try? LiveBudgetReservation(cap: Decimal(string: "0.40")!) else {
            report.set("conclusion", "The shared qualification budget is unavailable/exhausted."); return
        }
        guard let database = try? AIMDatabase(inMemory: true) else { return }
        let ledger = SQLiteGlobalSpendLedger(database: database)
        do { try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "0.40", period: .envelope)) }
        catch { report.set("conclusion", "Budget policy preparation failed before model send; reservation retained."); return }
        let exceptions = SpendExceptionBroker()
        let service = SkillLearningService(secureStore: model.scopedProviderCredentials(),
                                           meter: BillableRequestMeter(ledger: ledger, exceptions: exceptions))
        // As in the live scenarios: unknown-cost attempts are allowed; the ledger cap still stops spending.
        let spendTask = Task {
            for await pending in await exceptions.updates() {
                for exception in pending { await exceptions.decide(id: exception.id, allow: false) }
            }
        }
        defer { spendTask.cancel() }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("aim-learning-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let global = scratch.appendingPathComponent("Skills", isDirectory: true)
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = global.appendingPathComponent("weekly-report", isDirectory: true)
        try? FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try? "---\nname: weekly-report\ndescription: Write the team's weekly status report.\n---\n\n1. Read the notes in notes/.\n2. Write report.md with one section per project.\n"
            .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        var cases: [String: Bool] = [:]
        var details: [String: Any] = [:]

        // Positive: the person corrected the output of a task governed by a loaded skill.
        let corrected = conversation(workspace)
        let correctedMessages = messages(corrected.id, [
            (.user, "Write this week's status report from the notes."),
            (.assistant, "I wrote report.md with a section for each project (Atlas, Beacon) dated 2 Oct 2026."),
            (.user, "Two things for every report from now on: dates are always written YYYY-MM-DD, and the report must end with a 'Sources' section listing each note file you used."),
            (.assistant, "Updated report.md: dates are now 2026-10-02 and a Sources section lists notes/atlas.md and notes/beacon.md. I read the file back to confirm.")
        ])
        let correctedRun = history(corrected.id, ["skill_view": ["name": "weekly-report"]],
            reads: ["notes/atlas.md", "notes/beacon.md", "report.md"], writes: 3)
        do {
            let proposal = try await service.learn(from: corrected, messages: correctedMessages, run: correctedRun,
                                                   level: .suggest, global: global)?.proposal
            let text = (proposal?.instructions ?? "").lowercased()
            cases["correction_becomes_skill_update"] = proposal?.name == "weekly-report" &&
                text.contains("yyyy-mm-dd") && text.contains("sources")
            cases["proposal_is_inactive"] = SkillCatalog.discover(workspace: nil, global: global)
                .first { $0.name == "weekly-report" }?.description == "Write the team's weekly status report."
            cases["proposal_marked_learned"] = SkillCatalog.proposals(global: global).first?.origin == "learned"
            details["positive_proposal"] = proposal.map { ["name": $0.name, "description": $0.description,
                                                            "instructions": $0.instructions] } ?? NSNull()
        } catch {
            cases["correction_becomes_skill_update"] = false
            details["positive_error"] = error.localizedDescription
        }

        // Negative control: a routine look-around with no correction teaches nothing.
        let routine = conversation(workspace)
        let routineMessages = messages(routine.id, [
            (.user, "What files are in this folder?"),
            (.assistant, "The folder contains README.md, notes/atlas.md and notes/beacon.md.")
        ])
        let routineRun = history(routine.id, [:], reads: ["README.md", "notes/atlas.md", "notes/beacon.md"], writes: 0,
                                 listings: 6)
        let before = SkillCatalog.proposals(global: global).count
        do {
            let proposal = try await service.learn(from: routine, messages: routineMessages, run: routineRun,
                                                   level: .suggest, global: global)?.proposal
            cases["routine_run_proposes_nothing"] = proposal == nil && SkillCatalog.proposals(global: global).count == before
            details["negative_proposal"] = proposal.map { ["name": $0.name, "description": $0.description] } ?? NSNull()
        } catch {
            cases["routine_run_proposes_nothing"] = false
            details["negative_error"] = error.localizedDescription
        }

        report.set("cases", cases)
        report.set("details", details)
        let snapshot = try? await ledger.snapshot(at: .now)
        let spent = Decimal(string: snapshot?.confirmedUSD ?? "0") ?? 0
        let total: Decimal
        do { total = try reservation.settle(scenario: "skill-learning", confirmed: spent, unknown: snapshot?.unknownAttempts ?? 1,
            reserved: snapshot.flatMap { Decimal(string: $0.reservedUSD) }) }
        catch { report.set("conclusion", "Budget settlement failed; reservation retained."); return }
        report.set("model", LiveScenarioRunner.modelID)
        report.set("confirmed_usd", "\(spent)")
        report.set("spent_after_usd", "\(total)")
        let failed = cases.filter { !$0.value }.map(\.key).sorted()
        report.set("conclusion", failed.isEmpty ? "all skill-learning cases passed (\(cases.count))" : "failed: \(failed.joined(separator: ", "))")
    }

    private static func conversation(_ workspace: URL) -> Conversation {
        Conversation(title: "[AIM live] learning", mode: .agent, provider: .openRouter,
                     modelID: LiveScenarioRunner.modelID, workspacePath: workspace.path)
    }

    private static func messages(_ id: UUID, _ items: [(MessageRole, String)]) -> [ConversationMessage] {
        items.enumerated().map { ConversationMessage(conversationID: id, role: $0.element.0, content: $0.element.1, sequence: $0.offset) }
    }

    private static func history(_ id: UUID, _ first: [String: [String: String]], reads: [String], writes: Int,
                                listings: Int = 2) -> WorkspaceRunHistory {
        var run = WorkspaceRun(conversationID: id, provider: .openRouter, modelID: LiveScenarioRunner.modelID, workspacePath: "/workspace")
        run.state = .unverified
        var calls: [(String, [String: String], String)] = first.map { ($0.key, $0.value, "Skill weekly-report (global). 1. Read the notes…") }
        calls += (0..<listings).map { _ in ("list_dir", [:], "README.md\nnotes/") }
        calls += reads.map { ("read_file", ["path": $0], "…") }
        for index in 0..<writes { calls.append((index % 2 == 0 ? "propose_edit" : "apply_edit", ["path": "report.md"], "ok")) }
        let records = calls.enumerated().compactMap { index, call -> WorkspaceCall? in
            var record = try? WorkspaceCall(runID: run.id, ordinal: index, call: ModelToolCall(id: "c\(index)", name: call.0,
                jsonArguments: call.1.mapValues { .string($0) }))
            record?.state = .succeeded
            record?.result = call.2
            return record
        }
        return WorkspaceRunHistory(run: run, calls: records)
    }
}
#endif
