import AIMApplication
import CryptoKit
import Foundation

/// A shared cancellable loop; no fixed total step quota. Provider adapters never execute tools.
public enum NativeWorkspaceTurn {
    public static func run(conversation: any ModelToolConversation, dispatcher: ApprovedToolDispatcher,
                           conversationID: UUID, journal: WorkspaceRunJournal? = nil,
                           missionRepository: (any AgentMissionRepository)? = nil, missionID: UUID? = nil,
                           checkpointing: (any ExecutionCheckpointing)? = nil,
                           workspaceRunID: String? = nil,
                           continuationMessage: String? = nil,
                           emit: @escaping @Sendable (EngineEvent) -> Void) async throws {
        var journalStarted = false
        // What the model writes is shown as it arrives; the step's final text is then not repeated.
        let streamed = StreamedStep()
        let streaming = conversation as? any StreamingToolConversation
        await streaming?.setStreamHandler { delta in
            switch delta {
            case let .text(text): streamed.add(text: text); emit(.textDelta(conversationID: conversationID, text: text))
            case let .reasoning(text): streamed.add(reasoning: text); emit(.reasoningDelta(conversationID: conversationID, text: text))
            }
        }
        defer { Task { await streaming?.setStreamHandler(nil) } }
        do {
            try await journal?.start()
            journalStarted = journal != nil
            var outputs: [ModelToolOutput] = []
            var seen: Set<String> = []
            var failedRoutes: [ModelToolCall] = []
            var blockedRoutes: [ModelToolCall] = []
            var blockedTurns = 0
            var lastSuccessfulResult: (call: ModelToolCall, content: String, image: Data?, count: Int)?
            var recentSuccesses: [ProgressSample] = []
            var journalOrdinal = 0
            var restored = try await checkpointing?.load()
            var continuationMessage = continuationMessage
            if let checkpoint = restored {
                guard !checkpoint.needsReconciliation,
                      let durable = conversation as? any DurableModelConversation else {
                    throw ExecutionStoreError.invalidTransition
                }
                try await durable.restoreCheckpoint(checkpoint.conversation)
                try await dispatcher.restoreToolState(checkpoint.toolState ?? [:])
                if let missionRepository, let missionID {
                    for id in checkpoint.deliveredMissionInputIDs ?? [] {
                        try await missionRepository.consumeInput(id: id, missionID: missionID)
                    }
                }
                if let checkpointing {
                    var current = checkpoint
                    current.missionID = missionID; current.workspaceRunID = workspaceRunID
                    try await checkpointing.prepare(current)
                    restored = current
                }
                seen = checkpoint.seenCallIDs; blockedRoutes = checkpoint.blockedCalls
                if checkpoint.turn.calls.isEmpty, continuationMessage != nil { restored = nil }
                if checkpoint.effects.allSatisfy({ $0.state == .returned }), !checkpoint.turn.calls.isEmpty {
                    outputs = checkpoint.effects.compactMap(\.output); restored = nil
                }
            }
            while true {
                try Task.checkCancellation()
                try await checkpointing?.checkBoundary()
                emit(.runStage(conversationID: conversationID, stage: .waitingForModel))
                let corrections: [AgentMissionInput]
                if let missionRepository, let missionID {
                    corrections = try await missionRepository.pendingInputs(missionID: missionID)
                } else { corrections = [] }
                let executionInputs = try await checkpointing?.pendingUserInputs() ?? []
                let uniqueInputs = executionInputs.filter { input in !corrections.contains { $0.id == input.id } }
                if restored?.turn.calls.isEmpty == true, !corrections.isEmpty || !uniqueInputs.isEmpty || continuationMessage != nil { restored = nil }
                let turn: ModelToolTurn
                let restoringTurn = restored != nil
                if let checkpoint = restored {
                    turn = checkpoint.turn
                } else if !corrections.isEmpty || !uniqueInputs.isEmpty || continuationMessage != nil {
                    guard let steerable = conversation as? any SteerableModelToolConversation,
                          corrections.isEmpty || missionRepository != nil else { throw ModelToolError.invalidConfiguration }
                    turn = try await steerable.next(outputs: outputs,
                        userMessages: corrections.map(\.content) + uniqueInputs.map(\.content) + (continuationMessage.map { [$0] } ?? []))
                    continuationMessage = nil
                } else {
                    turn = try await conversation.next(outputs: outputs)
                }
                try Task.checkCancellation()
                let live = streamed.take()
                if turn.contextCompacted == true {
                    // One line in the turn, as in Codex: the older part was summarized to continue.
                    let marker = "context-compaction-" + UUID().uuidString
                    emit(.toolStartedDetailed(conversationID: conversationID, callID: marker, name: "context_compaction", detail: nil))
                    emit(.toolFinished(conversationID: conversationID, callID: marker, isError: false))
                }
                if let checkpointing, !restoringTurn {
                    guard let durable = conversation as? any DurableModelConversation else { throw ExecutionStoreError.incompatibleCheckpoint }
                    var effects: [ExecutionEffect] = []
                    for call in turn.calls {
                        effects.append(ExecutionEffect(call: call, policy: await dispatcher.recoveryPolicy(for: call.name)))
                    }
                    var checkpoint = ExecutionCheckpoint(conversation: try await durable.exportCheckpoint(),
                        turn: turn, effects: effects, ordinal: seen.count, seenCallIDs: seen, blockedCalls: blockedRoutes,
                        toolState: try await dispatcher.exportToolState(), missionID: missionID,
                        workspaceRunID: workspaceRunID)
                    checkpoint.deliveredMissionInputIDs = Array(Set(corrections.map(\.id) + executionInputs.map(\.id)))
                    try await checkpointing.prepare(checkpoint)
                    try await checkpointing.checkBoundary()
                }
                if !restoringTurn, let missionRepository, let missionID {
                    for correction in corrections { try await missionRepository.consumeInput(id: correction.id, missionID: missionID) }
                }
                if turn.calls.isEmpty {
                    if !(try await checkpointing?.pendingUserInputs() ?? []).isEmpty {
                        outputs = []; restored = nil; continue
                    }
                    // A correction may have arrived while the model was answering.
                    // Discard that now-obsolete final answer and give it another round.
                    if let missionRepository, let missionID {
                        if !(try await missionRepository.pendingInputs(missionID: missionID)).isEmpty {
                            outputs = []
                            restored = nil
                            continue
                        }
                    }
                    await dispatcher.close()
                    try await journal?.finish(.unverified)
                    // finish closes correction admission in the same SQLite
                    // database. A correction committed just before it remains
                    // queued, so suppress the obsolete final answer.
                    if let missionRepository, let missionID,
                       !(try await missionRepository.pendingInputs(missionID: missionID)).isEmpty {
                        return
                    }
                    if !(try await checkpointing?.pendingUserInputs() ?? []).isEmpty { return }
                    if live.reasoning.isEmpty, let reasoning = turn.reasoning { emit(.reasoningDelta(conversationID: conversationID, text: reasoning)) }
                    if live.text.isEmpty, !turn.text.isEmpty { emit(.textDelta(conversationID: conversationID, text: turn.text)) }
                    return
                }
                if live.reasoning.isEmpty, let reasoning = turn.reasoning { emit(.reasoningDelta(conversationID: conversationID, text: reasoning)) }
                if !turn.text.isEmpty { emit(.textDelta(conversationID: conversationID, text: live.text.isEmpty ? turn.text + "\n\n" : "\n\n")) }
                guard Set(turn.calls.map(\.id)).count == turn.calls.count,
                      (restoringTurn || turn.calls.allSatisfy({ !seen.contains($0.id) })) else { throw ModelToolError.invalidProtocol }
                // A step made only of blocked actions is answered with the reason (the model can change
                // approach); the run pauses only if it insists three steps in a row.
                if turn.calls.allSatisfy({ call in
                    blockedRoutes.contains { $0.name == call.name && $0.arguments == call.arguments }
                }) {
                    blockedTurns += 1
                    if blockedTurns >= 3 { throw ModelToolError.repeatedFailures }
                } else { blockedTurns = 0 }
                outputs = []
                // Independent read-only calls of one turn run concurrently; their
                // requests are journaled in order first and results are handled in order.
                var parallel: [ModelToolCall] = []
                for call in turn.calls where !restoringTurn {
                    if await dispatcher.isParallelSafe(call.name),
                       !blockedRoutes.contains(where: { $0.name == call.name && $0.arguments == call.arguments }) {
                        parallel.append(call)
                    }
                }
                var prefetched: [String: ToolResult] = [:]
                if parallel.count >= 2 {
                    for call in turn.calls where parallel.contains(where: { $0.id == call.id }) {
                        try Task.checkCancellation()
                        try await journal?.requested(call, ordinal: journalOrdinal)
                        journalOrdinal += 1
                        emit(.toolStartedDetailed(conversationID: conversationID, callID: call.id,
                                                  name: call.name, detail: activityDetail(for: call)))
                    }
                    prefetched = await withTaskGroup(of: (String, ToolResult).self) { group in
                        for call in parallel {
                            group.addTask {
                                (call.id, await dispatcher.executeJSON(id: call.id, name: call.name, arguments: call.jsonArguments,
                                    willExecute: {
                                        try await journal?.launched(call.id)
                                        try await checkpointing?.launched(call.id)
                                    }))
                            }
                        }
                        var results: [String: ToolResult] = [:]
                        for await (id, result) in group { results[id] = result }
                        return results
                    }
                }
                for call in turn.calls {
                    try Task.checkCancellation()
                    if let prior = restored?.effects.first(where: { $0.call.id == call.id }),
                       prior.state == .returned, let output = prior.output {
                        outputs.append(output); seen.insert(call.id); continue
                    }
                    let wasPrefetched = prefetched[call.id] != nil
                    if !wasPrefetched {
                        try await journal?.requested(call, ordinal: journalOrdinal)
                        journalOrdinal += 1
                        try Task.checkCancellation()
                        emit(.toolStartedDetailed(conversationID: conversationID, callID: call.id,
                                                  name: call.name, detail: activityDetail(for: call)))
                    }
                    seen.insert(call.id)
                    let blocked = !wasPrefetched && blockedRoutes.contains { $0.name == call.name && $0.arguments == call.arguments }
                    var result: ToolResult
                    if let early = prefetched[call.id] {
                        result = early
                    } else if blocked {
                        result = ToolResult(requestID: call.id,
                            content: "This exact operation repeatedly failed and is blocked for this run. Choose a different approach. No action was executed.", isError: true)
                    } else {
                        result = await dispatcher.executeJSON(id: call.id, name: call.name, arguments: call.jsonArguments,
                            willExecute: {
                                try await journal?.launched(call.id)
                                try await checkpointing?.launched(call.id)
                            })
                    }
                    if result.metadata["journal_failure"] == "true" { throw WorkspaceHistoryError.persistence }
                    if let outcome = result.actionOutcome,
                       [ActionOutcome.unknown, .unverified, .partial].contains(outcome) {
                        // A submitted effect may already exist even when the
                        // adapter could not prove its final state. Never let
                        // this run blindly repeat the same operation.
                        result.metadata["recovery_required"] = "This action may already have changed its target. Read the current state and reconcile before another mutation; the exact call is blocked for this run."
                        if !blockedRoutes.contains(where: { $0.name == call.name && $0.arguments == call.arguments }) {
                            blockedRoutes.append(call)
                        }
                    }
                    if result.isError && failedRoutes.count >= 2 {
                        result.metadata["recovery_required"] = "Repeated tool errors. Inspect the error and change the approach; do not repeat the same failed operation."
                    }
                    if result.isError || (call.name == "await_subagents" &&
                                          result.metadata["expected_wait"] == "true" &&
                                          result.metadata["wait_condition"] == "all_children_terminal")
                        // Watching a long build or server is waiting on a running process, not stagnation.
                        || call.name == "read_command" {
                        // A trusted host wait with an observable condition is
                        // not a repeated attempt to change the same state.
                        lastSuccessfulResult = nil
                        recentSuccesses.removeAll()
                    } else {
                        // Three identical successful results from the exact same
                        // operation are evidence of stagnation, not progress.
                        // Let the model see the diagnosis before blocking a retry.
                        let count: Int
                        if let previous = lastSuccessfulResult,
                           previous.call.name == call.name, previous.call.arguments == call.arguments,
                           previous.content == result.content, previous.image == result.imagePNG {
                            count = previous.count + 1
                        } else { count = 1 }
                        lastSuccessfulResult = (call, result.content, result.imagePNG, count)
                        recentSuccesses.append(ProgressSample(call: call, result: result))
                        if recentSuccesses.count > 12 { recentSuccesses.removeFirst() }
                        if count == 3 {
                            result.metadata["stagnation_warning"] = "Repeated identical successful result; no observable progress. Change the approach or explicitly explain the wait condition. This exact route is now blocked."
                            result.content += "\n[Progress diagnostic] This exact operation returned an identical result three times. No observable progress was made. Do not repeat it; inspect another source or explain the limitation."
                            blockedRoutes.append(call)
                        } else if let cycle = Self.repeatingCycle(in: recentSuccesses) {
                            result.metadata["stagnation_warning"] = "\(cycle.count) operations repeated in the same order three times with identical results. None showed observable progress; choose a new approach."
                            result.content += "\n[Progress diagnostic] The same \(cycle.count) operations cycled three times without a changed result. Do not repeat these routes."
                            recentSuccesses.removeAll()
                            for stalled in cycle {
                                if !blockedRoutes.contains(where: { $0.name == stalled.name && $0.arguments == stalled.arguments }) {
                                    blockedRoutes.append(stalled)
                                }
                            }
                        }
                    }
                    let output = ModelToolOutput(id: call.id, content: result.content, isError: result.isError,
                                                 imagePNG: result.imagePNG, metadata: result.metadata)
                    try await checkpointing?.returned(output, toolState: try await dispatcher.exportToolState())
                    // The audit record contains only the textual result, never raw pixels.
                    try await journal?.returned(ModelToolOutput(id: call.id, content: result.content, isError: result.isError,
                                                               metadata: result.metadata))
                    try Task.checkCancellation()
                    emit(.toolFinished(conversationID: conversationID, callID: call.id, isError: result.isError))
                    outputs.append(output)
                    if result.isError {
                        failedRoutes.append(call)
                        if failedRoutes.count > 16 { failedRoutes.removeFirst() }
                        if !blocked, failedRoutes.filter({ $0.name == call.name && $0.arguments == call.arguments }).count >= 3 {
                            blockedRoutes.append(call)
                        }
                    } else { failedRoutes.removeAll() }
                }
                restored = nil
                if checkpointing != nil, let wait = ExecutionManagedWait.from(outputs) { throw wait }
            }
        } catch {
            await dispatcher.close()
            if journalStarted { try await journal?.finish(error is ExecutionManagedWait ? .unverified : Task.isCancelled || error is CancellationError ? .cancelled : .failed) }
            throw error
        }
    }

    /// The calls of a cycle of period 2–4 repeated three times at the end of the
    /// history with identical results (a single repeated call is handled separately).
    private static func repeatingCycle(in samples: [ProgressSample]) -> [ModelToolCall]? {
        for period in 2...4 where samples.count >= period * 3 {
            let window = Array(samples.suffix(period * 3))
            guard (0..<(period * 2)).allSatisfy({ window[$0] == window[$0 + period] }) else { continue }
            let unit = Array(window.prefix(period))
            guard !unit.dropFirst().allSatisfy({ $0 == unit[0] }) else { continue }
            return unit.map(\.call)
        }
        return nil
    }

    private static func activityDetail(for call: ModelToolCall) -> String? {
        let args = call.arguments
        let raw: String?
        if let path = args["path"] ?? args["source"] {
            raw = URL(fileURLWithPath: path).lastPathComponent
        } else if let query = args["query"] ?? args["text"],
                  ["search_files", "glob_files", "web_search", "browser_find"].contains(call.name) {
            raw = query
        } else if let url = args["url"], let host = URL(string: url)?.host {
            raw = host
        } else if let window = args["window_id"] {
            raw = "Window \(window)"
        } else if let title = args["title"], call.name == "delegate_task" {
            raw = title
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let clean = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(90))
    }
}

private struct ProgressSample: Equatable {
    let call: ModelToolCall
    let contentDigest: Data
    let imageDigest: Data?

    init(call: ModelToolCall, result: ToolResult) {
        self.call = call
        contentDigest = Data(SHA256.hash(data: Data(result.content.utf8)))
        imageDigest = result.imagePNG.map { Data(SHA256.hash(data: $0)) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.call.name == rhs.call.name && lhs.call.arguments == rhs.call.arguments &&
            lhs.contentDigest == rhs.contentDigest && lhs.imageDigest == rhs.imageDigest
    }
}

/// The text and reasoning a step already streamed, so the step's final copy is not shown twice.
private final class StreamedStep: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var reasoning = ""
    func add(text piece: String) { lock.withLock { text += piece } }
    func add(reasoning piece: String) { lock.withLock { reasoning += piece } }
    func take() -> (text: String, reasoning: String) {
        lock.withLock { defer { text = ""; reasoning = "" }; return (text, reasoning) }
    }
}
