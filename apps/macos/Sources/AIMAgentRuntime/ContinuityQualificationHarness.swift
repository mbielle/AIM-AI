import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import Darwin
import Foundation

/// Debug-only, isolated coordinator endurance. Does not access accounts, Keychain,
/// the production database, desktop, Remote or the live LaunchAgent registration.
package enum ContinuityQualificationHarness {
    private struct Manifest: Codable {
        var startedAt: Date
        var deadline: Date
        var commandID: UUID
        var conversationID: UUID
    }
    private struct Report: Codable {
        var qualification = "simulated-provider-coordinator-real-clock"
        var status: String
        var startedAt: Date
        var sampledAt: Date
        var elapsedSeconds: Double
        var tickCount: Int
        var maximumTickGapSeconds: Double
        var executionID: UUID
        var state: ExecutionState
        var simulatedModelCalls: Int
        var pendingDeliveries: Int
        var limitations = ["No paid model", "No signed NSXPC or SMAppService qualification", "No desktop or physical iPhone qualification"]
    }
    private actor Driver: ContinuityTurnDriving {
        let deadline: Date
        init(deadline: Date) { self.deadline = deadline }
        func run(_ request: AgentRequest, context: RuntimeExecutionContext,
                 event: @escaping @Sendable (EngineEvent) async throws -> Void) async throws -> ContinuityTurnOutcome {
            let calls = try await context.repository.latestEvents(context.executionID, kind: "fixtureModelCall", limit: 1000)
            try await context.repository.recordEvent(context.executionID, owner: context.owner, kind: "fixtureModelCall", payload: Data())
            if calls.isEmpty {
                return .wait(WakeCondition(executionID: context.executionID, kind: .deadline, key: "endurance", dueAt: deadline))
            }
            guard calls.count == 1, Date.now >= deadline else { throw ExecutionStoreError.invalidTransition }
            return .completed(result: Data("Simulated provider result delivered.".utf8))
        }
        func cancel(conversationID: UUID) async {}
    }

    package static func run(directory: URL, duration: TimeInterval, interval: TimeInterval = 30) async throws {
        guard duration.isFinite, duration > 0, interval.isFinite, interval >= 0.1 else { throw ExecutionStoreError.invalidTransition }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        // A qualification invocation can never point at a user database.
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp").standardizedFileURL.resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent().path == temporaryRoot.path,
              directory.lastPathComponent.hasPrefix("aim-continuity-qualification-") else { throw ExecutionStoreError.invalidTransition }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifestURL = directory.appending(path: "manifest.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest: Manifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } else {
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw ExecutionStoreError.invalidTransition }
            manifest = Manifest(startedAt: .now, deadline: .now.addingTimeInterval(duration), commandID: UUID(), conversationID: UUID())
            try save(encoder.encode(manifest), to: manifestURL)
        }
        let lease = try RuntimeLease(url: directory.appending(path: "runtime.lock")); defer { lease.release() }
        let database = try AIMDatabase(path: directory.appending(path: "qualification.sqlite").path)
        let conversations = SQLiteConversationRepository(database: database)
        if try await conversations.conversation(id: manifest.conversationID) == nil {
            try await conversations.save(Conversation(id: manifest.conversationID, title: "Isolated endurance", mode: .agent))
        }
        let repository = SQLiteAgentExecutionRepository(database: database,
            artifacts: try ExecutionArtifactStore(directory: directory.appending(path: "artifacts")))
        let coordinator = RunCoordinator(repository: repository, driver: Driver(deadline: manifest.deadline), lease: lease, authorized: { _ in true })
        try await coordinator.start()
        let request = AgentRequest(conversationID: manifest.conversationID, text: "Wait, then deliver a qualitative fixture result.", modelID: "simulated-only", mode: .agent, workspaceToolsEnabled: true)
        let admitted = try await coordinator.admit(commandID: manifest.commandID, accountID: nil, request: request)
        var previous = Date.now, ticks = 0, maximumGap: TimeInterval = 0
        let reportURL = directory.appending(path: "report.json")
        let previousReport = try? JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL))
        if let previousReport {
            ticks = previousReport.tickCount; maximumGap = previousReport.maximumTickGapSeconds
            previous = previousReport.sampledAt
        }
        while !Task.isCancelled {
            let now = Date.now
            maximumGap = max(maximumGap, now.timeIntervalSince(previous)); previous = now; ticks += 1
            try await coordinator.tick(at: now)
            let execution = try await coordinator.snapshot(admitted.id)
            guard let execution else { throw ExecutionStoreError.notFound }
            let calls = try await repository.latestEvents(execution.id, kind: "fixtureModelCall", limit: 1000).count
            let deliveries = try await repository.pendingDeliveries().filter { $0.executionID == execution.id }.count
            let status = execution.state == .accepted && calls == 2 && deliveries == 1 ? "passed" :
                [.blocked, .failed, .cancelled, .paused].contains(execution.state) || calls > 2 ? "failed" : "running"
            try save(encoder.encode(Report(status: status, startedAt: manifest.startedAt, sampledAt: now,
                elapsedSeconds: now.timeIntervalSince(manifest.startedAt), tickCount: ticks, maximumTickGapSeconds: maximumGap,
                executionID: execution.id, state: execution.state, simulatedModelCalls: calls, pendingDeliveries: deliveries)), to: reportURL)
            if status == "passed" { try await coordinator.shutdown(); return }
            if status == "failed" { try await coordinator.shutdown(); throw ExecutionStoreError.invalidTransition }
            try await Task.sleep(for: .seconds(now >= manifest.deadline ? 0.1 : min(interval, manifest.deadline.timeIntervalSince(now))))
        }
        try await coordinator.shutdown()
    }
    private static func save(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
