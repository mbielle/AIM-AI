import AIMApplication
import AIMCore
import XCTest

final class UsageProfileTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func day(_ offset: Int, from now: Date) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    private func metric(_ date: Date, provider: String = "openrouter", input: Int, output: Int, effort: String? = nil) -> TurnMetrics {
        TurnMetrics(provider: provider, modelID: provider == "local" ? "qwen" : "sonnet", mode: "chat", effort: effort, startedAt: date,
                    usage: TokenUsage(inputTokens: input, outputTokens: output), totalSeconds: Double(output) / 10)
    }

    func testStreaksFromMessageDaysAndTotalsFromMetrics() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        // Active: today, yesterday, two days ago (current streak 3); earlier a 4-day run.
        let activity = [0, -1, -2, -10, -11, -12, -13].map { day($0, from: now) }
        let metrics = [metric(now, input: 1_000, output: 200, effort: "high"),
                       metric(day(-1, from: now), provider: "local", input: 300, output: 100, effort: "high"),
                       metric(day(-1, from: now), input: 50, output: 10, effort: "low")]
        let profile = UsageProfile.compute(metrics: metrics, activity: activity, calendar: calendar, now: now)
        XCTAssertEqual(profile.currentStreak, 3)
        XCTAssertEqual(profile.longestStreak, 4)
        XCTAssertEqual(profile.lifetimeTokens, 1_660)
        XCTAssertEqual(profile.peakTokens, 1_200)
        XCTAssertEqual(profile.effortShares.first?.effort, "high")
        XCTAssertEqual(profile.topModels.first?.modelID, "sonnet")
        let local = UsageProfile.compute(metrics: metrics, activity: activity, scope: .local, calendar: calendar, now: now)
        XCTAssertEqual(local.lifetimeTokens, 400)
        XCTAssertEqual(local.currentStreak, 3, "Streaks do not depend on the scope")
    }

    func testCurrentStreakSurvivesUntilTheDayEnds() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9))!
        let profile = UsageProfile.compute(metrics: [], activity: [day(-1, from: now), day(-2, from: now)], calendar: calendar, now: now)
        XCTAssertEqual(profile.currentStreak, 2)
    }

    func testHeatmapModes() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        let days = (-3...0).map { calendar.startOfDay(for: day($0, from: now)) }
        let profile = UsageProfile.compute(metrics: [metric(day(-3, from: now), input: 100, output: 0),
                                                     metric(now, input: 50, output: 0)], activity: [], calendar: calendar, now: now)
        let daily = profile.heatmapValues(days: days, mode: .daily, calendar: calendar)
        XCTAssertEqual(daily[days[0]], 100)
        XCTAssertEqual(daily[days[1]], 0)
        let cumulative = profile.heatmapValues(days: days, mode: .cumulative, calendar: calendar)
        XCTAssertEqual(cumulative[days[2]], 100)
        XCTAssertEqual(cumulative[days[3]], 150)
        let weekly = profile.heatmapValues(days: days, mode: .weekly, calendar: calendar)
        XCTAssertEqual(weekly[days[3]], weekly[days[2]], "Days of the same week share its total")
    }
    func testAccountProfileUsesSharedTotalsZoneStreakAndUnknownMeasurementRules() {
        let account = UUID(), now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
        let first = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", provider: "fixture", modelID: "same-model", mode: "agent", startedAt: day(-1, from: now), totalTokens: 30)
        let unmeasured = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "phone", deviceName: "iPhone", provider: "different", modelID: "same-model", mode: "chat", startedAt: now)
        let unknown = AccountActivityRecord(id: UUID(), accountID: account, deviceID: AccountActivityRecord.unattributedDeviceID, deviceName: "Unknown execution device", provider: "unknown", modelID: "Earlier", mode: "chat", startedAt: now, totalTokens: 10)
        let rows = [first, first, unmeasured, unknown]
        let shared = AccountActivitySummary(records: rows, accountID: account, calendar: calendar, now: now)
        let profile = UsageProfile.compute(records: rows, accountID: account, calendar: calendar, now: now)
        XCTAssertEqual(profile.lifetimeTokens, shared.tokens); XCTAssertEqual(profile.peakTokens, shared.peakTokens)
        XCTAssertEqual(profile.dailyTokens, shared.dailyTokens); XCTAssertEqual(profile.currentStreak, shared.currentStreak)
        XCTAssertEqual(profile.unmeasuredResponses, 1)
        XCTAssertEqual(profile.topModels.filter { $0.modelID == "same-model" }.count, 2)
        XCTAssertNil(profile.topModels.first { $0.provider == "different" }?.measuredTokens)
        let online = UsageProfile.compute(records: rows, accountID: account, scope: .online, calendar: calendar, now: now)
        XCTAssertEqual(online.lifetimeTokens, 30, "Unknown origins must not be guessed online")
    }

}
