import AIMAgentKit
import AIMApplication
import AIMCore
import CryptoKit
import Foundation
import os

/// A pinned, user-configured subprocess. Only structured protocol frames have
/// meaning; free stdout cannot authorize a host tool or expand a request scope.
public struct ExternalEngineConfinement: Sendable {
    public let readRoots: [URL]
    public let writeRoots: [URL]
    public let privateHome: URL
    public init(readRoots: [URL], writeRoots: [URL], privateHome: URL) {
        self.readRoots = readRoots; self.writeRoots = writeRoots; self.privateHome = privateHome
    }
}
public actor StdioAgentEngine: AgentEngine {
    public nonisolated let id: AgentEngineID
    private let configuration: ExternalEngineConfiguration
    private let secureStore: any SecureStoring
    private let runner: MacProcessRunner
    private let approvalBroker: ToolApprovalBroker
    private let financeResolver: ExternalFinanceResolver?
    private let providerHandler: ExternalProviderHandler?
    private let confinement: ExternalEngineConfinement?
    private let toolHandler: ExternalToolHandler?
    private let toolSchemas: Data?
    private let activityHandler: ExternalActivityHandler?
    private var providerRequests: Set<UUID> = []
    private var approvalTasks: [String: Task<Void, Never>] = [:]
    private let processID = UUID()
    private var nonce = UUID()
    private var processTask: Task<Void, Never>?
    private var currentStatus = EngineStatus(id: .externalStdio, state: .stopped, isInstalled: false)
    private var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private struct Run: Sendable { var request: AgentRequest; var sequence = 0; var finance: ExternalFinanceSession? }
    private var runs: [UUID: Run] = [:]
    private struct Approval: Sendable { let runID: UUID; let frame: ExternalEngineApproval; let publicID: String }
    private var approvals: [String: Approval] = [:]
    private var stdoutCount = 0
    private var buffer = Data()
    private var handshakeComplete = false
    private var writingFrame = false
    public init(configuration: ExternalEngineConfiguration, secureStore: any SecureStoring,
        approvals: ToolApprovalBroker = ToolApprovalBroker(), runner: MacProcessRunner = MacProcessRunner(),
        financeResolver: ExternalFinanceResolver? = nil, providerHandler: ExternalProviderHandler? = nil,
        confinement: ExternalEngineConfinement? = nil, toolHandler: ExternalToolHandler? = nil, toolSchemas: Data? = nil,
        activityHandler: ExternalActivityHandler? = nil, engineID: AgentEngineID = .externalStdio) {
        self.toolHandler = toolHandler; self.toolSchemas = toolSchemas; self.activityHandler = activityHandler
        self.id = engineID; self.providerHandler = providerHandler; self.confinement = confinement
        self.configuration = configuration; self.secureStore = secureStore; self.runner = runner; self.approvalBroker = approvals
        self.financeResolver = financeResolver
        self.currentStatus = EngineStatus(id: engineID, state: .stopped,
            isInstalled: configuration.enabled && FileManager.default.isExecutableFile(atPath: configuration.executable.path),
            version: configuration.engineVersion, runtimeVersion: "aim-stdio-v\(configuration.version)")
    }
    public func status() -> EngineStatus { currentStatus }
    public func diagnose() -> EngineDiagnostic? { currentStatus.diagnostic }
    public func install() async throws {
        throw EngineError.invalidRuntime("Install through EngineRuntimeManager using a pinned manifest, then configure this adapter explicitly.")
    }
    private func validate() throws {
        guard [1, 2].contains(configuration.version), configuration.enabled, !configuration.identity.isEmpty, !configuration.engineVersion.isEmpty,
              configuration.executable.isFileURL, configuration.executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configuration.executable.path),
              configuration.executableSHA256.count == 64,
              configuration.executableSHA256.allSatisfy(\.isHexDigit),
              !configuration.allowExternalEffects || configuration.isolationReceipt?.isEmpty == false else {
            throw EngineError.invalidRuntime("The external adapter configuration, pinned executable or isolation receipt is missing.")
        }
        guard configuration.version == 1 ? configuration.financeProtocolVersion == nil : configuration.financeProtocolVersion == 1 else {
            throw EngineError.invalidRuntime("The external adapter finance protocol version is unsupported.")
        }
        if configuration.version == 2, configuration.allowModelCalls, financeResolver == nil {
            throw EngineError.invalidRuntime("AIM stdio v2 model execution has no host-admitted finance resolver. An opaque external engine cannot own a durable native mission implicitly.")
        }
        if configuration.version == 2 {
            guard confinement != nil, configuration.secretEnvironmentKeys.isEmpty else {
                throw EngineError.invalidRuntime("AIM stdio v2 requires native OS confinement and forbids subprocess credentials.")
            }
        }
        let handle = try FileHandle(forReadingFrom: configuration.executable)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { digest.update(data: data) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == configuration.executableSHA256.lowercased() else {
            throw EngineError.invalidRuntime("The external adapter executable differs from its pinned identity.")
        }
    }
    public func start() async throws {
        if handshakeComplete { return }
        if currentStatus.state == .error { await processTask?.value; processTask = nil }
        guard processTask == nil else { throw EngineError.invalidRuntime("The external adapter handshake is already pending.") }
        try validate()
        // A third-party program cannot be attested local solely from its stdout.
        try RuntimePrivacyPolicy.requireNetwork()
        var environment = configuration.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        for (name, key) in configuration.secretEnvironmentKeys {
            guard !name.isEmpty, !name.contains("="), !name.contains("\0"),
                  let data = try secureStore.readData(forKey: key), let value = String(data: data, encoding: .utf8) else {
                throw EngineError.invalidRuntime("A configured external adapter credential is unavailable.")
            }
            environment[name] = value
        }
        currentStatus = EngineStatus(id: id, state: .starting, isInstalled: true, version: configuration.engineVersion, runtimeVersion: "aim-stdio-v\(configuration.version)")
        publish(.state(currentStatus))
        nonce = UUID(); handshakeComplete = false; stdoutCount = 0; buffer = Data()
        let command = ProcessCommand(executable: configuration.executable, arguments: configuration.arguments,
            environment: environment, inheritsEnvironment: false, acceptsStandardInput: true)
        let stream: AsyncThrowingStream<ProcessStreamEvent, Error>
        if let confinement {
            let confined = try OSProcessConfinement.prepare(command, readRoots: confinement.readRoots,
                writeRoots: confinement.writeRoots, privateHome: confinement.privateHome, network: .deny)
            stream = runner.streamConfined(confined, id: processID)
        } else { stream = runner.stream(command, id: processID) }
        processTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .output(let snapshot): try await self?.read(snapshot)
                    case .completed(let result):
                        try await self?.read(ProcessOutputSnapshot(stdout: result.stdout, stderr: result.stderr, wasTruncated: result.wasTruncated))
                        await self?.ended(code: "external.process.exit")
                    }
                }
            } catch {
                Logger(subsystem: "com.aimai.agent", category: "external-engine").error("External adapter protocol error: \(String(describing: error), privacy: .public)")
                await self?.ended(code: "external.protocol.failed")
            }
        }
        var hello = ExternalEngineFrame(kind: "hello", nonce: nonce, identity: configuration.identity)
        hello.engineVersion = configuration.engineVersion; hello.readOnly = !configuration.allowExternalEffects
        hello.financeProtocolVersion = configuration.financeProtocolVersion
        hello.providerProtocolVersion = providerHandler == nil ? nil : 1
        do { try await write(hello) }
        catch { await stop(); throw error }
        do {
            for _ in 0..<100 {
                try Task.checkCancellation()
                if handshakeComplete { return }
                if currentStatus.state == .error { throw EngineError.invalidRuntime(currentStatus.diagnostic?.message ?? "External adapter failed.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw EngineError.invalidRuntime("The external adapter did not confirm the pinned protocol/identity/version.")
        } catch {
            await stop()
            throw error
        }
    }
    public func stop() async {
        currentStatus.state = .stopping; publish(.state(currentStatus))
        approvals.removeAll()
        for task in approvalTasks.values { task.cancel() }
        approvalTasks.removeAll()
        processTask?.cancel()
        await runner.terminateAll()
        await processTask?.value; processTask = nil
        for task in approvalTasks.values { task.cancel() }
        approvalTasks.removeAll()
        let diagnostic = EngineDiagnostic(code: "external.stopped", message: "The external adapter stopped; any remaining turn requires explicit review before retry.", isRecoverable: true)
        let stoppedRuns = runs; runs.removeAll(); approvals.removeAll(); handshakeComplete = false
        for run in stoppedRuns.values {
            do { try await run.finance?.close() }
            catch { currentStatus.diagnostic = EngineDiagnostic(code: "external.finance.unresolved", message: "The external run stopped with an unresolved native billing receipt; no request may be retried automatically.", isRecoverable: true) }
            publish(.failed(conversationID: run.request.conversationID, diagnostic: currentStatus.diagnostic ?? diagnostic))
        }
        currentStatus.state = .stopped; publish(.state(currentStatus))
    }
    public func send(_ request: AgentRequest) async throws {
        guard configuration.allowModelCalls else { throw EngineError.invalidRuntime("Model execution through this adapter has not been explicitly enabled.") }
        guard configuration.version == 2, configuration.financeProtocolVersion == 1,
              configuration.isolationReceipt?.isEmpty == false, let financeResolver else {
            throw EngineError.invalidRuntime("Paid or durable external turns require AIM stdio v2, a verified host execution binding and finance v1. Legacy v1 and an operator opt-in cannot admit a model request.")
        }
        try RuntimePrivacyPolicy.requireNetwork()
        if !handshakeComplete { try await start() }
        guard !runs.values.contains(where: { $0.request.conversationID == request.conversationID }) else { throw EngineError.conversationAlreadyRunning }
        var scoped = request
        if !configuration.allowExternalEffects && providerHandler == nil {
            scoped.workspaceEditsEnabled = false; scoped.workspaceCommandsEnabled = false
            scoped.workspacePlanOnly = true; scoped.approvalPolicy = .alwaysAsk
        }
        // Host-side authority fields stay immutable for this run.
        await approvalBroker.reopen(sessionID: scoped.conversationID)
        let runID = UUID(); runs[runID] = Run(request: scoped)
        do {
            let finance = try await financeResolver(scoped, runID, configuration)
            guard finance.grant.runID == runID, finance.grant.conversationID == scoped.conversationID,
                  finance.grant.engineIdentity == configuration.identity, finance.grant.engineVersion == configuration.engineVersion,
                  finance.grant.executableSHA256 == configuration.executableSHA256.lowercased(),
                  finance.grant.provider == scoped.provider?.rawValue, finance.grant.modelID == scoped.modelID,
                  runs[runID] != nil, handshakeComplete else {
                try await finance.close(); throw EngineError.invalidRuntime("The host finance binding no longer matches this external run.")
            }
            runs[runID]?.finance = finance
            var frame = ExternalEngineFrame(kind: "run", nonce: nonce, identity: configuration.identity, id: runID)
            frame.toolSchemas = toolSchemas
            frame.request = scoped; frame.conversationID = scoped.conversationID; frame.readOnly = !configuration.allowExternalEffects
            frame.financeProtocolVersion = 1; frame.financeGrant = finance.grant
            try RuntimePrivacyPolicy.requireNetwork()
            try await write(frame)
        } catch {
            // No partial run or lost admission ACK may cause an automatic resend.
            if let run = runs.removeValue(forKey: runID) { try? await run.finance?.close() }
            await stop()
            throw error
        }
    }
    public func cancel(conversationID: UUID) async {
        guard let entry = runs.first(where: { $0.value.request.conversationID == conversationID }) else { return }
        var frame = ExternalEngineFrame(kind: "cancel", nonce: nonce, identity: configuration.identity, id: entry.key)
        frame.conversationID = conversationID
        try? await write(frame)
        // No canceled event may restore this run's authority. Stop the subprocess
        // if it does not end promptly; cancellation is never a model suggestion.
        if let run = runs.removeValue(forKey: entry.key) {
            do { try await run.finance?.close() }
            catch {
                currentStatus.diagnostic = EngineDiagnostic(code: "external.finance.unresolved", message: "Cancellation retained unresolved native billing receipts; no model request may be retried automatically.", isRecoverable: true)
                publish(.failed(conversationID: conversationID, diagnostic: currentStatus.diagnostic!))
            }
        }
        approvals = approvals.filter { $0.value.runID != entry.key }
        await stop()
    }
    public func decide(approvalID: String, decision: ApprovalDecision) async {
        let parts = approvalID.split(separator: "/")
        guard parts.count == 2, let session = UUID(uuidString: String(parts[0])), let approval = UUID(uuidString: String(parts[1])) else { return }
        await approvalBroker.decide(id: approval, sessionID: session, decision: decision == .deny ? .deny : .allowOnce)
    }
    private func answer(_ key: String, approved: Bool) async {
        approvalTasks.removeValue(forKey: key)
        guard let approval = approvals.removeValue(forKey: key), runs[approval.runID] != nil else { return }
        var frame = ExternalEngineFrame(kind: "approval_decision", nonce: nonce, identity: configuration.identity, id: approval.runID)
        frame.approval = approval.frame
        frame.decision = approved && !RuntimePrivacyPolicy.isEnabled ? .allowOnce : .deny
        do { try await write(frame) } catch { await stop() }
    }
    public func events() -> AsyncStream<EngineEvent> {
        let token = UUID()
        return AsyncStream { continuation in
            subscribers[token] = continuation; continuation.yield(.state(currentStatus))
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(token) } }
        }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func publish(_ event: EngineEvent) { for continuation in subscribers.values { continuation.yield(event) } }
    private func write(_ frame: ExternalEngineFrame) async throws {
        var frame = frame; frame.version = configuration.version
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(frame); data.append(10)
        guard data.count <= 1_048_576 else { throw EngineError.invalidRuntime("The external adapter frame exceeds its bound.") }
        // Requests now run side by side (an engine's sub-agents): frames are written one at a time.
        while writingFrame { try Task.checkCancellation(); await Task.yield() }
        writingFrame = true; defer { writingFrame = false }
        var start = 0
        while start < data.count {
            var end = min(start + 16_384, data.count)
            while end < data.count, end > start, data[end] & 0xc0 == 0x80 { end -= 1 }
            guard end > start else { throw EngineError.invalidRuntime("Invalid UTF-8 adapter frame boundary.") }
            let part = data.subdata(in: start..<end)
            let accepted = try await runner.send(String(decoding: part, as: UTF8.self), to: processID)
            guard accepted == part.count else { throw EngineError.invalidRuntime("The adapter input was only partially accepted; the frame must not be replayed.") }
            start = end
        }
    }
    private static let log = Logger(subsystem: "com.aimai.agent", category: "external-engine")
    /// The provider frames of one streamed answer, numbered in order.
    private actor StreamSequence {
        private var index = 0
        private(set) var streamedBytes = 0
        func next(bytes: Int) -> Int { defer { index += 1 }; streamedBytes += bytes; return index }
    }
    fileprivate var isConnected: Bool { handshakeComplete }
    fileprivate func ownsFinance(_ run: UUID, _ grant: UUID) -> Bool { runs[run]?.finance?.grant.id == grant }
    /// Calls run side by side; a failure ends the adapter as an unordered frame would.
    private func concurrent(_ work: @escaping @Sendable (StdioAgentEngine) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do { try await work(self) }
            catch {
                Self.log.error("External adapter call failed: \(String(describing: error), privacy: .public)")
                await self.ended(code: "external.protocol.failed")
            }
        }
    }
    /// The end of the adapter's own log, kept for diagnosis (never protocol or authority).
    private var stderrTail = ""
    private func read(_ snapshot: ProcessOutputSnapshot) async throws {
        if !snapshot.stderr.isEmpty { stderrTail = String(snapshot.stderr.suffix(4_000)) }
        guard !snapshot.wasTruncated else { throw EngineError.invalidRuntime("The adapter exceeded its bounded protocol output; frames cannot be recovered safely.") }
        let data = Data(snapshot.stdout.utf8)
        // Process snapshots decode UTF-8 for presentation. Only commit through a
        // newline; a trailing multi-byte character may be incomplete in a snapshot.
        guard let newline = data.lastIndex(of: 10) else {
            guard data.count <= 1_048_576 else { throw EngineError.invalidRuntime("The adapter protocol frame is too large.") }
            return
        }
        let completeCount = data.distance(from: data.startIndex, to: newline) + 1
        guard completeCount >= stdoutCount else { throw EngineError.invalidRuntime("The adapter output offset regressed.") }
        buffer.append(data.prefix(completeCount).dropFirst(stdoutCount)); stdoutCount = completeCount
        guard buffer.count <= 1_048_576 else { throw EngineError.invalidRuntime("The adapter protocol frame is too large.") }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            let frame = try JSONDecoder().decode(ExternalEngineFrame.self, from: line)
            try await receive(frame)
        }
    }
    private func receive(_ frame: ExternalEngineFrame) async throws {
        guard frame.version == configuration.version, frame.nonce == nonce, frame.identity == configuration.identity else {
            throw EngineError.invalidRuntime("The external adapter frame identity or protocol does not match.")
        }
        if frame.kind == "hello_ack" {
            guard !handshakeComplete, frame.engineVersion == configuration.engineVersion,
                  frame.readOnly == !configuration.allowExternalEffects,
                  frame.financeProtocolVersion == configuration.financeProtocolVersion,
                  frame.providerProtocolVersion == (providerHandler == nil ? nil : 1),
                  frame.providerRequest == nil, frame.providerChunk == nil,
                  frame.financeGrant == nil, frame.financeRequest == nil, frame.financeResponse == nil else { throw EngineError.invalidRuntime("External adapter handshake mismatch.") }
            handshakeComplete = true; currentStatus.state = .ready; publish(.state(currentStatus)); return
        }
        guard handshakeComplete, let id = frame.id, var run = runs[id], frame.conversationID == run.request.conversationID,
              let sequence = frame.sequence, sequence == run.sequence + 1 else { throw EngineError.invalidRuntime("Unknown, stale or reordered external run frame.") }
        run.sequence = sequence; runs[id] = run
        if frame.kind == "tool_request" {
            guard let call = frame.toolCall, let toolHandler, let finance = run.finance,
                  UUID(uuidString: call.id) != nil, frame.providerRequest == nil, frame.origin.map({ $0.utf8.count <= 256 }) ?? true,
                  frame.financeRequest == nil, frame.financeGrant == nil else { throw EngineError.invalidRuntime("No native upstream tool binding.") }
            let context = ExternalCallContext(origin: frame.origin), nonce = self.nonce, request = run.request
            // Runs beside other calls (an engine's sub-agents work in parallel); the reply is keyed by call ID.
            concurrent { engine in
                let data = try await toolHandler(call, request, finance.grant, context)
                guard data.count <= 2_097_152, await engine.ownsFinance(id, finance.grant.id) else { throw EngineError.invalidRuntime("Tool result owner was revoked.") }
                let count = max(1, (data.count + 8191) / 8192)
                for index in 0..<count {
                    let start = min(index * 8192, data.count), end = min((index + 1) * 8192, data.count)
                    var answer = ExternalEngineFrame(kind: "tool_response", nonce: nonce, identity: engine.configuration.identity, id: id)
                    answer.conversationID = request.conversationID
                    answer.providerChunk = ExternalProviderChunk(requestID: UUID(uuidString: call.id)!, index: index,
                        final: index == count - 1, status: 200, contentType: "application/json", bytes: data.subdata(in: start..<end))
                    try await engine.write(answer)
                }
            }
            return
        }
        guard frame.toolCall == nil, frame.toolSchemas == nil else { throw EngineError.invalidRuntime("An upstream event cannot advertise host tools.") }
        if frame.kind == "provider_request" {
            guard configuration.version == 2, frame.providerProtocolVersion == 1,
                  let request = frame.providerRequest, let finance = run.finance,
                  request.grantID == finance.grant.id, let providerHandler,
                  frame.financeRequest == nil, frame.financeGrant == nil, frame.financeResponse == nil,
                  request.body.count <= 524_288, request.version == 1,
                  SHA256.hash(data: request.body).map({ String(format: "%02x", $0) }).joined() == request.sha256,
                  providerRequests.insert(request.requestID).inserted else {
                throw EngineError.invalidRuntime("Unknown or repeated upstream provider attempt; it cannot be resent automatically.")
            }
            let nonce = self.nonce, conversation = run.request.conversationID, origin = frame.origin, agentRequest = run.request
            guard origin.map({ $0.utf8.count <= 256 }) ?? true else { throw EngineError.invalidRuntime("Invalid upstream request origin.") }
            concurrent { engine in
                // The answer reaches the engine while the model writes it (true streaming); the last
                // frame closes it. A body sent at once keeps the previous chunking.
                let sequence = StreamSequence()
                let identity = engine.configuration.identity
                @Sendable func frame(_ index: Int, final: Bool, status: Int, contentType: String, bytes: Data) -> ExternalEngineFrame {
                    var answer = ExternalEngineFrame(kind: "provider_response", nonce: nonce, identity: identity, id: id)
                    answer.conversationID = conversation; answer.providerProtocolVersion = 1
                    answer.providerChunk = ExternalProviderChunk(requestID: request.requestID, index: index,
                        final: final, status: status, contentType: contentType, bytes: bytes)
                    return answer
                }
                let sink: ExternalProviderStreamSink = { status, contentType, bytes in
                    var start = 0
                    while start < bytes.count {
                        let end = min(start + 8192, bytes.count)
                        try await engine.write(frame(await sequence.next(bytes: end - start), final: false, status: status,
                                                     contentType: contentType, bytes: bytes.subdata(in: start..<end)))
                        start = end
                    }
                }
                let response = try await providerHandler(request, agentRequest, finance.grant, ExternalCallContext(origin: origin, stream: sink))
                guard await engine.ownsFinance(id, finance.grant.id), await engine.isConnected,
                      response.body.count <= 33_554_432 else { throw EngineError.invalidRuntime("The provider response has no current external owner or exceeds its bound.") }
                try RuntimePrivacyPolicy.requireNetwork()
                if await sequence.streamedBytes > 0 {
                    try await engine.write(frame(await sequence.next(bytes: 0), final: true, status: response.status,
                                                 contentType: response.contentType, bytes: Data()))
                    return
                }
                let count = max(1, (response.body.count + 8191) / 8192)
                for index in 0..<count {
                    let start = min(index * 8192, response.body.count), end = min((index + 1) * 8192, response.body.count)
                    try await engine.write(frame(index, final: index == count - 1, status: response.status,
                                                 contentType: response.contentType, bytes: response.body.subdata(in: start..<end)))
                }
            }
            return
        }
        guard frame.providerRequest == nil, frame.providerChunk == nil else { throw EngineError.invalidRuntime("Unexpected upstream transport data.") }
        if frame.kind == "finance_request" {
            guard providerHandler == nil else { throw EngineError.invalidRuntime("The confined upstream bridge cannot issue billing actions; its native provider dispatcher owns admission and send.") }
            guard configuration.version == 2, frame.financeProtocolVersion == 1, let request = frame.financeRequest,
                  frame.financeGrant == nil, frame.financeResponse == nil, let finance = run.finance else {
                throw EngineError.invalidRuntime("The external adapter has no host-admitted financial scope.")
            }
            let response = try await finance.handle(request)
            guard runs[id]?.finance?.grant.id == finance.grant.id, handshakeComplete, frame.nonce == nonce else {
                throw EngineError.invalidRuntime("The external finance run was revoked before acknowledgment.")
            }
            if request.action == .admit || request.action == .sent { try RuntimePrivacyPolicy.requireNetwork() }
            var answer = ExternalEngineFrame(kind: "finance_response", nonce: nonce, identity: configuration.identity, id: id)
            answer.conversationID = run.request.conversationID; answer.financeProtocolVersion = 1; answer.financeResponse = response
            try await write(answer)
            return
        }
        guard frame.financeGrant == nil, frame.financeRequest == nil, frame.financeResponse == nil else {
            throw EngineError.invalidRuntime("An external event cannot supply financial authority.")
        }
        if frame.kind == "approval", let approval = frame.approval {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let canonical = try encoder.encode(["action": RemoteJSONValue.string(approval.action),
                "arguments": .object(approval.arguments.mapValues(RemoteJSONValue.string))])
            let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            guard approval.digest == digest, !approval.id.isEmpty, approval.id.utf8.count <= 200 else {
                throw EngineError.invalidRuntime("External approval arguments do not match their digest.")
            }
            let publicID = "external:" + id.uuidString + ":" + approval.id
            guard approvals[publicID] == nil else { throw EngineError.invalidRuntime("Duplicate external approval.") }
            approvals[publicID] = Approval(runID: id, frame: approval, publicID: publicID)
            let permitted = configuration.allowExternalEffects && run.request.workspacePlanOnly != true
                && configuration.allowedApprovalActions.contains(approval.action)
                && (run.request.allowedToolNames == nil || run.request.allowedToolNames!.contains(approval.action))
                && (!["run_command", "start_command"].contains(approval.action) || run.request.workspaceCommandsEnabled == true)
                && (!["write_file", "edit_file", "delete_file", "create_directory"].contains(approval.action) || run.request.workspaceEditsEnabled == true)
            guard permitted else { await answer(publicID, approved: false); return }
            let request = ToolRequest(id: publicID, name: approval.action, arguments: approval.arguments,
                risk: .externalEffect, workspacePath: run.request.workspacePath)
            let conversation = run.request.conversationID
            let broker = approvalBroker
            approvalTasks[publicID] = Task { [weak self] in
                let approved = await broker.request(request, sessionID: conversation, allowsSessionDecision: false)
                await self?.answer(publicID, approved: approved)
            }
            return
        }
        if frame.kind == "activity" {
            guard let activity = frame.activity, activity.isValid, frame.event == nil, frame.approval == nil else {
                throw EngineError.invalidRuntime("Invalid external activity.")
            }
            await activityHandler?(activity, run.request)
            return
        }
        guard frame.kind == "event", let event = frame.event else { throw EngineError.invalidRuntime("Unknown external adapter frame kind.") }
        let conversation = run.request.conversationID
        switch event {
        case .textDelta(let id, _), .reasoningDelta(let id, _), .runStage(let id, _), .turnMetrics(let id, _), .contextUsage(let id, _), .titleGenerated(let id, _):
            guard id == conversation else { throw EngineError.invalidRuntime("External event targets another conversation.") }
        case .completed(let target):
            guard target == conversation else { throw EngineError.invalidRuntime("External completion targets another conversation.") }
            try await finishRun(id)
        case .failed(let target, _):
            guard target == conversation else { throw EngineError.invalidRuntime("External failure targets another conversation.") }
            try await finishRun(id)
        default: throw EngineError.invalidRuntime("External stdout cannot publish host authorization, plans or tool lifecycle.")
        }
        publish(event)
    }
    private func finishRun(_ id: UUID) async throws {
        let run = runs[id]
        let pending = approvals.filter { $0.value.runID == id }.map(\.key)
        for key in pending {
            approvals.removeValue(forKey: key)
            approvalTasks.removeValue(forKey: key)?.cancel()
        }
        try await run?.finance?.close()
        runs.removeValue(forKey: id)
        if runs.isEmpty { providerRequests.removeAll() }
    }
    private func ended(code: String) async {
        Self.log.error("External engine \(self.id.rawValue, privacy: .public) ended (\(code, privacy: .public)). stderr tail: \(self.stderrTail, privacy: .public)")
        handshakeComplete = false
        currentStatus.state = .error
        currentStatus.diagnostic = EngineDiagnostic(code: code, message: "The configured external adapter ended or violated its pinned protocol.", isRecoverable: true)
        let endedRuns = runs; runs.removeAll()
        for run in endedRuns.values {
            do { try await run.finance?.close() }
            catch { currentStatus.diagnostic = EngineDiagnostic(code: "external.finance.unresolved", message: "The adapter ended with unresolved native billing receipts; costs remain reserved or unknown.", isRecoverable: true) }
            publish(.failed(conversationID: run.request.conversationID, diagnostic: currentStatus.diagnostic!))
        }
        for task in approvalTasks.values { task.cancel() }
        approvalTasks.removeAll()
        runs.removeAll(); approvals.removeAll(); publish(.state(currentStatus))
        await runner.terminateAll()
    }
}
