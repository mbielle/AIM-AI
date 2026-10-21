import Foundation
import AIMApplication
import CryptoKit

public struct PendingToolApproval: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let toolName: String
    public let arguments: [String: String]
    public let workspacePath: String?
    public let risk: ToolRisk
    public let allowsSessionDecision: Bool
    public let review: ToolReview?
    public let priorUncertainAction: Bool
    /// The action type shown as the card's header; nil in approvals recorded before it existed.
    public let category: ToolApprovalCategory?
    /// True when "Always allow" and "Allow this conversation" may cover the whole category.
    public let allowsStandingDecision: Bool?
    /// Why Auto's safety check asks the person about this action.
    public let safetyNote: String?
    public init(id: UUID, sessionID: UUID, toolName: String, arguments: [String: String], workspacePath: String?, risk: ToolRisk,
                allowsSessionDecision: Bool, review: ToolReview?, priorUncertainAction: Bool,
                category: ToolApprovalCategory? = nil, allowsStandingDecision: Bool? = nil, safetyNote: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.toolName = toolName; self.arguments = arguments
        self.workspacePath = workspacePath; self.risk = risk; self.allowsSessionDecision = allowsSessionDecision
        self.review = review; self.priorUncertainAction = priorUncertainAction
        self.category = category; self.allowsStandingDecision = allowsStandingDecision; self.safetyNote = safetyNote
    }

    /// Whether a decision is offered for this approval.
    public func accepts(_ decision: ApprovalDecision) -> Bool {
        switch decision {
        case .allowOnce, .deny: true
        case .allowForSession: allowsSessionDecision || allowsStandingDecision == true
        case .allowAlways: allowsStandingDecision == true && category != nil
        }
    }
}

/// Stores decisions for exact tool/arguments/workspace combinations and, where the dispatcher
/// allows it, for a whole action type: in one conversation, or everywhere ("Always allow").
public actor ToolApprovalBroker {
    private struct Grant: Hashable {
        let sessionID: UUID
        let name: String
        let arguments: [String: String]
        let workspace: String?
        let risk: ToolRisk
    }
    private struct Pending {
        let approval: PendingToolApproval
        let grant: Grant
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var pending: [UUID: Pending] = [:]
    private var grants: Set<Grant> = []
    private struct CategoryGrant: Hashable { let sessionID: UUID; let key: String }
    private var categoryGrants: Set<CategoryGrant> = []
    private var closedSessions: Set<UUID> = []
    private var subscribers: [UUID: AsyncStream<[PendingToolApproval]>.Continuation] = [:]
    private let persistence: AgentInteractionStore?
    public init(persistence: AgentInteractionStore? = nil) { self.persistence = persistence }
    public func reopen(sessionID: UUID) { closedSessions.remove(sessionID) }

    /// True when a standing decision already covers this category in this session.
    public func isAllowed(category: ToolApprovalCategory, sessionID: UUID) -> Bool {
        categoryGrants.contains(CategoryGrant(sessionID: sessionID, key: category.key)) || AlwaysAllowedActions.contains(category.key)
    }

    /// `category` is the action type shown to the person; `standing` lets a decision cover it all.
    public func request(_ request: ToolRequest, sessionID: UUID, allowsSessionDecision: Bool,
                        review: ToolReview? = nil, priorUncertainAction: Bool = false,
                        category: ToolApprovalCategory? = nil, standing: Bool = false, safetyNote: String? = nil) async -> Bool {
        guard !Task.isCancelled, !closedSessions.contains(sessionID) else { return false }
        let grant = Grant(sessionID: sessionID, name: request.name, arguments: request.arguments, workspace: request.workspacePath, risk: request.risk)
        if allowsSessionDecision && grants.contains(grant) { return true }
        if standing, let category, isAllowed(category: category, sessionID: sessionID) { return true }
        guard pending.count < 32 else { return false }
        var computedID = UUID()
        if persistence != nil {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let data = (try? encoder.encode(request)) ?? Data()
            let reviewData = (try? encoder.encode(review)) ?? Data()
            let digest = SHA256.hash(data: Data(sessionID.uuidString.utf8) + data + reviewData)
                .prefix(16).map { String(format: "%02x", $0) }.joined()
            let chars = Array(digest)
            let value = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
            guard let stable = UUID(uuidString: value) else { return false }; computedID = stable
        }
        let id = computedID
        let approval = PendingToolApproval(id: id, sessionID: sessionID, toolName: request.name,
            arguments: request.arguments, workspacePath: request.workspacePath, risk: request.risk,
            allowsSessionDecision: allowsSessionDecision, review: review,
            priorUncertainAction: priorUncertainAction, category: category,
            allowsStandingDecision: standing && category != nil, safetyNote: safetyNote)
        if let persistence {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                if let response = try persistence.register(id: id.uuidString, kind: "approval", sessionID: sessionID,
                                                           payload: encoder.encode(approval)) {
                    let decision = try JSONDecoder().decode(ApprovalDecision.self, from: response)
                    guard approval.accepts(decision) else { return false }
                    // A replayed answer restores this conversation's grant; the global list is
                    // already saved (and may have been revoked since), so it is not rewritten.
                    remember(decision == .allowAlways ? .allowForSession : decision, approval: approval, grant: grant)
                    return decision != .deny
                }
            } catch { return false }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                pending[id] = Pending(approval: approval, grant: grant, continuation: continuation)
                publish()
            }
        } onCancel: {
            Task { await self.reject(id) }
        }
    }

    @discardableResult public func decide(id: UUID, sessionID: UUID, decision: ApprovalDecision) -> Bool {
        guard let item = pending[id], item.approval.sessionID == sessionID else { return false }
        guard item.approval.accepts(decision) else { return false }
        if let persistence {
            do { try persistence.answer(id: id.uuidString, sessionID: sessionID, response: JSONEncoder().encode(decision)) }
            catch { return false }
        }
        pending.removeValue(forKey: id)
        remember(decision, approval: item.approval, grant: item.grant)
        item.continuation.resume(returning: decision != .deny)
        publish()
        return true
    }

    private func remember(_ decision: ApprovalDecision, approval: PendingToolApproval, grant: Grant) {
        guard decision == .allowForSession || decision == .allowAlways else { return }
        if approval.allowsStandingDecision == true, let category = approval.category {
            categoryGrants.insert(CategoryGrant(sessionID: approval.sessionID, key: category.key))
            if decision == .allowAlways { AlwaysAllowedActions.add(category) }
        } else if approval.allowsSessionDecision { grants.insert(grant) }
    }

    public func close(sessionID: UUID) {
        closedSessions.insert(sessionID)
        grants = grants.filter { $0.sessionID != sessionID }
        categoryGrants = categoryGrants.filter { $0.sessionID != sessionID }
        let ids = pending.filter { $0.value.approval.sessionID == sessionID }.map(\.key)
        for id in ids { reject(id) }
    }

    public func updates() -> AsyncStream<[PendingToolApproval]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    public func snapshot() -> [PendingToolApproval] {
        pending.values.map(\.approval).sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func matchesReceipt(id: UUID, sessionID: UUID, decision: ApprovalDecision) -> Bool {
        guard let persistence else { return false }
        return (try? persistence.matchesResponse(id: id.uuidString, kind: "approval", sessionID: sessionID,
                                                 response: JSONEncoder().encode(decision))) == true
    }
    private func reject(_ id: UUID) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.continuation.resume(returning: false)
        publish()
    }
    private func publish() { for subscriber in subscribers.values { subscriber.yield(snapshot()) } }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}
