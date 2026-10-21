import Foundation

public struct ConversationRouteAttempt: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable { case trying, accepted, rejected, uncertain }
    public var provider: ChatProvider
    public var modelID: String
    public var ordinal: Int
    public var state: State
    public init(provider: ChatProvider, modelID: String, ordinal: Int, state: State) {
        self.provider = provider; self.modelID = modelID; self.ordinal = ordinal; self.state = state
    }
}
public extension ConversationRouteAttempt {
    static func merge(_ lhs: [Self]?, _ rhs: [Self]?) -> [Self]? {
        guard lhs != nil || rhs != nil else { return nil }
        var result = lhs ?? []
        for value in rhs ?? [] {
            if let index = result.firstIndex(where: { $0.ordinal == value.ordinal && $0.provider == value.provider && $0.modelID == value.modelID }) {
                if result[index].state == .trying || value.state != .trying { result[index] = value }
            } else { result.append(value) }
        }
        return result.sorted { $0.ordinal < $1.ordinal }
    }
}
public struct NativeChatRoute: Sendable {
    public var provider: ChatProvider
    public var model: ChatModel
    public var key: String
    public init(provider: ChatProvider, model: ChatModel, key: String) { self.provider = provider; self.model = model; self.key = key }
}

/// Only an HTTP refusal before acceptance allows a second route. Nothing in this
/// executor retries a request whose admission or result is uncertain.
public enum RoutedChatTransport {
    public static func stream(routes: [NativeChatRoute],
        makeStream: @escaping @Sendable (NativeChatRoute) -> AsyncThrowingStream<NativeChatEvent, Error>) -> AsyncThrowingStream<NativeChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var seen = Set<String>()
                let identity = routes.first.map { CanonicalModelRouting.identity($0.model.id, provider: $0.provider.rawValue) }
                var lastError: Error = ChatServiceError.invalidResponse
                for (ordinal, route) in routes.enumerated() {
                    guard CanonicalModelRouting.identity(route.model.id, provider: route.provider.rawValue) == identity,
                          route.provider != .local || ordinal == 0,
                          seen.insert(route.provider.rawValue + ":" + route.model.id).inserted else { continue }
                    do { try Task.checkCancellation() } catch { continuation.finish(throwing: error); return }
                    var admitted = false, output = false
                    continuation.yield(.init(routeAttempt: .init(provider: route.provider, modelID: route.model.id, ordinal: ordinal, state: .trying)))
                    do {
                        for try await event in makeStream(route) {
                            admitted = admitted || event.requestAccepted == true || event.usage != nil || event.skillActivities != nil || event.webSearchActivities != nil
                            output = output || !event.text.isEmpty
                            if event.requestAccepted == true {
                                continuation.yield(.init(routeAttempt: .init(provider: route.provider, modelID: route.model.id, ordinal: ordinal, state: .accepted)))
                            }
                            continuation.yield(event)
                        }
                        continuation.finish(); return
                    } catch {
                        lastError = error
                        let safe = CanonicalModelRouting.permitsFallback(error, admitted: admitted, emittedOutput: output)
                        continuation.yield(.init(routeAttempt: .init(provider: route.provider, modelID: route.model.id, ordinal: ordinal, state: safe ? .rejected : .uncertain)))
                        guard safe else { continuation.finish(throwing: error); return }
                    }
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
