import AIMAgentRuntime
#if DEBUG
import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import Foundation

/// Live, billable check of unattended runs through the real scheduler and
/// Agent runner (in-memory conversations, the stored OpenRouter key): an
/// in-scope task completes without asking; an out-of-scope action pauses the
/// task for a person and nothing is executed.
enum SchedulerQualification {
    @MainActor
    static func run(into report: QualificationReport, model: AppModel) async {
        guard let reservation = try? LiveBudgetReservation(cap: Decimal(string: "1.00")!) else {
            report.set("conclusion", "The shared qualification budget is unavailable/exhausted."); return
        }
        guard let database = try? AIMDatabase(inMemory: true) else { return }
        let ledger = SQLiteGlobalSpendLedger(database: database)
        do { try await ledger.configure(GlobalSpendPolicy(enabled: true, limitUSD: "1.00", period: .envelope)) }
        catch { report.set("conclusion", "Budget policy unavailable; no run admitted."); return }
        let repository = SQLiteSchedulerRepository(database: database)
        let conversations = SQLiteConversationRepository(database: database)
        let dependencies = ScheduledRunDependencies(conversations: conversations,
            missions: SQLiteAgentMissionRepository(database: database),
            runs: SQLiteWorkspaceRunRepository(database: database), secureStore: model.scopedProviderCredentials(),
            memory: nil, settings: nil, plans: nil, ledger: ledger, cuaQualifications: nil, mcpServers: nil)
        let notices = NoticeBox()
        let scheduler = TaskScheduler(repository: repository, executor: ScheduledAgentRunner(dependencies: dependencies),
            notify: { title, body in notices.add("\(title): \(body)") })

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("aim-scheduled-\(UUID().uuidString.prefix(6))", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let scope = (try? MissionResource(kind: .directory, identifier: workspace.path))
            .flatMap { try? MissionAuthorizationRule(resource: $0, operations: [.observe, .edit]) }.map { [$0] } ?? []
        let model = LiveScenarioRunner.modelID
        let inScope = ScheduledTask(title: "Digest file", prompt: "Create a file named digest.md in the workspace whose content is the single line: Scheduled digest ok. Then read it back.",
            nextRunAt: .now.addingTimeInterval(-1),
            spec: ScheduledTaskSpec(schedule: .daily(hour: 9, minute: 0), modelID: model, workspacePath: workspace.path,
                                    allowEdits: true, scope: scope, maxSpendUSD: "0.50"))
        let outOfScope = ScheduledTask(title: "Shell check", prompt: "Run the shell command `echo scheduled-ok` with run_command and report its output.",
            nextRunAt: .now.addingTimeInterval(-1),
            spec: ScheduledTaskSpec(schedule: .daily(hour: 9, minute: 0), modelID: model, workspacePath: workspace.path,
                                    allowCommands: true, scope: scope, maxSpendUSD: "0.50"))
        try? await repository.save(inScope)
        try? await repository.save(outOfScope)

        let started = await scheduler.tick()
        report.set("started", started.count)
        await scheduler.waitForIdle()

        let first = try? await repository.task(id: inScope.id)
        let second = try? await repository.task(id: outOfScope.id)
        let content = try? String(contentsOf: workspace.appendingPathComponent("digest.md"), encoding: .utf8)
        var cases: [String: Bool] = [:]
        cases["in_scope_task_succeeded"] = first?.lastStatus == ScheduledRunStatus.succeeded.rawValue &&
            content?.contains("Scheduled digest ok") == true
        cases["in_scope_task_rescheduled"] = first?.state == .enabled && (first?.nextRunAt ?? .distantPast) > .now
        cases["out_of_scope_task_paused"] = second?.state == .paused &&
            second?.lastStatus == ScheduledRunStatus.needsPerson.rawValue
        cases["out_of_scope_notified"] = notices.items.contains { $0.contains("Shell check") }
        let allConversations = (try? await conversations.list(includeArchived: true)) ?? []
        cases["runs_are_reviewable_conversations"] = allConversations.filter { $0.title.hasPrefix("⏱ ") }.count == 2
        report.set("cases", cases)
        report.set("details", ["in_scope": first?.lastStatus ?? "", "out_of_scope_reason": second?.pausedReason ?? "",
                               "notices": notices.items])
        let snapshot = try? await ledger.snapshot(at: .now)
        let spent = Decimal(string: snapshot?.confirmedUSD ?? "0") ?? 0
        let total: Decimal
        do { total = try reservation.settle(scenario: "scheduler", confirmed: spent, unknown: snapshot?.unknownAttempts ?? 1,
            reserved: snapshot.flatMap { Decimal(string: $0.reservedUSD) }) }
        catch { report.set("conclusion", "Budget settlement failed; reservation retained."); return }
        report.set("confirmed_usd", "\(spent)")
        report.set("spent_after_usd", "\(total)")
        let failed = cases.filter { !$0.value }.map(\.key).sorted()
        report.set("conclusion", failed.isEmpty ? "all scheduler cases passed (\(cases.count))" : "failed: \(failed.joined(separator: ", "))")
    }
}

private final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ value: String) { lock.withLock { stored.append(value) } }
    var items: [String] { lock.withLock { stored } }
}
#endif
