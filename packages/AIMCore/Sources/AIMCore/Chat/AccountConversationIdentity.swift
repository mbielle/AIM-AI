import Foundation

/// Identity never depends on a title or a machine. Callers supply the
/// authenticated account; references to each execution machine stay in overview.
public struct AccountConversationIdentity: Hashable, Sendable {
    public let accountID: String
    public let conversationID: String
    public init(accountID: String, conversationID: String) {
        self.accountID = Self.normalized(accountID)
        self.conversationID = Self.normalized(conversationID)
    }
    public static func normalized(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }
    /// Native snapshots are preferred for presentation, without deleting any
    /// Remote reference or initiating any execution during this projection.
    public static func sessions(accountID: String, native: [RemoteSession], remote: [RemoteSession]) -> [RemoteSession] {
        projections(accountID: accountID, native: native, remote: remote).map(\.session)
    }
    public static func projections(accountID: String, native: [RemoteSession], remote: [RemoteSession]) -> [AccountConversationProjection] {
        let groups = Dictionary(grouping: native + remote) { Self(accountID: accountID, conversationID: $0.id) }
        return groups.map { identity, candidates in
            let nativeSession = native.first { matches($0.id, identity.conversationID) }
            let references = remote.filter { matches($0.id, identity.conversationID) }
            let latest = candidates.max { $0.updatedAt < $1.updatedAt }!
            let display = nativeSession ?? latest
            let provenance = candidates.compactMap(\.executionDeviceIDs)
            let response = candidates.compactMap(\.latestResponseVersion).max { $0.completedAt == $1.completedAt ? $0.id < $1.id : $0.completedAt < $1.completedAt }
            let active = candidates.filter { ["running", "generating", "waiting_approval", "pending", "queued"].contains($0.status) && (response == nil || $0.updatedAt > response!.completedAt) }.max { $0.updatedAt < $1.updatedAt }
            let status = active?.status ?? latest.status
            let session = RemoteSession(id: display.id, machineID: display.machineID, mode: display.mode, title: display.title,
                workspace: display.workspace, modelID: display.modelID, approvalMode: display.approvalMode, status: status,
                messageCount: display.messageCount, updatedAt: latest.updatedAt, agentSystem: display.agentSystem, phase: latest.phase,
                isSilent: latest.isSilent, isInterrupted: latest.isInterrupted, pendingApproval: latest.pendingApproval,
                runStartedAt: latest.runStartedAt, isPinned: candidates.contains { $0.isPinned }, archivedAt: display.archivedAt,
                projectID: display.projectID, readState: display.readState, modelProvider: display.modelProvider,
                executionDeviceIDs: provenance.isEmpty ? nil : Array(Set(provenance.flatMap { $0 })).sorted(), latestResponseVersion: response)
            return AccountConversationProjection(identity: identity, session: session, remoteReferences: references)
        }.sorted { $0.session.updatedAt > $1.session.updatedAt }
    }
}

public struct AccountConversationProjection: Identifiable, Equatable, Sendable {
    public let identity: AccountConversationIdentity
    public var id: AccountConversationIdentity { identity }
    public let session: RemoteSession
    public let remoteReferences: [RemoteSession]
}
