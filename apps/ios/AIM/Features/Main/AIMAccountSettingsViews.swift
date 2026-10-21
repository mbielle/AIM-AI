import AIMCore
import SwiftUI

struct AIMAccountProfileView: View {
    let identity: AppIdentity
    let openAccount: () -> Void
    let nativeChat: NativeChatStore
    let onBack: () -> Void
    let openActivity: ([UUID], String, String) -> Void
    let openImport: () -> Void
    @State private var scope = "all"
    @State private var period = "all"
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var heatmap = AccountActivitySummary.HeatmapMode.daily
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var selectedDay = Date()
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt; return value }
    private var allRecords: [AccountActivityRecord] {
        AccountActivityRecord.merge(nativeChat.activityRecords, accountID: identity.storageID).filter {
            let local = ["local", "ollama", "lmStudio"].contains($0.provider)
            if $0.provider == "unknown" { return scope == "all" }
            return scope == "all" || (scope == "online" ? !local : local)
        }
    }
    private var records: [AccountActivityRecord] { AccountActivityFilter(period: .init(rawValue: period) ?? .all, timeZoneID: timeZoneID).apply(allRecords, accountID: identity.storageID) }
    private var summary: AccountActivitySummary { .init(records: records, accountID: identity.storageID, calendar: calendar) }
    private var annualSummary: AccountActivitySummary { .init(records: allRecords, accountID: identity.storageID, calendar: calendar) }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Profile", back: onBack)
            profileForm
        }.task { await nativeChat.syncAccountData() }
    }
    private var profileForm: some View {
        AIMSettingsForm {
            Section {
                AIMSettingsAction(title: identity.displayName ?? "AIM profile", icon: "person.crop.circle", value: "Edit", action: openAccount)
                Text(identity.accountEmail ?? "").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("Scope", selection: $scope) { Text("All").tag("all"); Text("Online").tag("online"); Text("Local").tag("local") }.pickerStyle(.segmented)
                Picker("Period", selection: $period) { Text("Today").tag("day"); Text("This week").tag("week"); Text("This month").tag("month"); Text("This year").tag("year"); Text("All time").tag("all") }
                Picker("Time zone", selection: $timeZoneID) { ForEach(Array(Set([TimeZone.current.identifier, "UTC", "Europe/Paris", "America/New_York", "Asia/Tokyo"])).sorted(), id: \.self) { Text($0).tag($0) } }
            }
            Section {
                metric("Measured tokens", value: summary.peakTokens == nil ? "—" : summary.tokens.formatted())
                metric("Peak per request", value: summary.peakTokens?.formatted() ?? "—")
                metric("Longest task", value: duration(summary.longestTask))
                metric("Waiting in longest task", value: duration(summary.longestTaskWaiting))
                metric("Measured task waiting", value: duration(summary.measuredWaitingSeconds))
                metric("Longest streak", value: "\(summary.longestStreak) days")
                metric("Current streak", value: "\(summary.currentStreak) days")
                metric("Active days", value: summary.activeDays.count.formatted())
            } header: { Text("Activity") } footer: {
                Text("Complete task durations include sub-agents. Waiting is shown separately.")
                if summary.unmeasuredResponses > 0 { Text("\(summary.unmeasuredResponses) responses have no token measurement.") }
                if summary.unmeasuredTasks > 0 { Text("\(summary.unmeasuredTasks) tasks have no complete duration measurement.") }
            }
            Section {
                Stepper("Year \(year.formatted(.number.grouping(.never)))", value: $year, in: 2000...Calendar.current.component(.year, from: .now))
                Picker("Display", selection: $heatmap) { Text("Daily").tag(AccountActivitySummary.HeatmapMode.daily); Text("Weekly").tag(AccountActivitySummary.HeatmapMode.weekly); Text("Cumulative").tag(AccountActivitySummary.HeatmapMode.cumulative) }
                AIMAccountTokenHeatmap(summary: annualSummary, calendar: calendar, year: year, mode: heatmap)
                DatePicker("Day", selection: $selectedDay, in: ...Date(), displayedComponents: .date).environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
                AIMSettingsAction(title: "Day details", value: selectedDay.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))) {
                    let title = selectedDay.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: calendar.timeZone))
                    openActivity(annualSummary.records(on: selectedDay, calendar: calendar).map(\.id), title, timeZoneID)
                }
            } header: { Text("Annual token activity") } footer: { Text("Choose a day to see its requests. Unmeasured tokens remain unavailable.") }
            Section("Models") {
                if summary.modelUses.isEmpty { Text("No recorded model activity").foregroundStyle(.secondary) }
                ForEach(summary.modelUses) { use in
                    AIMSettingsAction(title: use.title, value: "\(use.count) · \(use.measuredTokens?.formatted() ?? "—") tokens") { openActivity(use.records.map(\.id), use.title, timeZoneID) }
                }
            }
            Section("Tools") {
                if summary.toolUses.isEmpty { Text("No recorded tool activity").foregroundStyle(.secondary) }
                ForEach(summary.toolUses) { use in AIMSettingsAction(title: use.title, value: use.count.formatted()) { openActivity(use.records.map(\.id), use.title, timeZoneID) } }
            }
            Section { AIMSettingsAction(title: "Import earlier activity", icon: "square.and.arrow.down", action: openImport) }
            if let error = nativeChat.accountDataError { AIMSettingsMessage(text: error) }
            if let date = nativeChat.lastActivitySync { Text("Synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        }.refreshable { await nativeChat.syncAccountData() }
    }
    private func metric(_ title: String, value: String) -> some View {
        LabeledContent(title) { Text(value).monospacedDigit().foregroundStyle(.secondary) }
    }
    private func duration(_ value: TimeInterval?) -> String { value.map { Duration.seconds($0).formatted(.time(pattern: .hourMinuteSecond)) } ?? "—" }
}

struct AIMAccountTokenHeatmap: View {
    let summary: AccountActivitySummary
    let calendar: Calendar
    let year: Int
    let mode: AccountActivitySummary.HeatmapMode
    private var days: [Date] {
        guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)), let interval = calendar.dateInterval(of: .year, for: first) else { return [] }
        return (0..<366).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }.filter { $0 < interval.end && $0 <= Date() }
    }
    var body: some View {
        let values = summary.heatmapValues(days: days, mode: mode, calendar: calendar)
        ScrollView(.horizontal) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(14), spacing: 4), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    let value = values[day] ?? 0
                    let unmeasured = summary.records(on: day, calendar: calendar).filter { [.response, .voice].contains($0.kind) && $0.totalTokens == nil }.count
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(value == 0 ? (unmeasured > 0 ? 0.16 : 0.06) : min(0.85, 0.2 + log10(Double(value) + 1) * 0.1)))
                        .frame(width: 14, height: 14).accessibilityHidden(true)
                }
            }.padding(.vertical, 12)
        }.defaultScrollAnchor(.trailing).accessibilityElement(children: .ignore)
            .accessibilityLabel("Annual token activity for \(year). Choose a day below to hear its measurements.")
    }
}

struct AIMAccountActivityDetailList: View {
    let records: [AccountActivityRecord]
    let accountID: UUID
    let calendar: Calendar
    var body: some View {
        let summary = AccountActivitySummary(records: records, accountID: accountID, calendar: calendar)
        AIMSettingsForm {
            Section {
                LabeledContent("Measured tokens", value: summary.peakTokens == nil ? "—" : summary.tokens.formatted())
                LabeledContent("Confirmed costs", value: summary.confirmedUSD.formatted(.currency(code: "USD")))
                LabeledContent("Estimated costs", value: summary.estimatedUSD.formatted(.currency(code: "USD")))
                LabeledContent("Unknown costs", value: summary.unknownCosts.formatted())
            }
            Section("Requests and tasks") {
                if records.isEmpty { Text("No recorded activity").foregroundStyle(.secondary) }
                ForEach(records.sorted { $0.startedAt > $1.startedAt }) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.toolName ?? row.modelID).font(.subheadline.weight(.medium))
                        Text("\(row.deviceName) · \(row.mode.capitalized) · \(row.kind.rawValue.capitalized)").font(.footnote).foregroundStyle(.secondary)
                        Text(row.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone))).font(.caption).foregroundStyle(.secondary)
                        if [.response, .voice].contains(row.kind) { Text("\(row.totalTokens?.formatted() ?? "—") measured tokens").font(.footnote) }
                        if row.kind == .task {
                            Text("Duration: \(duration(row.duration)) · Waiting: \(duration(row.waitingSeconds))").font(.footnote)
                        }
                    }.padding(.vertical, 5)
                }
            }
        }
    }
    private func duration(_ value: TimeInterval?) -> String { value.map { Duration.seconds($0).formatted(.time(pattern: .hourMinuteSecond)) } ?? "—" }
}

struct AIMAccountUsageView: View {
    let chat: NativeChatStore
    let back: () -> Void
    @State private var device = "all"
    @State private var provider = "all"
    @State private var period = "month"
    @State private var model = "all"
    @State private var mode = "all"
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var providerUsage: ProviderAccountUsage?
    @State private var providerUsageError: String?
    @State private var checkingProviderUsage = false
    @State private var providerUsageGeneration = UUID()
    @State private var providerUsageTask: Task<Void, Never>?
    @AppStorage("aim.budget.enabled") private var budgetEnabled = false
    @AppStorage("aim.budget.limit") private var budget = 2.0
    @AppStorage("aim.budget.strict-web-search") private var strictWebSearchBudget = false
    private var rows: [AccountActivityRecord] {
        AccountActivityFilter(period: .init(rawValue: period) ?? .month, timeZoneID: timeZoneID,
            deviceID: device == "all" ? nil : device, provider: provider == "all" ? nil : provider,
            modelID: model == "all" ? nil : model, mode: mode == "all" ? nil : mode).apply(chat.activityRecords, accountID: chat.accountID)
    }
    private var summary: AccountActivitySummary { .init(records: rows, accountID: chat.accountID) }
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: "Usage & costs", back: back)
            AIMSettingsForm {
                Section {
                    Picker("Period", selection: $period) { Text("Today").tag("day"); Text("This week").tag("week"); Text("This month").tag("month"); Text("This year").tag("year"); Text("All time").tag("all") }
                    Picker("Time zone", selection: $timeZoneID) { ForEach(Array(Set([TimeZone.current.identifier, "UTC", "Europe/Paris", "America/New_York", "Asia/Tokyo"])).sorted(), id: \.self) { Text($0).tag($0) } }
                    Picker("Device", selection: $device) {
                        Text("All devices").tag("all")
                        ForEach(Array(Set(chat.activityRecords.map(\.deviceID))).sorted(), id: \.self) { id in Text(chat.activityRecords.first { $0.deviceID == id }?.deviceName ?? id).tag(id) }
                    }
                    Picker("Provider", selection: $provider) { Text("All providers").tag("all"); ForEach(Array(Set(chat.activityRecords.map(\.provider))).sorted(), id: \.self) { Text($0).tag($0) } }
                    Picker("Model", selection: $model) { Text("All models").tag("all"); ForEach(Array(Set(chat.activityRecords.map(\.modelID))).sorted(), id: \.self) { Text($0).tag($0) } }
                    Picker("Mode", selection: $mode) { Text("All modes").tag("all"); ForEach(Array(Set(["chat", "code", "agent", "voice", "memory"] + chat.activityRecords.map(\.mode))).sorted(), id: \.self) { Text($0.capitalized).tag($0) } }
                    money("Confirmed", summary.confirmedUSD)
                    money("Estimated", summary.estimatedUSD)
                    money("Reserved", summary.reservedUSD)
                    HStack { Text("Unknown costs"); Spacer(); Text(summary.unknownCosts.formatted()).foregroundStyle(.secondary) }
                } header: { Text("AIM account activity") } footer: { Text("AIM records, not a supplier invoice. Provider accounts can include usage outside AIM.") }
                providerAccounts
                Section {
                    Toggle("budget.estimated_limit", isOn: $budgetEnabled).tint(.green)
                    if budgetEnabled {
                        TextField("Monthly limit in USD", value: $budget, format: .number)
                            .keyboardType(.decimalPad)
                        Toggle("budget.verified_web_maximum", isOn: $strictWebSearchBudget)
                        if chat.completedUnknownBudgetCharges > 0 {
                            LabeledContent("budget.unknown_completed", value: chat.completedUnknownBudgetCharges.formatted())
                            Text("budget.unknown_history_coverage").font(.footnote).foregroundStyle(.secondary)
                        }
                        if !budget.isFinite || budget <= 0 { Text("Enter a positive monthly amount.").font(.caption).foregroundStyle(.secondary) }
                    }
                } header: { Text("Budget on this iPhone") } footer: { Text("budget.estimate_coverage") }
                Section("Recent requests") {
                    ForEach(rows.filter { $0.kind == .cost || ([.response, .voice].contains($0.kind) && $0.costTrackedSeparately != true) }.reversed().prefix(40)) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.modelID).font(.subheadline)
                            HStack { Text(record.deviceName); Spacer(); Text(record.costUSD.map { $0.formatted(.currency(code: "USD")) } ?? "Unknown") }.font(.footnote).foregroundStyle(.secondary)
                            Text(record.costState.rawValue.capitalized + " · " + record.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if let error = chat.accountDataError { AIMSettingsMessage(text: error) }
                if let date = chat.lastActivitySync { Text("Synced \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            }.refreshable { await chat.syncAccountData(); await refreshProviderUsage() }
        }.task { clearProviderUsage(); await chat.syncAccountData() }
        .onChange(of: chat.accountID) { _, _ in clearProviderUsage() }
        .onChange(of: chat.connectedProviders) { _, _ in clearProviderUsage() }
        .onDisappear { clearProviderUsage() }
    }
    private var providerAccounts: some View {
        Section {
            providerHeading(.openRouter, status: chat.connectedProviders.contains(.openRouter) ? "This iPhone’s key · all apps" : "Not connected on this iPhone")
            if let usage = providerUsage, usage.accountID == chat.accountID {
                providerMoney("OpenRouter credits used · all time", usage.creditUsageUSD)
                providerMoney("Credits used · today", usage.dailyCreditUsageUSD)
                providerMoney("Credits used · this week", usage.weeklyCreditUsageUSD)
                providerMoney("Credits used · this month", usage.monthlyCreditUsageUSD)
                if let byok = usage.byokUsageUSD { money("External BYOK usage · all time", byok) }
                providerMoney("Key spending limit", usage.creditLimitUSD)
                providerMoney("Key limit remaining", usage.creditRemainingUSD)
                if let reset = usage.limitReset { LabeledContent("Key limit resets", value: reset.rawValue.capitalized) }
                if let includesBYOK = usage.includesBYOKInLimit { LabeledContent("External BYOK counts toward limit", value: includesBYOK ? "Yes" : "No") }
                Text("Checked \(usage.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            } else if chat.connectedProviders.contains(.openRouter), providerUsageError == nil, !checkingProviderUsage {
                Text("Check the provider for this key’s spending and any reported limit.").font(.footnote).foregroundStyle(.secondary)
            }
            if chat.connectedProviders.contains(.openRouter) {
                Button {
                    providerUsageTask = Task { await refreshProviderUsage() }
                } label: {
                    HStack {
                        Text(providerUsage == nil ? "Check OpenRouter usage" : "Refresh OpenRouter usage")
                        Spacer()
                        if checkingProviderUsage { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }.foregroundStyle(.primary)
                }.disabled(checkingProviderUsage)
                Link(destination: URL(string: "https://openrouter.ai/settings/credits")!) {
                    Label("OpenRouter credits", systemImage: "arrow.up.right").foregroundStyle(.primary)
                }
            }
            if let providerUsageError { AIMSettingsMessage(text: providerUsageError) }
            providerHeading(.chatgpt, status: "Plan usage unavailable")
            Text("Available after AIM receives applicable OpenAI authorization.").font(.footnote).foregroundStyle(.secondary)
        } header: { Text("Provider accounts") } footer: {
            Text("Provider totals cover all apps using this key. AIM filters do not apply; provider periods use UTC.")
        }
    }
    private func providerHeading(_ provider: ChatProvider, status: String) -> some View {
        HStack(spacing: 12) {
            AIMModelLogo(modelID: "", provider: provider == .chatgpt ? "openai" : provider.rawValue, displayName: provider.name, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider == .chatgpt ? "ChatGPT plan" : "OpenRouter key").font(.subheadline.weight(.medium))
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private func providerMoney(_ title: String, _ value: Double?) -> some View {
        if let value { money(title, value) }
        else { LabeledContent(title, value: "Unavailable").foregroundStyle(.secondary) }
    }
    @MainActor private func clearProviderUsage() {
        providerUsageTask?.cancel(); providerUsageTask = nil
        providerUsageGeneration = UUID(); checkingProviderUsage = false
        providerUsage = nil; providerUsageError = nil
    }
    @MainActor private func refreshProviderUsage() async {
        let owner = chat.accountID
        let generation = UUID(); providerUsageGeneration = generation
        providerUsage = nil; providerUsageError = nil
        guard chat.connectedProviders.contains(.openRouter) else { checkingProviderUsage = false; return }
        checkingProviderUsage = true
        defer { if providerUsageGeneration == generation { checkingProviderUsage = false } }
        do {
            guard let key = try chat.key(for: .openRouter) else { throw ProviderAccountUsageError.missingKey }
            let value = try await ProviderAccountUsageService().fetch(accountID: owner, provider: .openRouter, key: key)
            guard !Task.isCancelled, providerUsageGeneration == generation, chat.accountID == owner,
                  chat.connectedProviders.contains(.openRouter), try chat.key(for: .openRouter) == key else { return }
            providerUsage = value
        } catch {
            guard !Task.isCancelled, providerUsageGeneration == generation, chat.accountID == owner else { return }
            providerUsageError = (error as? ProviderAccountUsageError)?.localizedDescription
                ?? "Provider usage could not be checked. Try again later."
        }
    }
    private func money(_ title: String, _ value: Double) -> some View {
        LabeledContent(title) {
            Text(value.formatted(.currency(code: "USD").precision(.fractionLength(2...6)))).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct AIMAccountMemoryView: View {
    let chat: NativeChatStore
    let legacyService: any CloudContentServicing
    let summary: Bool
    let openSummary: () -> Void
    let back: () -> Void
    @State private var editing: AccountMemoryEntry?
    @State private var draft = ""
    @State private var subject = ""
    @State private var dirty = false
    @State private var discard = false
    @State private var deleting: AccountMemoryEntry?
    @State private var base = AccountMemorySnapshot()
    @State private var adding = false
    @State private var project: UUID?
    @State private var legacyPreview: String?
    var body: some View {
        AIMSettingsPageContainer {
            AIMSettingsPageHeader(title: editing == nil ? (summary ? "Memory summary" : "Memory") : "Edit memory", back: leave)
            AIMSettingsForm {
                if let entry = editing {
                    Section { TextField("Subject", text: $subject).textFieldStyle(.roundedBorder); Picker("Scope", selection: $project) { Text("General").tag(UUID?.none); ForEach(chat.projects) { Text($0.name).tag(Optional($0.id)) } }; AIMSettingsEditor(title: "Memory", text: $draft) }
                    Section {
                        Button("Save") { Task { await saveEntry() } }.foregroundStyle(.primary)
                    }
                } else if !summary {
                    Section {
                        Toggle("Enable memory", isOn: Binding(get: { chat.memory.enabled }, set: { enabled in Task { var value = chat.memory; value.enabled = enabled; _ = await chat.saveMemory(value) } })).tint(.green)
                    } footer: {
                        Text("After a successful Chat response, AIM makes an additional request to the same provider and model to propose memories. Its API cost counts toward this iPhone’s budget. New memories require review before use. Turning this off stops capture and recall without deleting saved entries.")
                    }
                    Section { AIMSettingsAction(title: "Memory summary", icon: "brain.head.profile", value: "\(chat.memory.entries.count)", action: openSummary) }
                    AIMSettingsMessage(text: "Shared with your AIM account. Only relevant, reviewed entries are used in requests.")
                    if chat.isCapturingMemory { Text("Capturing memory…").font(.caption).foregroundStyle(.secondary) }
                    if let message = chat.memoryCaptureMessage { AIMSettingsMessage(text: message) }
                } else {
                    ForEach(chat.memory.entries.filter { !$0.archived }) { entry in
                        memorySection(entry)
                    }
                    Section { Button("Add memory", systemImage: "plus") { base = chat.memory; editing = .init(subject: "", content: ""); subject = ""; draft = ""; project = nil; adding = true }
                    }
                    Section {
                        Button("Preview earlier memory") { Task { await previewLegacy() } }
                        if let legacyPreview, !legacyPreview.isEmpty {
                            Text(legacyPreview).font(.subheadline).lineLimit(8)
                            Button("Import this memory") { Task { await importLegacy(legacyPreview) } }
                        }
                    } header: { Text("Earlier iPhone memory") } footer: { Text("Review before importing. The original document is kept.") }
                    if chat.memory.entries.isEmpty { Text("No saved memory yet").foregroundStyle(.secondary) }
                }
                if let error = chat.accountDataError { AIMSettingsMessage(text: error) }
            }
        }.task { await chat.syncAccountData() }
        .onChange(of: draft) { _, _ in dirty = editing?.content != draft || editing?.subject != subject }
        .onChange(of: subject) { _, _ in dirty = editing?.content != draft || editing?.subject != subject }
        .interactiveDismissDisabled(dirty).settingsDraftNavigationProtection(editing != nil, onBackAttempt: leave)
        .alert("Save changes?", isPresented: $discard) { Button("Keep editing", role: .cancel) {}; Button("Discard", role: .destructive) { editing = nil; dirty = false }; Button("Save") { Task { await saveEntry() } } }
        .alert("Delete this memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { Task { await deleteMemory() } }
        }
        .onChange(of: project) { _, _ in dirty = editing?.projectID != project || editing?.subject != subject || editing?.content != draft }
    }
    private func saveEntry() async {
        guard var entry = editing else { return }; var value = base
        entry.subject = subject.trimmingCharacters(in: .whitespacesAndNewlines); entry.content = draft; entry.projectID = project; entry.reviewed = true
        entry.reviewStatus = "verified"; entry.scope = project == nil ? "global" : "project"; entry.scopeKey = project?.uuidString ?? "self"
        entry.updatedAt = .now
        if adding { entry.createdAt = .now; entry.kind = "fact" }
        if let i = value.entries.firstIndex(where: { $0.id == entry.id }) { value.entries[i] = entry } else { value.entries.append(entry) }
        if await chat.saveMemory(value) { editing = nil; dirty = false; adding = false }
    }
    private func previewLegacy() async {
        do { let document = try await legacyService.loadMemoryDocument(); legacyPreview = document.content }
        catch { chat.accountDataError = "Earlier memory could not be loaded. Its original document is preserved." }
    }
    private func importLegacy(_ content: String) async {
        var value = chat.memory
        let source = "ios-memory-document"
        guard !value.entries.contains(where: { $0.sourceID == source && $0.content == content }) else { return }
        let entry = AccountMemoryEntry(subject: "Earlier iPhone memory", content: content, sourceID: source, kind: "fact", scope: "global", scopeKey: "self", reviewStatus: "verified", createdAt: .now, updatedAt: .now)
        value.entries.append(entry)
        if await chat.saveMemory(value) { legacyPreview = nil }
    }
    private func deleteMemory() async {
        guard let entry = deleting else { return }
        var value = chat.memory; value.entries.removeAll { $0.id == entry.id }
        if await chat.saveMemory(value) { deleting = nil }
    }
    private func pinBinding(_ entry: AccountMemoryEntry) -> Binding<Bool> {
        Binding(get: { entry.pinned }, set: { pin in Task {
            var value = chat.memory
            if let i = value.entries.firstIndex(where: { $0.id == entry.id }) {
                value.entries[i].pinned = pin; value.entries[i].updatedAt = .now
                _ = await chat.saveMemory(value)
            }
        } })
    }
    private func memorySection(_ entry: AccountMemoryEntry) -> some View {
        Section {
            AIMSettingsAction(title: entry.subject, value: entry.projectID == nil ? "General" : "Project") {
                base = chat.memory; editing = entry; project = entry.projectID; subject = entry.subject; draft = entry.content; dirty = false; adding = false
            }
            Text(entry.content).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            Toggle("Pinned", isOn: pinBinding(entry)).tint(.green)
            Button("Delete") { deleting = entry }.foregroundStyle(.primary)
            if let source = entry.sourceID { Text("Source: \(source)").font(.caption).foregroundStyle(.secondary) }
            if let evidence = entry.evidence, !evidence.isEmpty { Text("Evidence: \(evidence)").font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if !entry.reviewed || (entry.reviewStatus != nil && entry.reviewStatus != "verified") { Text("Review needed").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func leave() { if editing != nil { if dirty { discard = true } else { editing = nil } } else { back() } }
}
