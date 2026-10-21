import Foundation
import AIMCore
import GRDB

public struct DraftVisualApproval: Codable, Equatable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var primaryProvider: ChatProvider
    public var primaryModel: String
    public var sources: [NativeChatAttachment]
    public var conversationID: UUID
    public var target: String
    public init(id: UUID, accountID: UUID, primaryProvider: ChatProvider, primaryModel: String, sources: [NativeChatAttachment], conversationID: UUID, target: String) {
        self.id = id; self.accountID = accountID; self.primaryProvider = primaryProvider; self.primaryModel = primaryModel
        self.sources = sources; self.conversationID = conversationID; self.target = target
    }
}

public struct ComposerDraft: Codable, Equatable, Sendable {
    public var text: String
    public var attachments: [TextAttachment]
    public var images: [ImageAttachment]?
    public var visualReport: VisualAnalysisReport?
    public var visualApproval: DraftVisualApproval?
    public init(text: String = "", attachments: [TextAttachment] = [], images: [ImageAttachment]? = nil, visualReport: VisualAnalysisReport? = nil, visualApproval: DraftVisualApproval? = nil) {
        self.text = text; self.attachments = attachments; self.images = images; self.visualReport = visualReport; self.visualApproval = visualApproval
    }
    public var isEmpty: Bool { text.isEmpty && attachments.isEmpty && (images?.isEmpty ?? true) }
}

public enum ComposerDraftError: LocalizedError {
    case tooLarge
    public var errorDescription: String? { "The draft exceeds 1 MB of text. Copy it somewhere safe and shorten it before leaving this conversation." }
}

/// Small, local snapshots only; never used as provider context until explicitly sent.
public final class ComposerDraftStore: Sendable {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }
    public func load(key: String) throws -> ComposerDraft {
        try database.pool.read { db in
            guard let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM composerDrafts WHERE scope = ?", arguments: [key]) else { return ComposerDraft() }
            let draft = try JSONDecoder().decode(ComposerDraft.self, from: bytes)
            try TextAttachment.validate(draft.attachments)
            try ImageAttachment.validate(draft.images ?? [])
            if let pending = draft.visualApproval { for source in pending.sources { try NativeChatAttachment.validate([source]) } }
            guard draft.text.utf8.count <= 1_000_000 else { throw ComposerDraftError.tooLarge }
            return draft
        }
    }
    public func save(_ draft: ComposerDraft, key: String) throws {
        guard draft.text.utf8.count <= 1_000_000 else { throw ComposerDraftError.tooLarge }
        try TextAttachment.validate(draft.attachments)
        try ImageAttachment.validate(draft.images ?? [])
        if let pending = draft.visualApproval { for source in pending.sources { try NativeChatAttachment.validate([source]) } }
        let bytes = try JSONEncoder().encode(draft)
        try database.pool.write { db in
            if draft.isEmpty {
                try db.execute(sql: "DELETE FROM composerDrafts WHERE scope = ?", arguments: [key])
            } else {
                try db.execute(sql: "INSERT INTO composerDrafts(scope, payload) VALUES (?, ?) ON CONFLICT(scope) DO UPDATE SET payload = excluded.payload", arguments: [key, bytes])
            }
        }
    }
    public func removeIfUnchanged(_ draft: ComposerDraft, key: String) throws {
        try database.pool.write { db in
            guard let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM composerDrafts WHERE scope = ?", arguments: [key]),
                  try JSONDecoder().decode(ComposerDraft.self, from: bytes) == draft else { return }
            try db.execute(sql: "DELETE FROM composerDrafts WHERE scope = ?", arguments: [key])
        }
    }
}
