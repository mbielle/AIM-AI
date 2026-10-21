import AIMCore
import Foundation

/// The user's statistics for the profile page, computed from what AIM recorded.
public struct UsageProfile: Equatable, Sendable {
    public enum Scope: String, CaseIterable, Sendable { case all, online, local }

    public struct ModelUse: Equatable, Sendable {
        public let modelID: String
        public let provider: String
        public let answers: Int
        public let tokens: Int
        public var unmeasuredAnswers: Int = 0
        public var id: String { provider + ":" + modelID }
        public var measuredTokens: Int? { answers > 0 && unmeasuredAnswers == answers ? nil : tokens }
    }

    public var lifetimeTokens = 0
    public var peakTokens = 0
    public var longestTaskSeconds: Double?
    public var longestStreak = 0
    public var currentStreak = 0
    /// Tokens per day (start of day in the user's calendar).
    public var dailyTokens: [Date: Int] = [:]
    public var activeDays: Set<Date> = []
    public var answers = 0
    public var unmeasuredResponses = 0
    public var measuringSince: Date?
    public var firstActivity: Date?
    public var topModels: [ModelUse] = []
    /// Effort level → share of answers that set one.
    public var effortShares: [(effort: String, share: Double)] = []
    public var chatShare: Double?
    public var localShare: Double?
    public var averageLocalSpeed: Double?

    public static func == (lhs: UsageProfile, rhs: UsageProfile) -> Bool {
        lhs.lifetimeTokens == rhs.lifetimeTokens && lhs.peakTokens == rhs.peakTokens && lhs.dailyTokens == rhs.dailyTokens
            && lhs.longestStreak == rhs.longestStreak && lhs.currentStreak == rhs.currentStreak && lhs.answers == rhs.answers
            && lhs.topModels == rhs.topModels && lhs.activeDays == rhs.activeDays
            && lhs.longestTaskSeconds == rhs.longestTaskSeconds && lhs.unmeasuredResponses == rhs.unmeasuredResponses
    }

    public init() {}

    public static func compute(metrics: [TurnMetrics], activity: [Date], scope: Scope = .all,
                               calendar: Calendar = .current, now: Date = .now) -> UsageProfile {
        var profile = UsageProfile()
        let all = metrics
        let selected = metrics.filter { scope == .all || (scope == .local) == $0.isLocal }
        profile.answers = selected.count
        profile.measuringSince = all.map(\.startedAt).min()
        for metric in selected {
            let tokens = metric.totalTokens
            profile.lifetimeTokens += tokens
            profile.peakTokens = max(profile.peakTokens, tokens)
            profile.dailyTokens[calendar.startOfDay(for: metric.startedAt), default: 0] += tokens
        }

        // Streaks count days with at least one message, from the whole history.
        profile.activeDays = Set(activity.map { calendar.startOfDay(for: $0) })
            .union(all.map { calendar.startOfDay(for: $0.startedAt) })
        profile.firstActivity = profile.activeDays.min()
        let days = profile.activeDays.sorted()
        var run = 0
        var previous: Date?
        for day in days {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 { run += 1 } else { run = 1 }
            profile.longestStreak = max(profile.longestStreak, run)
            previous = day
        }
        let today = calendar.startOfDay(for: now)
        var cursor = profile.activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while profile.activeDays.contains(cursor) {
            profile.currentStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        var models: [String: (provider: String, answers: Int, tokens: Int)] = [:]
        for metric in selected {
            let key = metric.modelID
            var entry = models[key] ?? (metric.provider, 0, 0)
            entry.answers += 1
            entry.tokens += metric.totalTokens
            models[key] = entry
        }
        profile.topModels = models.map { ModelUse(modelID: $0.key, provider: $0.value.provider, answers: $0.value.answers, tokens: $0.value.tokens) }
            .sorted { ($0.answers, $0.tokens) > ($1.answers, $1.tokens) }
            .prefix(6).map { $0 }

        let efforts = selected.compactMap(\.effort)
        if !efforts.isEmpty {
            let counts = Dictionary(grouping: efforts, by: { $0 }).mapValues(\.count)
            profile.effortShares = counts.map { (effort: $0.key, share: Double($0.value) / Double(efforts.count)) }
                .sorted { $0.share > $1.share }
        }
        if !selected.isEmpty {
            profile.chatShare = Double(selected.filter { $0.mode == "chat" }.count) / Double(selected.count)
        }
        if !all.isEmpty { profile.localShare = Double(all.filter(\.isLocal).count) / Double(all.count) }
        let localSpeeds = all.filter(\.isLocal).compactMap(\.outputTokensPerSecond)
        if !localSpeeds.isEmpty { profile.averageLocalSpeed = localSpeeds.reduce(0, +) / Double(localSpeeds.count) }
        return profile
    }

    public static func compute(records: [AccountActivityRecord], accountID: UUID, scope: Scope = .all,
                               calendar: Calendar = .current, now: Date = .now) -> UsageProfile {
        func local(_ row: AccountActivityRecord) -> Bool { ["ollama", "lmStudio", "local"].contains(row.provider) }
        let all = AccountActivityRecord.merge(records, accountID: accountID)
        let selected = all.filter { scope == .all || ($0.provider != "unknown" && (scope == .local) == local($0)) }
        let summary = AccountActivitySummary(records: selected, accountID: accountID, calendar: calendar, now: now)
        let responses = summary.records.filter { $0.kind == .response || $0.kind == .voice }
        var profile = UsageProfile()
        profile.lifetimeTokens = summary.tokens; profile.peakTokens = summary.peakTokens ?? 0
        profile.longestTaskSeconds = summary.longestTask; profile.currentStreak = summary.currentStreak; profile.longestStreak = summary.longestStreak
        profile.dailyTokens = summary.dailyTokens; profile.activeDays = Set(selected.filter { $0.kind != .cost }.map { calendar.startOfDay(for: $0.startedAt) })
        profile.answers = responses.count; profile.measuringSince = all.map(\.startedAt).min(); profile.firstActivity = profile.activeDays.min()
        profile.unmeasuredResponses = summary.unmeasuredResponses
        let groups = Dictionary(grouping: responses, by: { $0.provider + ":" + $0.modelID })
        var uses: [ModelUse] = []
        for group in groups.values {
            guard let first = group.first else { continue }
            let tokens = group.compactMap(\.totalTokens).reduce(0, +)
            uses.append(ModelUse(modelID: first.modelID, provider: first.provider, answers: group.count, tokens: tokens, unmeasuredAnswers: group.filter { $0.totalTokens == nil }.count))
        }
        uses.sort { lhs, rhs in lhs.answers == rhs.answers ? lhs.tokens > rhs.tokens : lhs.answers > rhs.answers }
        profile.topModels = Array(uses.prefix(6))
        if !responses.isEmpty { profile.chatShare = Double(responses.filter { $0.mode == "chat" }.count) / Double(responses.count) }
        let allResponses = all.filter { ($0.kind == .response || $0.kind == .voice) && $0.provider != "unknown" }
        if !allResponses.isEmpty { profile.localShare = Double(allResponses.filter(local).count) / Double(allResponses.count) }
        return profile
    }

    public enum HeatmapMode: String, CaseIterable, Sendable { case daily, weekly, cumulative }

    /// The value of each day of the grid: the day's tokens, its week's total, or the running total.
    public func heatmapValues(days: [Date], mode: HeatmapMode, calendar: Calendar = .current) -> [Date: Int] {
        switch mode {
        case .daily:
            return Dictionary(uniqueKeysWithValues: days.map { ($0, dailyTokens[$0] ?? 0) })
        case .weekly:
            var weeks: [Date: Int] = [:]
            for (day, tokens) in dailyTokens {
                let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
                weeks[week, default: 0] += tokens
            }
            return Dictionary(uniqueKeysWithValues: days.map { ($0, weeks[calendar.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0] ?? 0) })
        case .cumulative:
            var running = dailyTokens.filter { $0.key < (days.first ?? .distantPast) }.values.reduce(0, +)
            var result: [Date: Int] = [:]
            for day in days.sorted() {
                running += dailyTokens[day] ?? 0
                result[day] = running
            }
            return result
        }
    }
}
