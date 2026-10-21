import AIMAgentKit
import AIMApplication
import Foundation

/// The model may propose a check, but only the host reads the target and
/// records evidence. Defining a criterion always gets an exact user review.
public actor AgentMissionEvidenceToolService: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = [
        "mission_list_criteria", "mission_define_file_criterion", "mission_verify_file_criterion",
        "mission_define_check", "mission_verify_criterion"
    ]
    private let repository: any AgentMissionRepository
    private let checks: any MissionHostCheckRunning
    private let conversationID: UUID
    private let workspacePath: String
    private var boundMissionID: UUID?
    private var boundRunID: String?

    public init(repository: any AgentMissionRepository, conversationID: UUID, workspacePath: String,
                checks: any MissionHostCheckRunning = MissionHostCheckRunner()) {
        self.repository = repository
        self.checks = checks
        self.conversationID = conversationID
        self.workspacePath = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Bind after the run has entered its executing state. A delayed call from
    /// an older run must never write evidence into the conversation's next mission.
    public func bind(missionID: UUID, runID: String) throws {
        guard boundMissionID == nil, boundRunID == nil, UUID(uuidString: runID) != nil else {
            throw AgentMissionError.invalidTransition
        }
        boundMissionID = missionID
        boundRunID = runID
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard request.workspacePath == workspacePath,
                  let boundMissionID, let boundRunID,
                  let mission = try await repository.load(id: boundMissionID),
                  mission.conversationID == conversationID,
                  mission.state == .executing,
                  mission.activeRunID == boundRunID,
                  try await repository.latest(conversationID: conversationID)?.id == boundMissionID else {
                throw AgentMissionError.invalidTransition
            }
            switch request.name {
            case "mission_list_criteria":
                let items = mission.criteria.map { criterion in
                    ["id": criterion.id.uuidString,
                     "description": criterion.description,
                     "kind": criterion.hostCheck?.kind.rawValue ?? (criterion.fileCheck == nil ? "unverifiable" : "file"),
                     "check": criterion.hostCheck?.summary ?? criterion.fileCheck?.relativePath ?? "",
                     "receipt_recorded": criterion.verifiedAt == nil ? "false" : "true"]
                }
                let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
                return ToolResult(requestID: request.id, content: String(decoding: data, as: UTF8.self))
            case "mission_define_file_criterion":
                guard let description = request.arguments["description"],
                      let path = request.arguments["path"] else { throw AgentMissionError.invalidInput }
                let check = MissionFileCheck(relativePath: path,
                    requiredText: request.arguments["required_text"])
                let updated = try await repository.appendFileCriterion(missionID: mission.id,
                    expectedRevision: mission.revision, description: description, check: check)
                guard let criterion = updated.criteria.last else { throw AgentMissionError.conflict }
                return ToolResult(requestID: request.id,
                    content: "Criterion \(criterion.id.uuidString) recorded for \(path). This is a proposed success condition, not proof; call mission_verify_file_criterion after the file is ready.",
                    metadata: ["criterion_id": criterion.id.uuidString])
            case "mission_verify_file_criterion":
                guard let raw = request.arguments["criterion_id"],
                      let id = UUID(uuidString: raw) else { throw AgentMissionError.invalidInput }
                let updated = try await repository.verifyFileCriterion(missionID: mission.id,
                    expectedRevision: mission.revision, criterionID: id,
                    workspacePath: workspacePath, expectedRunID: boundRunID)
                guard updated.criteria.contains(where: { $0.id == id }),
                      let evidence = try await repository.fileEvidence(missionID: mission.id,
                                                                       criterionID: id) else {
                    throw AgentMissionError.missingEvidence
                }
                return ToolResult(requestID: request.id,
                    content: "Host verified criterion \(id.uuidString) from \(evidence.relativePath): \(evidence.byteCount) bytes. Receipt \(evidence.id.uuidString) is stored locally; the file digest is not sent to the model. This is a point-in-time check; mission success is decided only after all criteria are rechecked.",
                    metadata: ["criterion_id": id.uuidString, "evidence_id": evidence.id.uuidString,
                               "action_outcome": ActionOutcome.confirmed.rawValue])
            case "mission_define_check":
                guard let description = request.arguments["description"] else { throw AgentMissionError.invalidInput }
                let check = try Self.hostCheck(request.arguments)
                let updated = try await repository.appendHostCriterion(missionID: mission.id,
                    expectedRevision: mission.revision, description: description, check: check)
                guard let criterion = updated.criteria.last else { throw AgentMissionError.conflict }
                return ToolResult(requestID: request.id,
                    content: "Criterion \(criterion.id.uuidString) recorded: \(check.summary). This is a proposed success condition, not proof; call mission_verify_criterion once the work is done. AIM observes it again before declaring the mission verified.",
                    metadata: ["criterion_id": criterion.id.uuidString])
            case "mission_verify_criterion":
                guard let raw = request.arguments["criterion_id"], let id = UUID(uuidString: raw),
                      let criterion = mission.criteria.first(where: { $0.id == id }) else {
                    throw AgentMissionError.invalidInput
                }
                if criterion.fileCheck != nil {
                    var forwarded = request
                    forwarded.name = "mission_verify_file_criterion"
                    return await execute(forwarded)
                }
                guard let check = criterion.hostCheck else { throw AgentMissionError.invalidInput }
                let observation = try await checks.observe(check, workspacePath: workspacePath)
                guard observation.satisfied else {
                    return ToolResult(requestID: request.id,
                        content: "Not satisfied: \(observation.summary). No receipt was recorded.", isError: true,
                        metadata: ["criterion_id": id.uuidString, "action_outcome": ActionOutcome.suspectedAbsent.rawValue])
                }
                _ = try await repository.recordHostCheck(missionID: mission.id, expectedRevision: mission.revision,
                    criterionID: id, observation: observation, expectedRunID: boundRunID)
                return ToolResult(requestID: request.id,
                    content: "Host verified criterion \(id.uuidString): \(observation.summary). This is a point-in-time check; AIM observes it again before the mission can be verified.",
                    metadata: ["criterion_id": id.uuidString, "action_outcome": ActionOutcome.confirmed.rawValue])
            default:
                throw AgentMissionError.invalidInput
            }
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    /// Builds a host check from typed tool arguments; `command` is a JSON array argv.
    static func hostCheck(_ arguments: [String: String]) throws -> MissionHostCheck {
        guard let rawKind = arguments["kind"], let kind = MissionHostCheck.Kind(rawValue: rawKind) else {
            throw AgentMissionError.invalidInput
        }
        let timeout = try arguments["timeout_seconds"].map { value -> Int in
            guard let seconds = Int(value) else { throw AgentMissionError.invalidInput }
            return seconds
        }
        let check: MissionHostCheck
        switch kind {
        case .command:
            guard let raw = arguments["command"], let data = raw.data(using: .utf8),
                  let argv = try? JSONDecoder().decode([String].self, from: data), let first = argv.first else {
                throw AgentMissionError.invalidInput
            }
            let executable = first.hasPrefix("/") ? first : Self.resolve(first)
            guard let executable else { throw AgentMissionError.invalidInput }
            let exitCode = try arguments["expected_exit_code"].map { value -> Int in
                guard let code = Int(value) else { throw AgentMissionError.invalidInput }
                return code
            }
            check = MissionHostCheck(kind: .command, executable: executable, arguments: Array(argv.dropFirst()),
                expectedExitCode: exitCode ?? 0, requiredText: arguments["required_text"], timeoutSeconds: timeout)
        case .web:
            check = MissionHostCheck(kind: .web, url: arguments["url"], requiredText: arguments["required_text"],
                timeoutSeconds: timeout)
        case .desktop:
            check = MissionHostCheck(kind: .desktop, bundleID: arguments["bundle_id"],
                windowTitleContains: arguments["window_title_contains"], requiredText: arguments["required_text"],
                timeoutSeconds: timeout)
        }
        guard check.isValid else { throw AgentMissionError.invalidInput }
        return check
    }

    /// Resolves a bare program name on the standard search path at definition time,
    /// so the approved check names one exact executable.
    /// Public resolver for user-entered program names (connectors, checks).
    public nonisolated static func resolveProgram(_ name: String) -> String? { resolve(name) }

    static func resolve(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
