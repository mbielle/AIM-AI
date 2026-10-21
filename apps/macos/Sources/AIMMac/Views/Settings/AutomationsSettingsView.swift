import AIMCore
import AIMApplication
import AIMMacPlatform
import SwiftUI

/// Scheduled and triggered Agent tasks. Runs are unattended: they act only
/// within each task's pre-approved scope and pause for you otherwise.
struct AutomationsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var executions: [UUID: [ScheduledExecution]] = [:]
    @State private var showingAdd = false
    @State private var message: String?
    @State private var webhookToken: (title: String, command: String)?

    var body: some View {
        SettingsPage("Automations", subtitle: "Each run opens a ⏱ Agent conversation you can review. It uses the task's model and folder, acts automatically only within the scope approved when the task was created, stops at its spending cap, and pauses with a notification when it needs you.") {
            if let message { SettingsNotice(message) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tasks").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("New task…") { showingAdd = true }.buttonStyle(.settingsPrimary)
                }
                SettingsCard {
                    let tasks = model.scheduledTasks.filter { $0.spec != nil }
                    if tasks.isEmpty { SettingsRow("No automation yet", description: "Create one here, or ask the Agent to schedule one.") }
                    ForEach(tasks) { task in row(task) }
                }
                Text("A recurring task turns itself off after \(ScheduledTask.failureLimit) failed runs in a row. Tasks run while AIM is open and you are signed in; it stays in the menu bar when the window is closed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
        .sheet(isPresented: Binding(get: { webhookToken != nil }, set: { if !$0 { webhookToken = nil } })) {
            if let webhookToken {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Webhook for “\(webhookToken.title)”").font(.headline)
                    Text("Copy it now: AIM keeps only a fingerprint and cannot show it again. It works only from this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(webhookToken.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(webhookToken.command, forType: .string)
                        }
                        Button("Done") { self.webhookToken = nil }.keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 560)
            }
        }
        .task { await model.reloadScheduledTasks() }
        .sheet(isPresented: $showingAdd) {
            AddAutomationSheet(defaultModel: model.selectedModelID, defaultProvider: model.selectedProvider,
                defaultFolder: model.workspacePath) { task in
                do { try await model.saveScheduledTask(task); showingAdd = false } catch { message = error.localizedDescription }
            } cancel: { showingAdd = false }
        }
    }

    /// The token is shown only here, to the person, never to a model.
    private func regenerateToken(_ task: ScheduledTask) async {
        var updated = task
        let token = LocalWebhookServer.newToken()
        updated.spec?.trigger = .webhook(tokenSHA256: LocalWebhookServer.tokenHash(token))
        do {
            try await model.saveScheduledTask(updated)
            webhookToken = (task.title, "curl -X POST http://127.0.0.1:\(LocalWebhookServer.defaultPort)/aim/tasks/\(task.id.uuidString) -H 'Authorization: Bearer \(token)' --data 'optional details'")
        } catch { message = error.localizedDescription }
    }

    private func row(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(task.title, description: [task.spec?.summary, status(task)].compactMap { $0 }.joined(separator: "\n")) {
                Menu {
                    Button("Run now") {
                        Task {
                            let started = await model.runScheduledTaskNow(task.id)
                            message = started ? "“\(task.title)” started." : "“\(task.title)” is running, paused or disabled."
                        }
                    }.disabled(task.state != .enabled)
                    Button("Show history") { Task { executions[task.id] = await model.scheduledExecutions(task.id) } }
                    if case .webhook? = task.spec?.trigger {
                        Button("New webhook token…") { Task { await regenerateToken(task) } }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { Task { await model.deleteScheduledTask(task.id) } }
                        .disabled(task.state == .running)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(task.title)")
                SettingsSwitch(isOn: Binding(get: { task.state == .enabled || task.state == .running },
                    set: { value in Task { await model.setScheduledTask(task.id, enabled: value) } }), label: "Enabled")
                    .disabled(task.state == .running)
            }
            if let history = executions[task.id] {
                VStack(alignment: .leading, spacing: 4) {
                    if history.isEmpty { Text("No run yet.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(history) { execution in
                        Text("\(execution.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(execution.status?.rawValue ?? "running")" +
                             (execution.detail.map { " · \($0)" } ?? ""))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.bottom, 14)
            }
        }
    }

    private func status(_ task: ScheduledTask) -> String {
        var parts: [String] = [task.state.rawValue.capitalized]
        if let next = task.nextRunAt, task.state == .enabled { parts.append("next \(next.formatted(date: .abbreviated, time: .shortened))") }
        if let last = task.lastStatus { parts.append("last \(last)") }
        if task.consecutiveFailures > 0 { parts.append("\(task.consecutiveFailures) failure(s) in a row") }
        if let reason = task.pausedReason { parts.append(reason) }
        if let cap = task.spec?.maxSpendUSD { parts.append("≤ \(cap) USD/run") }
        return parts.joined(separator: " · ")
    }
}

private struct AddAutomationSheet: View {
    let defaultModel: String
    let defaultProvider: ChatProvider
    let defaultFolder: String?
    let onSave: (ScheduledTask) async -> Void
    let cancel: () -> Void
    @State private var title = ""
    @State private var prompt = ""
    @State private var kind = "daily"
    @State private var time = Date.now
    @State private var minutes = 60
    @State private var weekday = 2
    @State private var folder = ""
    @State private var allowEdits = false
    @State private var cap = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New automation").font(.headline)
            TextField("Title", text: $title)
            TextField("What should the Agent do each run?", text: $prompt, axis: .vertical).lineLimit(3...6)
            Picker("When", selection: $kind) {
                Text("Daily").tag("daily"); Text("Weekly").tag("weekly"); Text("Every N minutes").tag("interval")
                Text("When a folder changes").tag("folder")
            }
            switch kind {
            case "interval": Stepper("Every \(minutes) minutes", value: $minutes, in: 1...10_080)
            case "weekly":
                Picker("Day", selection: $weekday) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            case "folder": TextField("Folder path", text: $folder)
            default: DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            }
            Text("Model: \(defaultModel.isEmpty ? "none selected" : defaultModel) · Folder: \(defaultFolder ?? "none")")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Allow file edits inside the folder without asking", isOn: $allowEdits).disabled(defaultFolder == nil)
            TextField("Optional spending cap per run (USD)", text: $cap)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", action: cancel); Button("Create") { Task { await create() } }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
    }

    private func create() async {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        var schedule: ScheduledTaskSpec.Schedule?
        var trigger: ScheduledTaskSpec.Trigger?
        switch kind {
        case "interval": schedule = .interval(seconds: minutes * 60)
        case "weekly": schedule = .weekly(weekday: weekday, hour: components.hour ?? 9, minute: components.minute ?? 0)
        case "folder": trigger = .folderChanged(path: folder)
        default: schedule = .daily(hour: components.hour ?? 9, minute: components.minute ?? 0)
        }
        var scope: [MissionAuthorizationRule] = []
        if let defaultFolder, let resource = try? MissionResource(kind: .directory, identifier: defaultFolder),
           let rule = try? MissionAuthorizationRule(resource: resource, operations: allowEdits ? [.observe, .edit] : [.observe]) {
            scope.append(rule)
        }
        let spec = ScheduledTaskSpec(schedule: schedule, trigger: trigger, provider: defaultProvider, modelID: defaultModel,
            workspacePath: defaultFolder, allowEdits: allowEdits, scope: scope,
            maxSpendUSD: cap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cap)
        guard !title.isEmpty, !prompt.isEmpty, spec.isValid else {
            error = "A title, an instruction, a selected model and a valid schedule are required. An optional spending cap must be above 0."
            return
        }
        await onSave(ScheduledTask(title: title, prompt: prompt, nextRunAt: spec.nextRun(after: .now), spec: spec))
    }
}
