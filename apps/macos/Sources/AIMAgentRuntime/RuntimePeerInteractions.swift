import AIMAgentKit
import AIMApplication
import AIMMacPlatform
import CryptoKit
import Foundation

/// Presentation routes never grant rights. Every decision returns to the paired
/// worker's exact broker; receipts are written only after its confirmed ACK.
package actor RuntimePeerInteractions {
    private struct Scope: Sendable { let child: DurableSubagent; let conversationID: UUID }
    private struct Receipt: Codable {
        var version = 1
        let childID: UUID
        let parentExecutionID: UUID
        let conversationID: UUID
        let digest: String
    }
    private var scopes: [UUID: Scope] = [:]
    package func collect(_ execution: AgentExecution, children: [DurableSubagent]) async -> ContinuityInteractions {
        for child in children where child.remoteAssignment != nil {
            scopes[child.id] = Scope(child: child, conversationID: execution.conversationID)
        }
        let active = children.filter { $0.remoteAssignment != nil && !$0.state.isTerminal }
        let replies = await withTaskGroup(of: (UUID, ContinuityInteractions?).self) { group in
            // Bound transport concurrency, without truncating the mission graph.
            var remaining = active.makeIterator()
            for _ in 0..<min(3, active.count) {
                if let child = remaining.next() { group.addTask { (child.id, try? await RuntimePeerWorkerRegistry.shared.interactions(child)) } }
            }
            var replies: [(UUID, ContinuityInteractions)] = []
            for await (id, reply) in group {
                if let reply { replies.append((id, reply)) }
                if let child = remaining.next() { group.addTask { (child.id, try? await RuntimePeerWorkerRegistry.shared.interactions(child)) } }
            }
            return replies
        }
        var approvals: [PendingToolApproval] = []; var questions: [AgentQuestion] = []
        for (childID, reply) in replies {
            guard let scope = scopes[childID], let placement = scope.child.remoteAssignment else { continue }
            approvals += reply.approvals.filter { $0.sessionID == childID }.map {
                PendingToolApproval(id: $0.id, sessionID: childID, toolName: $0.toolName, arguments: $0.arguments,
                    workspacePath: $0.workspacePath, risk: $0.risk, allowsSessionDecision: false,
                    review: $0.review, priorUncertainAction: $0.priorUncertainAction)
            }
            questions += reply.questions.filter { $0.conversationID == placement.remoteConversationID && $0.id.utf8.count <= 2048 }.map {
                AgentQuestion(id: Self.questionID(childID: childID, original: $0.id), conversationID: execution.conversationID, items: $0.items)
            }
        }
        return ContinuityInteractions(approvals: approvals, questions: questions)
    }
    package func approve(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool {
        guard decision != .allowForSession, decision != .allowAlways, let scope = scopes[sessionID] else { return false }
        do {
            try await RuntimePeerWorkerRegistry.shared.approve(scope.child, id: id, sessionID: sessionID, decision: decision)
            try save(scope, value: "approval:" + id.uuidString + ":" + decision.rawValue)
            return true
        } catch { return false }
    }
    package func answer(id: String, text: String) async -> Bool {
        guard let (childID, original) = Self.parseQuestionID(id), let scope = scopes[childID] else { return false }
        do {
            try await RuntimePeerWorkerRegistry.shared.answer(scope.child, id: original, text: text)
            try save(scope, value: "question:" + original + ":" + Self.hash(Data(text.utf8)))
            return true
        } catch { return false }
    }
    package func approvalReceipt(id: UUID, sessionID: UUID, decision: ApprovalDecision) async -> Bool {
        guard decision != .allowForSession, decision != .allowAlways, let scope = scopes[sessionID] else { return false }
        return await receipt(scope, value: "approval:" + id.uuidString + ":" + decision.rawValue)
    }
    package func questionReceipt(id: String, conversationID: UUID, text: String) async -> Bool {
        guard let (childID, original) = Self.parseQuestionID(id), let scope = scopes[childID], scope.conversationID == conversationID else { return false }
        return await receipt(scope, value: "question:" + original + ":" + Self.hash(Data(text.utf8)))
    }
    private func receipt(_ scope: Scope, value: String) async -> Bool {
        do {
            let digest = Self.hash(Data(value.utf8)), file = try file(scope, digest: digest)
            let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 4096 else { return false }
            let stored = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file))
            guard stored.version == 1, stored.childID == scope.child.id, stored.parentExecutionID == scope.child.parentExecutionID,
                  stored.conversationID == scope.conversationID, stored.digest == digest else { return false }
            return await RuntimePeerWorkerRegistry.shared.authorized(scope.child)
        } catch { return false }
    }
    private func save(_ scope: Scope, value: String) throws {
        let digest = Self.hash(Data(value.utf8)), path = try file(scope, digest: digest)
        let receipt = Receipt(childID: scope.child.id, parentExecutionID: scope.child.parentExecutionID, conversationID: scope.conversationID, digest: digest)
        try JSONEncoder().encode(receipt).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    private func file(_ scope: Scope, digest: String) throws -> URL {
        let directory = try ApplicationPaths().applicationSupport.appending(path: "RemotePeerInteractions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw ExecutionStoreError.incompatibleCheckpoint }
        return directory.appendingPathComponent(scope.child.parentExecutionID.uuidString + "-" + scope.child.id.uuidString + "-" + digest + ".json")
    }
    private static func questionID(childID: UUID, original: String) -> String {
        "peer:" + childID.uuidString + ":" + Data(original.utf8).base64EncodedString()
    }
    private static func parseQuestionID(_ raw: String) -> (UUID, String)? {
        guard raw.utf8.count <= 4096 else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, parts[0] == "peer", let id = UUID(uuidString: String(parts[1])),
              let bytes = Data(base64Encoded: String(parts[2])), let text = String(data: bytes, encoding: .utf8) else { return nil }
        return (id, text)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
