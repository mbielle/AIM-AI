import Foundation

/// Identity of a completed answer. Titles, projects and synchronization dates are not response versions.
public struct ConversationResponseVersion: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var completedAt: Date
    public init(id: String, completedAt: Date) { self.id = AccountConversationIdentity.normalized(id); self.completedAt = completedAt }
}

public struct ConversationReadReceipt: Codable, Equatable, Sendable {
    public var conversationID: String
    public var responseIDs: Set<String>
    public init(conversationID: String, responseIDs: Set<String> = []) {
        self.conversationID = AccountConversationIdentity.normalized(conversationID)
        self.responseIDs = Set(responseIDs.map(AccountConversationIdentity.normalized))
    }
    public func merging(_ other: Self) -> Self {
        guard conversationID == other.conversationID else { return self }
        return .init(conversationID: conversationID, responseIDs: responseIDs.union(other.responseIDs))
    }
}

/// A grow-only acknowledgement set avoids clock comparisons and never acknowledges a future answer.
public struct ConversationReadReceipts: Codable, Equatable, Sendable {
    public var receipts: [String: ConversationReadReceipt] = [:]
    public init() {}
    public func contains(conversationID: String, response: ConversationResponseVersion?) -> Bool {
        guard let response else { return false }
        return receipts[AccountConversationIdentity.normalized(conversationID)]?.responseIDs.contains(response.id) == true
    }
    public mutating func acknowledge(conversationID: String, response: ConversationResponseVersion) {
        let key = AccountConversationIdentity.normalized(conversationID)
        var receipt = receipts[key] ?? .init(conversationID: key)
        receipt.responseIDs.insert(response.id); receipts[key] = receipt
    }
    public func merging(_ other: Self) -> Self {
        var value = self
        for (key, receipt) in other.receipts { value.receipts[key] = value.receipts[key]?.merging(receipt) ?? receipt }
        return value
    }
}

public enum ConversationActivityState: String, Codable, Sendable {
    case idle, running, waiting, unread, failed
    public static func resolve(status: String, latestResponse: ConversationResponseVersion?, read: Bool) -> Self {
        switch status.lowercased() {
        case "running", "generating", "queued", "pending": return .running
        case "waiting", "waiting_approval", "waiting_input": return .waiting
        case "error", "failed": return .failed
        default: return latestResponse != nil && !read ? .unread : .idle
        }
    }
}

/// Optional metadata carried inside the existing encrypted phase column. Plain legacy phases still decode.
public struct RemoteConversationAnnouncement: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var phase: String?
    public var executionDeviceIDs: [String]?
    public var latestResponseVersion: ConversationResponseVersion?
    public init(phase: String?, executionDeviceIDs: [String]?, latestResponseVersion: ConversationResponseVersion?) {
        self.phase = phase; self.executionDeviceIDs = executionDeviceIDs; self.latestResponseVersion = latestResponseVersion
    }
    private static let prefix = "aim-continuity-v1:"
    public func encodedPhase() -> String? {
        guard executionDeviceIDs != nil || latestResponseVersion != nil else { return phase }
        guard let bytes = try? JSONEncoder().encode(self) else { return phase }
        return Self.prefix + String(decoding: bytes, as: UTF8.self)
    }
    public static func decode(phase: String?) -> Self {
        guard let phase, phase.hasPrefix(prefix), let value = try? JSONDecoder().decode(Self.self, from: Data(phase.dropFirst(prefix.count).utf8)), value.version == 1 else {
            return .init(phase: phase, executionDeviceIDs: nil, latestResponseVersion: nil)
        }
        return value
    }
}

/// Revision-checked monotone merge in an existing account document; a failed sync keeps local acknowledgements.
public enum ConversationReadReceiptSync {
    public static let documentID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C104")!
    public static func synchronize(_ local: ConversationReadReceipts, accountID: UUID, service: any AccountContentSyncing,
                                   currentAccount: @Sendable () async -> UUID?) async throws -> ConversationReadReceipts {
        var merged = local
        for attempt in 0..<3 {
            guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
            let documents = try await service.documents(accountID: accountID)
            guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
            let doc = documents.first { $0.id == documentID && !$0.deleted }
            if let doc {
                // Never overwrite an unrecognized document with an empty receipt set.
                let remote = try JSONDecoder().decode(ConversationReadReceipts.self, from: Data(doc.payload.utf8))
                merged = merged.merging(remote)
                if merged == remote { return merged }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let payload = String(decoding: try encoder.encode(merged), as: UTF8.self)
            do {
                guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
                _ = try await service.save(.init(id: documentID, kind: "preferences", payload: payload, revision: doc?.revision ?? 0), accountID: accountID)
                guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
                return merged
            } catch AccountServiceError.conflict where attempt < 2 { continue }
        }
        throw AccountServiceError.conflict
    }
}
