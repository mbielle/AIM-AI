@testable import AIMMac
import AIMCore
import AIMMacPlatform
import XCTest

@MainActor
final class MacVisualDelegationCoordinatorTests: XCTestCase {
    func testOnlyMatchingDraftOwnerModelTargetAndEpochCanBegin() async {
        for changedField in ["scope", "navigation", "draft", "owner", "provider", "model", "target", "epoch"] {
            let fixture = VisualConsentFixture()
            let pending = fixture.pending
            fixture.change(changedField)
            await assertCancelled { try await fixture.coordinator().analyse(pending, choice: fixture.choice, remember: true) }
            XCTAssertEqual(fixture.catalogReads, 0, changedField)
            XCTAssertEqual(fixture.credentialReads, 0, changedField)
            XCTAssertTrue(fixture.consents.isEmpty, changedField)
        }
    }

    func testModelChangedDuringCatalogWaitCannotReadCredentialsOrPersistConsent() async {
        let fixture = VisualConsentFixture(), pending = fixture.pending
        fixture.afterCatalogWait = { fixture.change("model") }
        await assertCancelled { try await fixture.coordinator().analyse(pending, choice: fixture.choice, remember: true) }
        XCTAssertEqual(fixture.credentialReads, 0)
        XCTAssertTrue(fixture.consents.isEmpty)
        XCTAssertEqual(fixture.analysisCalls, 0)
    }

    func testLeavingAndReturningToSameProfileDuringKeyWaitCannotPersistConsent() async {
        let fixture = VisualConsentFixture(), pending = fixture.pending
        fixture.afterCredentialWait = { fixture.change("epoch") }
        await assertCancelled { try await fixture.coordinator().analyse(pending, choice: fixture.choice, remember: true) }
        XCTAssertEqual(fixture.credentialReads, 1)
        XCTAssertTrue(fixture.consents.isEmpty)
        XCTAssertEqual(fixture.analysisCalls, 0)
    }

    func testPerRequestValidationRejectsNavigationChangeBeforeFurtherProviderAdmission() async {
        let fixture = VisualConsentFixture(), pending = fixture.pending
        fixture.duringAnalysis = { validate in
            try validate()
            fixture.change("navigation")
            try validate()
        }
        await assertCancelled { try await fixture.coordinator().analyse(pending, choice: fixture.choice, remember: false) }
        XCTAssertEqual(fixture.consents, [false])
        XCTAssertEqual(fixture.analysisCalls, 1)
    }

    func testLateReportAfterDraftEditCannotBeCommittedToCurrentDraft() async {
        let fixture = VisualConsentFixture(), pending = fixture.pending
        fixture.duringAnalysis = { _ in fixture.change("draft") }
        await assertCancelled { try await fixture.coordinator().analyse(pending, choice: fixture.choice, remember: false) }
        XCTAssertEqual(fixture.analysisCalls, 1)
    }

    func testSuccessfulAnalysisKeepsPrimaryModelAndExplicitRememberChoice() async throws {
        let fixture = VisualConsentFixture(), pending = fixture.pending
        let report = try await fixture.coordinator().analyse(pending, choice: fixture.choice, remember: true)
        XCTAssertEqual(report.choice, fixture.choice)
        XCTAssertEqual(report.text, "fixture observations")
        XCTAssertEqual(fixture.context, pending.context)
        XCTAssertEqual(fixture.consents, [true])
        XCTAssertEqual(fixture.analysisKeys, ["fixture-api-key"])
    }

    func testLocalAnalystDoesNotReadAProviderCredential() async throws {
        let fixture = VisualConsentFixture()
        let choice = SubagentModelChoice(provider: .local, modelID: fixture.choice.modelID)
        _ = try await fixture.coordinator().analyse(fixture.pending, choice: choice, remember: false)
        XCTAssertEqual(fixture.credentialReads, 0)
        XCTAssertEqual(fixture.analysisKeys, ["local"])
    }

    func testCancelledOperationCannotReadCatalogOrSaveConsent() async {
        let fixture = VisualConsentFixture()
        let task = Task { try await fixture.coordinator().analyse(fixture.pending, choice: fixture.choice, remember: true) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled consent must not begin") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(fixture.catalogReads, 0)
        XCTAssertTrue(fixture.consents.isEmpty)
    }

    private func assertCancelled(_ operation: () async throws -> VisualAnalysisReport) async {
        do { _ = try await operation(); XCTFail("Changed visual context must be rejected") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
    }
}

@MainActor
private final class VisualConsentFixture {
    let credentialScope: CredentialStorageScope
    var context: MacVisualDraftContext
    let choice = SubagentModelChoice(provider: .openRouter, modelID: "fixture-visual-analyst")
    var catalogReads = 0
    var credentialReads = 0
    var analysisCalls = 0
    var analysisKeys: [String] = []
    var consents: [Bool] = []
    var afterCatalogWait: (() -> Void)?
    var afterCredentialWait: (() -> Void)?
    var duringAnalysis: ((@MainActor @Sendable () throws -> Void) throws -> Void)?
    init() {
        let owner = UUID(), scope = CredentialStorageScope(ownerID: owner)
        credentialScope = scope
        context = .init(scope: "new:chat", navigation: UUID(), draftRevision: UUID(), ownerID: owner, primaryProvider: .anthropic,
                        primaryModel: "fixture-primary", target: "mac:fixture-machine", credentialScope: scope.snapshot())
    }
    var pending: MacVisualApproval {
        .init(scope: context.scope, navigation: context.navigation, draftRevision: context.draftRevision, ownerID: context.ownerID,
              primaryProvider: context.primaryProvider, primaryModel: context.primaryModel, sources: [],
              conversationID: UUID(), target: context.target, credentialScope: context.credentialScope)
    }
    func change(_ field: String) {
        let old = context
        if field == "epoch" { credentialScope.activate(UUID()); credentialScope.activate(old.ownerID) }
        context = .init(scope: field == "scope" ? "conversation:another" : old.scope,
            navigation: field == "navigation" ? UUID() : old.navigation,
            draftRevision: field == "draft" ? UUID() : old.draftRevision,
            ownerID: field == "owner" ? UUID() : old.ownerID,
            primaryProvider: field == "provider" ? .openAI : old.primaryProvider,
            primaryModel: field == "model" ? "other-primary" : old.primaryModel,
            target: field == "target" ? "mac:another-machine" : old.target,
            credentialScope: credentialScope.snapshot())
    }
    func coordinator() -> MacVisualDelegationCoordinator {
        .init(currentContext: { self.context }, catalog: { _ in
            self.catalogReads += 1
            await Task.yield(); self.afterCatalogWait?()
            return [.init(id: self.choice.modelID, name: "Fixture analyst", inputModalities: ["text", "image"])]
        }, credential: { _ in
            self.credentialReads += 1
            await Task.yield(); self.afterCredentialWait?()
            return "fixture-api-key"
        }, recordConsent: { _, choice, remember in
            XCTAssertEqual(choice.modelID, self.choice.modelID)
            self.consents.append(remember)
        }, analyser: FixtureVisualAnalyser(fixture: self))
    }
}

private struct FixtureVisualAnalyser: MacVisualAnalysing {
    let fixture: VisualConsentFixture
    @MainActor func analyse(_ pending: MacVisualApproval, choice: SubagentModelChoice, model: ChatModel,
                           key: String, validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> VisualAnalysisReport {
        fixture.analysisCalls += 1; fixture.analysisKeys.append(key)
        try fixture.duringAnalysis?(validate)
        return .init(sourceIDs: [], choice: choice, text: "fixture observations")
    }
}
