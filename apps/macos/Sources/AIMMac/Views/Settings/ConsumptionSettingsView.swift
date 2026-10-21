import AIMApplication
import AIMCore
import SwiftUI

struct ConsumptionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var limitEnabled = false
    @State private var limitAmount = ""
    @State private var budgetProtection: SpendBudgetProtection = .estimated
    @State private var period: SpendPeriod = .calendarMonth
    @State private var breakdownDimension: SpendBreakdownDimension = .provider
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var accountPeriod: AccountActivityFilter.Period = .month
    @State private var accountDevice = "all"
    @State private var accountProvider = "all"
    @State private var accountModel = "all"
    @State private var accountMode = "all"
    @State private var accountTimeZone = TimeZone.current.identifier

    private var accountRows: [AccountActivityRecord] {
        guard let accountID = model.account.accessUser?.id else { return [] }
        return AccountActivityFilter(period: accountPeriod, timeZoneID: accountTimeZone,
            deviceID: accountDevice == "all" ? nil : accountDevice, provider: accountProvider == "all" ? nil : accountProvider,
            modelID: accountModel == "all" ? nil : accountModel, mode: accountMode == "all" ? nil : accountMode)
            .apply(model.accountActivityRecords, accountID: accountID)
    }

    var body: some View {
        SettingsPage("Usage & costs", subtitle: "What this installation spends on your provider accounts, and an optional limit.") {
            if let accountID = model.account.accessUser?.id {
                accountActivity(accountID: accountID)
            }
            UsageAccountsGroup()
            SettingsGroup("Global spending limit", footer: "Estimated protection counts known charges and reservations. Unreported completed charges remain visible but do not block new priced requests; the provider bill can exceed this estimate. Strict protection also pauses for unpriced history and unbounded web requests. Provider billing outside this AIM installation is not covered.") {
                SettingsToggleRow("Limit billable requests", description: "Applies to every request AIM sends with your keys.", isOn: $limitEnabled)
                if limitEnabled {
                    SettingsMenuRow("Budget protection", selection: $budgetProtection, options: [
                        (.estimated, "Estimated"), (.strict, "Strict")])
                    SettingsRow("Amount", description: "In US dollars.") {
                        TextField("e.g. 20", text: $limitAmount).textFieldStyle(.settings).frame(width: 120)
                            .accessibilityIdentifier("global-spend-limit-amount")
                    }
                    SettingsMenuRow("Period", selection: $period, options: [
                        (SpendPeriod.day, "Per day"), (.calendarMonth, "Calendar month"), (.envelope, "Envelope without renewal")])
                }
                SettingsRow("Period time zone") {
                    Text(timeZoneID).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                SettingsRow("Save changes", description: saveError) {
                    Button(isSaving ? "Saving…" : "Save limit") { Task { await savePolicy() } }
                        .buttonStyle(.settingsPrimary).disabled(isSaving)
                }
            }
            SettingsGroup("This installation", footer: "A request with no verified price receipt remains unknown. These figures are not a provider invoice and exclude use of the same API keys outside AIM.") {
                if let snapshot = model.spendSnapshot {
                    HStack(spacing: 0) {
                        figure("Known subtotal", "$\(snapshot.countedUSD)")
                        figure("Confirmed", "$\(snapshot.confirmedUSD)")
                        figure("Reserved", "$\(snapshot.reservedUSD)")
                        figure("Estimated", "$\(snapshot.estimatedUSD)")
                        figure("Unknown cost", "\(snapshot.unknownAttempts)")
                    }
                    .padding(.vertical, 6)
                    SettingsRow("Budget protection", description: snapshot.unknownAttempts > 0
                        ? (snapshot.policy.protection == .estimated
                            ? "Completed unreported charges are excluded from the known subtotal; they are not free. Unsettled unpriced attempts still pause requests."
                            : "Unreported charges must be reconciled before new requests.") : nil) {
                        Text(snapshot.policy.protection == .estimated ? "Estimated" : "Strict")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    SettingsRow("Global limit") {
                        Text(snapshot.policy.enabled ? "$\(snapshot.policy.limitUSD ?? "?") USD · \(periodName(snapshot.policy.period))" : "Off")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if let start = snapshot.periodStart, let end = snapshot.periodEnd {
                        SettingsRow("Current period") {
                            Text("\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    SettingsBlock { ProgressView("Loading usage…").controlSize(.small) }
                }
                if let error = model.spendReportError { SettingsBlock { SettingsNotice(error, tone: .error) } }
                SettingsRow("Figures", description: "Updated after each request.") {
                    Button("Refresh") { Task { await model.loadSpendReport() } }.buttonStyle(.settings)
                }
            }
            SettingsGroup("Current-period breakdown") {
                SettingsMenuRow("Group by", selection: $breakdownDimension, options: [
                    (SpendBreakdownDimension.provider, "Provider"), (.model, "Model"), (.feature, "Function")])
                if let breakdown = model.spendBreakdown {
                    let rows = switch breakdownDimension {
                    case .provider: breakdown.providers
                    case .model: breakdown.models
                    case .feature: breakdown.features
                    }
                    if rows.isEmpty { SettingsRow("No billable requests in this period") }
                    ForEach(rows) { row in
                        SettingsRow(row.label, description: "\(row.attemptCount) requests · $\(row.estimatedUSD) estimated · $\(row.reservedUSD) reserved · \(row.unknownAttempts) unknown · \(row.exceptionCount) one-attempt exceptions") {
                            Text("$\(row.confirmedUSD)").font(.system(size: 14, weight: .medium)).monospacedDigit()
                        }
                    }
                }
            }
            SettingsGroup("Recent requests") {
                if model.recentSpendAttempts.isEmpty { SettingsRow("No recorded requests yet") }
                ForEach(model.recentSpendAttempts) { attempt in
                    SettingsRow("\(attempt.provider) · \(attempt.modelID)",
                                description: "\(attempt.feature) · \(attempt.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(attempt.state.rawValue)\(attempt.isException ? " · one-attempt exception" : "")") {
                        Text(amountLabel(attempt)).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if !model.recentSpendCorrections.isEmpty {
                SettingsGroup("Cost corrections") {
                    ForEach(model.recentSpendCorrections) { correction in
                        SettingsRow("\(correction.provider) · \(correction.modelID)",
                                    description: "\(correction.feature) · receipt \(correction.sourceID) · \(correction.occurredAt.formatted(date: .abbreviated, time: .shortened))") {
                            Text("$\(correction.previousUSD) → $\(correction.correctedUSD)").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            await model.loadSpendReport()
            await model.refreshAccountActivity()
            if let policy = model.spendSnapshot?.policy {
                limitEnabled = policy.enabled
                limitAmount = policy.limitUSD ?? ""
                period = policy.period
                timeZoneID = policy.timeZoneID
                budgetProtection = policy.protection
            }
        }
    }

    private func accountActivity(accountID: UUID) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: accountTimeZone) ?? .gmt
        let ownedRecords = AccountActivityRecord.merge(model.accountActivityRecords, accountID: accountID)
        let summary = AccountActivitySummary(records: accountRows, accountID: accountID, calendar: calendar)
        return SettingsGroup("AIM account activity", footer: "Same account records on Mac and iPhone. Provider accounts may include other applications. Historical local data is kept until you choose to import it.") {
            SettingsMenuRow("Period", selection: $accountPeriod, options: [(.day, "Today"), (.week, "This week"), (.month, "This month"), (.year, "This year"), (.all, "All time")])
            SettingsMenuRow("Time zone", selection: $accountTimeZone, options: Array(Set([TimeZone.current.identifier, "UTC", "Europe/Paris", "America/New_York", "Asia/Tokyo"])).sorted().map { ($0, $0) })
            SettingsMenuRow("Device", selection: $accountDevice, options: [("all", "All devices")] + Array(Set(ownedRecords.map(\.deviceID))).sorted().map { id in
                (id, ownedRecords.first { $0.deviceID == id }?.deviceName ?? id)
            })
            SettingsMenuRow("Provider", selection: $accountProvider, options: [("all", "All providers")] + Array(Set(ownedRecords.map(\.provider))).sorted().map { ($0, $0) })
            SettingsMenuRow("Model", selection: $accountModel, options: [("all", "All models")] + Array(Set(ownedRecords.map(\.modelID))).sorted().map { ($0, $0) })
            SettingsMenuRow("Mode", selection: $accountMode, options: [("all", "All modes"), ("chat", "Chat"), ("code", "Code"), ("agent", "Agent"), ("voice", "Voice")])
            HStack(spacing: 0) {
                figure("Confirmed", currency(summary.confirmedUSD))
                figure("Estimated", currency(summary.estimatedUSD))
                figure("Reserved", currency(summary.reservedUSD))
                figure("Unknown costs", summary.unknownCosts.formatted())
            }
            if let date = model.accountActivitySyncedAt { SettingsRow("Last sync") { Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) } }
            SettingsRow("Account activity", description: model.accountActivityError) {
                Button("Refresh") { Task { await model.refreshAccountActivity() } }.buttonStyle(.settings)
            }
            ForEach(accountRows.filter { $0.kind == .cost || ([.response, .voice].contains($0.kind) && $0.costTrackedSeparately != true) }.reversed().prefix(20)) { row in
                SettingsRow(row.modelID, description: "\(row.deviceName) · \(row.mode) · \(row.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(row.costState.rawValue)") {
                    Text(row.costUSD.map(currency) ?? "Unknown").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func currency(_ amount: Double) -> String { amount.formatted(.currency(code: "USD").precision(.fractionLength(2...6))) }

    private func savePolicy() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.configureSpendPolicy(GlobalSpendPolicy(enabled: limitEnabled,
                limitUSD: limitEnabled ? limitAmount.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                period: period, timeZoneID: timeZoneID, requiresVerifiedWebSearch: budgetProtection == .strict))
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsMetrics.rowHorizontal).padding(.vertical, 10)
    }

    private func amountLabel(_ attempt: SpendAttempt) -> String {
        if let actual = attempt.actualUSD { return "$\(actual) USD" }
        if let estimate = attempt.estimatedUSD { return "Estimated $\(estimate) USD · no provider receipt" }
        if let maximum = attempt.maximumUSD { return "Up to $\(maximum) USD" }
        return attempt.state == .notSent ? "Not sent" : "Cost unknown"
    }

    private func periodName(_ period: SpendPeriod) -> String {
        switch period {
        case .day: "per day"
        case .calendarMonth: "per month"
        case .envelope: "envelope"
        }
    }
}

/// Plans and credits on your accounts: the ChatGPT plan and the OpenRouter key.
private struct UsageAccountsGroup: View {
    @Environment(AppModel.self) private var model
    @State private var openRouter: (usage: Double, limit: Double?)?
    @State private var loaded = false

    var body: some View {
        if model.connectedProviders.contains(.chatgpt) || model.connectedProviders.contains(.openRouter) {
            SettingsGroup("Accounts") {
                if model.connectedProviders.contains(.chatgpt) {
                    SettingsRow(title: "ChatGPT plan", description: "Requests use the usage included in your plan; OpenAI resets it on its own schedule.",
                                leading: { ProviderLogo(provider: .chatgpt, size: 22).frame(width: 28) }) {
                        Link("Manage usage", destination: ChatGPTPlanAuth.manageUsageURL).font(.system(size: 12.5))
                    }
                }
                if model.connectedProviders.contains(.openRouter) {
                    SettingsRow(title: "OpenRouter key", description: openRouterText,
                                leading: { ProviderLogo(provider: .openRouter, size: 22).frame(width: 28) }) {
                        Link("Credits", destination: URL(string: "https://openrouter.ai/settings/credits")!).font(.system(size: 12.5))
                    }
                }
            }
            .task {
                openRouter = await model.openRouterKeyUsage()
                loaded = true
            }
        }
    }

    private var openRouterText: String {
        guard let openRouter else { return loaded ? "Usage unavailable right now." : "Loading…" }
        let used = openRouter.usage.formatted(.currency(code: "USD"))
        guard let limit = openRouter.limit else { return "\(used) spent with this key (all apps)." }
        return "\(used) of \(limit.formatted(.currency(code: "USD"))) spent with this key."
    }
}
