import AIMCore
import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import Foundation

/// Lets an Agent conversation propose a recurring or triggered task. Creating
/// one is always an exact approval; the task inherits only the scope already
/// approved for the current mission, never a wider one.
actor AgentSchedulerToolService: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["schedule_task", "list_scheduled_tasks", "cancel_scheduled_task"]
    private let repository: SQLiteSchedulerRepository
    private let missions: (any AgentMissionRepository)?
    private let conversationID: UUID
    private let provider: ChatProvider
    private let modelID: String
    private let workspacePath: String?
    private let allowEdits: Bool
    private let allowCommands: Bool

    init(repository: SQLiteSchedulerRepository, missions: (any AgentMissionRepository)?, conversationID: UUID,
         provider: ChatProvider, modelID: String, workspacePath: String?, allowEdits: Bool, allowCommands: Bool) {
        self.repository = repository; self.missions = missions; self.conversationID = conversationID
        self.provider = provider; self.modelID = modelID; self.workspacePath = workspacePath
        self.allowEdits = allowEdits; self.allowCommands = allowCommands
    }

    func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            switch request.name {
            case "schedule_task": return try await schedule(request)
            case "list_scheduled_tasks":
                let tasks = try await repository.list().filter { $0.spec != nil }
                let rows = tasks.prefix(50).map { task -> [String: Any] in
                    ["id": task.id.uuidString, "title": task.title, "when": task.spec?.summary ?? "",
                     "state": task.state.rawValue, "next_run": task.nextRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                     "last_status": task.lastStatus ?? "", "consecutive_failures": task.consecutiveFailures]
                }
                let data = try JSONSerialization.data(withJSONObject: ["tasks": rows], options: [.sortedKeys])
                return ToolResult(requestID: request.id, content: String(decoding: data, as: UTF8.self))
            case "cancel_scheduled_task":
                guard let raw = request.arguments["task_id"], let id = UUID(uuidString: raw),
                      var task = try await repository.task(id: id) else { throw AgentMissionError.invalidInput }
                task.state = .disabled
                task.updatedAt = .now
                try await repository.save(task)
                return ToolResult(requestID: request.id, content: "Task \(task.title) is disabled; it will not run again until re-enabled in Settings → Automations.")
            default:
                throw AgentMissionError.invalidInput
            }
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    func cancel(requestID: String) async {}

    private func schedule(_ request: ToolRequest) async throws -> ToolResult {
        let arguments = request.arguments
        guard let title = arguments["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= 120,
              let prompt = arguments["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty, prompt.utf8.count <= 16_000 else {
            throw ScheduleToolError.invalid("title (≤120) and prompt are required.")
        }
        let schedule = try Self.schedule(arguments)
        var trigger: ScheduledTaskSpec.Trigger?
        if let folder = arguments["trigger_folder"] { trigger = .folderChanged(path: folder) }
        if let app = arguments["trigger_app"] { trigger = .applicationLaunched(bundleID: app) }
        if arguments["trigger_new_mail"] == "true" { trigger = .newMail }
        if let script = arguments["trigger_script"] {
            trigger = .scriptResultChanged(source: script,
                intervalSeconds: Int(arguments["trigger_script_interval_seconds"] ?? "") ?? 300)
        }
        let webhook = arguments["trigger_webhook"] == "true"
        if webhook {
            // The secret is created by the person in Settings, never seen by a model; until then nothing matches.
            trigger = .webhook(tokenSHA256: LocalWebhookServer.tokenHash(LocalWebhookServer.newToken()))
        }
        var scope: [MissionAuthorizationRule] = []
        if let missions, let mission = try await missions.latest(conversationID: conversationID),
           let authorization = try await missions.authorization(missionID: mission.id), authorization.revokedAt == nil {
            scope = authorization.rules
        }
        let spec = ScheduledTaskSpec(schedule: schedule, trigger: trigger, provider: provider, modelID: modelID,
            workspacePath: workspacePath, allowEdits: allowEdits && arguments["allow_edits"] == "true",
            allowCommands: allowCommands && arguments["allow_commands"] == "true",
            scope: scope, maxSpendUSD: arguments["max_spend_usd"],
            continuesConversation: arguments["continue_conversation"] == "true" ? true : nil)
        guard spec.isValid else { throw ScheduleToolError.invalid("The schedule, trigger or spending cap is invalid.") }
        let task = ScheduledTask(title: title, prompt: prompt, nextRunAt: spec.nextRun(after: .now), spec: spec)
        try await repository.save(task)
        let budget = spec.maxSpendUSD.map { "up to \($0) USD per run" } ?? "without a per-run spending cap"
        var content = "Scheduled “\(title)” (\(spec.summary)), \(budget), with \(scope.count) pre-approved scope rule(s). Anything outside that scope will pause the task and notify the person. Manage it in Settings → Automations."
        if webhook {
            content += " Its local webhook needs a token: tell the person to open Settings → Automations and click “New webhook token…” on this task (the secret is shown only to them)."
        }
        return ToolResult(requestID: request.id, content: content, metadata: ["task_id": task.id.uuidString])
    }

    static func schedule(_ arguments: [String: String]) throws -> ScheduledTaskSpec.Schedule? {
        guard let kind = arguments["schedule"] else { return nil }
        func time() throws -> (Int, Int) {
            let parts = (arguments["time"] ?? "").split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { throw ScheduleToolError.invalid("time must be HH:MM.") }
            return (parts[0], parts[1])
        }
        switch kind {
        case "once":
            guard let raw = arguments["at_iso"], let date = ISO8601DateFormatter().date(from: raw) else {
                throw ScheduleToolError.invalid("at_iso must be an ISO-8601 date with time zone.")
            }
            return .once(at: date)
        case "interval":
            guard let minutes = Int(arguments["interval_minutes"] ?? "") else {
                throw ScheduleToolError.invalid("interval_minutes is required.")
            }
            return .interval(seconds: minutes * 60)
        case "daily":
            let (hour, minute) = try time()
            return .daily(hour: hour, minute: minute)
        case "weekly":
            guard let weekday = Int(arguments["weekday"] ?? "") else { throw ScheduleToolError.invalid("weekday 1–7 (Sunday = 1) is required.") }
            let (hour, minute) = try time()
            return .weekly(weekday: weekday, hour: hour, minute: minute)
        default:
            throw ScheduleToolError.invalid("schedule is once, interval, daily or weekly.")
        }
    }
}

enum ScheduleToolError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let detail): detail } }
}
