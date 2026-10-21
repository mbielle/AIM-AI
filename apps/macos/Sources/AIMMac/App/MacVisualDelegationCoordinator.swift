import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// A consent belongs to one draft, model, machine and identity epoch. Moving
/// away and back must not turn an old asynchronous result into new authority.
struct MacVisualDraftContext: Equatable, Sendable {
    let scope: String
    let navigation: UUID
    let draftRevision: UUID
    let ownerID: UUID
    let primaryProvider: ChatProvider
    let primaryModel: String
    let target: String
    let credentialScope: CredentialStorageScope.Snapshot
}

struct MacVisualApproval: Identifiable, Sendable {
    var id = UUID()
    let scope: String
    let navigation: UUID
    let draftRevision: UUID
    let ownerID: UUID
    let primaryProvider: ChatProvider
    let primaryModel: String
    let sources: [NativeChatAttachment]
    let conversationID: UUID
    let target: String
    let credentialScope: CredentialStorageScope.Snapshot
    var context: MacVisualDraftContext {
        .init(scope: scope, navigation: navigation, draftRevision: draftRevision, ownerID: ownerID, primaryProvider: primaryProvider,
              primaryModel: primaryModel, target: target, credentialScope: credentialScope)
    }
}

protocol MacVisualAnalysing: Sendable {
    func analyse(_ pending: MacVisualApproval, choice: SubagentModelChoice, model: ChatModel,
                 key: String, validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> VisualAnalysisReport
}

/// Catalog/key waits and consent persistence have one admission contract.
/// AppModel keeps its repositories, composer state and navigation private.
@MainActor
struct MacVisualDelegationCoordinator {
    let currentContext: () -> MacVisualDraftContext?
    let catalog: (ChatProvider) async throws -> [ChatModel]
    let credential: (ChatProvider) async throws -> String
    let recordConsent: (MacVisualApproval, SubagentModelChoice, Bool) throws -> Void
    let analyser: any MacVisualAnalysing

    func validate(_ pending: MacVisualApproval) throws {
        try Task.checkCancellation()
        guard currentContext() == pending.context else { throw CancellationError() }
    }

    func analyse(_ pending: MacVisualApproval, choice: SubagentModelChoice, remember: Bool) async throws -> VisualAnalysisReport {
        try validate(pending)
        let models = try await catalog(choice.provider)
        try validate(pending)
        guard let model = models.first(where: { $0.id == choice.modelID && $0.supportsImageInput == true }) else {
            throw NativeImageSnapshotError.unsupportedProvider
        }
        let key = choice.provider == .local ? "local" : try await credential(choice.provider)
        try validate(pending)
        guard !key.isEmpty else { throw ChatServiceError.missingKey }
        // No suspension between admission and persistence. An account/draft
        // change during either wait must not save consent into a new profile.
        try recordConsent(pending, choice, remember)
        let report = try await analyser.analyse(pending, choice: choice, model: model, key: key,
            validate: { try validate(pending) })
        try validate(pending)
        return report
    }
}

struct MeteredMacVisualAnalyser: MacVisualAnalysing {
    let meter: BillableRequestMeter
    func analyse(_ pending: MacVisualApproval, choice: SubagentModelChoice, model: ChatModel,
                 key: String, validate: @escaping @MainActor @Sendable () throws -> Void) async throws -> VisualAnalysisReport {
        try await VisualAnalysisService.analyse(pending.sources, choice: choice, model: model, key: key,
            streamFactory: { message, instructions in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            try await validate()
                            let images = try (message.attachments ?? []).flatMap(\.visualImages).map {
                                try ImageAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data ?? Data())
                            }
                            let input = ConversationMessage(id: message.id, conversationID: pending.conversationID,
                                role: .user, content: instructions + "\n\n" + message.text, sequence: 0, images: images)
                            for try await event in ProviderChatService(meter: meter).events(provider: choice.provider,
                                modelID: choice.modelID, messages: [input], apiKey: key, mode: .chat,
                                anthropicOutputTokens: model.maxOutputTokens ?? model.topProvider?.maxCompletionTokens,
                                useWebSearch: false, billingFeature: "visual_analysis") {
                                switch event {
                                case .text(let text): continuation.yield(.init(text: text))
                                case .metrics(let metrics): continuation.yield(.init(usage: metrics.usage, isComplete: true, sources: metrics.sources))
                                default: break
                                }
                            }
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }, checkBudget: { _ in try await validate() })
    }
}
