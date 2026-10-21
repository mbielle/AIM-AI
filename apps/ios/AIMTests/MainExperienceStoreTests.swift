import AIMCore
import XCTest
import UserNotifications
import UIKit
@testable import AIM

@MainActor final class AIMNotificationRoutingTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let suite = "AIMNotificationRoutingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func center(_ defaults: UserDefaults) -> AIMNotificationCenter {
        AIMNotificationCenter(defaults: defaults, registerRemote: {}, unregisterRemote: {}, authorize: { true }, readAuthorization: { .authorized })
    }
    private func event(_ conversation: UUID = UUID(), category: AIMNotificationCategory = .response) -> AccountNotificationEvent {
        .init(id: UUID(), conversation: conversation, category: category, createdAt: "2026-10-06T15:30:00.123456+00:00")
    }
    private func page(_ events: [AccountNotificationEvent], more: Bool = false) -> AccountNotificationPage {
        .init(events: events, cursor: events.last.map { .init(createdAt: $0.created_at, eventID: $0.id) }, hasMore: more)
    }
    func testColdLaunchWaitsForMatchingAuthenticatedAccount() async {
        let center = center(preferences()), account = UUID(), conversation = UUID()
        center.received(account: account.uuidString, conversation: conversation.uuidString, tapped: true)
        XCTAssertNil(center.pendingConversation)
        await center.bind(accountID: account, service: nil)
        XCTAssertEqual(center.pendingConversation, conversation)
        await center.disconnect()
        XCTAssertNil(center.pendingConversation)
    }
    func testOtherAccountAndConcealedContentCannotShowANotice() async {
        let defaults = preferences(); defaults.set(true, forKey: "aim.notifications.enabled")
        let center = center(defaults), account = UUID(), other = UUID(), update = event()
        center.received(account: other.uuidString, conversation: update.conversation.uuidString, tapped: true)
        await center.bind(accountID: account, service: nil)
        XCTAssertNil(center.pendingConversation)
        center.received(account: other.uuidString, conversation: update.conversation.uuidString, tapped: true)
        XCTAssertNil(center.pendingConversation)
        await center.presence(foreground: true, conversation: nil, concealed: true)
        center.received(account: account.uuidString, conversation: update.conversation.uuidString, event: update.id.uuidString, category: "response", tapped: false)
        XCTAssertNil(center.notice)
        XCTAssertNil(center.noticeConversation)
        await center.disconnect()
    }
    func testOfflineDisablePersistsAndRetriesUnregistration() async {
        let defaults = preferences(); defaults.set(true, forKey: "aim.notifications.enabled")
        var localUnregistrations = 0
        let center = AIMNotificationCenter(defaults: defaults, registerRemote: {}, unregisterRemote: { localUnregistrations += 1 }, authorize: { true }, readAuthorization: { .authorized })
        let account = UUID(), service = NotificationServiceFixture()
        await center.bind(accountID: account, service: service)
        await center.receiveToken(Data([1, 2, 3]))
        await service.failUnregister(true)
        await center.requestEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: "aim.notifications.enabled"))
        XCTAssertEqual(localUnregistrations, 1)
        XCTAssertNotNil(defaults.string(forKey: "aim.push.pending-unregister." + account.uuidString))
        XCTAssertEqual(center.status, "Disabled on this iPhone. Server update pending.")
        await service.failUnregister(false)
        await center.synchronizeRegistration()
        XCTAssertNil(defaults.string(forKey: "aim.push.pending-unregister." + account.uuidString))
        XCTAssertEqual(center.status, "Disabled")
        let attempts = await service.unregisterCount
        XCTAssertEqual(attempts, 2)
        await center.disconnect()
    }
    func testReenableWinsOverUnregisterAlreadyInFlight() async {
        let defaults = preferences(); defaults.set(true, forKey: "aim.notifications.enabled")
        let center = center(defaults), service = NotificationServiceFixture(), account = UUID()
        await center.bind(accountID: account, service: service)
        await center.receiveToken(Data([4, 5, 6]))
        await service.holdNextUnregister()
        let disabling = Task { await center.requestEnabled(false) }
        while !(await service.isUnregisterHeld) { await Task.yield() }
        await center.requestEnabled(true)
        await service.resumeUnregister()
        await disabling.value
        XCTAssertTrue(defaults.bool(forKey: "aim.notifications.enabled"))
        XCTAssertEqual(center.status, "Registered with AIM")
        let registrations = await service.registerCount
        XCTAssertEqual(registrations, 2)
        XCTAssertNil(defaults.string(forKey: "aim.push.pending-unregister." + account.uuidString))
        await center.disconnect()
    }
    func testDisableWinsOverRegistrationAlreadyInFlight() async {
        let defaults = preferences(); defaults.set(true, forKey: "aim.notifications.enabled")
        let center = center(defaults), service = NotificationServiceFixture(), account = UUID()
        await center.bind(accountID: account, service: service)
        await service.holdNextRegistration()
        let registering = Task { await center.receiveToken(Data([7, 8, 9])) }
        while !(await service.isRegistrationHeld) { await Task.yield() }
        await center.requestEnabled(false)
        await service.resumeRegistration()
        await registering.value
        XCTAssertFalse(defaults.bool(forKey: "aim.notifications.enabled"))
        XCTAssertEqual(center.status, "Disabled")
        let unregistrations = await service.unregisterCount
        XCTAssertEqual(unregistrations, 1, "A stale successful registration must still be removed")
        XCTAssertNil(defaults.string(forKey: "aim.push.pending-unregister." + account.uuidString))
        await center.disconnect()
    }
    func testPreferencesAndEventIdentitySuppressAPNsAndPollingDuplicates() async {
        let defaults = preferences(); defaults.set(true, forKey: "aim.notifications.enabled")
        let center = center(defaults), account = UUID(), service = NotificationServiceFixture()
        await center.bind(accountID: account, service: service)
        let ignored = event(category: .question), shown = event()
        defaults.set(false, forKey: "aim.notifications.question")
        center.received(account: account.uuidString, conversation: ignored.conversation.uuidString, event: ignored.id.uuidString, category: "question", tapped: false)
        XCTAssertNil(center.notice)
        defaults.set(true, forKey: "aim.notifications.question")
        center.received(account: account.uuidString, conversation: ignored.conversation.uuidString, event: ignored.id.uuidString, category: "question", tapped: false)
        XCTAssertNil(center.notice, "An already observed event does not re-alert after a category is reenabled")
        defaults.set(false, forKey: "aim.notifications.enabled")
        center.received(account: account.uuidString, conversation: shown.conversation.uuidString, event: shown.id.uuidString, category: "response", tapped: false)
        XCTAssertNil(center.notice)
        defaults.set(true, forKey: "aim.notifications.enabled")
        center.received(account: account.uuidString, conversation: shown.conversation.uuidString, event: shown.id.uuidString, category: "response", tapped: false)
        XCTAssertTrue(center.attention.entries.contains { $0.conversation == shown.conversation })
        XCTAssertNil(center.notice)
        center.received(account: account.uuidString, conversation: shown.conversation.uuidString, event: shown.id.uuidString, category: "response", tapped: true)
        await service.enqueue(page([ignored, shown]))
        await center.pollEvents()
        XCTAssertNil(center.notice, "Foreground polling cannot redisplay the same APNs event")
        XCTAssertEqual(center.pendingConversation, shown.conversation)
        await center.disconnect()
    }
    func testServerCursorPaginatesMoreThanOneHundredEventsAndPersistsPrecision() async throws {
        let defaults = preferences(); defaults.set(true, forKey: "aim.notifications.enabled")
        let center = center(defaults), account = UUID(), service = NotificationServiceFixture()
        let events = (0..<101).map { _ in event() }
        await service.enqueue(page(Array(events.prefix(100)), more: true))
        await service.enqueue(page([events[100]]))
        await center.bind(accountID: account, service: service)
        await center.pollEvents()
        let calls = await service.pageRequests
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[0].cursor, "A device timestamp is never used as a first cursor")
        XCTAssertTrue(calls[0].overlap)
        XCTAssertEqual(calls[1].cursor?.eventID, events[99].id)
        XCTAssertEqual(calls[1].cursor?.createdAt, events[99].created_at)
        XCTAssertFalse(calls[1].overlap)
        XCTAssertTrue(center.attention.entries.contains { $0.conversation == events[100].conversation })
        XCTAssertEqual(center.arrivalRevision, 0, "Historical catchup never produces a live alert")
        let data = try XCTUnwrap(defaults.data(forKey: "aim.push.cursor." + account.uuidString))
        let cursor = try JSONDecoder().decode(AccountNotificationCursor.self, from: data)
        XCTAssertEqual(cursor.eventID, events[100].id)
        XCTAssertEqual(cursor.createdAt, "2026-10-06T15:30:00.123456+00:00")
        center.openNotice()
        await service.enqueue(page(events))
        await center.pollEvents()
        XCTAssertNil(center.notice)
        await center.disconnect()
    }
    func testBoundedCatchupContinuesInsteadOfSkippingRemainingPages() async {
        let defaults = preferences(); defaults.set(true, forKey: "aim.notifications.enabled")
        let center = center(defaults), account = UUID(), service = NotificationServiceFixture()
        let updates = (0..<11).map { _ in event() }
        for (index, update) in updates.enumerated() { await service.enqueue(page([update], more: index < 10)) }
        await center.bind(accountID: account, service: service)
        await center.pollEvents()
        let firstCalls = await service.pageRequests
        XCTAssertEqual(firstCalls.count, 10)
        await center.pollEvents()
        let finalCalls = await service.pageRequests
        XCTAssertEqual(finalCalls.count, 11)
        XCTAssertEqual(finalCalls[10].cursor?.eventID, updates[9].id)
        XCTAssertFalse(finalCalls[10].overlap)
        XCTAssertTrue(center.attention.entries.contains { $0.conversation == updates[10].conversation })
        await center.disconnect()
    }
    func testAuthorizationRefreshUpdatesExistingSettingsState() async {
        let defaults = preferences()
        var authorization: UNAuthorizationStatus = .denied
        let center = AIMNotificationCenter(defaults: defaults, registerRemote: {}, unregisterRemote: {}, authorize: { false }, readAuthorization: { authorization })
        await center.refreshAuthorization()
        XCTAssertEqual(center.authorizationStatus, .denied)
        await center.requestEnabled(true)
        XCTAssertFalse(defaults.bool(forKey: "aim.notifications.enabled"))
        authorization = .authorized
        await center.refreshAuthorization()
        XCTAssertEqual(center.authorizationStatus, .authorized)
    }
}

private actor NotificationServiceFixture: AccountNotificationServicing {
    struct PageRequest: Sendable { let cursor: AccountNotificationCursor?; let overlap: Bool }
    private var pages: [AccountNotificationPage] = []
    private(set) var pageRequests: [PageRequest] = []
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private var unregisterFails = false
    private var holdUnregister = false
    private var holdRegistration = false
    private var registrationContinuation: CheckedContinuation<Void, Never>?
    private var unregisterContinuation: CheckedContinuation<Void, Never>?
    var isUnregisterHeld: Bool { unregisterContinuation != nil }
    var isRegistrationHeld: Bool { registrationContinuation != nil }
    func enqueue(_ page: AccountNotificationPage) { pages.append(page) }
    func failUnregister(_ fails: Bool) { unregisterFails = fails }
    func holdNextUnregister() { holdUnregister = true }
    func holdNextRegistration() { holdRegistration = true }
    func resumeRegistration() { registrationContinuation?.resume(); registrationContinuation = nil }
    func resumeUnregister() { unregisterContinuation?.resume(); unregisterContinuation = nil }
    func register(installation: UUID, token: String, topic: String, environment: String, categories: [AIMNotificationCategory]) async {
        registerCount += 1
        if holdRegistration { holdRegistration = false; await withCheckedContinuation { registrationContinuation = $0 } }
    }
    func presence(installation: UUID, foreground: Bool, conversation: UUID?) {}
    func unregister(installation: UUID) async throws {
        unregisterCount += 1
        if holdUnregister { holdUnregister = false; await withCheckedContinuation { unregisterContinuation = $0 } }
        if unregisterFails { throw URLError(.notConnectedToInternet) }
    }
    func notify(accountID: UUID, event: UUID, task: UUID, conversation: UUID, category: AIMNotificationCategory) {}
    func eventPage(after cursor: AccountNotificationCursor?, overlap: Bool) -> AccountNotificationPage {
        pageRequests.append(.init(cursor: cursor, overlap: overlap))
        return pages.isEmpty ? .init(events: [], cursor: cursor, hasMore: false) : pages.removeFirst()
    }
}

final class AIMMarkdownParserTests: XCTestCase {
    func testParsesCommonConversationMarkdownBlocks() {
        let source = """
        # Result

        A paragraph with **strong text** and `inline code`.

        - First item
        - Second item

        1. Prepare
        2. Run

        > Important note

        ```swift
        let answer = 42
        ```
        """

        XCTAssertEqual(
            AIMMarkdownParser.blocks(from: source),
            [
                .heading(level: 1, text: "Result"),
                .paragraph("A paragraph with **strong text** and `inline code`."),
                .unorderedList(["First item", "Second item"]),
                .orderedList(["Prepare", "Run"]),
                .quote("Important note"),
                .code(language: "swift", content: "let answer = 42"),
            ]
        )
    }

    func testKeepsConsecutiveParagraphLinesTogetherAndTrimsWhitespace() {
        let source = """

          First line
        second line

        ---

        """

        XCTAssertEqual(
            AIMMarkdownParser.blocks(from: source),
            [.paragraph("First line\nsecond line"), .rule]
        )
    }

    func testParsesGFMTableInsteadOfDisplayingRawPipes() {
        let source = """
        | # | Bug | File | Severity |
        | --- | --- | --- | --- |
        | 1 | Missing return | `universe.gd` | **blocking** |
        | 2 | Invalid format | `tests.gd` | warning |
        """

        XCTAssertEqual(
            AIMMarkdownParser.blocks(from: source),
            [
                .table(
                    headers: ["#", "Bug", "File", "Severity"],
                    rows: [
                        ["1", "Missing return", "`universe.gd`", "**blocking**"],
                        ["2", "Invalid format", "`tests.gd`", "warning"],
                    ]
                ),
            ]
        )
    }

    func testRepairsMissingTableDelimiterAndCommonModelMarkdown() {
        let source = """
        ##Result

        • First item
        • Second item

        | Name | State |
        | AIM | Ready |
        """

        XCTAssertEqual(
            AIMMarkdownParser.blocks(from: source),
            [
                .heading(level: 2, text: "Result"),
                .unorderedList(["First item", "Second item"]),
                .table(headers: ["Name", "State"], rows: [["AIM", "Ready"]]),
            ]
        )
    }
}

final class AIMConversationComposerPresentationTests: XCTestCase {
    func testEmptyUnfocusedComposerIsCompact() {
        XCTAssertEqual(
            AIMConversationComposerPresentation.state(
                focused: false,
                text: "   ",
                hasAttachments: false,
                hasActiveSecondaryState: false
            ),
            .compact
        )
    }

    func testComposerStaysExpandedAfterKeyboardDismissalWhenDraftExists() {
        XCTAssertEqual(
            AIMConversationComposerPresentation.state(
                focused: false,
                text: "Draft",
                hasAttachments: false,
                hasActiveSecondaryState: false
            ),
            .expanded
        )
    }

    func testFocusedOrSecondaryComposerIsExpanded() {
        XCTAssertEqual(
            AIMConversationComposerPresentation.state(
                focused: true,
                text: "",
                hasAttachments: false,
                hasActiveSecondaryState: false
            ),
            .expanded
        )
        XCTAssertEqual(
            AIMConversationComposerPresentation.state(
                focused: false,
                text: "",
                hasAttachments: false,
                hasActiveSecondaryState: true
            ),
            .expanded
        )
    }
}

final class AIMMediaPanelGeometryTests: XCTestCase {
    func testReferencePhoneGeometryUsesEightPointMarginsAndSeventyPercentHeight() {
        let frame = AIMMediaPanelGeometry.frame(in: CGSize(width: 390, height: 844))

        XCTAssertEqual(frame.origin.x, 8, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 245, accuracy: 0.001)
        XCTAssertEqual(frame.width, 374, accuracy: 0.001)
        XCTAssertEqual(frame.height, 591, accuracy: 0.001)
        XCTAssertEqual(844 - frame.maxY, 8, accuracy: 0.001)
    }

    func testLargeDisplayCapsMediaPanelHeightAtSixHundredPoints() {
        let frame = AIMMediaPanelGeometry.frame(in: CGSize(width: 1024, height: 1366))

        XCTAssertEqual(frame.height, 600, accuracy: 0.001)
        XCTAssertEqual(frame.minX, 8, accuracy: 0.001)
        XCTAssertEqual(frame.maxX, 1016, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 1358, accuracy: 0.001)
    }
}

final class AIMLocalPreferenceTests: XCTestCase {
    func testAppearancePreferenceMapsToExpectedColorScheme() {
        XCTAssertNil(AIMAppearancePreference.system.colorScheme)
        XCTAssertEqual(AIMAppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AIMAppearancePreference.dark.colorScheme, .dark)
    }

    func testSupportedInterfaceLanguagesResolveLocales() {
        XCTAssertEqual(AIMInterfaceLanguage.french.locale.language.languageCode?.identifier, "fr")
        XCTAssertEqual(AIMInterfaceLanguage.english.locale.language.languageCode?.identifier, "en")
    }
}

final class MainExperienceStoreTests: XCTestCase {
    @MainActor
    func testServerCapacityErrorsKeepCreationDraftAndMacHealthUnknown() async {
        for (code, messageKey) in [("rate_limited", "remote.error.server_rate_limited"), ("queue_capacity_reached", "remote.error.server_queue_full")] {
            let errors: [RemoteServiceError] = [
                .commandRejected(code),
                .commandFailure(.init(code: .commandRefused, stage: .failed, serverCode: code, diagnosticReference: "SERVER-CAPACITY-FIXTURE"))
            ]
            for error in errors {
                let service = MockRemoteService(); service.overview = sampleOverview(); service.creationError = error
                let store = MainExperienceStore(service: service); await store.load()
                let draft = AIMCreationDraft(text: "Keep this draft", attachments: [.init(transferID: "retained-input", name: "notes.txt", mimeType: "text/plain", size: 12)])
                store.updateCreationDraft(draft, for: .chat)
                let sent = await store.sendNewChat(text: draft.text, attachments: draft.attachments)
                XCTAssertFalse(sent)
                XCTAssertEqual(service.creationCallCount, 1)
                XCTAssertEqual(store.creationDraft(for: .chat), draft)
                XCTAssertFalse(store.isSending)
                XCTAssertEqual(store.commandHealth(for: "machine-1"), .unknown)
                XCTAssertTrue(store.selectedMachine?.isOnline() == true)
                XCTAssertEqual(store.errorMessage, String(localized: String.LocalizationValue(messageKey)))
            }
        }
    }

    @MainActor
    func testServerCapacityRejectedResultExplainsWaitWithoutMarkingMacOffline() async {
        for (code, messageKey) in [("rate_limited", "remote.error.server_rate_limited"), ("queue_capacity_reached", "remote.error.server_queue_full")] {
            let service = MockRemoteService(); service.overview = sampleOverview()
            let store = MainExperienceStore(service: service); await store.load(); await store.selectSession(service.overview.sessions[0])
            service.sendResult = .init(succeeded: false, errorCode: code)
            let sent = await store.sendMessage("Keep the existing conversation input")
            XCTAssertFalse(sent)
            XCTAssertEqual(service.sendCount, 1)
            XCTAssertFalse(store.isSending)
            XCTAssertEqual(store.commandHealth(for: "machine-1"), .unknown)
            XCTAssertEqual(store.errorMessage, String(localized: String.LocalizationValue(messageKey)))
        }
    }

    @MainActor
    func testRemoteDownloadsNeverSubstituteTargetAndDiscardLateResults() async throws {
        let service = MockRemoteService()
        let online = RemoteMachine(id: "machine-1", name: "Chosen Mac", platform: "darwin", appVersion: "2", lastSeenAt: .now, keyVersion: nil,
            capabilities: .init(models: [], features: ["remoteDownloads": true]))
        service.overview = .init(connectionState: .paired, machines: [online], sessions: [])
        service.sendResult = .init(succeeded: true, result: .object(["jobs": .object([:])]))
        let store = MainExperienceStore(service: service); await store.load()
        do { _ = try await store.remoteDownload(["operation": .string("agent")], mutate: true, machineID: "another-mac"); XCTFail("Wrong Mac admitted") } catch {}
        XCTAssertEqual(service.sendCount, 0)
        let value = try await store.remoteDownload(["operation": .string("status")], machineID: online.id)
        XCTAssertNotNil(value.objectValue?["jobs"]); XCTAssertEqual(service.sendCount, 1)
        XCTAssertEqual(service.sentCommandType, .getMacSettings)
        service.sendHook = { @MainActor in store.selectedMachineID = "another-mac" }
        do { _ = try await store.remoteDownload(["operation": .string("agent"), "agent": .string("hermes")], mutate: true, machineID: online.id); XCTFail("Stale result admitted") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(service.sendCount, 2)
        store.selectedMachineID = online.id; store.setRemoteEnabled(false, machineID: online.id)
        do { _ = try await store.remoteDownload(["operation": .string("agent")], mutate: true, machineID: online.id); XCTFail("Suspended Mac admitted") } catch {}
        XCTAssertEqual(service.sendCount, 2)
        store.setRemoteEnabled(true, machineID: online.id)
    }

    @MainActor
    func testMacSettingsDiscardsResponseAfterSelectionChanges() async throws {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let store = MainExperienceStore(service: service); await store.load()
        let machineID = try XCTUnwrap(store.selectedMachine?.id)
        await store.loadRemoteSecurity()
        service.sendResult = .init(succeeded: true, result: RemoteMacSettings(appearance: .dark, notifyRemote: true, notifyApprovals: true, notifyQuestions: true).json)
        service.sendHook = { @MainActor in store.selectedMachineID = "another-mac" }
        do { _ = try await store.macSettings(machineID: machineID); XCTFail("A late response must be discarded") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(service.sendCount, 1)
    }
    @MainActor
    func testMacSettingsCannotSendDraftToDifferentComputer() async throws {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let store = MainExperienceStore(service: service); await store.load()
        do {
            _ = try await store.macSettings(.init(appearance: .light, notifyRemote: false, notifyApprovals: false, notifyQuestions: false), machineID: "old-computer")
            XCTFail("A draft belongs to its original computer")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(service.sendCount, 0)
    }
    @MainActor
    func testMacSettingsDiscardsResponseAfterAccountInvalidation() async throws {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let store = MainExperienceStore(service: service); await store.load()
        await store.loadRemoteSecurity()
        service.sendResult = .init(succeeded: true, result: RemoteMacSettings(appearance: .dark, notifyRemote: true, notifyApprovals: true, notifyQuestions: true).json)
        service.sendHook = { @MainActor in store.invalidateRemoteSecurityContext() }
        do { _ = try await store.macSettings(); XCTFail("An old account operation must not fill a page") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    @MainActor
    func testContinuousCreationRecoversAdmittedSessionAfterMirrorFailureAndStoreRestart() async throws {
        let service = MockRemoteService(), account = UUID()
        let initial = sampleOverview(), machine = try XCTUnwrap(initial.machines.first)
        service.overview = .init(connectionState: .paired, machines: [RemoteMachine(id: machine.id, name: machine.name,
            platform: machine.platform, appVersion: machine.appVersion, lastSeenAt: machine.lastSeenAt,
            keyVersion: machine.keyVersion, capabilities: .init(features: [RemoteCapabilities.Feature.continuity: true]))], sessions: initial.sessions)
        let store = MainExperienceStore(service: service, queueAccountID: account)
        await store.load()
        store.mode = .code; store.selectedMachineID = machine.id; store.selectedWorkspace = "/tmp"; store.selectedModelID = "fixture-only"
        service.creationHook = { @MainActor in service.loadError = .commandRejected("fixture-network") }
        let admittedButUnavailable = await store.createRemoteSession(text: "Continuous fixture", goalMaximumTurns: 0)
        XCTAssertFalse(admittedButUnavailable); XCTAssertEqual(service.creationCallCount, 1)
        service.creationHook = nil; service.loadError = nil
        let created = RemoteSession(id: service.createdSessionID, machineID: machine.id, mode: .code, title: "Fixture",
            workspace: "/tmp", modelID: "fixture-only", approvalMode: "review", status: "running", messageCount: 1,
            updatedAt: .now, agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false)
        service.overview = .init(connectionState: .paired, machines: service.overview.machines, sessions: initial.sessions + [created])
        let restored = MainExperienceStore(service: service, queueAccountID: account)
        await restored.load()
        restored.mode = .code; restored.selectedMachineID = machine.id; restored.selectedWorkspace = "/tmp"; restored.selectedModelID = "fixture-only"
        let recovered = await restored.createRemoteSession(text: "Continuous fixture", goalMaximumTurns: 0)
        XCTAssertTrue(recovered); XCTAssertEqual(restored.selectedSessionID, service.createdSessionID)
        XCTAssertEqual(service.creationCallCount, 1); XCTAssertEqual(service.sendCount, 0)
    }
    @MainActor
    func testContinuousStatusDoesNotLockControlsAndStopsPollingTerminalResult() async throws {
        let service = MockRemoteService()
        var overview = sampleOverview()
        let original = try XCTUnwrap(overview.machines.first)
        let machine = RemoteMachine(id: original.id, name: original.name, platform: original.platform,
            appVersion: original.appVersion, lastSeenAt: original.lastSeenAt, keyVersion: original.keyVersion,
            capabilities: .init(features: [RemoteCapabilities.Feature.continuity: true]))
        overview = .init(connectionState: .paired, machines: [machine], sessions: overview.sessions)
        service.overview = overview
        let store = MainExperienceStore(service: service)
        await store.load()
        let session = try XCTUnwrap(overview.sessions.first { $0.mode == .code })
        await store.selectSession(session)
        service.sendHook = { @MainActor in XCTAssertFalse(store.isSending) }
        service.sendResult = .init(succeeded: true, result: .object(["version": .number(1),
            "execution_id": .string(UUID().uuidString), "conversation_id": .string(UUID().uuidString),
            "state": .string("accepted"), "revision": .string("4")]))
        await store.refreshContinuousGoalInBackground(sessionID: session.id)
        XCTAssertEqual(store.continuitySnapshots[session.id]?.state, "accepted")
        XCTAssertEqual(service.sentCommandType, .continuousGoalStatus)
        await store.refreshContinuousGoalInBackground(sessionID: session.id)
        XCTAssertEqual(service.sendCount, 1)
    }
    @MainActor
    func testContinuousStatusFromPreviouslySelectedSessionCannotUpdateNewSelection() async throws {
        let service = MockRemoteService()
        let overview = sampleOverview(), machine = try XCTUnwrap(overview.machines.first)
        service.overview = .init(connectionState: .paired, machines: [RemoteMachine(id: machine.id, name: machine.name,
            platform: machine.platform, appVersion: machine.appVersion, lastSeenAt: machine.lastSeenAt,
            keyVersion: machine.keyVersion, capabilities: .init(features: [RemoteCapabilities.Feature.continuity: true]))], sessions: overview.sessions)
        let store = MainExperienceStore(service: service)
        await store.load()
        let code = try XCTUnwrap(overview.sessions.first { $0.mode == .code })
        let chat = try XCTUnwrap(overview.sessions.first { $0.mode == .chat })
        await store.selectSession(code)
        service.sendHook = { @MainActor in store.prepareSessionSelection(chat) }
        service.sendResult = .init(succeeded: true, result: .object(["version": .number(1),
            "execution_id": .string(UUID().uuidString), "conversation_id": .string(UUID().uuidString),
            "state": .string("running"), "revision": .string("2")]))
        await store.refreshContinuousGoalInBackground(sessionID: code.id)
        XCTAssertEqual(store.selectedSessionID, chat.id)
        XCTAssertNil(store.continuitySnapshots[code.id])
        XCTAssertNil(store.continuitySnapshots[chat.id])
    }
    @MainActor
    func testCreationDraftsRemainIndependentAcrossModes() {
        let store = MainExperienceStore(service: MockRemoteService())
        let photo = RemoteAttachmentReference(
            transferID: "photo-transfer",
            name: "reference.png",
            mimeType: "image/png",
            size: 42
        )

        store.updateCreationDraft(.init(text: "Chat draft", attachments: [photo]), for: .chat)
        store.updateCreationDraft(.init(text: "Code draft"), for: .code)
        store.updateCreationDraft(.init(text: "Agent draft"), for: .agent)

        store.switchCreationMode(to: .code)
        XCTAssertEqual(store.creationDraft(for: .chat), .init(text: "Chat draft", attachments: [photo]))
        XCTAssertEqual(store.creationDraft(for: .code).text, "Code draft")

        store.switchCreationMode(to: .agent)
        XCTAssertEqual(store.creationDraft(for: .agent).text, "Agent draft")

        store.switchCreationMode(to: .chat)
        XCTAssertEqual(store.creationDraft(for: .chat).text, "Chat draft")
        XCTAssertEqual(store.creationDraft(for: .chat).attachments, [photo])
    }

    func testAppBundleDeclaresFaceIDUsageDescription() {
        let reason = Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String

        XCTAssertNotNil(reason)
        XCTAssertFalse(reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    @MainActor
    func testAuthenticatedExperienceStartsOnANewChat() {
        let store = MainExperienceStore(service: MockRemoteService(), titleDraw: { 0.7 })

        XCTAssertEqual(store.destination, .newChat)
        XCTAssertEqual(store.creationTitleKey, "remoteNewTitleChat4")
        XCTAssertEqual(store.computerState, .loading)
    }

    @MainActor
    func testComputerStateIsPresentedInlineInsteadOfAsAnAlert() async {
        let service = MockRemoteService()
        service.overview = .init(connectionState: .paired, machines: [], sessions: [])
        let store = MainExperienceStore(service: service)

        await store.load()

        XCTAssertEqual(store.computerState, .noComputer)
        XCTAssertNil(store.errorMessage)

        service.loadError = .unavailable
        await store.load()

        XCTAssertEqual(store.computerState, .unavailable)
        XCTAssertNotNil(store.inlineErrorMessage)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testUnpairedDeviceOffersPairingWithoutBlockingTheNewChatScreen() async {
        let service = MockRemoteService()
        service.overview = .init(connectionState: .unpaired, machines: [], sessions: [])
        let store = MainExperienceStore(service: service)

        await store.load()

        XCTAssertTrue(store.shouldOfferPairing)
        XCTAssertEqual(store.computerState, .unpaired)
        XCTAssertNil(store.inlineErrorMessage)
        XCTAssertEqual(store.destination, .newChat)
    }

    @MainActor
    func testRound23LegacyAccountMigratesWithoutPINOrChangingAppLockPreference() async {
        let service = MockRemoteService(); service.deviceState = .init(version: 1, legacyProtected: true)
        let biometric = MockBiometricSecretStore(); biometric.storedPIN = "old-copy"
        let store = MainExperienceStore(service: service, biometricSecretStore: biometric)
        await store.loadRemoteSecurity()
        XCTAssertEqual(service.migrationCalls, 1); XCTAssertEqual(service.authorizationCalls, 1)
        XCTAssertTrue(store.remoteDeviceAuthorized); XCTAssertEqual(store.remoteSecurityPhase, .authorized)
        XCTAssertFalse(store.remoteNeedsProtectionGate); XCTAssertFalse(store.remoteCanConfigurePIN)
        XCTAssertNil(biometric.storedPIN); XCTAssertNil(service.lastSetPIN); XCTAssertNil(service.lastVerifiedPIN)
        XCTAssertNil(service.lastEnabledValue)
    }
    @MainActor
    func testRound23CurrentAccountDoesNotMigrateAgain() async {
        let service = MockRemoteService(); let store = MainExperienceStore(service: service)
        await store.loadRemoteSecurity()
        XCTAssertEqual(service.migrationCalls, 0); XCTAssertEqual(service.authorizationCalls, 1)
        XCTAssertTrue(store.remoteDeviceAuthorized)
    }
    @MainActor
    func testRound23ExpiredAuthorizationDoesNotOpenPIN() async {
        let service = MockRemoteService(); service.authorizationToken = .init(value: "fixture", expiresAt: .distantPast)
        let store = MainExperienceStore(service: service); await store.loadRemoteSecurity()
        XCTAssertFalse(store.remoteDeviceAuthorized); XCTAssertFalse(store.isRemoteUnlocked)
        XCTAssertFalse(store.remoteNeedsProtectionGate); XCTAssertFalse(store.needsProtectionGate(for: .agent))
        XCTAssertEqual(store.remoteSecurityDiagnosticCode, "authorization_expired")
    }
    @MainActor
    func testRound23NewerProtocolRequiresUpdateWithoutDowngrade() async {
        let service = MockRemoteService(); service.deviceState = .init(version: 3, legacyProtected: false)
        let store = MainExperienceStore(service: service); await store.loadRemoteSecurity()
        XCTAssertFalse(store.remoteDeviceAuthorized); XCTAssertEqual(service.migrationCalls, 0)
        XCTAssertEqual(service.authorizationCalls, 0); XCTAssertEqual(store.remoteSecurityDiagnosticCode, "client_update_required")
    }
    @MainActor
    func testRound23MigrationReauthenticationKeepsCachedConversationsAccessible() async {
        let service = MockRemoteService(); service.overview = sampleOverview(); service.deviceState = nil
        service.migrationError = .server(code: "fresh_sign_in_required")
        let store = MainExperienceStore(service: service); await store.load(); await store.loadRemoteSecurity()
        XCTAssertFalse(store.remoteDeviceAuthorized); XCTAssertEqual(store.remoteSecurityDiagnosticCode, "fresh_sign_in_required")
        XCTAssertFalse(store.recentChatSessions.isEmpty); XCTAssertFalse(store.needsProtectionGate(for: .code))
        XCTAssertNil(service.lastSetPIN)
    }
    @MainActor
    func testRound23LateDeviceAuthorizationCannotUnlockChangedContext() async {
        let service = MockRemoteService(); let latch = SecurityResponseLatch()
        service.securityStateHook = { await latch.wait() }
        let store = MainExperienceStore(service: service)
        let pending = Task { await store.loadRemoteSecurity() }; await latch.started()
        store.invalidateRemoteSecurityContext(); await latch.release(); await pending.value
        XCTAssertFalse(store.remoteDeviceAuthorized); XCTAssertFalse(store.isRemoteUnlocked)
        XCTAssertEqual(service.authorizationCalls, 0)
    }
    @MainActor
    func testRound23RetiredPINActionsNeverReachTheServerOrKeychain() async {
        let service = MockRemoteService(); let biometric = MockBiometricSecretStore()
        let store = MainExperienceStore(service: service, biometricSecretStore: biometric)
        let configured = await store.configureRemoteSecurity(pin: "123456", enableBiometrics: true)
        let unlocked = await store.unlockRemote(pin: "123456")
        let enabled = await store.enableRemoteBiometrics(pin: "123456")
        let local = await store.unlockRemoteWithBiometrics()
        let reset = await store.resetRemoteSecurity()
        let toggled = await store.setRemoteSecurityEnabled(true)
        XCTAssertFalse(configured || unlocked || enabled || local || reset || toggled)
        XCTAssertNil(service.lastSetPIN); XCTAssertNil(service.lastVerifiedPIN); XCTAssertNil(service.lastEnabledValue)
        XCTAssertNil(biometric.storedPIN); XCTAssertEqual(service.authorizationCalls, 0)
    }

    @MainActor
    func testInitialRemoteFailureDoesNotInventAnUnpairedDevice() async {
        let service = MockRemoteService()
        service.loadError = .unavailable
        let store = MainExperienceStore(service: service)

        await store.load()

        XCTAssertFalse(store.shouldOfferPairing)
        XCTAssertEqual(store.computerState, .unavailable)
        XCTAssertNotNil(store.inlineErrorMessage)
    }

    @MainActor
    func testPairedDeviceDoesNotOfferPairing() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)

        await store.load()

        XCTAssertFalse(store.shouldOfferPairing)
    }

    @MainActor
    func testAllConversationModesAppearInTheSidebar() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)

        await store.load()
        XCTAssertEqual(Set(store.recentChatSessions.map(\.id)), ["chat-1", "code-1"], "Device authorization does not hide cached modes")
        await store.loadRemoteSecurity()

        XCTAssertEqual(Set(store.recentChatSessions.map(\.id)), ["chat-1", "code-1"])
    }

    @MainActor
    func testSearchMatchesSessionTitlesWorkspacesAndModesWithoutDiacritics() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load(); await store.loadRemoteSecurity()

        XCTAssertEqual(store.searchSessions(matching: "discussion").map(\.id), ["chat-1"])
        XCTAssertEqual(store.searchSessions(matching: "tmp").map(\.id), ["code-1"])
        XCTAssertEqual(store.searchSessions(matching: "code").map(\.id), ["code-1"])
        XCTAssertEqual(store.searchSessions(matching: "introuvable"), [])
    }

    @MainActor
    func testSidebarDestinationsAreTypedAndNewChatResetsTheRoute() {
        let store = MainExperienceStore(service: MockRemoteService())

        store.navigate(to: .projects)
        XCTAssertEqual(store.destination, .projects)

        store.startNewChat()
        XCTAssertEqual(store.destination, .newChat)
    }

    @MainActor
    func testLoadFiltersSessionsByModeAndMachine() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)

        await store.load()
        store.mode = .code
        store.selectedMachineID = "machine-1"

        XCTAssertEqual(store.filteredSessions.map(\.id), ["code-1"])
        XCTAssertEqual(store.overview.connectionState, .paired)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testSelectingSessionLoadsItsMessages() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        service.messages = [.init(id: "message-1", sessionID: "chat-1", sequence: 1, role: .assistant, content: "Bonjour", reasoning: nil, timeline: nil)]
        let store = MainExperienceStore(service: service)
        await store.load()

        guard let session = store.overview.sessions.first(where: { $0.id == "chat-1" }) else {
            return XCTFail("Missing fixture session")
        }
        await store.selectSession(session)

        XCTAssertEqual(store.selectedSessionID, "chat-1")
        XCTAssertEqual(store.messages.map(\.content), ["Bonjour"])
        XCTAssertEqual(service.loadedSessionID, "chat-1")
    }

    @MainActor
    func testMessageRealtimeEventRefreshesOnlyTheSelectedConversation() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        guard let session = store.overview.sessions.first(where: { $0.id == "chat-1" }) else {
            return XCTFail("Missing fixture session")
        }
        await store.selectSession(session)
        service.messages = [.init(id: "live", sessionID: "chat-1", sequence: 2, role: .assistant, content: "Live", reasoning: nil, timeline: nil)]

        await store.handleRemoteEvent(.messagesChanged(sessionID: "another"))
        XCTAssertEqual(store.messages, [])

        await store.handleRemoteEvent(.messagesChanged(sessionID: "chat-1"))
        XCTAssertEqual(store.messages.map(\.content), ["Live"])
    }

    @MainActor
    func testSuccessfulPairingRefreshesOverview() async {
        let service = MockRemoteService()
        service.overview = RemoteOverview(connectionState: .unpaired, machines: [], sessions: [])
        service.overviewAfterPairing = sampleOverview()
        let store = MainExperienceStore(service: service)

        let paired = await store.pair(code: "ABCD-1234", name: "iPhone de test")

        XCTAssertTrue(paired)
        XCTAssertEqual(store.overview.connectionState, .paired)
        XCTAssertEqual(service.pairingCode, "ABCD-1234")
        XCTAssertFalse(store.isPairing)
    }

    @MainActor
    func testSuccessfulPairingRemainsConfirmedWhenImmediateMirrorRefreshFails() async {
        let service = MockRemoteService()
        service.overview = RemoteOverview(connectionState: .unpaired, machines: [], sessions: [])
        service.loadError = .unavailable
        let store = MainExperienceStore(service: service)

        let paired = await store.pair(code: "ABC234", name: "iPhone de test")

        XCTAssertTrue(paired)
        XCTAssertEqual(store.overview.connectionState, .paired)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.inlineErrorMessage)
        XCTAssertFalse(store.isPairing)
    }

    @MainActor
    func testExpiredOrUnknownPairingCodeUsesTheActionableError() async {
        let service = MockRemoteService()
        service.pairingResult = .init(succeeded: false, errorCode: "invalid_or_expired_code")
        let store = MainExperienceStore(service: service)

        let paired = await store.pair(code: "ABC234", name: "iPhone de test")

        XCTAssertFalse(paired)
        XCTAssertEqual(store.errorMessage, String(localized: "main.pair.invalid"))
    }

    @MainActor
    func testPairingTransportFailureDoesNotMasqueradeAsAMirrorLoadingError() async {
        let service = MockRemoteService()
        service.pairingError = .unavailable
        let store = MainExperienceStore(service: service)

        let paired = await store.pair(code: "ABC234", name: "iPhone de test")

        XCTAssertFalse(paired)
        XCTAssertEqual(store.errorMessage, String(localized: "main.pair.failed"))
    }

    @MainActor
    func testPairingFailureExposesSafeDiagnosticReference() async {
        let service = MockRemoteService()
        service.pairingError = .pairingFailed(.init(stage: .request, code: "PGRST202"))
        let store = MainExperienceStore(service: service)

        let paired = await store.pair(code: "ABC234", name: "iPhone de test")

        XCTAssertFalse(paired)
        XCTAssertEqual(store.pairingDiagnosticCode, "PAIR-RPC-PGRST202")
        XCTAssertEqual(store.errorMessage, String(localized: "main.pair.failed"))
    }

    @MainActor
    func testAuthenticationFailureRecoversAndRetriesPairingOnce() async {
        let service = MockRemoteService()
        service.pairingError = .pairingFailed(.init(stage: .authentication, code: "SESSION_NOT_FOUND"))
        var recoveryCount = 0
        let store = MainExperienceStore(service: service) {
            recoveryCount += 1
            service.pairingError = nil
            return true
        }

        let paired = await store.pair(code: "ABC234", name: "iPhone de test")

        XCTAssertTrue(paired)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(service.pairingCallCount, 2)
        XCTAssertNil(store.pairingDiagnosticCode)
    }

    @MainActor
    func testAuthenticationFailureDuringOverviewRecoversAndRetriesOnce() async {
        let service = MockRemoteService()
        service.loadError = .pairingFailed(.init(stage: .authentication, code: "SESSION_NOT_FOUND"))
        var recoveryCount = 0
        let store = MainExperienceStore(service: service) {
            recoveryCount += 1
            service.loadError = nil
            return true
        }

        await store.load()

        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(service.loadCallCount, 2)
        XCTAssertNil(store.inlineErrorMessage)
    }

    @MainActor
    func testBackgroundMirrorFailureKeepsTheLastPairedComputerVisible() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        service.loadError = .unavailable

        await store.load()

        XCTAssertEqual(store.computerState, .available(name: "Mac"))
        XCTAssertEqual(store.overview.connectionState, .paired)
        XCTAssertFalse(store.shouldOfferPairing)
        XCTAssertNotNil(store.inlineErrorMessage)
    }

    @MainActor
    func testServerPairingRejectionExposesStructuredDiagnosticReference() async {
        let service = MockRemoteService()
        service.pairingResult = .init(succeeded: false, errorCode: "weak_secret")
        let store = MainExperienceStore(service: service)

        let paired = await store.pair(code: "ABC234", name: "iPhone de test")

        XCTAssertFalse(paired)
        XCTAssertEqual(store.pairingDiagnosticCode, "PAIR-RESPONSE-WEAK_SECRET")
    }

    @MainActor
    func testNewChatCreatesARemoteChatWithTheOfficialDefaultModel() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        service.createdSessionID = "chat-1"
        let store = MainExperienceStore(service: service)
        await store.load()

        let sent = await store.sendNewChat(text: "Bonjour")

        XCTAssertTrue(sent)
        XCTAssertEqual(service.creationRequest?.mode, .chat)
        XCTAssertEqual(service.creationRequest?.modelID, "claude-sonnet-5")
        XCTAssertEqual(service.creationRequest?.text, "Bonjour")
        XCTAssertEqual(store.destination, .conversation("chat-1"))
    }

    @MainActor
    func testNewChatUploadsMediaIntoADeferredSessionBeforePublishingTheMessage() async {
        let service = MockRemoteService()
        let base = sampleOverview()
        guard let sourceMachine = base.machines.first else { return XCTFail("Missing machine") }
        let machine = RemoteMachine(
            id: sourceMachine.id,
            name: sourceMachine.name,
            platform: sourceMachine.platform,
            appVersion: sourceMachine.appVersion,
            lastSeenAt: sourceMachine.lastSeenAt,
            keyVersion: sourceMachine.keyVersion,
            capabilities: .init(
                models: sourceMachine.capabilities?.models ?? [],
                features: ["attachments": true]
            )
        )
        service.overview = .init(connectionState: .paired, machines: [machine], sessions: base.sessions)
        service.createdSessionID = "chat-1"
        let owner = UUID(); let root = URL.applicationSupportDirectory.appending(path: "Chat/" + owner.uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        service.attachmentTransferID = UUID().uuidString
        let store = MainExperienceStore(service: service, queueAccountID: owner)
        await store.load()

        guard let reference = await store.uploadNewChatAttachment(
            data: UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).jpegData(withCompressionQuality: 0.8) { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            },
            name: "photo.jpg",
            mimeType: "image/jpeg"
        ) else { return XCTFail("Upload should succeed") }
        let sent = await store.sendNewChat(text: "Describe this", attachments: [reference])

        XCTAssertTrue(sent)
        XCTAssertEqual(service.creationRequest?.mode, .chat)
        XCTAssertTrue(service.creationRequest?.defersInitialMessage == true)
        XCTAssertEqual(service.sentCommandType, .userMessage)
        XCTAssertEqual(
            service.sentPayload?.objectValue?["attachments"]?.arrayValue?.first?.objectValue?["transfer_id"]?.stringValue,
            service.attachmentTransferID
        )
    }

    @MainActor
    func testConversationMessageUsesTheAuthenticatedRemoteCommand() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        guard let session = store.overview.sessions.first else { return XCTFail("Missing session") }
        await store.selectSession(session)

        let sent = await store.sendMessage("Continue")

        XCTAssertTrue(sent)
        XCTAssertEqual(service.sentCommandType, .userMessage)
        XCTAssertEqual(service.sentPayload?.objectValue?["text"]?.stringValue, "Continue")
    }

    @MainActor
    func testConversationMessageIncludesOnlyUploadedAttachmentReferences() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        guard let session = store.overview.sessions.first(where: { $0.mode == .code }) else {
            return XCTFail("Missing code session")
        }
        await store.selectSession(session)
        guard let reference = await store.uploadAttachment(
            data: Data("secret file".utf8),
            name: "notes.txt",
            mimeType: "text/plain"
        ) else { return XCTFail("Upload should succeed") }

        let sent = await store.sendMessage("Review this", attachments: [reference])

        XCTAssertTrue(sent)
        XCTAssertEqual(service.uploadedAttachment?.name, "notes.txt")
        let attachment = service.sentPayload?.objectValue?["attachments"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(attachment?["transfer_id"]?.stringValue, "transfer-1")
        XCTAssertEqual(attachment?["name"]?.stringValue, "notes.txt")
        XCTAssertNil(service.sentPayload?.objectValue?["data"])
    }

    @MainActor
    func testApprovalResponseCarriesThePendingMessageIdentity() async {
        let service = MockRemoteService()
        let approval = RemotePendingApproval(messageID: "approval-1", toolName: "shell", summary: "Run tests")
        let base = sampleOverview()
        let source = base.sessions[0]
        let waiting = RemoteSession(
            id: source.id, machineID: source.machineID, mode: source.mode, title: source.title,
            workspace: source.workspace, modelID: source.modelID, approvalMode: source.approvalMode,
            status: "waiting_approval", messageCount: source.messageCount, updatedAt: source.updatedAt,
            agentSystem: source.agentSystem, phase: source.phase, isSilent: source.isSilent,
            isInterrupted: source.isInterrupted, pendingApproval: approval
        )
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [waiting])
        let store = MainExperienceStore(service: service)
        await store.load()
        await store.selectSession(waiting)

        let answered = await store.respondToApproval(approved: true)

        XCTAssertTrue(answered)
        XCTAssertEqual(service.sentCommandType, .approvalResponse)
        XCTAssertEqual(service.sentPayload?.objectValue?["approved"]?.boolValue, true)
        XCTAssertEqual(service.sentPayload?.objectValue?["messageId"]?.stringValue, "approval-1")
    }

    @MainActor
    func testActiveApprovalSnapshotCannotEraseReadableTextButTerminalAndUnreadableStayAuthoritative() async {
        let service = MockRemoteService(), base = sampleOverview(), source = sampleOverview().sessions[0]
        func session(_ status: String) -> RemoteSession {
            .init(id: source.id, machineID: source.machineID, mode: source.mode, title: source.title, workspace: source.workspace,
                modelID: source.modelID, approvalMode: source.approvalMode, status: status, messageCount: 2, updatedAt: .now,
                agentSystem: source.agentSystem, phase: nil, isSilent: false, isInterrupted: false)
        }
        func message(_ text: String, state: RemoteReadState = .readable) -> RemoteMessage {
            .init(id: "assistant", sessionID: source.id, sequence: 2, role: .assistant, content: text,
                reasoning: nil, timeline: nil, readState: state)
        }
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [session("waiting_approval")])
        service.messages = [message("I will open the app.")]
        let store = MainExperienceStore(service: service)
        await store.load(); await store.selectSession(session("waiting_approval"))
        service.messages = [message("")]
        await store.refreshSelectedSession()
        XCTAssertEqual(store.messages.first?.content, "I will open the app.")
        service.messages = [message("I will open the app. Done.")]
        await store.refreshSelectedSession()
        XCTAssertEqual(store.messages.first?.content, "I will open the app. Done.")
        service.messages = [message("", state: .envelopeUnreadable)]
        await store.refreshSelectedSession()
        XCTAssertEqual(store.messages.first?.content, "")
        XCTAssertEqual(store.messages.first?.readState, .envelopeUnreadable)
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [session("idle")])
        await store.load()
        service.messages = [message("")]
        await store.refreshSelectedSession()
        XCTAssertEqual(store.messages.first?.content, "", "Terminal snapshots never restore cached data")
    }

    @MainActor
    func testLateMessageSnapshotCannotReplaceNewerRefresh() async {
        let service = MockRemoteService(), base = sampleOverview(), session = sampleOverview().sessions[0]
        service.overview = base
        let old = RemoteMessage(id: "assistant", sessionID: session.id, sequence: 2, role: .assistant, content: "Old", reasoning: nil, timeline: nil)
        let new = RemoteMessage(id: "assistant", sessionID: session.id, sequence: 2, role: .assistant, content: "New", reasoning: nil, timeline: nil)
        let store = MainExperienceStore(service: service)
        await store.load(); await store.selectSession(session)
        let gate = AsyncStream<Void>.makeStream(), submitted = expectation(description: "old read pending")
        var reads = 0
        service.messageReadHook = { @MainActor in
            reads += 1
            if reads == 1 { submitted.fulfill(); for await _ in gate.stream { break }; return [old] }
            return [new]
        }
        let older = Task { await store.refreshSelectedSession() }
        await fulfillment(of: [submitted], timeout: 2)
        await store.refreshSelectedSession()
        XCTAssertEqual(store.messages.first?.content, "New")
        gate.continuation.yield(()); gate.continuation.finish()
        await older.value
        XCTAssertEqual(store.messages.first?.content, "New")
    }

    @MainActor
    func testApprovalAcknowledgementClearsOnlyExactCardAndRejectsLateSnapshots() async {
        let service = MockRemoteService(), base = sampleOverview()
        let source = base.sessions[0]
        let first = RemotePendingApproval(messageID: "first", toolName: "open_app", summary: "Fixture")
        let waiting = source.replacing(pendingApproval: .some(first))
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [waiting])
        let store = MainExperienceStore(service: service)
        await store.load(); await store.selectSession(waiting)
        let gate = AsyncStream<Void>.makeStream()
        let submitted = expectation(description: "response submitted")
        service.sendHook = { submitted.fulfill(); for await _ in gate.stream { break } }
        let response = Task { await store.respondToApproval(approved: true) }
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(store.selectedSession?.pendingApproval?.messageID, "first", "No optimistic clearing before ACK")
        gate.continuation.yield(()); gate.continuation.finish()
        let accepted = await response.value
        XCTAssertTrue(accepted)
        XCTAssertNil(store.selectedSession?.pendingApproval)
        await store.load() // server still carries the acknowledged ID
        XCTAssertNil(store.selectedSession?.pendingApproval)
        let next = source.replacing(pendingApproval: .some(.init(messageID: "second", toolName: "open_app", summary: "New fixture")))
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [next])
        await store.load()
        XCTAssertEqual(store.selectedSession?.pendingApproval?.messageID, "second")
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [waiting])
        await store.load() // late snapshot of the first card must not erase the newer second card
        XCTAssertEqual(store.selectedSession?.pendingApproval?.messageID, "second")
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [source.replacing(pendingApproval: .some(nil))])
        await store.load()
        XCTAssertNil(store.selectedSession?.pendingApproval)
    }

    @MainActor
    func testApprovalLateSuccessAfterAccountContextInvalidationDoesNotConsumeCard() async {
        let service = MockRemoteService(), base = sampleOverview()
        let waiting = base.sessions[0].replacing(pendingApproval: .some(.init(messageID: "pending", toolName: "open_app", summary: "Fixture")))
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [waiting])
        let store = MainExperienceStore(service: service)
        await store.load(); await store.selectSession(waiting)
        var current = true
        store.setSecurityContextValidator { current }
        service.sendHook = { @MainActor in current = false; store.invalidateRemoteSecurityContext() }
        let accepted = await store.respondToApproval(approved: true)
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.selectedSession?.pendingApproval?.messageID, "pending")
        current = true
        await store.load()
        XCTAssertEqual(store.selectedSession?.pendingApproval?.messageID, "pending")
    }

    @MainActor
    func testMissingApprovalReplyKeepsBridgeResponsiveAndExplainsPendingRequest() async {
        for error in [RemoteServiceError.commandRejected("aucune_approbation_en_attente"),
                      .commandFailure(.init(code: .commandRefused, stage: .failed,
                         serverCode: "approbation_expiree", diagnosticReference: "REMOTE-APPROVAL-FIXTURE"))] {
            let service = MockRemoteService()
            let source = sampleOverview().sessions[0]
            let waiting = RemoteSession(id: source.id, machineID: source.machineID, mode: source.mode,
                title: source.title, workspace: source.workspace, modelID: source.modelID,
                approvalMode: source.approvalMode, status: "waiting_approval", messageCount: source.messageCount,
                updatedAt: source.updatedAt, agentSystem: source.agentSystem, phase: source.phase,
                isSilent: source.isSilent, isInterrupted: source.isInterrupted,
                pendingApproval: .init(messageID: "approval-pending", toolName: "open_app", summary: "Fixture"))
            service.overview = .init(connectionState: .paired, machines: sampleOverview().machines, sessions: [waiting])
            let store = MainExperienceStore(service: service)
            await store.load(); await store.selectSession(waiting)
            service.sendError = error
            let answered = await store.respondToApproval(approved: true)
            XCTAssertFalse(answered)
            XCTAssertFalse(store.isSending)
            XCTAssertEqual(store.commandHealth(for: source.machineID), .responsive)
            XCTAssertEqual(store.selectedSession?.pendingApproval?.messageID, "approval-pending")
            XCTAssertEqual(store.errorMessage, "The Mac could not find this pending approval. Refresh the conversation and check the request on the Mac.")
        }
    }

    @MainActor
    func testRemoteImagePreparationRetainsPrivateOriginalAndAccountScopedPreviewAfterRestart() async throws {
        let owner = UUID(), transferID = UUID().uuidString
        let root = URL.applicationSupportDirectory.appending(path: "Chat/" + owner.uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32)).pngData { context in
            UIColor.systemRed.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }
        let service = MockRemoteService(); service.overview = sampleOverview(); service.attachmentTransferID = transferID
        let store = MainExperienceStore(service: service, queueAccountID: owner)
        await store.load(); await store.selectSession(service.overview.sessions[0])
        let uploaded = await store.uploadAttachment(data: source, name: "private-image.png", mimeType: "image/png")
        XCTAssertEqual(uploaded?.transferID, transferID)
        let input = try XCTUnwrap(store.preparedRemoteInput(transferID))
        XCTAssertEqual(input.kind, .image); XCTAssertNotNil(input.data)
        let original = try XCTUnwrap(store.originalRemoteInput(input))
        XCTAssertEqual(try Data(contentsOf: original), source)
        let restored = MainExperienceStore(service: MockRemoteService(), queueAccountID: owner)
        XCTAssertEqual(restored.preparedRemoteInput(transferID), input)
        let other = MainExperienceStore(service: MockRemoteService(), queueAccountID: UUID())
        XCTAssertNil(other.preparedRemoteInput(transferID)); XCTAssertNil(other.originalRemoteInput(input))
        XCTAssertNil(service.sentCommandType, "Preparing and uploading input never sends a provider request")
        let file = root.appending(path: "RemotePreviews/" + transferID.lowercased() + ".json")
        try Data("corrupt".utf8).write(to: file)
        XCTAssertNil(restored.preparedRemoteInput(transferID))
        XCTAssertEqual(try Data(contentsOf: original), source, "A broken preview never deletes its private original")
    }

    @MainActor
    func testRound24ReconnectionBelongsOnlyToAnActiveAccessibleTurnAndPersistsCancellation() async {
        let suite = "round24-reconnect-" + UUID().uuidString, owner = UUID()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let id = UUID().uuidString
        func session(_ status: String, _ readState: RemoteReadState = .readable) -> RemoteSession {
            .init(id: id, machineID: "machine-1", mode: .chat, title: "Fixture", workspace: nil, modelID: nil, approvalMode: nil, status: status, messageCount: 1, updatedAt: .now, agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false, readState: readState)
        }
        service.overview = .init(connectionState: .paired, machines: service.overview.machines, sessions: [session("running")])
        service.messages = [.init(id: UUID().uuidString, sessionID: id, sequence: 0, role: .user, content: "fixture", reasoning: nil, timeline: nil, readState: .readable)]
        let store = MainExperienceStore(service: service, queueAccountID: owner, machineSelectionDefaults: defaults)
        await store.load(); await store.selectSession(service.overview.sessions[0])
        store.recordObservationInterruption(for: store.selectedSession)
        XCTAssertNotNil(store.reconnectionAction(for: service.overview.sessions[0]))
        store.recordObservationInterruption(for: store.selectedSession)
        XCTAssertTrue(store.reconnectionAction(for: service.overview.sessions[0])?.name.hasSuffix("2") == true)
        let idle = session("idle")
        XCTAssertNil(store.reconnectionAction(for: idle))
        let locked = session("running", .keyPending)
        XCTAssertNil(store.reconnectionAction(for: locked))
        store.cancelReconnection(for: service.overview.sessions[0])
        XCTAssertNil(store.reconnectionAction(for: service.overview.sessions[0]))
        let restored = MainExperienceStore(service: service, queueAccountID: owner, machineSelectionDefaults: defaults)
        await restored.load(); await restored.selectSession(service.overview.sessions[0])
        restored.recordObservationInterruption(for: restored.selectedSession)
        XCTAssertNil(restored.reconnectionAction(for: service.overview.sessions[0]))
        XCTAssertEqual(service.sendCount, 0)
    }

    @MainActor
    func testObservationPausePersistsOnlyForItsAccountAndExplicitResume() {
        let suite = "round23-observation-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        let first = MainExperienceStore(service: MockRemoteService(), queueAccountID: owner, machineSelectionDefaults: defaults)
        first.pauseObservation()
        let restored = MainExperienceStore(service: MockRemoteService(), queueAccountID: owner, machineSelectionDefaults: defaults)
        XCTAssertTrue(restored.observationPaused)
        let other = MainExperienceStore(service: MockRemoteService(), queueAccountID: UUID(), machineSelectionDefaults: defaults)
        XCTAssertFalse(other.observationPaused)
        restored.resumeObservation()
        let resumed = MainExperienceStore(service: MockRemoteService(), queueAccountID: owner, machineSelectionDefaults: defaults)
        XCTAssertFalse(resumed.observationPaused)
    }

    @MainActor
    func testPausedObservationIgnoresPeriodicRefreshAndLateEventsUntilExplicitResume() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load(); await store.selectSession(service.overview.sessions[0])
        let before = service.messageLoadCount
        store.pauseObservation()
        await store.refreshSelectedSession()
        await store.handleRemoteEvent(.messagesChanged(sessionID: service.overview.sessions[0].id))
        XCTAssertEqual(service.messageLoadCount, before)
        XCTAssertTrue(store.observationPaused); XCTAssertTrue(store.observationNotice?.contains("paused") == true)
        XCTAssertNil(service.sentCommandType, "Pausing the follow never stops the admitted Mac task")
        store.resumeObservation(); await store.refreshSelectedSession()
        XCTAssertEqual(service.messageLoadCount, before + 1)
    }

    @MainActor
    func testChangedAccountContextCannotSendNewRemoteCommands() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load(); await store.selectSession(service.overview.sessions[0])
        store.setSecurityContextValidator { false }
        let sent = await store.sendMessage("Old account request")
        XCTAssertFalse(sent); XCTAssertEqual(service.sendCount, 0)
        let attachment = await store.uploadAttachment(data: Data("old account".utf8), name: "old.txt", mimeType: "text/plain")
        XCTAssertNil(attachment); XCTAssertNil(service.uploadedAttachment)
    }

    @MainActor
    func testVisualApprovalUsesOnlyCurrentAdvertisedRouteAndApproval() async {
        let service = MockRemoteService()
        let approval = RemotePendingApproval(messageID: "visual-1", toolName: "visual_analysis", summary: "Analyse input", kind: "visual",
            questions: [.object(["provider": .string("openrouter"), "model_id": .string("vision-model")])])
        let base = sampleOverview(), source = base.sessions[0]
        let waiting = RemoteSession(id: source.id, machineID: source.machineID, mode: source.mode, title: source.title,
            workspace: source.workspace, modelID: source.modelID, approvalMode: source.approvalMode,
            status: "waiting_approval", messageCount: source.messageCount, updatedAt: source.updatedAt,
            agentSystem: source.agentSystem, phase: source.phase, isSilent: source.isSilent, isInterrupted: source.isInterrupted, pendingApproval: approval)
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [waiting])
        let store = MainExperienceStore(service: service)
        await store.load(); await store.selectSession(waiting)
        let wrongRoute = await store.respondToVisualApproval(approval, provider: "openrouter", modelID: "other", remember: true, approved: true)
        XCTAssertFalse(wrongRoute); XCTAssertNil(service.sentCommandType)
        let stale = RemotePendingApproval(messageID: "visual-old", toolName: "visual_analysis", summary: "Old", kind: "visual")
        let wrongApproval = await store.respondToVisualApproval(stale, provider: "openrouter", modelID: "vision-model", remember: false, approved: true)
        XCTAssertFalse(wrongApproval); XCTAssertNil(service.sentCommandType)
        let accepted = await store.respondToVisualApproval(approval, provider: "openrouter", modelID: "vision-model", remember: true, approved: true)
        XCTAssertTrue(accepted); XCTAssertEqual(service.sentCommandType, .approvalResponse)
        XCTAssertEqual(service.sentPayload?.objectValue?["visual_model"]?.stringValue, "vision-model")
        XCTAssertEqual(service.sentPayload?.objectValue?["remember"]?.boolValue, true)
        let sentBeforeReplay = service.sendCount
        let replay = await store.respondToVisualApproval(approval, provider: nil, modelID: nil, remember: false, approved: false)
        XCTAssertFalse(replay); XCTAssertEqual(service.sendCount, sentBeforeReplay)
        let declineApproval = RemotePendingApproval(messageID: "visual-2", toolName: "visual_analysis", summary: "New input", kind: "visual",
            questions: approval.questions)
        let declineSession = RemoteSession(id: source.id, machineID: source.machineID, mode: source.mode, title: source.title,
            workspace: source.workspace, modelID: source.modelID, approvalMode: source.approvalMode,
            status: "waiting_approval", messageCount: source.messageCount, updatedAt: source.updatedAt,
            agentSystem: source.agentSystem, phase: source.phase, isSilent: source.isSilent, isInterrupted: source.isInterrupted, pendingApproval: declineApproval)
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [declineSession])
        await store.load(); await store.selectSession(declineSession)
        let declined = await store.respondToVisualApproval(declineApproval, provider: nil, modelID: nil, remember: false, approved: false)
        XCTAssertEqual(service.sendCount, sentBeforeReplay + 1)
        XCTAssertTrue(declined); XCTAssertEqual(service.sentPayload?.objectValue?["approved"]?.boolValue, false)
        XCTAssertNil(service.sentPayload?.objectValue?["visual_model"])
    }

    @MainActor
    func testConversationModelEffortAndPermissionChangesUseRemoteCommands() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        guard let session = store.overview.sessions.first(where: { $0.mode == .code }) else {
            return XCTFail("Missing code session")
        }
        await store.selectSession(session)

        let changedModel = await store.setModel("gpt-5.6-sol", effort: "high")
        XCTAssertTrue(changedModel)
        XCTAssertEqual(service.sentCommandType, .setModel)
        XCTAssertEqual(service.sentPayload?.objectValue?["model_id"]?.stringValue, "gpt-5.6-sol")
        XCTAssertEqual(service.sentPayload?.objectValue?["effort"]?.stringValue, "high")

        let changedPermission = await store.setApprovalMode("accept")
        XCTAssertTrue(changedPermission)
        XCTAssertEqual(service.sentCommandType, .setApprovalMode)
        XCTAssertEqual(service.sentPayload?.objectValue?["mode"]?.stringValue, "accept")
    }

    @MainActor
    func testGoalMessageCarriesTheBoundedTurnLimit() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        guard let session = store.overview.sessions.first(where: { $0.mode == .code }) else {
            return XCTFail("Missing code session")
        }
        await store.selectSession(session)

        let sent = await store.sendGoal("Finish the migration", maximumTurns: 100)

        XCTAssertTrue(sent)
        XCTAssertEqual(service.sentCommandType, .userMessage)
        XCTAssertEqual(service.sentPayload?.objectValue?["text"]?.stringValue, "Finish the migration")
        XCTAssertEqual(service.sentPayload?.objectValue?["goal"]?.objectValue?["max_turns"]?.numberValue, 50)
    }

    @MainActor
    func testQuestionResponseCarriesTheComposedAnswersWithoutAnApprovalFlag() async {
        let service = MockRemoteService()
        let question = RemotePendingApproval(
            messageID: "question-1",
            toolName: "ask_user",
            summary: "Choose a database",
            kind: "question",
            questions: [.object(["question": .string("Which database?")])]
        )
        let base = sampleOverview()
        let source = base.sessions[0]
        let waiting = RemoteSession(
            id: source.id, machineID: source.machineID, mode: source.mode, title: source.title,
            workspace: source.workspace, modelID: source.modelID, approvalMode: source.approvalMode,
            status: "waiting_approval", messageCount: source.messageCount, updatedAt: source.updatedAt,
            agentSystem: source.agentSystem, phase: source.phase, isSilent: source.isSilent,
            isInterrupted: source.isInterrupted, pendingApproval: question
        )
        service.overview = .init(connectionState: .paired, machines: base.machines, sessions: [waiting])
        let store = MainExperienceStore(service: service)
        await store.load()
        await store.selectSession(waiting)

        let answered = await store.respondToQuestion(answers: "SQLite")

        XCTAssertTrue(answered)
        XCTAssertEqual(service.sentCommandType, .approvalResponse)
        XCTAssertEqual(service.sentPayload?.objectValue?["messageId"]?.stringValue, "question-1")
        XCTAssertEqual(service.sentPayload?.objectValue?["answers"]?.stringValue, "SQLite")
        XCTAssertNil(service.sentPayload?.objectValue?["approved"])
    }

    @MainActor
    func testCodeCreationRequiresAndSendsTheSelectedWorkspace() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        service.createdSessionID = "code-1"
        service.folderListing = .init(folders: [.init(path: "/Projects/AIM", name: "AIM")])
        let store = MainExperienceStore(service: service)
        await store.load()
        store.startNewRemoteSession(mode: .code)
        await store.loadFolders()
        store.selectedWorkspace = store.remoteFolders.first?.path

        let created = await store.createRemoteSession(text: "Fix the tests")

        XCTAssertTrue(created)
        XCTAssertEqual(service.creationRequest?.mode, .code)
        XCTAssertEqual(service.creationRequest?.workspace, "/Projects/AIM")
        XCTAssertEqual(service.creationRequest?.approvalMode, "review")
        XCTAssertEqual(store.destination, .conversation("code-1"))
    }

    @MainActor
    func testGoalCanStartANewRemoteSessionWithTheExactTurnLimit() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        service.createdSessionID = "code-1"
        let store = MainExperienceStore(service: service)
        await store.load()
        store.startNewRemoteSession(mode: .code)
        store.selectedWorkspace = "/Projects/AIM"

        let created = await store.createRemoteSession(
            text: "Finish the migration",
            goalMaximumTurns: 20
        )

        XCTAssertTrue(created)
        XCTAssertEqual(service.creationRequest?.text, "Finish the migration")
        XCTAssertEqual(service.creationRequest?.goal?.maximumTurns, 20)
    }

    @MainActor
    func testChatComputerSelectionDoesNotReadProtectedFoldersOrReplaceModel() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        store.selectedModelID = "saved-model-not-on-this-computer"
        await store.selectMachine(id: "machine-1")

        XCTAssertEqual(service.folderLoadCount, 0)
        XCTAssertEqual(store.selectedModelID, "saved-model-not-on-this-computer")
        store.startNewChat()
        await store.load()
        XCTAssertEqual(store.selectedModelID, "saved-model-not-on-this-computer")
        let sent = await store.sendNewChat(text: "Do not silently bill another model")
        XCTAssertFalse(sent)
        XCTAssertEqual(service.creationCallCount, 0)
    }

    @MainActor
    func testLegacyMacCannotSilentlyChooseAnAmbiguousProvider() async {
        let service = MockRemoteService()
        let models = [RemoteModelAnnouncement(id: "same-model", name: "Direct", provider: "anthropic"),
                      RemoteModelAnnouncement(id: "same-model", name: "Routed", provider: "openrouter")]
        let machine = RemoteMachine(id: "machine-1", name: "Mac", platform: "darwin", appVersion: "2.0",
                                    lastSeenAt: .now, keyVersion: nil, capabilities: .init(models: models))
        service.overview = .init(connectionState: .paired, machines: [machine], sessions: [])
        let store = MainExperienceStore(service: service)
        await store.load(); store.selectModel(models[1])
        let sent = await store.sendNewChat(text: "Do not use the first provider")
        XCTAssertFalse(sent)
        XCTAssertEqual(service.creationCallCount, 0)
        XCTAssertTrue(store.errorMessage?.contains("Update") == true)
    }

    @MainActor
    func testRemoteCreationAndModelChangeCarryTheChosenProvider() async throws {
        let service = MockRemoteService()
        let base = sampleOverview()
        let models = [RemoteModelAnnouncement(id: "same-model", name: "Direct", provider: "anthropic"),
                      RemoteModelAnnouncement(id: "same-model", name: "Routed", provider: "openrouter")]
        let machine = RemoteMachine(id: "machine-1", name: "Mac", platform: "darwin", appVersion: "2.0",
                                    lastSeenAt: .now, keyVersion: nil, capabilities: .init(models: models, features: ["modelRouting": true]))
        service.overview = .init(connectionState: .paired, machines: [machine], sessions: base.sessions)
        service.createdSessionID = "chat-1"
        let store = MainExperienceStore(service: service)
        await store.load()
        store.selectedModelID = "same-model"
        let ambiguous = await store.sendNewChat(text: "Choose explicitly")
        XCTAssertFalse(ambiguous)
        XCTAssertEqual(service.creationCallCount, 0)
        store.selectModel(models[1])
        let sent = await store.sendNewChat(text: "Use the selected provider")
        XCTAssertTrue(sent)
        XCTAssertEqual(service.creationRequest?.provider, "openrouter")
        XCTAssertEqual(service.creationRequest?.modelID, "same-model")
        let changed = await store.setModel("same-model", provider: "anthropic")
        XCTAssertTrue(changed)
        XCTAssertEqual(service.sentPayload?.objectValue?["provider"]?.stringValue, "anthropic")
    }

    @MainActor
    func testSelectingAnotherComputerClearsComputerSpecificFolderState() async {
        let service = MockRemoteService()
        let first = RemoteMachine(id: "machine-1", name: "Mac", platform: "darwin", appVersion: "2.0", lastSeenAt: Date(), keyVersion: nil)
        let second = RemoteMachine(id: "machine-2", name: "PC", platform: "windows", appVersion: "2.0", lastSeenAt: Date(), keyVersion: nil)
        service.overview = .init(connectionState: .paired, machines: [first, second], sessions: [])
        service.folderListing = .init(folders: [.init(path: "/Projects/AIM", name: "AIM")])
        let store = MainExperienceStore(service: service)
        await store.load()
        store.startNewRemoteSession(mode: .agent)
        await store.loadFolders()
        store.selectedWorkspace = "/Projects/AIM"

        await store.selectMachine(id: second.id)

        XCTAssertEqual(store.selectedMachineID, second.id)
        XCTAssertNil(store.selectedWorkspace)
        XCTAssertNil(store.currentFolderPath)
    }

    @MainActor
    func testRemoteSelectionMultipleComputersRequiresExplicitChoice() async {
        let service = MockRemoteService(); service.overview = selectionOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        XCTAssertNil(store.selectedMachine); XCTAssertNil(store.selectedMachineID)
        XCTAssertEqual(store.computerState, .chooseComputer)
        store.startNewChat(); XCTAssertNil(store.selectedMachineID)
        // An old mode configuration from a single-computer mirror is not an explicit choice.
        service.overview = .init(connectionState: .paired, machines: [service.overview.machines[1]], sessions: [])
        await store.load(); store.startNewRemoteSession(mode: .code)
        service.overview = selectionOverview(); await store.load(); store.startNewChat()
        store.switchCreationMode(to: .code)
        XCTAssertNil(store.selectedMachineID); XCTAssertEqual(store.computerState, .chooseComputer)
    }
    @MainActor
    func testRemoteSelectionExplicitRealHostPersistsAcrossStoreAndCreationModes() async throws {
        let suite = "AIM-selection-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID(); let service = MockRemoteService(); service.overview = selectionOverview()
        let store = MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults)
        await store.load(); await store.selectMachine(id: "native")
        let restored = MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults)
        await restored.load()
        XCTAssertEqual(restored.selectedMachineID, "native"); XCTAssertEqual(restored.selectedMachineDisplayName, "TEST NATIF")
        restored.startNewChat(); XCTAssertEqual(restored.selectedMachineID, "native")
        restored.startNewRemoteSession(mode: .agent); XCTAssertEqual(restored.selectedMachineID, "native")
        restored.switchCreationMode(to: .code); XCTAssertEqual(restored.selectedMachineID, "native")
    }
    @MainActor
    func testRemoteSelectionPreferencesAreIsolatedByAccount() async throws {
        let suite = "AIM-selection-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let service = MockRemoteService(); service.overview = selectionOverview()
        let first = MainExperienceStore(service: service, queueAccountID: UUID(), machineSelectionDefaults: defaults)
        await first.load(); await first.selectMachine(id: "native")
        let other = MainExperienceStore(service: service, queueAccountID: UUID(), machineSelectionDefaults: defaults)
        await other.load()
        XCTAssertNil(other.selectedMachineID); XCTAssertEqual(other.computerState, .chooseComputer)
    }
    @MainActor
    func testRemoteSelectionMissingOrOfflinePreferenceNeverReroutesToFixture() async throws {
        let suite = "AIM-selection-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID(); let service = MockRemoteService(); service.overview = selectionOverview()
        let first = MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults)
        await first.load(); await first.selectMachine(id: "native")
        let fixture = service.overview.machines[0]
        let offline = RemoteMachine(id: "native", name: "TEST NATIF", platform: "darwin", appVersion: "2.0", lastSeenAt: .now.addingTimeInterval(-600), keyVersion: nil)
        service.overview = .init(connectionState: .paired, machines: [fixture, offline], sessions: [])
        let restored = MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults)
        await restored.load(); XCTAssertEqual(restored.computerState, .offline(name: "TEST NATIF"))
        service.overview = .init(connectionState: .paired, machines: [fixture], sessions: [])
        await restored.load(); restored.startNewChat()
        XCTAssertEqual(restored.selectedMachineID, "native"); XCTAssertNil(restored.selectedMachine)
        XCTAssertEqual(restored.computerState, .selectionUnavailable(name: "TEST NATIF"))
    }
    @MainActor
    func testRemoteSelectionReaffirmingCurrentSingleComputerPersistsTheExplicitChoice() async throws {
        let suite = "AIM-selection-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID(); let service = MockRemoteService(); let both = selectionOverview()
        service.overview = .init(connectionState: .paired, machines: [both.machines[1]], sessions: [])
        let first = MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults)
        await first.load(); await first.selectMachine(id: "native")
        service.overview = both
        let restored = MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults)
        await restored.load(); XCTAssertEqual(restored.selectedMachineID, "native")
    }
    @MainActor
    func testRemoteSelectionNewExplicitChoiceOverridesOldPerModeComputerConfiguration() async {
        let service = MockRemoteService(); service.overview = selectionOverview()
        let store = MainExperienceStore(service: service)
        await store.load(); await store.selectMachine(id: "fixture")
        store.startNewRemoteSession(mode: .code); store.switchCreationMode(to: .chat)
        await store.selectMachine(id: "native")
        store.switchCreationMode(to: .code)
        XCTAssertEqual(store.selectedMachineID, "native")
        XCTAssertNil(store.selectedWorkspace)
    }
    @MainActor
    func testRound23LegacySectionPoliciesDoNotReactivateLocalProtection() async {
        for modes: [RemoteMode] in [[], [.code, .agent], [.chat, .code, .agent]] {
            let service = MockRemoteService(); service.unlockState = .init(succeeded: true, hasPIN: true, isEnabled: true)
            service.protectionPolicy = .init(revision: 10, protectedModes: modes)
            let store = MainExperienceStore(service: service); await store.loadRemoteSecurity()
            for mode in RemoteMode.allCases { XCTAssertFalse(store.needsProtectionGate(for: mode)) }
            XCTAssertTrue(store.remoteDeviceAuthorized); XCTAssertFalse(store.remoteProtectionEnabled)
            let saved = await store.saveRemoteProtectionPolicy([])
            XCTAssertFalse(saved); XCTAssertEqual(service.policySaveCount, 0)
        }
    }

    private func selectionOverview() -> RemoteOverview {
        let fixture = RemoteMachine(id: "fixture", name: "TEST SIMULÉ V2", platform: "darwin", appVersion: "2.0", lastSeenAt: .now, keyVersion: nil)
        let native = RemoteMachine(id: "native", name: "TEST NATIF", platform: "darwin", appVersion: "2.0", lastSeenAt: .now, keyVersion: nil)
        return .init(connectionState: .paired, machines: [fixture, native], sessions: [])
    }

    @MainActor
    func testRemoteReadFailureIsExplicitAndDoesNotInventCommandHealth() async {
        let service = MockRemoteService()
        for state in [RemoteReadState.envelopeUnreadable, .historicalKeyMissing, .invalidData] {
            let machine = RemoteMachine(id: "native", name: "TEST NATIF", platform: "darwin", appVersion: "2.0",
                lastSeenAt: .now, keyVersion: 2, readState: state)
            service.overview = .init(connectionState: .paired, machines: [machine], sessions: [])
            let store = MainExperienceStore(service: service)
            await store.load()
            guard case .readFailure(let name, _) = store.computerState else { XCTFail("read failure must be visible"); continue }
            XCTAssertEqual(name, "TEST NATIF")
            XCTAssertEqual(store.commandHealth(for: "native"), .unknown)
        }
    }

    @MainActor
    func testRemoteTerminalKeyPublicationFailureIsVisibleAndClearsOnSuccessfulRead() async {
        let service = MockRemoteService()
        let failure = RemoteCommandFailure(code: .commandRefused, stage: .failed,
            serverCode: "key_publication_incomplete", diagnosticReference: "REMOTE-FIXTURE")
        service.overview = .init(connectionState: .paired, machines: [RemoteMachine(id: "native", name: "TEST NATIF", platform: "darwin",
            appVersion: "2.0", lastSeenAt: .now, keyVersion: 1, readState: .keyPending, keyRequestFailure: failure)], sessions: [])
        let store = MainExperienceStore(service: service); await store.load()
        XCTAssertEqual(store.computerState, .readFailure(name: "TEST NATIF", messageKey: "remote.error.key_publication_failed"))
        service.overview = .init(connectionState: .paired, machines: [RemoteMachine(id: "native", name: "TEST NATIF", platform: "darwin",
            appVersion: "2.0", lastSeenAt: .now, keyVersion: 1, capabilities: .init(models: [.init(id: "fixture", name: "Fixture", provider: "fixture")]), readState: .readable)], sessions: [])
        await store.load()
        XCTAssertEqual(store.computerState, .available(name: "TEST NATIF"))
        XCTAssertEqual(store.commandHealth(for: "native"), .unknown)
    }

    @MainActor
    func testChatBridgeCheckDoesNotUnlockProtectedModesOrListFolders() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        service.unlockState = .init(succeeded: true, hasPIN: true, isEnabled: true)
        let store = MainExperienceStore(service: service)
        await store.load(); await store.loadRemoteSecurity()
        XCTAssertFalse(store.remoteRequiresUnlock)
        await store.probeSelectedRemoteHealth(); await store.probeSelectedRemoteHealth()
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .responsive)
        XCTAssertEqual(service.bridgeCheckCount, 1)
        XCTAssertEqual(service.folderLoadCount, 0)
        XCTAssertTrue(store.remoteDeviceAuthorized)
        XCTAssertFalse(store.remoteRequiresUnlock)
    }

    @MainActor
    func testRemoteStatusMissingCapabilitiesSynchronizesThenBecomesReady() async {
        let service = MockRemoteService()
        let machine = RemoteMachine(id: "machine-1", name: "Mac", platform: "darwin", appVersion: "0.1", lastSeenAt: .now, keyVersion: nil)
        service.overview = .init(connectionState: .paired, machines: [machine], sessions: [])
        let store = MainExperienceStore(service: service)
        await store.load()
        XCTAssertEqual(store.computerState, .synchronizing(name: "Mac"))
        service.overview = sampleOverview()
        await store.load()
        XCTAssertEqual(store.computerState, .available(name: "Mac"))
    }
    @MainActor
    func testRemoteStatusEmptyModelAnnouncementIsNotAVersionFailure() async {
        let service = MockRemoteService()
        let machine = RemoteMachine(id: "machine-1", name: "Mac", platform: "darwin", appVersion: nil, lastSeenAt: .now, keyVersion: nil, capabilities: .init(models: []))
        service.overview = .init(connectionState: .paired, machines: [machine], sessions: [])
        let store = MainExperienceStore(service: service)
        await store.load()
        XCTAssertEqual(store.computerState, .noModels(name: "Mac"))
    }
    @MainActor
    func testRemoteStatusUsesSelectedSecondComputerInsteadOfFirstOnline() async {
        let service = MockRemoteService()
        let first = sampleOverview().machines[0]
        let second = RemoteMachine(id: "machine-2", name: "Second Mac", platform: "darwin", appVersion: nil, lastSeenAt: .now, keyVersion: nil)
        service.overview = .init(connectionState: .paired, machines: [first, second], sessions: [])
        let store = MainExperienceStore(service: service)
        await store.load(); store.selectedMachineID = second.id
        XCTAssertEqual(store.computerState, .synchronizing(name: "Second Mac"))
    }
    @MainActor
    func testRemoteStatusUnsupportedHostFeatureRemainsResponsiveWithDiagnostic() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        service.folderProbeError = .commandFailure(.init(code: .unsupportedCommand, stage: .failed, diagnosticReference: "REMOTE-UNSUPPORTED-HOST"))
        let store = MainExperienceStore(service: service)
        await store.load(); await store.probeSelectedRemoteHealth()
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .responsive)
        XCTAssertEqual(store.computerState, .available(name: "Mac"))
        XCTAssertEqual(store.lastRemoteDiagnosticReference, "REMOTE-UNSUPPORTED-HOST")
        XCTAssertEqual(store.errorMessage, String(localized: "remote.error.unsupported_command"))
    }
    @MainActor
    func testRemoteStatusUnsupportedRPCDoesNotInventAHostResponse() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        service.folderProbeError = .commandFailure(.init(code: .unsupportedCommand, stage: .rpc, diagnosticReference: "REMOTE-UNSUPPORTED-RPC"))
        let store = MainExperienceStore(service: service)
        await store.load(); await store.probeSelectedRemoteHealth()
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .unknown)
        XCTAssertEqual(store.lastRemoteDiagnosticReference, "REMOTE-UNSUPPORTED-RPC")
    }
    @MainActor
    func testRemoteStatusBootstrapFailuresDoNotInventAHostResponse() async {
        for code: RemoteCommandErrorCode in [.encryptionKeyPending, .networkUnavailable, .authenticationRequired, .commandRefused] {
            let service = MockRemoteService(); service.overview = sampleOverview()
            service.folderProbeError = .commandFailure(.init(code: code, stage: .rpc, diagnosticReference: "REMOTE-BOOTSTRAP"))
            let store = MainExperienceStore(service: service)
            await store.load(); await store.probeSelectedRemoteHealth()
            XCTAssertEqual(store.commandHealth(for: "machine-1"), .unknown, code.rawValue)
            XCTAssertEqual(store.lastRemoteDiagnosticReference, "REMOTE-BOOTSTRAP")
        }
    }
    @MainActor
    func testRemoteStatusActualVersionFailureRemainsIncompatible() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        service.folderProbeError = .commandFailure(.init(code: .incompatibleVersion, stage: .failed, diagnosticReference: "REMOTE-VERSION"))
        let store = MainExperienceStore(service: service)
        await store.load(); await store.probeSelectedRemoteHealth()
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .incompatible)
        XCTAssertEqual(store.computerState, .incompatible(name: "Mac"))
    }
    @MainActor
    func testRemoteStatusLateProbeCannotReplaceNewerSuccessfulCommand() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let race = RemoteHealthFolderRace()
        service.folderProbeHook = { try await race.load() }
        let store = MainExperienceStore(service: service)
        await store.load()
        let oldProbe = Task { await store.probeSelectedRemoteHealth() }
        await race.started()
        await store.loadFolders() // Newer real command proves the bridge answered.
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .responsive)
        await race.release(); await oldProbe.value
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .responsive)
        XCTAssertNil(store.lastRemoteDiagnosticReference)
    }
    @MainActor
    func testRemoteStatusChangedMirrorDiscardsOldProbeAndReopensProbeAdmission() async {
        let service = MockRemoteService()
        let machine = RemoteMachine(id: "machine-1", name: "Mac", platform: "darwin", appVersion: nil, lastSeenAt: .now, keyVersion: nil)
        service.overview = .init(connectionState: .paired, machines: [machine], sessions: [])
        let race = RemoteHealthFolderRace(); service.folderProbeHook = { try await race.load() }
        let store = MainExperienceStore(service: service)
        await store.load()
        let oldProbe = Task { await store.probeSelectedRemoteHealth() }
        await race.started()
        service.overview = sampleOverview(); await store.load()
        await race.release(); await oldProbe.value
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .unknown)
        await store.probeSelectedRemoteHealth()
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .responsive)
    }
    @MainActor
    func testRemoteStatusHeartbeatAndCatalogueRefreshKeepValidProbeResponse() async {
        let service = MockRemoteService()
        let machine = RemoteMachine(id: "machine-1", name: "Mac", platform: "darwin", appVersion: "2.0", lastSeenAt: .now, keyVersion: nil)
        service.overview = .init(connectionState: .paired, machines: [machine], sessions: [])
        let race = RemoteHealthFolderRace(failFirst: false); service.folderProbeHook = { try await race.load() }
        let store = MainExperienceStore(service: service)
        await store.load()
        let oldProbe = Task { await store.probeSelectedRemoteHealth() }
        await race.started()
        service.overview = sampleOverview(); await store.load() // New heartbeat/catalogue, same key and app identity.
        await race.release(); await oldProbe.value
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .responsive)
        XCTAssertEqual(store.computerState, .available(name: "Mac"))
    }

    @MainActor
    func testRemoteStatusInvalidatedDeviceContextDiscardsOldProbe() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let race = RemoteHealthFolderRace(); service.folderProbeHook = { try await race.load() }
        let store = MainExperienceStore(service: service)
        await store.load()
        let oldProbe = Task { await store.probeSelectedRemoteHealth() }
        await race.started(); store.invalidateRemoteSecurityContext()
        await race.release(); await oldProbe.value
        XCTAssertEqual(store.commandHealth(for: "machine-1"), .unknown)
        XCTAssertNil(store.lastRemoteDiagnosticReference)
    }

    @MainActor
    func testRemoteHealthProbeTurnsAnOnlineUnknownComputerResponsive() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()

        XCTAssertEqual(store.commandHealth(for: "machine-1"), .unknown)

        await store.probeSelectedRemoteHealth()

        XCTAssertEqual(store.commandHealth(for: "machine-1"), .responsive)
    }

    @MainActor
    func testDeletingSidebarSessionsUpdatesTheMirrorImmediately() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()

        let deleted = await store.deleteSessions(ids: ["chat-1"])

        XCTAssertTrue(deleted)
        XCTAssertEqual(service.deletedSessionIDs, ["chat-1"])
        XCTAssertFalse(store.overview.sessions.contains { $0.id == "chat-1" })
        XCTAssertTrue(store.overview.sessions.contains { $0.id == "code-1" })
    }

    @MainActor
    func testSessionMetadataActionsUpdateTheMirrorWithoutMixingModes() async {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let store = MainExperienceStore(service: service)
        await store.load()
        let chat = try! XCTUnwrap(store.overview.sessions.first { $0.id == "chat-1" })
        let code = try! XCTUnwrap(store.overview.sessions.first { $0.id == "code-1" })

        let pinned = await store.setPinned(true, session: chat)
        let assigned = await store.setProject("project-1", session: chat)
        let renamed = await store.renameSession(code, title: "  Session renommée  ")
        let archived = await store.setArchived(true, session: code)
        XCTAssertTrue(pinned)
        XCTAssertTrue(assigned)
        XCTAssertTrue(renamed)
        XCTAssertTrue(archived)

        let updatedChat = try! XCTUnwrap(store.overview.sessions.first { $0.id == chat.id })
        let updatedCode = try! XCTUnwrap(store.overview.sessions.first { $0.id == code.id })
        XCTAssertTrue(updatedChat.isPinned)
        XCTAssertEqual(updatedChat.projectID, "project-1")
        XCTAssertEqual(updatedCode.title, "Session renommée")
        XCTAssertNotNil(updatedCode.archivedAt)
        XCTAssertEqual(service.pinnedUpdate?.sessionID, chat.id)
        XCTAssertEqual(service.projectUpdate?.projectID, "project-1")
        XCTAssertEqual(service.renameUpdate?.title, "Session renommée")
        XCTAssertEqual(service.archiveUpdate?.archived, true)
    }

    @MainActor
    func testQueuedCreationPreservesExactConfigurationAndAccount() async throws {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let account = UUID(), store = MainExperienceStore(service: service, queueAccountID: account)
        await store.load(); store.startNewRemoteSession(mode: .code)
        store.selectedWorkspace = "/Projects/Chosen"; store.selectedApprovalMode = "plan"
        let target = store.selectedMachineID, model = store.selectedModelID
        store.updateCreationDraft(.init(text: "Later code", attachments: []), for: .code)
        XCTAssertTrue(store.queueCreation())
        XCTAssertTrue(store.creationDraft(for: .code).text.isEmpty)
        let restored = MainExperienceStore(service: service, queueAccountID: account)
        let entry = try XCTUnwrap(restored.queuedMessages.first)
        XCTAssertEqual(entry.machineID, target); XCTAssertEqual(entry.creation?.workspace, "/Projects/Chosen")
        XCTAssertEqual(entry.creation?.modelID, model); XCTAssertEqual(entry.creation?.approvalMode, "plan")
        XCTAssertTrue(MainExperienceStore(service: service, queueAccountID: UUID()).queuedMessages.isEmpty)
        await restored.load(); await restored.loadRemoteSecurity(); await restored.deliverQueuedMessages()
        XCTAssertTrue(restored.queuedMessages.isEmpty)
        XCTAssertEqual(service.creationRequest?.machineID, target)
        XCTAssertEqual(service.creationRequest?.delegationID, entry.id)
        XCTAssertEqual(service.creationRequest?.text, "Later code")
        await restored.deliverQueuedMessages(); XCTAssertEqual(service.creationRequest?.delegationID, entry.id)
    }

    @MainActor
    func testOutboxPersistsAndDeliversOnlyOnceForItsAccount() async throws {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let account = UUID()
        let store = MainExperienceStore(service: service, queueAccountID: account)
        let session = try XCTUnwrap(service.overview.sessions.first)
        XCTAssertTrue(store.queueMessage(text: "Later", attachments: [], session: session))
        let restored = MainExperienceStore(service: service, queueAccountID: account)
        XCTAssertEqual(restored.queuedMessages.map(\.text), ["Later"])
        XCTAssertTrue(MainExperienceStore(service: service, queueAccountID: UUID()).queuedMessages.isEmpty)
        await restored.load()
        await restored.deliverQueuedMessages()
        XCTAssertTrue(restored.queuedMessages.isEmpty)
        XCTAssertEqual(service.sentPayload?.objectValue?["text"]?.stringValue, "Later")
        XCTAssertEqual(service.sendCount, 1)
        await restored.deliverQueuedMessages()
        XCTAssertEqual(service.sendCount, 1)
    }

    @MainActor
    func testOutboxUncertainDeliveryIsNotAutomaticallyRetried() async throws {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        service.sendError = .commandRejected("timeout")
        let store = MainExperienceStore(service: service)
        XCTAssertTrue(store.queueMessage(text: "First", attachments: [], session: service.overview.sessions[0]))
        XCTAssertTrue(store.queueMessage(text: "Second", attachments: [], session: service.overview.sessions[0]))
        await store.load()
        await store.deliverQueuedMessages()
        XCTAssertEqual(store.queuedMessages.first?.state, "review")
        await store.deliverQueuedMessages()
        XCTAssertEqual(service.sendCount, 1)
    }

    @MainActor
    func testOutboxDoesNotDeliverWhileInactiveAndCancellationPersists() async throws {
        let service = MockRemoteService()
        service.overview = sampleOverview()
        let account = UUID()
        let store = MainExperienceStore(service: service, queueAccountID: account)
        XCTAssertTrue(store.queueMessage(text: "Cancel this", attachments: [], session: service.overview.sessions[0]))
        await store.load()
        store.queueDeliveryActive = false
        await store.deliverQueuedMessages()
        XCTAssertEqual(service.sendCount, 0)
        store.removeQueuedMessage(try XCTUnwrap(store.queuedMessages.first?.id))
        XCTAssertTrue(MainExperienceStore(service: service, queueAccountID: account).queuedMessages.isEmpty)
    }

    @MainActor
    func testRemoteSuspensionPersistsPerAccountWithoutChangingSelectionOrPairing() async throws {
        let suite = "SuspensionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MockRemoteService(); service.overview = sampleOverview()
        let account = UUID()
        let store = MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults)
        await store.load()
        store.setRemoteEnabled(false, machineID: "machine-1")
        XCTAssertEqual(store.selectedMachineID, "machine-1")
        XCTAssertEqual(store.overview.connectionState, .paired)
        XCTAssertTrue(MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults).isRemoteSuspended(machineID: "machine-1"))
        XCTAssertFalse(MainExperienceStore(service: service, queueAccountID: UUID(), machineSelectionDefaults: defaults).isRemoteSuspended(machineID: "machine-1"))
        store.setRemoteEnabled(true, machineID: "machine-1")
        XCTAssertFalse(MainExperienceStore(service: service, queueAccountID: account, machineSelectionDefaults: defaults).isRemoteSuspended(machineID: "machine-1"))
    }

    @MainActor
    func testSuspensionBlocksCommandsAndRefreshButKeepsCachedMessagesAndOverview() async throws {
        let service = MockRemoteService(); service.overview = sampleOverview()
        service.messages = [.init(id: "cached", sessionID: "chat-1", sequence: 1, role: .assistant, content: "Cached", reasoning: nil, timeline: nil)]
        let store = MainExperienceStore(service: service); await store.load()
        let session = try XCTUnwrap(store.overview.sessions.first { $0.id == "chat-1" })
        await store.selectSession(session)
        store.setRemoteEnabled(false, machineID: session.machineID)
        let sent = await store.sendMessage("Do not send")
        XCTAssertFalse(sent); XCTAssertEqual(service.sendCount, 0)
        await store.probeRemoteHealth(machineID: session.machineID)
        XCTAssertEqual(service.bridgeCheckCount, 0)
        service.messages = []
        await store.refreshSelectedSession()
        XCTAssertEqual(store.messages.first?.content, "Cached")
        await store.load()
        XCTAssertEqual(store.overview.machines.count, 1)
        do { _ = try await store.attachmentMetadata(for: session); XCTFail("Remote attachment access must be blocked") } catch { }
        do { _ = try await store.skillCommand(); XCTFail("Remote skills must be blocked") } catch { }
        XCTAssertEqual(service.sendCount, 0)
    }

    @MainActor
    func testPairingDoesNotReplaceExplicitTarget() async {
        let service = MockRemoteService(); service.overview = sampleOverview()
        let store = MainExperienceStore(service: service); await store.load()
        store.selectedMachineID = "explicit-offline-mac"
        let succeeded = await store.pair(code: "ABC234", name: "iPhone")
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.selectedMachineID, "explicit-offline-mac")
        XCTAssertNotNil(store.pairingSuccessMessage)
    }

    func testPairingQRRequiresExactAIMContractAndOneCode() {
        XCTAssertEqual(AIMPairingCode.qr("aim://remote/pair?code=ABC234&name=My%20Mac&v=1"), .init(code: "ABC234", computerName: "My Mac"))
        for input in ["https://remote/pair?code=ABC234&v=1", "aim://other/pair?code=ABC234&v=1", "aim://remote/pair?code=ABC234&v=2", "aim://remote/pair?code=ABC234&code=DEF567&v=1", "aim://remote/pair?code=ABC234&v=1&secret=private", "aim://remote/pair?code=ABC234&v=1#fragment", "aim://remote/pair?code=abc234&v=1", "aim://remote/pair?code=ABCIO0&v=1", "aim://remote/pair?code=ABC234", "aim://user@remote/pair?code=ABC234&v=1"] {
            XCTAssertNil(AIMPairingCode.qr(input), input)
        }
        XCTAssertEqual(AIMPairingCode.manual(" abc234 ")?.code, "ABC234")
        XCTAssertNil(AIMPairingCode.manual("ABC-234"))
        XCTAssertNil(AIMPairingCode.manual("ABC234extra"))
    }

    private func sampleOverview() -> RemoteOverview {
        let machine = RemoteMachine(
            id: "machine-1",
            name: "Mac",
            platform: "darwin",
            appVersion: "2.0",
            lastSeenAt: Date(),
            keyVersion: nil,
            capabilities: .init(models: [
                .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", provider: "Anthropic"),
            ])
        )
        let chat = RemoteSession(id: "chat-1", machineID: machine.id, mode: .chat, title: "Discussion", workspace: nil, modelID: nil, approvalMode: nil, status: "idle", messageCount: 2, updatedAt: Date(), agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false)
        let code = RemoteSession(id: "code-1", machineID: machine.id, mode: .code, title: "Projet", workspace: "/tmp", modelID: "gpt", approvalMode: "review", status: "idle", messageCount: 1, updatedAt: Date(), agentSystem: nil, phase: nil, isSilent: false, isInterrupted: false)
        return .init(connectionState: .paired, machines: [machine], sessions: [chat, code])
    }
}

private final class MockRemoteService: RemoteServicing, @unchecked Sendable {
    var creationError: RemoteServiceError?
    var creationHook: (@Sendable () async -> Void)?
    private(set) var creationCallCount = 0
    var sendResult: RemoteCommandResult?
    var sendHook: (@Sendable () async -> Void)?
    var sendError: RemoteServiceError?
    var sendCount = 0
    var overview = RemoteOverview(connectionState: .unpaired, machines: [], sessions: [])
    var overviewAfterPairing: RemoteOverview?
    var messages: [RemoteMessage] = []
    private(set) var loadedSessionID: String?
    private(set) var messageLoadCount = 0
    var messageReadHook: (@Sendable () async -> [RemoteMessage])?
    private(set) var pairingCode: String?
    var loadError: RemoteServiceError?
    var pairingResult = RemotePairingResult(succeeded: true)
    var pairingError: RemoteServiceError?
    var createdSessionID = "created-session"
    private(set) var creationRequest: RemoteSessionCreationRequest?
    private(set) var sentCommandType: RemoteCommandType?
    private(set) var sentPayload: RemoteJSONValue?
    private(set) var uploadedAttachment: RemoteAttachmentCandidate?
    var attachmentTransferID = "transfer-1"
    var folderListing = RemoteFolderListing(folders: [])
    var bridgeCheckCount = 0
    var folderLoadCount = 0
    var folderProbeError: RemoteServiceError?
    var folderProbeHook: (@Sendable () async throws -> RemoteFolderListing)?
    private(set) var loadCallCount = 0
    private(set) var pairingCallCount = 0
    var deviceState: RemoteDeviceAuthorizationState? = .init(version: 2, legacyProtected: false)
    var migrationError: RemoteSecurityServiceError?
    var migrationCalls = 0
    var authorizationCalls = 0
    var authorizationToken = RemoteUnlockToken(value: "fixture", expiresAt: .distantFuture)
    func deviceAuthorizationState() async throws -> RemoteDeviceAuthorizationState? {
        await securityStateHook?()
        if let securityStateError { throw securityStateError }
        return deviceState
    }
    func migrateDeviceAuthorization() async throws -> RemoteDeviceAuthorizationState {
        migrationCalls += 1
        if let migrationError { throw migrationError }
        deviceState = .init(version: 2, legacyProtected: false); return deviceState!
    }
    func authorizeDevice() async throws -> RemoteUnlockToken { authorizationCalls += 1; return authorizationToken }
    var unlockState = RemoteUnlockState(succeeded: true, hasPIN: false, isEnabled: false)
    var protectionPolicy: RemoteProtectionPolicy?
    var policyError: RemoteSecurityServiceError?
    var policySaveCount = 0
    var policySaveHook: (@Sendable () async -> Void)?
    var securityStateError: RemoteSecurityServiceError?
    var securityStateHook: (@Sendable () async -> Void)?
    var verifySecurityHook: (@Sendable () async -> Void)?
    private(set) var verifySecurityCallCount = 0
    var setPINResult = RemoteSecurityResult(succeeded: false, errorCode: "unavailable")
    var verifyPINResult = RemoteSecurityResult(succeeded: false, errorCode: "unavailable")
    var setEnabledResult = RemoteSecurityResult(succeeded: false, errorCode: "unavailable")
    private(set) var lastSetPIN: String?
    private(set) var lastVerifiedPIN: String?
    private(set) var lastEnabledValue: Bool?
    private(set) var deletedSessionIDs: [String] = []
    private(set) var pinnedUpdate: (sessionID: String, pinned: Bool)?
    private(set) var projectUpdate: (sessionID: String, projectID: String?)?
    private(set) var renameUpdate: (sessionID: String, title: String)?
    private(set) var archiveUpdate: (sessionID: String, archived: Bool)?

    func loadOverview() async throws -> RemoteOverview {
        loadCallCount += 1
        if let loadError { throw loadError }
        return overviewAfterPairing ?? overview
    }

    func loadMessages(sessionID: String, machineID: String) async throws -> [RemoteMessage] {
        loadedSessionID = sessionID; messageLoadCount += 1
        if let messageReadHook { return await messageReadHook() }
        return messages
    }

    func pairDevice(code: String, name: String) async throws -> RemotePairingResult {
        pairingCallCount += 1
        pairingCode = code
        if let pairingError { throw pairingError }
        return pairingResult
    }

    func sendCommand(machineID: String, sessionID: String, type: RemoteCommandType, payload: RemoteJSONValue) async throws -> RemoteCommandResult {
        sentCommandType = type
        sentPayload = payload
        sendCount += 1
        await sendHook?()
        if let sendError { throw sendError }
        return sendResult ?? .init(succeeded: true)
    }

    func createSession(_ request: RemoteSessionCreationRequest) async throws -> String {
        creationCallCount += 1
        await creationHook?()
        creationRequest = request
        if let creationError { throw creationError }
        return createdSessionID
    }

    func checkBridge(machineID: String) async throws {
        bridgeCheckCount += 1
        // Existing race fixtures simulate both probe and explicit folder commands.
        if let folderProbeHook { _ = try await folderProbeHook() }
        if let folderProbeError { throw folderProbeError }
    }

    func loadFolders(machineID: String, path: String?) async throws -> RemoteFolderListing {
        folderLoadCount += 1
        if let folderProbeHook { return try await folderProbeHook() }
        if let folderProbeError { throw folderProbeError }
        return folderListing
    }

    func deleteSessions(ids: [String]) async throws {
        deletedSessionIDs = ids
    }

    func setSessionPinned(_ pinned: Bool, sessionID: String) async throws {
        pinnedUpdate = (sessionID, pinned)
    }

    func setSessionProject(_ projectID: String?, sessionID: String) async throws {
        projectUpdate = (sessionID, projectID)
    }

    func renameSession(_ title: String, machineID: String, sessionID: String) async throws {
        renameUpdate = (sessionID, title)
    }

    func setSessionArchived(_ archived: Bool, machineID: String, sessionID: String) async throws {
        archiveUpdate = (sessionID, archived)
    }

    func remoteProtectionPolicy() async throws -> RemoteProtectionPolicy? {
        if let policyError { throw policyError }; return protectionPolicy
    }
    func setRemoteProtectionPolicy(_ modes: [RemoteMode], expectedRevision: Int) async throws -> RemoteProtectionPolicy {
        policySaveCount += 1
        await policySaveHook?()
        if let policyError { throw policyError }
        guard let previous = protectionPolicy, previous.revision == expectedRevision else { throw RemoteSecurityServiceError.server(code: "policy_conflict") }
        guard previous.unlockAuthorized else { throw RemoteSecurityServiceError.server(code: "unlock_required") }
        let updated = RemoteProtectionPolicy(revision: previous.revision + 1, protectedModes: modes, unlockAuthorized: true)
        protectionPolicy = updated; return updated
    }
    func remoteUnlockState() async throws -> RemoteUnlockState {
        await securityStateHook?()
        if let securityStateError { throw securityStateError }
        return unlockState
    }
    func setRemoteUnlockEnabled(_ enabled: Bool) async throws -> RemoteSecurityResult {
        lastEnabledValue = enabled
        return setEnabledResult
    }
    func setRemotePIN(_ pin: String) async throws -> RemoteSecurityResult {
        lastSetPIN = pin
        if setPINResult.succeeded { unlockState = .init(succeeded: true, hasPIN: true, isEnabled: unlockState.isEnabled) }
        return setPINResult
    }
    func verifyRemotePIN(_ pin: String) async throws -> RemoteSecurityResult {
        lastVerifiedPIN = pin
        verifySecurityCallCount += 1
        await verifySecurityHook?()
        return verifyPINResult
    }

    func requestDiff(machineID: String, sessionID: String) async throws -> RemoteDiffResult { .init(diff: "") }
    func runTerminalCommand(_ command: String, machineID: String, sessionID: String) async throws -> RemoteTerminalResult { .init(output: "") }
    func startPreview(script: String?, machineID: String, sessionID: String) async throws -> RemotePreviewResult { .init() }
    func stopPreview(machineID: String, sessionID: String) async throws {}
    func uploadAttachment(data: Data, name: String, mimeType: String, machineID: String, sessionID: String) async throws -> RemoteAttachmentReference {
        let candidate = RemoteAttachmentCandidate(name: name, size: data.count, mimeType: mimeType)
        uploadedAttachment = candidate
        return RemoteAttachmentRules.reference(transferID: attachmentTransferID, file: candidate)
    }
}

private final class MockBiometricSecretStore: BiometricSecretStoring, @unchecked Sendable {
    var storedPIN: String?
    var readError: BiometricSecretStoreError?
    private(set) var removeCallCount = 0

    func storeBiometricPIN(_ pin: String) throws { storedPIN = pin }

    func biometricPIN(reason: String) async throws -> String {
        if let readError { throw readError }
        guard let storedPIN else { throw BiometricSecretStoreError.unavailable }
        return storedPIN
    }

    func removeBiometricPIN() throws {
        removeCallCount += 1
        storedPIN = nil
    }
}

@MainActor private final class SecurityAccountValidity { var current = true }
private actor SecurityResponseLatch {
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        for continuation in startContinuations { continuation.resume() }
        startContinuations.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func started() async {
        if entered { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

private actor RemoteHealthFolderRace {
    private let failFirst: Bool
    init(failFirst: Bool = true) { self.failFirst = failFirst }
    private let latch = SecurityResponseLatch()
    private var calls = 0
    func load() async throws -> RemoteFolderListing {
        calls += 1
        if calls == 1 {
            await latch.wait()
            if failFirst { throw RemoteServiceError.commandFailure(.init(code: .bridgeUnresponsive, stage: .failed, diagnosticReference: "OLD-PROBE")) }
        }
        return .init(folders: [])
    }
    func started() async { await latch.started() }
    func release() async { await latch.release() }
}

final class AIMMediaPermissionBridgeTests: XCTestCase {
    @MainActor
    func testPermissionCallbackMayCompleteOnBackgroundQueue() async {
        let granted: Bool = await AIMMediaPermissionBridge.request { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                XCTAssertFalse(Thread.isMainThread)
                completion(true)
            }
        }
        XCTAssertTrue(granted)
        // The awaiting caller still resumes on its original actor.
        MainActor.assertIsolated()
    }

    @MainActor
    func testPermissionDenialAndSynchronousCompletionArePreserved() async {
        let granted: Bool = await AIMMediaPermissionBridge.request { $0(false) }
        XCTAssertFalse(granted)
    }
}
