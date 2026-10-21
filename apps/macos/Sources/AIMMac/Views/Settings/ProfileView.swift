import AIMCore
import AIMApplication
import AppKit
import SwiftUI

/// The user's profile, as in ChatGPT: lifetime figures, a year of token activity, favourite
/// models and tools, and insights. Everything is computed on this Mac from AIM's own records.
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var metrics: [TurnMetrics] = []
    @State private var activity: [Date] = []
    @State private var tools: [(name: String, count: Int)] = []
    @State private var spend: Double = 0
    @State private var scope: UsageProfile.Scope = .all
    @State private var heatmap: UsageProfile.HeatmapMode = .daily
    @State private var loaded = false
    @State private var period = AccountActivityFilter.Period.all
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var legacyPreview: [AccountActivityImportItem] = []
    @State private var legacySelection: Set<UUID> = []
    @State private var legacyAccountID: UUID?
    @State private var legacyMessage: String?
    @State private var importing = false
    @State private var detailDay: Date?
    private var activityCalendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt; return value }
    private var accountRows: [AccountActivityRecord] {
        guard let id = model.account.accessUser?.id else { return [] }
        return AccountActivityFilter(period: period, timeZoneID: timeZoneID).apply(model.accountActivityRecords, accountID: id).filter { row in
            let local = ["local", "ollama", "lmStudio"].contains(row.provider)
            if row.provider == "unknown" { return scope == .all }
            return scope == .all || (scope == .local) == local
        }
    }
    private var accountSummary: AccountActivitySummary? {
        model.account.accessUser.map { AccountActivitySummary(records: accountRows, accountID: $0.id, calendar: activityCalendar) }
    }

    private var debugHover: Date? {
        #if DEBUG
        model.debugProfileSample?.metrics.last?.startedAt
        #else
        nil
        #endif
    }

    private var user: AuthenticatedUserSummary { AuthenticatedUserSummary(model.account.accessUser) }
    private var profile: UsageProfile {
        if let id = model.account.accessUser?.id {
            return UsageProfile.compute(records: accountRows, accountID: id, calendar: activityCalendar)
        }
        return UsageProfile.compute(metrics: metrics, activity: activity, scope: scope)
    }
    private var displayedTools: [(name: String, count: Int)] {
        guard let id = model.account.accessUser?.id else { return tools }
        return (accountSummary?.toolUses ?? []).map { (name: $0.title, count: $0.count) }
    }
    private var displayedSpend: Double {
        guard let id = model.account.accessUser?.id else { return spend }
        let summary = AccountActivitySummary(records: accountRows, accountID: id, calendar: activityCalendar)
        return summary.confirmedUSD + summary.estimatedUSD
    }

    var body: some View {
        let profile = profile
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Spacer()
                    Button { model.settingsSection = .account } label: { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(.settings)
                    Button { share(profile) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.settings)
                }
                .padding(.bottom, 8)

                ProfileIdentity(name: user.name, since: profile.firstActivity)
                    .padding(.bottom, 26)

                HStack {
                    Spacer()
                    ProfileTabs(selection: $scope, options: [(.all, "All"), (.online, "Online"), (.local, "Local models")])
                }
                .padding(.bottom, 10)
                if model.account.accessUser != nil {
                    SettingsMenuRow("Period", selection: $period, options: [(.day, "Today"), (.week, "This week"), (.month, "This month"), (.year, "This year"), (.all, "All time")])
                    SettingsMenuRow("Time zone", selection: $timeZoneID, options: Array(Set([TimeZone.current.identifier, "UTC", "Europe/Paris", "America/New_York", "Asia/Tokyo"])).sorted().map { ($0, $0) })
                }
                ProfileFigures(profile: profile)
                if profile.unmeasuredResponses > 0 {
                    Text("\(profile.unmeasuredResponses) responses have no reported token count.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                if let date = model.accountActivitySyncedAt {
                    Text("Account activity · synced \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 8)
                }
                if let message = model.accountActivityError { Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 8) }

                section("Token activity", trailing: {
                    ProfileTabs(selection: $heatmap, options: [(.daily, "Daily"), (.weekly, "Weekly"), (.cumulative, "Cumulative")])
                }) {
                    TokenHeatmap(profile: profile, mode: heatmap, calendar: activityCalendar, initialHover: debugHover)
                    if let since = profile.measuringSince {
                        Text("Tokens are counted since \(since.formatted(date: .abbreviated, time: .omitted)).")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    } else {
                        Text("Tokens are counted from your next answers on: this grid fills in as you use AIM.")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    }
                }

                if !profile.topModels.isEmpty {
                    section("Top models") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                            ForEach(profile.topModels, id: \.id) { use in modelCard(use) }
                        }
                    }
                }

                if !displayedTools.isEmpty {
                    section("Top tools") {
                        FlowRow(spacing: 8) {
                            ForEach(displayedTools, id: \.name) { tool in
                                HStack(spacing: 6) {
                                    Text(WorkspaceProgressView.title(for: tool.name)).font(.system(size: 12.5, weight: .medium))
                                    Text(tool.count.formatted()).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(AIMTheme.card(scheme), in: Capsule())
                                .overlay(Capsule().strokeBorder(AIMTheme.cardBorder(scheme)))
                            }
                        }
                    }
                }

                section("Insights") {
                    VStack(spacing: 0) {
                        insight("Answers measured", profile.answers > 0 ? profile.answers.formatted() : "None yet")
                        insight("Most used reasoning", profile.effortShares.first.map {
                            Self.effortName($0.effort) + " · " + $0.share.formatted(.percent.precision(.fractionLength(0)))
                        } ?? "—")
                        insight("Chat or Agent", profile.chatShare.map {
                            $0 >= 0.5 ? "Chat · " + $0.formatted(.percent.precision(.fractionLength(0)))
                                      : "Agent · " + (1 - $0).formatted(.percent.precision(.fractionLength(0)))
                        } ?? "—")
                        insight("Local-model answers", profile.localShare.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                        insight("Local speed", profile.averageLocalSpeed.map { AnswerMetricsBadge.number($0, digits: 1) + " tok/s" } ?? "—")
                        insight("Days active", profile.activeDays.count.formatted())
                        insight("Waiting in longest task", accountSummary?.longestTaskWaiting.map(ProfileFigures.duration) ?? "—")
                        insight("Measured task waiting", accountSummary?.measuredWaitingSeconds.map(ProfileFigures.duration) ?? "—")
                        insight("Recorded provider spend", displayedSpend > 0 ? "$" + AnswerMetricsBadge.number(displayedSpend, digits: displayedSpend < 1 ? 3 : 2) : "—")
                    }
                }
                if model.account.accessUser != nil {
                    section("Earlier local activity") {
                        Text("Review and select activity to attach to this account. Original conversations are kept; unknown tokens and task durations remain unavailable.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Preview earlier activity") { Task { await previewHistory() } }.buttonStyle(.settings)
                        ForEach(legacyPreview) { item in
                            Toggle(isOn: Binding(get: { legacySelection.contains(item.id) }, set: { selected in
                                if selected { legacySelection.insert(item.id) } else { legacySelection.remove(item.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.subheadline)
                                    Text("\(item.record.kind.rawValue.capitalized) · \(item.record.modelID) · \(item.record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.record.totalTokens?.formatted() ?? "—") tokens")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.tint(.green).disabled(importing)
                        }
                        if !legacyPreview.isEmpty {
                            Button("Import \(legacySelection.count) selected records") { Task { await importHistory() } }
                                .buttonStyle(.settings).disabled(legacySelection.isEmpty || importing)
                        }
                        if let legacyMessage { Text(legacyMessage).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
        .animation(.easeOut(duration: 0.2), value: scope)
        .onChange(of: model.account.accessUser?.id) { _, _ in legacyPreview = []; legacySelection = []; legacyAccountID = nil; legacyMessage = nil }
    }

    private func previewHistory() async {
        guard let id = model.account.accessUser?.id else { return }
        do {
            let rows = try await model.accountActivityRepository.legacyPreview(accountID: id)
            guard model.account.accessUser?.id == id else { return }
            legacyAccountID = id; legacyPreview = rows; legacySelection = []; legacyMessage = rows.isEmpty ? "No earlier activity to import." : nil
        } catch { legacyMessage = "Earlier activity could not be read. Original records are preserved." }
    }
    private func importHistory() async {
        guard let id = legacyAccountID, model.account.accessUser?.id == id else { legacyPreview = []; legacySelection = []; return }
        importing = true; defer { importing = false }
        do {
            let count = try await model.accountActivityRepository.importLegacy(legacyPreview, selectedIDs: legacySelection, accountID: id)
            guard model.account.accessUser?.id == id else { return }
            await model.refreshAccountActivity(); await previewHistory(); legacyMessage = "\(count) activity records imported. Originals were kept."
        } catch { legacyMessage = "The preview changed or a record is already attributed. Refresh before importing." }
    }
    private func load() async {
        await model.refreshAccountActivity()
        let repository = model.metricsRepository
        metrics = (try? await repository.all()) ?? []
        activity = (try? await repository.userMessageDates()) ?? []
        tools = (try? await repository.toolCallCounts()) ?? []
        spend = (try? await repository.recordedSpendUSD()) ?? 0
        #if DEBUG
        if let sample = model.debugProfileSample { metrics = sample.metrics; activity = sample.activity; tools = sample.tools }
        #endif
        loaded = true
    }

    private func section<Content: View, Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
                                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                trailing()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 38)
    }

    private func insight(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 13.5))
        .padding(.vertical, 10)
    }

    private func modelCard(_ use: UsageProfile.ModelUse) -> some View {
        let provider = ChatProvider(rawValue: use.provider) ?? .openRouter
        let presentation = model.presentation(provider: provider, modelID: use.modelID)
        return HStack(spacing: 10) {
            ModelCreatorLogo(creator: presentation.creator, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(use.answers.formatted()) answers · \(use.measuredTokens.map(AnswerMetricsBadge.tokens) ?? "—") measured tokens")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }

    static func effortName(_ raw: String) -> String {
        OpenAIReasoningEffort(rawValue: raw)?.title ?? raw.capitalized
    }

    /// A PNG card of the profile (figures and activity), shared or saved by the user.
    private func share(_ profile: UsageProfile) {
        let card = ProfileShareCard(name: user.name, profile: profile)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIM profile.png")
        do { try png.write(to: url) } catch { return }
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: view.bounds.maxX - 120, y: view.bounds.maxY - 60, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}

/// Avatar with two initials, the name and how long the user has been on AIM.
private struct ProfileIdentity: View {
    let name: String
    let since: Date?

    var body: some View {
        VStack(spacing: 10) {
            ProfileAvatar(name: name, size: 92)
            Text(name).font(.system(size: 24, weight: .semibold))
            if let since {
                Text("Using AIM since \(since.formatted(.dateTime.month(.wide).year()))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ProfileAvatar: View {
    let name: String
    var size: CGFloat = 92

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.count > 1 ? words.compactMap(\.first).map(String.init).joined() : String(name.prefix(2))
        return letters.uppercased()
    }

    /// A steady colour per name.
    private var hue: Double {
        Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.72),
                                                 Color(hue: hue, saturation: 0.62, brightness: 0.55)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Text tabs ("Daily · Weekly · Cumulative"), the selected one in full colour.
struct ProfileTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(options, id: \.0) { option in
                Button { withAnimation(.snappy(duration: 0.2)) { selection = option.0 } } label: {
                    Text(option.1).font(.system(size: 13, weight: selection == option.0 ? .semibold : .regular))
                        .foregroundStyle(selection == option.0 ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Five figures in one rounded strip.
struct ProfileFigures: View {
    let profile: UsageProfile
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            figure(profile.answers > 0 && profile.unmeasuredResponses == profile.answers ? "—" : AnswerMetricsBadge.tokens(profile.lifetimeTokens), "Measured tokens")
            divider
            figure(profile.answers > 0 && profile.unmeasuredResponses == profile.answers ? "—" : AnswerMetricsBadge.tokens(profile.peakTokens), "Peak tokens")
            divider
            figure(profile.longestTaskSeconds.map(Self.duration) ?? "—", "Longest task")
            divider
            figure(Self.days(profile.longestStreak), "Longest streak")
            divider
            figure(Self.days(profile.currentStreak), "Current streak")
        }
        .padding(.vertical, 14)
        .background(AIMTheme.card(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AIMTheme.cardBorder(scheme)))
    }

    private var divider: some View { Rectangle().fill(AIMTheme.rowDivider(scheme)).frame(width: 1, height: 34) }

    private func figure(_ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit().contentTransition(.numericText())
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    static func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3_600 { return "\(total / 3_600)h \((total % 3_600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(max(total, 1))s"
    }
}

/// A year of days in weekly columns; hovering a day shows its date and tokens.
struct TokenHeatmap: View {
    let profile: UsageProfile
    let mode: UsageProfile.HeatmapMode
    var calendar: Calendar = .current
    var interactive = true
    /// A day shown hovered from the start (debug gallery).
    var initialHover: Date?
    @State private var hovered: Date?
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    /// 53 weeks ending with the current one, Monday or Sunday first as the user's calendar says.
    private var weeks: [[Date]] {
        let today = calendar.startOfDay(for: .now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .weekOfYear, value: -52, to: thisWeek) ?? thisWeek
        return (0..<53).map { week in
            (0..<7).compactMap { day in calendar.date(byAdding: .day, value: week * 7 + day, to: first) }
        }
    }

    var body: some View {
        let weeks = weeks
        let days = weeks.flatMap { $0 }
        let values = profile.heatmapValues(days: days, mode: mode, calendar: calendar)
        let maximum = max(values.values.max() ?? 0, 1)
        let today = calendar.startOfDay(for: .now)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let size = min(cell, (geometry.size.width - gap * 52) / 53)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(week, id: \.self) { day in
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(day > today ? Color.clear : color(values[day] ?? 0, maximum: maximum))
                                    .frame(width: size, height: size)
                                    .overlay {
                                        if hovered == day {
                                            RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                                        }
                                    }
                                    .onHover { inside in
                                        guard interactive, day <= today else { return }
                                        if inside { hovered = day } else if hovered == day { hovered = nil }
                                    }
                                    .overlay(alignment: .bottom) {
                                        if hovered == day {
                                            tooltip(day, values[day] ?? 0)
                                                .fixedSize()
                                                .offset(y: -size - 8)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .zIndex(hovered == day ? 1 : 0)
                            }
                        }
                        .zIndex(week.contains(hovered ?? .distantPast) ? 1 : 0)
                    }
                }
            }
            .frame(height: cell * 7 + gap * 6)
            .onAppear { if let initialHover { hovered = Calendar.current.startOfDay(for: initialHover) } }
            HStack(spacing: 0) {
                ForEach(monthLabels(weeks), id: \.offset) { label in
                    Text(label.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func tooltip(_ day: Date, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day().month(.abbreviated)))
            Text(value == 0 ? "No tokens" : AnswerMetricsBadge.tokens(value) + " tokens" + (mode == .weekly ? " this week" : mode == .cumulative ? " in total" : ""))
        }
        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func color(_ value: Int, maximum: Int) -> Color {
        guard value > 0 else { return Color.primary.opacity(0.06) }
        let level = Double(value) / Double(maximum)
        let tint = Color.primary
        return tint.opacity(level > 0.75 ? 1 : level > 0.5 ? 0.75 : level > 0.25 ? 0.5 : 0.28)
    }

    /// One label per month, spread over 12 equal slots like ChatGPT's.
    private func monthLabels(_ weeks: [[Date]]) -> [(offset: Int, title: String)] {
        guard !weeks.isEmpty else { return [] }
        return (0..<12).reversed().enumerated().compactMap { index, back in
            calendar.date(byAdding: .month, value: -back, to: .now).map { (index, $0.formatted(.dateTime.month(.abbreviated))) }
        }
    }
}

/// The image shared from the profile.
private struct ProfileShareCard: View {
    let name: String
    let profile: UsageProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                ProfileAvatar(name: name, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 22, weight: .semibold))
                    Text("on AIM").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                AIMLogoView(size: 30)
            }
            ProfileFigures(profile: profile)
            VStack(alignment: .leading, spacing: 10) {
                Text("Token activity").font(.system(size: 14, weight: .semibold))
                TokenHeatmap(profile: profile, mode: .daily, interactive: false)
            }
        }
        .padding(28)
        .frame(width: 760)
        .background(Color.white)
    }
}
