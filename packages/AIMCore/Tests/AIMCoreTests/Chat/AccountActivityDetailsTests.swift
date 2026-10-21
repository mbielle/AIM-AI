import Foundation
import XCTest
@testable import AIMCore

final class AccountActivityDetailsTests: XCTestCase {
    func testWeekYearAndDailyDetailsUseSameDisplayedTimeZone() throws {
        let account = UUID(), formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: "2025-12-31T23:30:00Z"))
        let now = try XCTUnwrap(formatter.date(from: "2026-01-01T09:00:00Z"))
        let row = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "origin", deviceName: "Mac", provider: "fixture", modelID: "m", mode: "chat", startedAt: date, totalTokens: 23)
        let paris = AccountActivityFilter(period: .year, timeZoneID: "Europe/Paris").apply([row, row], accountID: account, now: now)
        XCTAssertEqual(paris.count, 1)
        XCTAssertTrue(AccountActivityFilter(period: .year, timeZoneID: "UTC").apply([row], accountID: account, now: now).isEmpty)
        XCTAssertEqual(AccountActivityFilter(period: .week, timeZoneID: "Europe/Paris").apply([row], accountID: account, now: now).count, 1)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let summary = AccountActivitySummary(records: paris, accountID: account, calendar: calendar, now: now)
        XCTAssertEqual(summary.records(on: now, calendar: calendar).map(\.id), [row.id])
        XCTAssertEqual(summary.dailyTokens[calendar.startOfDay(for: now)], 23)
    }
    func testWaitingAndIncompleteTasksStaySeparateAndModelToolsDeduplicate() {
        let account = UUID(), start = Date(timeIntervalSince1970: 1_790_000_000)
        let root = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", kind: .task, provider: "fixture", modelID: "m", mode: "agent", startedAt: start, completedAt: start.addingTimeInterval(300), waitingSeconds: 60)
        let child = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", parentTaskID: root.id, kind: .task, provider: "fixture", modelID: "m", mode: "agent", startedAt: start, completedAt: start.addingTimeInterval(100), waitingSeconds: 10)
        let incomplete = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", kind: .task, provider: "fixture", modelID: "m", mode: "agent", startedAt: start)
        let response = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", provider: "fixture", modelID: "m", mode: "agent", startedAt: start)
        let tool = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", kind: .tool, provider: "fixture", modelID: "m", mode: "agent", startedAt: start, toolName: "read_file")
        let summary = AccountActivitySummary(records: [root, child, incomplete, response, tool, tool], accountID: account)
        XCTAssertEqual(summary.longestTask, 300); XCTAssertEqual(summary.longestTaskWaiting, 60)
        XCTAssertEqual(summary.measuredWaitingSeconds, 60); XCTAssertEqual(summary.unmeasuredTasks, 1)
        XCTAssertEqual(summary.toolUses.first?.count, 1); XCTAssertNil(summary.modelUses.first?.measuredTokens)
    }
    func testImportSelectionRejectsChangedSourceAndOtherAccountAndKeepsUnknownModel() throws {
        let account = UUID(), id = UUID(), at = Date(timeIntervalSince1970: 1_790_000_000)
        let message = NativeChatMessage(id: id, role: .assistant, text: "Earlier", createdAt: at)
        let turn = NativeChatTurn(id: id, usage: .init(inputTokens: 10, outputTokens: 20), completedAt: at.addingTimeInterval(1))
        var conversation = NativeChatConversation(title: "Preserved", provider: .openAI, modelID: "currently-selected", messages: [message], turns: [turn])
        let preview = AccountActivityImportItem.preview(conversations: [conversation, conversation], existing: [], accountID: account, deviceID: "phone", deviceName: "iPhone")
        XCTAssertEqual(preview.count, 1); XCTAssertEqual(preview[0].record.totalTokens, 30); XCTAssertEqual(preview[0].record.provider, "unknown"); XCTAssertEqual(preview[0].record.deviceID, AccountActivityRecord.unattributedDeviceID)
        XCTAssertNil(preview[0].record.costUSD)
        let selected = try AccountActivityImportItem.selected([id], from: preview, current: preview, accountID: account)
        XCTAssertEqual(selected.map(\.id), [id])
        XCTAssertTrue(AccountActivityImportItem.preview(conversations: [conversation], existing: selected, accountID: account, deviceID: "phone", deviceName: "iPhone").isEmpty)
        conversation.turns[0].usage.outputTokens = 40
        let changed = AccountActivityImportItem.preview(conversations: [conversation], existing: [], accountID: account, deviceID: "phone", deviceName: "iPhone")
        XCTAssertThrowsError(try AccountActivityImportItem.selected([id], from: preview, current: changed, accountID: account))
        XCTAssertThrowsError(try AccountActivityImportItem.selected([id], from: preview, current: preview, accountID: UUID()))
        XCTAssertEqual(conversation.messages[0].text, "Earlier")
    }
    func testWeeklyHeatmapIncludesWholeWeekAndCumulativePriorDays() {
        let account = UUID(); var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let dates = [-1, 0, 1].map { calendar.date(byAdding: .day, value: $0, to: monday)! }
        let rows = dates.enumerated().map { index, at in AccountActivityRecord(id: UUID(), accountID: account, deviceID: "mac", deviceName: "Mac", provider: "fixture", modelID: "m", mode: "chat", startedAt: at, totalTokens: (index + 1) * 10) }
        let summary = AccountActivitySummary(records: rows, accountID: account, calendar: calendar)
        XCTAssertEqual(summary.heatmapValues(days: [dates[2]], mode: .cumulative, calendar: calendar)[dates[2]], 60)
        let expectedWeek = summary.dailyTokens.filter { calendar.dateInterval(of: .weekOfYear, for: $0.key)?.start == calendar.dateInterval(of: .weekOfYear, for: dates[2])?.start }.values.reduce(0, +)
        XCTAssertEqual(summary.heatmapValues(days: [dates[2]], mode: .weekly, calendar: calendar)[dates[2]], expectedWeek)
    }
    func testVerifiedOriginSupersedesLegacyImportButMirrorCannotReplaceIt() {
        let account = UUID(), at = Date(timeIntervalSince1970: 1_790_000_000)
        let origin = AccountActivityRecord(id: UUID(), accountID: account, deviceID: "original-mac", deviceName: "Mac", provider: "fixture", modelID: "verified", mode: "chat", startedAt: at, totalTokens: 30, updatedAt: at)
        var imported = origin; imported.deviceID = AccountActivityRecord.unattributedDeviceID; imported.deviceName = "Unknown execution device"; imported.provider = "unknown"; imported.updatedAt = at.addingTimeInterval(1000)
        XCTAssertEqual(AccountActivityRecord.merge([imported, origin], accountID: account).first, origin)
        XCTAssertEqual(AccountActivityRecord.merge([origin, imported], accountID: account).first, origin)
        let summary = AccountActivitySummary(records: [imported, origin, imported], accountID: account)
        XCTAssertEqual(summary.tokens, 30)
        XCTAssertEqual(DeviceBudgetRules.committedUSD(records: [imported], accountID: account, deviceID: "phone", now: at), 0)
    }

}
