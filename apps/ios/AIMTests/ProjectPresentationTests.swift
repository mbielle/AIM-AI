import AIMCore
import SwiftUI
import Foundation
import XCTest
@testable import AIM

final class ProjectPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecentDatesUseNowInsteadOfASecondsCountdown() {
        for locale in ["en_US", "fr_FR"] {
            let recent = label(age: 0, locale: locale)
            XCTAssertEqual(label(age: 29, locale: locale), recent)
            XCTAssertEqual(label(age: 59, locale: locale), recent)
        }
        XCTAssertEqual(label(age: 59), "now")
        XCTAssertEqual(label(age: 59, locale: "fr_FR"), "maintenant")
    }

    func testMinuteBoundariesNeverRoundBackIntoSeconds() {
        XCTAssertEqual(label(age: 60), "1 min. ago")
        XCTAssertEqual(label(age: 119), label(age: 60))
        XCTAssertEqual(label(age: 125), "2 min. ago")
        XCTAssertEqual(label(age: 3_599), "59 min. ago")
        XCTAssertEqual(label(age: 3_600), "1 hr. ago")
    }

    func testOlderDatesUseOnlyOneHourOrDayUnit() {
        XCTAssertEqual(label(age: 7_259), "2 hr. ago")
        XCTAssertEqual(label(age: 86_399), "23 hr. ago")
        XCTAssertEqual(label(age: 86_400), "1 day ago")
        XCTAssertEqual(label(age: 172_859), "2 days ago")
    }

    func testFrenchUnitsAndRelativeDirectionAreLocalized() {
        XCTAssertEqual(normalized(label(age: 125, locale: "fr_FR")), "il y a 2 min")
        XCTAssertEqual(normalized(label(age: 7_259, locale: "fr_FR")), "il y a 2 h")
        XCTAssertEqual(normalized(label(age: 172_859, locale: "fr_FR")), "il y a 2 j")
        XCTAssertEqual(normalized(label(age: -125, locale: "fr_FR")), "dans 2 min")
        XCTAssertEqual(label(age: -125), "in 2 min.")
    }

    func testConversationPreviewCollapsesParagraphsAndUnicodeWhitespace() {
        let original = "  test 45\n\nLa suite\tde la réponse\r\nreste\u{00A0}lisible.  "
        XCTAssertEqual(AIMProjectChatPreview.text(original), "test 45 La suite de la réponse reste lisible.")
        XCTAssertTrue(original.contains("\n\n"), "Presentation must preserve stored paragraphs")
        XCTAssertEqual(AIMProjectChatPreview.text(" \n\t\r\n"), "")
    }

    func testConversationPreviewNormalizesBeforeApplyingItsDisplayLimit() {
        let original = "test 45" + String(repeating: "\n", count: 200) + "La suite de la réponse."
        XCTAssertEqual(AIMProjectChatPreview.text(original), "test 45 La suite de la réponse.")
        let long = String(repeating: "👨‍👩‍👧‍👦", count: 220)
        let preview = AIMProjectChatPreview.text(long)
        XCTAssertEqual(preview.count, 180)
        XCTAssertEqual(preview, String(long.prefix(180)), "Do not split visible characters")
        XCTAssertEqual(long.count, 220)
    }

    func testConversationPreviewRemovesMarkdownSyntaxButPreservesVisibleContent() {
        let source = "# Résultat\n\ntest 45 **Test.txt** : **LOUTRE-7426**\n\n[Mozilla](https://mozilla.org) et `a*b`\n\n- Premier\n- *Second*"
        XCTAssertEqual(AIMProjectChatPreview.text(source), "Résultat test 45 Test.txt : LOUTRE-7426 Mozilla et a*b Premier Second")
        XCTAssertTrue(source.contains("**Test.txt**"), "Stored message must remain untouched")
    }

    func testConversationPreviewPreservesCodeAndEscapedMarkers() {
        XCTAssertEqual(AIMProjectChatPreview.text("\\*littéral\\* et `some_file.txt`"), "*littéral* et some_file.txt")
        XCTAssertEqual(AIMProjectChatPreview.text("```swift\nlet value = a * b\n```"), "let value = a * b")
    }

    private func label(age: TimeInterval, locale: String = "en_US") -> String {
        AIMProjectRelativeDate.string(for: now.addingTimeInterval(-age), relativeTo: now, locale: Locale(identifier: locale))
    }
    private func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }
}


private final class ProjectPresentationSecrets: SecureStoring, @unchecked Sendable {
    func store(_ data: Data, forKey key: String) throws {}
    func readData(forKey key: String) throws -> Data? { nil }
    func removeData(forKey key: String) throws {}
}

extension ProjectPresentationTests {
    @MainActor
    func testPassiveProjectPreviewCannotPresentOrDismissLiveApproval() {
        let owner = UUID(), secrets = ProjectPresentationSecrets()
        defer { try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Chat/\(owner.uuidString)")) }
        let chat = NativeChatStore(accountID: owner, credentials: secrets)
        let remote = LocalRemoteService()
        let pending = NativeVisualApproval(conversationID: UUID(), projectID: UUID(), text: "Synthetic review",
            primaryProvider: .openRouter, primaryModel: "fixture", catalog: [], target: .thisDevice,
            selectConversation: false, attachments: [], sources: [])
        chat.pendingVisualApproval = pending
        var view = AIMNativeChatView(chat: chat, remote: MainExperienceStore(service: remote),
            delegations: RemoteDelegationService(accountID: owner, remote: remote, secureStore: secrets),
            safeTop: 0, safeBottom: 0, openMenu: {}, selectMode: { _ in }, openProviders: {}, openConnection: {}, selectComputer: { _, _ in })
        view.isNavigationPreview = true
        XCTAssertNil(view.visualApprovalPresentation.wrappedValue)
        view.visualApprovalPresentation.wrappedValue = nil
        XCTAssertEqual(chat.pendingVisualApproval?.id, pending.id)
        view.isNavigationPreview = false
        XCTAssertEqual(view.visualApprovalPresentation.wrappedValue?.id, pending.id)
        view.visualApprovalPresentation.wrappedValue = nil
        XCTAssertNil(chat.pendingVisualApproval)
    }
}

final class DirectConnectionLifecycleTests: XCTestCase {
    func testReconnectChoicePersistsPerProfileAndExplicitDisconnectSurvivesRelaunch() {
        let suite = "aim-direct-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstProfile = UUID(), secondProfile = UUID(), mac = UUID(), other = UUID()
        let first = AIMDirectReconnectPreference(profileID: firstProfile, defaults: defaults)
        XCTAssertEqual(first.candidate(available: [mac]), mac)
        XCTAssertNil(first.candidate(available: [mac, other]))
        first.select(other)
        XCTAssertEqual(AIMDirectReconnectPreference(profileID: firstProfile, defaults: defaults).candidate(available: [mac, other]), other)
        XCTAssertNil(first.candidate(available: [mac]), "A missing or revoked saved Mac must not select a different Mac")
        first.disable()
        XCTAssertNil(AIMDirectReconnectPreference(profileID: firstProfile, defaults: defaults).candidate(available: [mac]))
        XCTAssertEqual(AIMDirectReconnectPreference(profileID: secondProfile, defaults: defaults).candidate(available: [mac]), mac)
        first.select(mac)
        XCTAssertEqual(first.candidate(available: [mac, other]), mac)
        XCTAssertNil(first.candidate(available: []))
    }

    func testClosingCaptureInvalidatesQueuedStartsAndRepeatedViewUpdatesCoalesce() {
        let intent = AIMPairingCaptureIntent()
        XCTAssertFalse(intent.request(false))
        XCTAssertTrue(intent.request(true))
        for _ in 0..<100 { XCTAssertFalse(intent.request(true)) }
        XCTAssertTrue(intent.isActive)
        XCTAssertTrue(intent.request(false))
        XCTAssertFalse(intent.isActive)
        XCTAssertTrue(intent.request(true))
        intent.close()
        XCTAssertFalse(intent.isActive)
        XCTAssertFalse(intent.request(true), "A dismantled scanner cannot restart from a late view update")
        XCTAssertFalse(intent.request(false))
    }
}
