import AIMApplication
import Foundation

/// A child's typed handoff: what it did, how it checked it, and what it did not check.
public struct SubagentReport: Codable, Sendable, Equatable {
    public enum Confidence: String, Codable, Sendable { case low, medium, high }

    public let summary: String
    public let changes: [String]
    public let evidence: [String]
    public let notChecked: [String]
    public let confidence: Confidence

    public init(summary: String, changes: [String], evidence: [String], notChecked: [String], confidence: Confidence) {
        self.summary = summary; self.changes = changes; self.evidence = evidence
        self.notChecked = notChecked; self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case summary, changes, evidence, confidence
        case notChecked = "not_checked"
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? summary
    }
}

/// Captures the child's single `subagent_report` call.
public actor SubagentReportToolService: ToolExecutor, DurableToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["subagent_report"]
    public private(set) var report: SubagentReport?

    public init() {}

    public static let definition = ModelToolDefinition(name: "subagent_report",
        description: "Finish your delegated task with a structured report for the parent agent: summary (what you did and the outcome), changes (array of files or effects), evidence (array: how you verified each claim, e.g. a file you read back or a command output), not_checked (array: anything you could not verify), confidence (low, medium or high). Call it exactly once, then stop.",
        requiredArguments: ["summary", "confidence"], optionalArguments: ["changes", "evidence", "not_checked"],
        argumentKinds: ["changes": .array, "evidence": .array, "not_checked": .array])

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard let summary = request.arguments["summary"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty, summary.count <= 8_000,
              let confidence = request.arguments["confidence"].flatMap({ SubagentReport.Confidence(rawValue: $0.lowercased()) }) else {
            return ToolResult(requestID: request.id, content: "Provide a non-empty summary and confidence low, medium or high.", isError: true)
        }
        func list(_ key: String) -> [String] {
            guard let raw = request.arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
            if let values = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) { return Array(values.prefix(100)) }
            return [raw]
        }
        report = SubagentReport(summary: summary, changes: list("changes"), evidence: list("evidence"),
                                notChecked: list("not_checked"), confidence: confidence)
        return ToolResult(requestID: request.id, content: "Report recorded. Stop now; do not call more tools.")
    }

    public func cancel(requestID: String) async {}
    public func exportToolState() throws -> Data { try JSONEncoder().encode(report) }
    public func restoreToolState(_ data: Data, workspacePath: String?) throws {
        report = try JSONDecoder().decode(SubagentReport?.self, from: data)
    }
    public nonisolated func recoveryPolicy(for name: String) -> ToolRecoveryPolicy { .readOnly }
    public func reconcile(_ call: ModelToolCall, workspacePath: String?) throws -> ModelToolOutput? { nil }
}

/// Gives a child that ended without `subagent_report` exactly one bounded
/// correction turn (more retries tend to degrade an otherwise correct answer).
public final class ReportEnforcingConversation: ModelToolConversation, DurableModelConversation, StreamingToolConversation, @unchecked Sendable {
    public func setStreamHandler(_ handler: (@Sendable (ToolStreamDelta) -> Void)?) async {
        await (inner as? any StreamingToolConversation)?.setStreamHandler(handler)
    }
    public static let correction = "You ended without calling subagent_report. Call subagent_report now with your summary, changes, evidence, not_checked and confidence. Do not repeat the work."
    private let inner: any SteerableModelToolConversation
    private let reports: SubagentReportToolService
    private let lock = NSLock()
    private var corrected = false

    public init(inner: any SteerableModelToolConversation, reports: SubagentReportToolService) {
        self.inner = inner
        self.reports = reports
    }

    public func next(outputs: [ModelToolOutput]) async throws -> ModelToolTurn {
        let turn = try await inner.next(outputs: outputs)
        guard turn.calls.isEmpty, await reports.report == nil, claimCorrection() else { return turn }
        let retry = try await inner.next(outputs: [], userMessages: [Self.correction])
        return ModelToolTurn(text: [turn.text, retry.text].filter { !$0.isEmpty }.joined(separator: "\n\n"), calls: retry.calls)
    }

    private func claimCorrection() -> Bool {
        lock.withLock {
            guard !corrected else { return false }
            corrected = true
            return true
        }
    }
    public func exportCheckpoint() async throws -> ModelConversationCheckpoint {
        guard let durable = inner as? any DurableModelConversation else { throw ExecutionStoreError.incompatibleCheckpoint }
        var checkpoint = try await durable.exportCheckpoint()
        var extensions = checkpoint.extensions ?? [:]
        extensions["report_corrected"] = try JSONEncoder().encode(lock.withLock { corrected })
        checkpoint.extensions = extensions
        return checkpoint
    }
    public func restoreCheckpoint(_ checkpoint: ModelConversationCheckpoint) async throws {
        guard let durable = inner as? any DurableModelConversation else { throw ExecutionStoreError.incompatibleCheckpoint }
        try await durable.restoreCheckpoint(checkpoint)
        let value = try checkpoint.extensions?["report_corrected"].map { try JSONDecoder().decode(Bool.self, from: $0) } ?? false
        lock.withLock { corrected = value }
    }
}
