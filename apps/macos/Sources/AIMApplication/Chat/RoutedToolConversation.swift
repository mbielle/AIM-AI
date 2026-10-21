import AIMCore
import Foundation

/// Route negotiation ends at the first admitted request. Checkpoints contain
/// the actual route, so restore never repeats initial negotiation.
public actor RoutedToolConversation: SteerableModelToolConversation, DurableModelConversation, StreamingToolConversation {
    private var streamHandler: (@Sendable (ToolStreamDelta) -> Void)?
    public func setStreamHandler(_ handler: (@Sendable (ToolStreamDelta) -> Void)?) async {
        streamHandler = handler; await inner.setStreamHandler(handler)
    }
    private let routes: [NativeChatRoute]
    private let factory: @Sendable (NativeChatRoute) throws -> ProviderToolConversation
    private let observe: @Sendable (ConversationRouteAttempt) async -> Void
    private var index = 0
    private var inner: ProviderToolConversation
    private var frozen = false
    private var attempts: [ConversationRouteAttempt] = []
    public func routingAttempts() -> [ConversationRouteAttempt] { attempts }
    private func record(_ value: ConversationRouteAttempt) async { attempts = ConversationRouteAttempt.merge(attempts, [value]) ?? []; await observe(value) }
    public init(routes: [NativeChatRoute], factory: @escaping @Sendable (NativeChatRoute) throws -> ProviderToolConversation,
                observe: @escaping @Sendable (ConversationRouteAttempt) async -> Void = { _ in }) throws {
        guard let first = routes.first else { throw ModelToolError.invalidConfiguration }
        guard routes.allSatisfy({ CanonicalModelRouting.identity($0.model.id, provider: $0.provider.rawValue) == CanonicalModelRouting.identity(first.model.id, provider: first.provider.rawValue) }) else { throw ModelToolError.invalidConfiguration }
        self.routes = routes; self.factory = factory; self.observe = observe; self.inner = try factory(first)
    }
    public func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn { try await next(outputs: outputs, userMessages: []) }
    public func next(outputs: [ModelToolOutput], userMessages: [String]) async throws -> ModelToolTurn {
        while true {
            try Task.checkCancellation()
            let route = routes[index]
            if !frozen { await record(.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .trying)) }
            do {
                let result = try await inner.next(outputs: outputs, userMessages: userMessages)
                if !frozen { await record(.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: .accepted)) }
                frozen = true; return result
            } catch {
                let accepted = await inner.admissionConfirmed
                let refused = CanonicalModelRouting.permitsFallback(error, admitted: accepted || frozen, emittedOutput: !outputs.isEmpty)
                await record(.init(provider: route.provider, modelID: route.model.id, ordinal: index, state: refused ? .rejected : .uncertain))
                guard refused, index + 1 < routes.count else { throw error }
                index += 1; inner = try factory(routes[index]); await inner.setStreamHandler(streamHandler)
            }
        }
    }
    public func currentRoute() -> (provider: AIMCore.ChatProvider, modelID: String) { (routes[index].provider, routes[index].model.id) }
    public func usageSoFar() async -> TokenUsage { await inner.usageSoFar() }
    public func exportCheckpoint() async throws -> ModelConversationCheckpoint { try await inner.exportCheckpoint() }
    public func restoreCheckpoint(_ checkpoint: ModelConversationCheckpoint) async throws {
        guard let index = routes.firstIndex(where: { $0.provider == checkpoint.provider && $0.model.id == checkpoint.modelID }) else { throw ExecutionStoreError.incompatibleCheckpoint }
        self.index = index; inner = try factory(routes[index]); await inner.setStreamHandler(streamHandler); try await inner.restoreCheckpoint(checkpoint); frozen = true
    }
}
