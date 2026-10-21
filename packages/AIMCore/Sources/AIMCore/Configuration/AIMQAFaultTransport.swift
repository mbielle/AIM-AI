#if DEBUG
import Foundation

public enum AIMQATransportFault: String, Sendable {
    case dropReplyOnce = "drop-reply-once"
    case delayRequest = "delay-request"
}

public actor AIMQAFaultState {
    private var dropped = false
    public init() {}
    func takeDrop() -> Bool {
        guard !dropped else { return false }
        dropped = true; return true
    }
}

/// Wraps the actual encrypted RPC session. A lost response happens *after* the
/// endpoint reply: no fabricated reply, extra retry, permission or command ID.
public struct AIMQAFaultTransport: DirectRemoteRPCTransport {
    private let base: any DirectRemoteRPCTransport
    private let fault: AIMQATransportFault?
    private let state: AIMQAFaultState
    private let delay: Duration
    private let trace: AIMQATraceRecorder?
    public init(base: any DirectRemoteRPCTransport, fault: AIMQATransportFault? = nil,
                delay: Duration = .milliseconds(350), state: AIMQAFaultState = AIMQAFaultState(), trace: AIMQATraceRecorder? = nil) {
        self.base = base; self.fault = fault; self.delay = delay; self.state = state; self.trace = trace
    }
    public var events: AsyncStream<RemoteEvent> { base.events }
    public func subscribeEvents() async -> AsyncStream<RemoteEvent> { await base.subscribeEvents() }
    public func connectionState() async -> DirectRemoteConnectionState { await base.connectionState() }
    public func request(operation: String, payload: RemoteJSONValue, id: UUID) async throws -> RemoteJSONValue {
        try Task.checkCancellation()
        if fault == .delayRequest { try await Task.sleep(for: delay) }
        await trace?.record(commandID: id, operation: operation, phase: "request")
        do {
            let result = try await base.request(operation: operation, payload: payload, id: id)
            if fault == .dropReplyOnce, operation == "command", await state.takeDrop() {
                await trace?.record(commandID: id, operation: operation, phase: "injected-lost-reply")
                throw DirectRemoteError.outcomeUnknown
            }
            await trace?.record(commandID: id, operation: operation, phase: "response")
            return result
        } catch {
            await trace?.record(commandID: id, operation: operation, phase: "error")
            throw error
        }
    }
}
#endif
