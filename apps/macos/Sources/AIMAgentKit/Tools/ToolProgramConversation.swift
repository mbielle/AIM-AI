import AIMCore
import AIMApplication
import CryptoKit
import Foundation

/// A bounded JSON interpreter. It cannot execute host code or access resources;
/// it emits ordinary calls for NativeWorkspaceTurn and its approval dispatcher.
/// Each primitive therefore keeps its own durable intent, result and recovery policy.
public actor ToolProgramConversation: SteerableModelToolConversation, DurableModelConversation, StreamingToolConversation {
    public func setStreamHandler(_ handler: (@Sendable (ToolStreamDelta) -> Void)?) async {
        await (inner as? any StreamingToolConversation)?.setStreamHandler(handler)
    }
    public static let definition = ModelToolDefinition(name: "run_tool_program", description: """
        Run a bounded JSON tool program without a model request between steps. program_json is \
        {"version":1,"steps":[{"id":"a","tool":"read_file","arguments":{"path":"README.md"}}],"stop_on_error":true}. \
        At most 64 steps, only run-authorized tools. Arguments may reference previous textual results with \
        {"$result":"a","offset":0,"limit":4096}; pages are at most 16384 bytes. Optional step when is \
        {"step":"a","succeeded":true}. Optional foreach is a literal array of at most 32 values; \
        use {"$item":true} in arguments and generated step IDs are id_0, id_1, etc. \
        Each operation retains the usual approval and recovery controls. An error stops by default. \
        Corrections stop all unissued steps. No arbitrary JavaScript/Python/shell interpreter is provided.
        """, requiredArguments: ["program_json"])

    private struct Condition: Codable, Equatable, Sendable { let step: String; let succeeded: Bool }
    private struct Step: Codable, Equatable, Sendable {
        let id: String
        let tool: String
        let arguments: [String: ToolJSONValue]
        let when: Condition?
    }
    private struct Receipt: Codable, Sendable {
        let id: String
        let content: String
        let isError: Bool
        let skipped: Bool
    }
    private struct Program: Codable, Sendable {
        let original: ModelToolCall
        let steps: [Step]
        let stopOnError: Bool
        var cursor: Int = 0
        var receipts: [Receipt] = []
        var pending: ModelToolCall?
    }
    private struct State: Codable, Sendable {
        let availableNames: [String]
        let innerCodec: String
        let innerPendingIDs: [String]
        let innerSeenIDs: Set<String>
        let innerFinished: Bool
        let program: Program?
        let seenIDs: Set<String>
        let pendingIDs: [String]
    }
    private let inner: any SteerableModelToolConversation & DurableModelConversation
    private let tools: [String: ModelToolDefinition]
    private let enabled: Bool
    private var program: Program?
    private var seenIDs: Set<String> = []
    private var pendingIDs: [String] = []
    private var requesting = false

    public init(inner: any SteerableModelToolConversation & DurableModelConversation, tools: [ModelToolDefinition]) throws {
        guard Set(tools.map(\.name)).count == tools.count else { throw ModelToolError.invalidConfiguration }
        self.inner = inner
        self.enabled = tools.contains { $0.name == Self.definition.name }
        self.tools = Dictionary(uniqueKeysWithValues: tools.filter { $0.name != Self.definition.name }.map { ($0.name, $0) })
    }
    public func usageSoFar() async -> TokenUsage { await inner.usageSoFar() }
    public func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn { try await next(outputs: outputs, userMessages: []) }

    public func next(outputs: [ModelToolOutput], userMessages: [String]) async throws -> ModelToolTurn {
        guard !requesting, outputs.map(\.id) == pendingIDs else { throw ModelToolError.invalidProtocol }
        requesting = true; defer { requesting = false }
        try Task.checkCancellation()
        var providerOutputs = outputs
        if var active = program {
            if let pending = active.pending {
                guard outputs.count == 1, outputs[0].id == pending.id, active.cursor < active.steps.count else { throw ModelToolError.invalidProtocol }
                let result = outputs[0]
                active.receipts.append(Receipt(id: active.steps[active.cursor].id,
                    content: Self.page(result.content, offset: 0, limit: 16_384), isError: result.isError, skipped: false))
                active.cursor += 1; active.pending = nil
                if active.stopOnError && result.isError { active.cursor = active.steps.count }
            }
            if !userMessages.isEmpty { active.cursor = active.steps.count }
            if active.cursor < active.steps.count, let call = try Self.advance(&active, tools: tools) {
                program = active; pendingIDs = [call.id]; seenIDs.insert(call.id)
                return ModelToolTurn(text: "", calls: [call])
            }
            program = nil
            providerOutputs = [try Self.result(active, interrupted: !userMessages.isEmpty)]
        }
        let turn = try await inner.next(outputs: providerOutputs, userMessages: userMessages)
        // A program owns one provider call. Mixed with other calls, it is not interpreted: the
        // dispatcher refuses it with an explanation and the other calls run normally.
        if enabled, turn.calls.count == 1, let call = turn.calls.first(where: { $0.name == Self.definition.name }) {
            do {
                var active = try Self.parse(call, tools: tools)
                guard let primitive = try Self.advance(&active, tools: tools) else { throw ModelToolError.invalidProtocol }
                program = active; pendingIDs = [primitive.id]; seenIDs.insert(primitive.id)
                return ModelToolTurn(text: turn.text, calls: [primitive])
            } catch {
                // Invalid programs cannot emit even their first effect. Return
                // a durable refusal as the original call; the empty registration
                // causes the dispatcher to refuse it without executing anything.
                pendingIDs = [call.id]; seenIDs.insert(call.id)
                return ModelToolTurn(text: turn.text, calls: [call])
            }
        }
        pendingIDs = turn.calls.map(\.id); seenIDs.formUnion(pendingIDs)
        return turn
    }

    public func exportCheckpoint() async throws -> ModelConversationCheckpoint {
        guard !requesting else { throw ModelToolError.invalidProtocol }
        let source = try await inner.exportCheckpoint()
        var checkpoint = source
        checkpoint.codec = "tool-program-v1"; checkpoint.pendingIDs = pendingIDs
        checkpoint.seenIDs = seenIDs; checkpoint.finished = source.finished && program == nil
        checkpoint.extensions = source.extensions ?? [:]
        checkpoint.extensions?["aim.tool-program.state.v1"] = try JSONEncoder().encode(State(
            availableNames: tools.keys.sorted(), innerCodec: source.codec, innerPendingIDs: source.pendingIDs,
            innerSeenIDs: source.seenIDs, innerFinished: source.finished, program: program, seenIDs: seenIDs, pendingIDs: pendingIDs))
        return checkpoint
    }
    public func restoreCheckpoint(_ checkpoint: ModelConversationCheckpoint) async throws {
        guard !requesting else { throw ExecutionStoreError.incompatibleCheckpoint }
        // Native checkpoints created before enabling programs remain readable.
        if checkpoint.codec != "tool-program-v1" {
            try await inner.restoreCheckpoint(checkpoint)
            pendingIDs = checkpoint.pendingIDs; seenIDs = checkpoint.seenIDs; program = nil
            return
        }
        guard checkpoint.version == 1,
              let stateData = checkpoint.extensions?["aim.tool-program.state.v1"], stateData.count <= 8 * 1_024 * 1_024,
              let state = try? JSONDecoder().decode(State.self, from: stateData),
              state.innerCodec != "tool-program-v1",
              Set(state.availableNames).count == state.availableNames.count,
              Set(state.availableNames).isSubset(of: Set(tools.keys)), state.pendingIDs == checkpoint.pendingIDs,
              state.seenIDs == checkpoint.seenIDs, Set(state.pendingIDs).isSubset(of: state.seenIDs) else {
            throw ExecutionStoreError.incompatibleCheckpoint
        }
        var source = checkpoint
        source.codec = state.innerCodec; source.pendingIDs = state.innerPendingIDs
        source.seenIDs = state.innerSeenIDs; source.finished = state.innerFinished
        source.extensions?.removeValue(forKey: "aim.tool-program.state.v1")
        if let active = state.program {
            guard enabled, active.original.name == Self.definition.name, source.pendingIDs == [active.original.id],
                  active.cursor >= 0, active.cursor < active.steps.count, active.steps.count <= 64,
                  active.pending.map({ [$0.id] == state.pendingIDs }) == true,
                  active.receipts.count <= 64 else { throw ExecutionStoreError.incompatibleCheckpoint }
            let parsed = try Self.parse(active.original, tools: tools)
            guard parsed.steps == active.steps, parsed.stopOnError == active.stopOnError,
                  active.receipts.map(\.id) == active.steps.prefix(active.cursor).map(\.id) else {
                throw ExecutionStoreError.incompatibleCheckpoint
            }
            for receipt in active.receipts where !receipt.skipped {
                guard receipt.content.utf8.count <= 16_384 else { throw ExecutionStoreError.incompatibleCheckpoint }
            }
            var expected = active; expected.pending = nil
            guard try Self.advance(&expected, tools: tools) == active.pending else { throw ExecutionStoreError.incompatibleCheckpoint }
        } else {
            guard source.pendingIDs == state.pendingIDs else { throw ExecutionStoreError.incompatibleCheckpoint }
        }
        try await inner.restoreCheckpoint(source)
        pendingIDs = state.pendingIDs; seenIDs = state.seenIDs; program = state.program
    }

    private static func parse(_ call: ModelToolCall, tools: [String: ModelToolDefinition]) throws -> Program {
        guard Set(call.jsonArguments.keys) == ["program_json"], case .string(let raw) = call.jsonArguments["program_json"],
              raw.utf8.count <= 64 * 1_024 else { throw ModelToolError.invalidProtocol }
        let object = try ToolJSONValue.decodeObject(Data(raw.utf8))
        guard Set(object.keys).isSubset(of: ["version", "steps", "stop_on_error"]),
              case .integer(1) = object["version"], case .array(let rawSteps) = object["steps"],
              !rawSteps.isEmpty, rawSteps.count <= 64 else { throw ModelToolError.invalidProtocol }
        let stopOnError: Bool
        if let value = object["stop_on_error"] {
            guard case .boolean(let flag) = value else { throw ModelToolError.invalidProtocol }
            stopOnError = flag
        } else { stopOnError = true }
        var steps: [Step] = []
        var identifiers: Set<String> = []
        for rawStep in rawSteps {
            guard case .object(let fields) = rawStep,
                  Set(fields.keys).isSubset(of: ["id", "tool", "arguments", "when", "foreach"]),
                  case .string(let id) = fields["id"], !id.isEmpty, id.utf8.count <= 32,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  case .string(let tool) = fields["tool"], tools[tool] != nil,
                  case .object(let arguments) = fields["arguments"] else { throw ModelToolError.invalidProtocol }
            let condition: Condition?
            if let when = fields["when"] {
                guard case .object(let values) = when, Set(values.keys) == ["step", "succeeded"],
                      case .string(let previous) = values["step"], identifiers.contains(previous),
                      case .boolean(let succeeded) = values["succeeded"] else { throw ModelToolError.invalidProtocol }
                condition = Condition(step: previous, succeeded: succeeded)
            } else { condition = nil }
            let items: [ToolJSONValue]?
            if let value = fields["foreach"] {
                guard case .array(let values) = value, !values.isEmpty, values.count <= 32 else { throw ModelToolError.invalidProtocol }
                items = values
            } else { items = nil }
            for index in 0..<(items?.count ?? 1) {
                let stepID = items == nil ? id : id + "_" + String(index)
                guard identifiers.insert(stepID).inserted, steps.count < 64 else { throw ModelToolError.limitReached }
                let bound = try arguments.mapValues { try bindItem($0, item: items?[index]) }
                try validateReferences(bound.values, previous: Set(steps.map(\.id)))
                steps.append(Step(id: stepID, tool: tool, arguments: bound, when: condition))
            }
        }
        return Program(original: call, steps: steps, stopOnError: stopOnError)
    }
    private static func bindItem(_ value: ToolJSONValue, item: ToolJSONValue?) throws -> ToolJSONValue {
        switch value {
        case .object(let fields) where fields["$item"] != nil:
            guard Set(fields.keys) == ["$item"], fields["$item"] == .boolean(true), let item else { throw ModelToolError.invalidProtocol }
            return item
        case .object(let fields): return .object(try fields.mapValues { try bindItem($0, item: item) })
        case .array(let values): return .array(try values.map { try bindItem($0, item: item) })
        default: return value
        }
    }
    private static func validateReferences<S: Sequence>(_ values: S, previous: Set<String>) throws where S.Element == ToolJSONValue {
        for value in values {
            switch value {
            case .object(let fields) where fields["$result"] != nil:
                guard Set(fields.keys).isSubset(of: ["$result", "offset", "limit"]),
                      case .string(let id) = fields["$result"], previous.contains(id) else { throw ModelToolError.invalidProtocol }
                if let offset = fields["offset"] { guard case .integer(let n) = offset, n >= 0 else { throw ModelToolError.invalidProtocol } }
                if let limit = fields["limit"] { guard case .integer(let n) = limit, n > 0, n <= 16_384 else { throw ModelToolError.invalidProtocol } }
            case .object(let fields): try validateReferences(fields.values, previous: previous)
            case .array(let values): try validateReferences(values, previous: previous)
            default: break
            }
        }
    }
    private static func resolve(_ value: ToolJSONValue, receipts: [Receipt]) throws -> ToolJSONValue {
        switch value {
        case .object(let fields) where fields["$result"] != nil:
            guard case .string(let id) = fields["$result"], let receipt = receipts.first(where: { $0.id == id }),
                  !receipt.isError, !receipt.skipped else { throw ModelToolError.invalidProtocol }
            let offset = fields["offset"].flatMap { if case .integer(let n) = $0 { n } else { nil } } ?? 0
            let limit = fields["limit"].flatMap { if case .integer(let n) = $0 { n } else { nil } } ?? 4_096
            return .string(page(receipt.content, offset: offset, limit: limit))
        case .object(let fields): return .object(try fields.mapValues { try resolve($0, receipts: receipts) })
        case .array(let values): return .array(try values.map { try resolve($0, receipts: receipts) })
        default: return value
        }
    }
    private static func advance(_ active: inout Program, tools: [String: ModelToolDefinition]) throws -> ModelToolCall? {
        while active.cursor < active.steps.count {
            let step = active.steps[active.cursor]
            if let condition = step.when,
               let result = active.receipts.first(where: { $0.id == condition.step }),
               result.skipped || (!result.isError) != condition.succeeded {
                active.receipts.append(Receipt(id: step.id, content: "Condition not met; no effect executed.", isError: false, skipped: true))
                active.cursor += 1; continue
            }
            guard let definition = tools[step.tool] else { throw ModelToolError.invalidProtocol }
            let resolved = try step.arguments.mapValues { try resolve($0, receipts: active.receipts) }
            let arguments = try definition.normalized(resolved)
            let hash = SHA256.hash(data: Data(active.original.id.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
            let call = ModelToolCall(id: "aim_program_" + hash + "_" + step.id, name: step.tool, jsonArguments: arguments)
            active.pending = call
            return call
        }
        return nil
    }
    private static func result(_ active: Program, interrupted: Bool) throws -> ModelToolOutput {
        // Each receipt is shortened until the whole summary fits one tool result.
        var data = Data()
        for limit in [1_024, 512, 256, 96] {
            let brief = active.receipts.map { Receipt(id: $0.id, content: page($0.content, offset: 0, limit: limit), isError: $0.isError, skipped: $0.skipped) }
            data = try JSONEncoder().encode(brief)
            if data.count <= ToolPayloadLimits.resultTextBytes { break }
        }
        guard data.count <= ToolPayloadLimits.resultTextBytes else { throw ModelToolError.limitReached }
        return ModelToolOutput(id: active.original.id, content: String(decoding: data, as: UTF8.self),
            isError: interrupted || active.receipts.contains(where: \.isError),
            metadata: ["program_steps": String(active.steps.count), "completed_steps": String(active.receipts.filter { !$0.skipped }.count),
                       "interrupted_by_correction": interrupted ? "true" : "false", "isolation": "bounded_json_interpreter_host_approval_per_primitive"])
    }
    private static func page(_ text: String, offset: Int, limit: Int) -> String {
        var bytes = Data(text.utf8.dropFirst(min(offset, text.utf8.count)).prefix(limit))
        while let first = bytes.first, (0x80...0xBF).contains(first) { bytes.removeFirst() }
        while !bytes.isEmpty {
            if let value = String(data: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }
}
