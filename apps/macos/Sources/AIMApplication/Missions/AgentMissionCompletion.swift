import Foundation

/// Called only after the model turn and its run journal have ended normally.
/// Model prose never supplies the success decision; the repository reopens
/// every host evidence target before allowing a verified transition.
public enum AgentMissionCompletion {
    public static func finalizeSuccessfulRun(repository: any AgentMissionRepository,
                                             missionID: UUID, runID: String,
                                             hostChecks: (any MissionHostCheckRunning)? = nil,
                                             workspacePath: String? = nil) async throws -> AgentMission {
        guard var current = try await repository.load(id: missionID),
              current.state == .executing, current.activeRunID == runID else {
            throw AgentMissionError.conflict
        }
        // Command, Web and desktop predicates are observed again now, after the
        // last action; a stale receipt from earlier in the run never counts.
        if let hostChecks {
            for criterion in current.criteria {
                guard let check = criterion.hostCheck else { continue }
                try Task.checkCancellation()
                guard let observation = try? await hostChecks.observe(check, workspacePath: workspacePath),
                      observation.satisfied,
                      let updated = try? await repository.recordHostCheck(missionID: missionID,
                          expectedRevision: current.revision, criterionID: criterion.id,
                          observation: observation, expectedRunID: runID) else { continue }
                current = updated
            }
        }
        if !current.criteria.isEmpty,
           current.criteria.allSatisfy({ $0.evidenceReference != nil }),
           try await repository.pendingInputs(missionID: missionID).isEmpty {
            do {
                return try await repository.transition(missionID: missionID,
                    expectedRevision: current.revision, to: .verified,
                    reason: "Every approved criterion was rechecked against current host file evidence.",
                    activeRunID: nil)
            } catch AgentMissionError.missingEvidence {
                // The target changed or a later action invalidated the receipt.
            } catch AgentMissionError.criterionNotMet {
                // An earlier observation no longer satisfies the check.
            }
        }
        return try await repository.finalizeRun(missionID: missionID,
            expectedRevision: current.revision, runID: runID)
    }
}
