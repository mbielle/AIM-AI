#if DEBUG
import AIMAgentKit
import Foundation

/// A model-boundary replacement for isolated debug qualification. It neither
/// replaces the Remote endpoint nor performs network requests or tool effects.
struct DeterministicQualificationProvider: NativeAgentTurnRunning {
    let marker: String
    func run(_ request: AgentRequest) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(conversationID: request.conversationID, text: marker))
            continuation.yield(.completed(conversationID: request.conversationID))
            continuation.finish()
        }
    }
    func cancel(conversationID: UUID) async {}
}
#endif
