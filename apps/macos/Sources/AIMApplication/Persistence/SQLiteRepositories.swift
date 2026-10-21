import AIMCore
import Foundation
import GRDB

private struct ConversationRecord: Codable, FetchableRecord, PersistableRecord {
    var provider: String?
    var modelID: String?
    var workspacePath: String?
    static let databaseTableName = "conversations"
    var id: String
    var title: String
    var mode: String
    var projectID: String?
    var engineID: String?
    var isArchived: Bool
    var pinnedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(_ value: Conversation) {
        provider = value.provider?.rawValue
        modelID = value.modelID
        workspacePath = value.workspacePath
        id = value.id.uuidString
        title = value.title
        mode = value.mode.rawValue
        projectID = value.projectID?.uuidString
        engineID = value.engineID
        isArchived = value.isArchived
        pinnedAt = value.pinnedAt
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }

    var value: Conversation? {
        guard let id = UUID(uuidString: id), let mode = AIMMode(rawValue: mode) else { return nil }
        return Conversation(
            id: id,
            title: title,
            mode: mode,
            projectID: projectID.flatMap(UUID.init(uuidString:)),
            engineID: engineID,
            isArchived: isArchived,
            pinnedAt: pinnedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            provider: provider.flatMap(ChatProvider.init(rawValue:)),
            modelID: modelID,
            workspacePath: workspacePath
        )
    }
}

private struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"
    var id: String
    var conversationID: String
    var role: String
    var content: String
    var sequence: Int
    var createdAt: Date
    var attachmentsJSON: Data?
    var imagesJSON: Data?
    var completionStatus: String?
    var videosJSON: Data?
    var actionsJSON: Data?
    var visualReportJSON: Data?

    init(_ value: ConversationMessage) throws {
        try TextAttachment.validate(value.attachments ?? [])
        try ImageAttachment.validate(value.images ?? [])
        attachmentsJSON = try value.attachments.map { try JSONEncoder().encode($0) }
        imagesJSON = try value.images.map { try JSONEncoder().encode($0) }
        if value.sources != nil || value.routeAttempts != nil || value.timeline != nil { visualReportJSON = try JSONEncoder().encode(MessagePresentationMetadata(visualReport: value.visualReport, sources: value.sources, routeAttempts: value.routeAttempts, timeline: value.timeline)) }
        else { visualReportJSON = try value.visualReport.map { try JSONEncoder().encode($0) } }
        actionsJSON = try value.actions.map { try JSONEncoder().encode($0) }
        videosJSON = try value.videos.map { try JSONEncoder().encode($0) }
        completionStatus = value.completionStatus?.rawValue
        id = value.id.uuidString
        conversationID = value.conversationID.uuidString
        role = value.role.rawValue
        content = value.content
        sequence = value.sequence
        createdAt = value.createdAt
    }

    func decodedValue() throws -> ConversationMessage? {
        guard
            let id = UUID(uuidString: id),
            let conversationID = UUID(uuidString: conversationID),
            let role = MessageRole(rawValue: role)
        else { return nil }
        let attachments = try attachmentsJSON.map { try JSONDecoder().decode([TextAttachment].self, from: $0) }
        let images = try imagesJSON.map { try JSONDecoder().decode([ImageAttachment].self, from: $0) }
        let decodedCompletion = completionStatus.flatMap(AssistantCompletionStatus.init(rawValue:))
        guard completionStatus == nil || decodedCompletion != nil else { throw MessageRecordError.unknownCompletion }
        try TextAttachment.validate(attachments ?? [])
        try ImageAttachment.validate(images ?? [])
        // An unreadable video list never hides the message itself.
        let videos = videosJSON.flatMap { try? JSONDecoder().decode([VideoAttachment].self, from: $0) }
        return ConversationMessage(id: id, conversationID: conversationID, role: role, content: content, sequence: sequence, createdAt: createdAt, attachments: attachments, images: images,
                                   completionStatus: decodedCompletion, videos: videos, actions: actionsJSON.flatMap { try? JSONDecoder().decode([ConversationAction].self, from: $0) }, visualReport: visualReportJSON.flatMap { (try? JSONDecoder().decode(MessagePresentationMetadata.self, from: $0))?.visualReport ?? (try? JSONDecoder().decode(VisualAnalysisReport.self, from: $0)) }, sources: visualReportJSON.flatMap { (try? JSONDecoder().decode(MessagePresentationMetadata.self, from: $0))?.sources }, routeAttempts: visualReportJSON.flatMap { (try? JSONDecoder().decode(MessagePresentationMetadata.self, from: $0))?.routeAttempts }, timeline: visualReportJSON.flatMap { (try? JSONDecoder().decode(MessagePresentationMetadata.self, from: $0))?.timeline })
    }
}

private struct MessagePresentationMetadata: Codable {
    var visualReport: VisualAnalysisReport?
    var sources: [ConversationSource]?
    var routeAttempts: [ConversationRouteAttempt]?
    var timeline: TurnTimeline?
}

private enum MessageRecordError: Error { case unknownCompletion }

public actor SQLiteConversationRepository: ConversationRepository {
    private let database: AIMDatabase

    public init(database: AIMDatabase) { self.database = database }

    public func list(includeArchived: Bool) throws -> [Conversation] {
        try database.pool.read { db in
            var request = ConversationRecord.order(Column("updatedAt").desc)
            if !includeArchived { request = request.filter(Column("isArchived") == false) }
            return try request.fetchAll(db).compactMap(\.value)
        }
    }

    public func conversation(id: UUID) throws -> Conversation? {
        try database.pool.read { db in try ConversationRecord.fetchOne(db, key: id.uuidString)?.value }
    }

    public func save(_ conversation: Conversation) throws {
        try database.pool.write { db in
            try ConversationRecord(conversation).save(db)
            try db.execute(
                sql: "DELETE FROM conversationSearch WHERE conversationID = ?",
                arguments: [conversation.id.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO conversationSearch(conversationID, title, content) VALUES (?, ?, (SELECT COALESCE(group_concat(content, ' '), '') FROM messages WHERE conversationID = ?))",
                arguments: [conversation.id.uuidString, conversation.title, conversation.id.uuidString]
            )
        }
    }

    /// Sync text without deleting local metadata, attachments, archives or tool history.
    public func mergePlainChat(_ snapshot: NativeChatConversation) throws {
        for message in snapshot.messages {
            try NativeChatAttachment.validate(message.attachments ?? [])
            guard message.role == .user || (message.attachments ?? []).isEmpty else { throw AccountServiceError.conflict }
        }
        try database.pool.write { db in
            let existing = try ConversationRecord.fetchOne(db, key: snapshot.id.uuidString)?.value
            guard existing == nil || existing?.mode == .chat else { throw AccountServiceError.conflict }
            let original = try MessageRecord.filter(Column("conversationID") == snapshot.id.uuidString).fetchAll(db).compactMap { try $0.decodedValue() }
            guard original.allSatisfy({ ($0.role == .user || $0.role == .assistant) && ($0.videos ?? []).isEmpty }) else { throw AccountServiceError.conflict }
            let incomingIDs = Set(snapshot.messages.map(\.id))
            guard incomingIDs.count == snapshot.messages.count,
                  Set(original.map(\.id)).isSubset(of: incomingIDs) else { throw AccountServiceError.conflict }
            var conversation = existing ?? Conversation(id: snapshot.id, title: snapshot.title, mode: .chat)
            conversation.title = snapshot.title; conversation.provider = snapshot.provider; conversation.modelID = snapshot.modelID
            conversation.projectID = snapshot.projectID.flatMap(UUID.init(uuidString:)); conversation.updatedAt = snapshot.updatedAt
            // A project may arrive after its conversation. Preserve the link once its row exists.
            if let id = conversation.projectID, try Row.fetchAll(db, sql: "SELECT id FROM projects WHERE id=?", arguments: [id.uuidString]).isEmpty { conversation.projectID = nil }
            try ConversationRecord(conversation).save(db)
            // Temporarily move portable sequences below all existing rows, within this
            // transaction, before assigning the merged chronological order.
            let minimum = original.map(\.sequence).min() ?? 0
            for (index, row) in original.enumerated() {
                try db.execute(sql: "UPDATE messages SET sequence=? WHERE id=?", arguments: [minimum - index - 1, row.id.uuidString])
            }
            // Existing UUIDs are updated in place; repeated sync never appends a second turn.
            for (sequence, message) in snapshot.messages.enumerated() {
                let prior = original.first { $0.id == message.id }
                var documents = prior?.attachments ?? []
                for value in message.attachments ?? [] where value.kind == .document && !documents.contains(where: { $0.id == value.id }) {
                    documents.append(TextAttachment(id: value.id, name: value.name, content: value.text ?? "", video: value.video))
                }
                var images = prior?.images ?? []
                for value in message.attachments ?? [] where value.kind == .image && !images.contains(where: { $0.id == value.id }) {
                    images.append(try ImageAttachment(id: value.id, name: value.name, mimeType: value.mimeType, data: value.data ?? Data()))
                }
                let row = ConversationMessage(id: message.id, conversationID: snapshot.id, role: message.role == .user ? .user : .assistant,
                    content: message.text, sequence: sequence, createdAt: message.createdAt, attachments: documents, images: images,
                    completionStatus: message.role == .assistant && snapshot.turns.first(where: { $0.id == message.id })?.completedAt == nil ? .cancelled : nil, actions: ConversationAction.merge(prior?.actions, message.actions), visualReport: message.visualReport ?? prior?.visualReport, sources: ConversationSource.merge(prior?.sources, message.sources), routeAttempts: ConversationRouteAttempt.merge(prior?.routeAttempts, message.routeAttempts), timeline: TurnTimeline.merge(prior?.timeline, message.timeline))
                if let other = try MessageRecord.fetchOne(db, key: message.id.uuidString), other.conversationID != snapshot.id.uuidString { throw AccountServiceError.conflict }
                try MessageRecord(row).save(db)
            }
            try db.execute(sql: "DELETE FROM conversationSearch WHERE conversationID=?", arguments: [snapshot.id.uuidString])
            try db.execute(sql: "INSERT INTO conversationSearch(conversationID,title,content) VALUES(?,?,?)", arguments: [snapshot.id.uuidString,snapshot.title,snapshot.messages.map(\.text).joined(separator: " ")])
        }
    }

    public func delete(id: UUID) throws {
        try database.pool.write { db in
            _ = try ConversationRecord.deleteOne(db, key: id.uuidString)
            try db.execute(sql: "DELETE FROM conversationSearch WHERE conversationID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM sessionCompactions WHERE sessionID = ?", arguments: [id.uuidString])
        }
    }

    public func messages(conversationID: UUID) throws -> [ConversationMessage] {
        try database.pool.read { db in
            try MessageRecord
                .filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("sequence"))
                .fetchAll(db)
                .compactMap { try $0.decodedValue() }
        }
    }

    public func message(conversationID: UUID, sequence: Int) throws -> ConversationMessage? {
        try database.pool.read { db in
            try MessageRecord
                .filter(Column("conversationID") == conversationID.uuidString && Column("sequence") == sequence)
                .fetchOne(db)?.decodedValue()
        }
    }

    public func saveActions(_ actions: [ConversationAction], messageID: UUID) throws {
        try database.pool.write { db in
            guard let record = try MessageRecord.fetchOne(db, key: messageID.uuidString) else { return }
            let prior = record.actionsJSON.flatMap { try? JSONDecoder().decode([ConversationAction].self, from: $0) }
            let merged = ConversationAction.merge(prior, actions)
            try db.execute(sql: "UPDATE messages SET actionsJSON = ? WHERE id = ?", arguments: [try merged.map { try JSONEncoder().encode($0) }, messageID.uuidString])
        }
    }
    /// `streamedContent`: the whole text the person saw while the turn ran. The timeline's text
    /// ranges index into it; when it contains the delivered answer it replaces it, so the work
    /// notes and the answer split where they were written.
    public func savePresentation(sources: [ConversationSource]?, routeAttempts: [ConversationRouteAttempt]?, timeline: TurnTimeline? = nil,
                                 streamedContent: String? = nil, messageID: UUID) throws {
        try database.pool.write { db in
            guard let record = try MessageRecord.fetchOne(db, key: messageID.uuidString), let message = try record.decodedValue() else { return }
            if let streamedContent, streamedContent != message.content, streamedContent.count > message.content.count,
               streamedContent.contains(message.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                try db.execute(sql: "UPDATE messages SET content = ? WHERE id = ?", arguments: [streamedContent, messageID.uuidString])
            }
            let metadata = MessagePresentationMetadata(visualReport: message.visualReport, sources: ConversationSource.merge(message.sources, sources), routeAttempts: ConversationRouteAttempt.merge(message.routeAttempts, routeAttempts), timeline: TurnTimeline.merge(message.timeline, timeline))
            try db.execute(sql: "UPDATE messages SET visualReportJSON = ? WHERE id = ?", arguments: [try JSONEncoder().encode(metadata), messageID.uuidString])
        }
    }
    public func append(_ message: ConversationMessage) throws {
        try database.pool.write { db in
            // Retrying an uncertain acknowledgement must not duplicate a committed message.
            if let existing = try MessageRecord.fetchOne(db, key: message.id.uuidString)?.decodedValue(),
               existing.conversationID == message.conversationID, existing.role == message.role,
               existing.sequence == message.sequence, existing.content == message.content,
               existing.attachments == message.attachments, existing.images == message.images,
               existing.completionStatus == message.completionStatus { return }
            try MessageRecord(message).insert(db)
            try db.execute(
                sql: "UPDATE conversationSearch SET content = trim(content || ' ' || ?) WHERE conversationID = ?",
                arguments: [message.content, message.conversationID.uuidString]
            )
            try db.execute(
                sql: "UPDATE conversations SET updatedAt = ? WHERE id = ?",
                arguments: [message.createdAt, message.conversationID.uuidString]
            )
        }
    }

    /// A generated-image prompt and result either both become visible or neither does.
    public func appendPair(_ first: ConversationMessage, _ second: ConversationMessage) async throws {
        guard first.conversationID == second.conversationID,
              first.role == .user, second.role == .assistant,
              second.sequence == first.sequence + 1, first.id != second.id else {
            throw ConversationPairError.invalidPair
        }
        try await database.pool.write { db in
            try MessageRecord(first).insert(db)
            try MessageRecord(second).insert(db)
            try db.execute(
                sql: "UPDATE conversationSearch SET content = trim(content || ' ' || ? || ' ' || ?) WHERE conversationID = ?",
                arguments: [first.content, second.content, first.conversationID.uuidString]
            )
            try db.execute(sql: "UPDATE conversations SET updatedAt = ? WHERE id = ?",
                           arguments: [second.createdAt, first.conversationID.uuidString])
        }
    }

    public func branch(conversationID: UUID, at messageID: UUID, includingMessage: Bool) async throws -> Conversation {
        try await database.pool.write { db in
            guard let source = try ConversationRecord.fetchOne(db, key: conversationID.uuidString)?.value else {
                throw ConversationBranchError.missingMessage
            }
            let messages = try MessageRecord.filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("sequence")).fetchAll(db).compactMap { try $0.decodedValue() }
            let branch = try ConversationBranch(source: source, messages: messages, at: messageID, includingMessage: includingMessage)
            try ConversationRecord(branch.conversation).insert(db)
            for message in branch.messages { try MessageRecord(message).insert(db) }
            try db.execute(sql: "INSERT INTO conversationSearch(conversationID, title, content) VALUES (?, ?, ?)",
                           arguments: [branch.conversation.id.uuidString, branch.conversation.title, branch.messages.map(\.content).joined(separator: " ")])
            return branch.conversation
        }
    }

    public func search(_ query: String, limit: Int) throws -> [Conversation] {
        let boundedLimit = min(max(limit, 1), 100)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try list(includeArchived: false) }
        return try database.pool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT conversationID FROM conversationSearch JOIN conversations ON conversations.id = conversationSearch.conversationID WHERE conversationSearch MATCH ? AND conversations.isArchived = 0 ORDER BY conversations.updatedAt DESC LIMIT ?",
                arguments: ["\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\"", boundedLimit]
            )
            guard !ids.isEmpty else { return [] }
            return try ConversationRecord
                .filter(ids.contains(Column("id")))
                .filter(Column("isArchived") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .compactMap(\.value)
        }
    }

    public func searchHits(_ query: String, limit: Int) async throws -> [ConversationSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256 else { return [] }
        let conversations = try search(trimmed, limit: limit)
        return try await hits(in: conversations, matching: trimmed)
    }

    public func searchHits(_ query: String, projectID: UUID?, limit: Int) async throws -> [ConversationSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256, limit > 0 else { return [] }
        let conversations = try await database.pool.read { db in
            let sql = """
                SELECT conversations.* FROM conversationSearch
                JOIN conversations ON conversations.id = conversationSearch.conversationID
                WHERE conversationSearch MATCH ? AND conversations.isArchived = 0
                AND conversations.projectID \(projectID == nil ? "IS NULL" : "= ?")
                ORDER BY conversations.updatedAt DESC LIMIT ?
                """
            var arguments: StatementArguments = ["\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""]
            if let projectID { arguments += [projectID.uuidString] }
            arguments += [min(limit, 100)]
            return try ConversationRecord.fetchAll(db, sql: sql, arguments: arguments).compactMap(\.value)
        }
        return try await hits(in: conversations, matching: trimmed)
    }

    public func searchHits(words query: String, preferring projectID: UUID?, limit: Int) async throws -> [ConversationSearchHit] {
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !HybridMemorySearch.stopWords.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
        guard !terms.isEmpty, limit > 0 else { return [] }
        // Each word as a prefix ("prefer" finds "preferences"); all words first, then any of them.
        let tokens = Array(Set(terms)).prefix(12).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        var conversations: [Conversation] = []
        for joiner in [" AND ", " OR "] where conversations.isEmpty {
            conversations = try await database.pool.read { db in
                try ConversationRecord.fetchAll(db, sql: """
                    SELECT conversations.* FROM conversationSearch
                    JOIN conversations ON conversations.id = conversationSearch.conversationID
                    WHERE conversationSearch MATCH ? AND conversations.isArchived = 0
                    ORDER BY (conversations.projectID IS ?) DESC, bm25(conversationSearch), conversations.updatedAt DESC LIMIT ?
                    """, arguments: [tokens.joined(separator: joiner), projectID?.uuidString, min(limit, 100)]).compactMap(\.value)
            }
            if tokens.count == 1 { break }
        }
        let found = conversations
        return try await database.pool.read { db in
            try found.map { conversation -> ConversationSearchHit in
                let rows = try Row.fetchCursor(db,
                    sql: "SELECT id, content FROM messages WHERE conversationID = ? AND role IN ('user', 'assistant') ORDER BY sequence",
                    arguments: [conversation.id.uuidString])
                var best: (count: Int, id: String, excerpt: String)?
                while let row = try rows.next() {
                    let content: String = row["content"]
                    let found = terms.compactMap { content.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
                    guard let first = found.min(by: { $0.lowerBound < $1.lowerBound }), found.count > (best?.count ?? 0) else { continue }
                    let before = content[..<first.lowerBound], after = content[first.upperBound...]
                    let excerpt = (before.isEmpty ? "" : "…") + String(before.suffix(65)) + String(content[first])
                        + String(after.prefix(155)) + (after.count > 155 ? "…" : "")
                    best = (found.count, row["id"], excerpt.replacingOccurrences(of: "\n", with: " "))
                    if found.count == terms.count { break }
                }
                return ConversationSearchHit(conversation: conversation, messageID: best.flatMap { UUID(uuidString: $0.id) },
                                             excerpt: best?.excerpt)
            }
        }
    }

    private func hits(in conversations: [Conversation], matching trimmed: String) async throws -> [ConversationSearchHit] {
        return try await database.pool.read { db in
            try conversations.compactMap { conversation -> ConversationSearchHit? in
                let rows = try Row.fetchCursor(db,
                    sql: "SELECT id, content FROM messages WHERE conversationID = ? AND role IN ('user', 'assistant') ORDER BY sequence",
                    arguments: [conversation.id.uuidString])
                while let row = try rows.next() {
                    let content: String = row["content"]
                    guard let range = content.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                    let before = content[..<range.lowerBound]
                    let after = content[range.upperBound...]
                    let excerpt = (before.isEmpty ? "" : "…") + String(before.suffix(65))
                        + String(content[range]) + String(after.prefix(105))
                        + (after.count > 105 ? "…" : "")
                    let messageID: String = row["id"]
                    return ConversationSearchHit(conversation: conversation, messageID: UUID(uuidString: messageID),
                                                 excerpt: excerpt.replacingOccurrences(of: "\n", with: " "))
                }
                guard conversation.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                    return nil
                }
                return ConversationSearchHit(conversation: conversation)
            }
        }
    }
}

public enum ConversationPairError: Error, Sendable { case invalidPair }

private struct ProjectRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projects"
    var id: String
    var name: String
    var instructions: String
    var usesGlobalMemory: Bool?
    var isPinned: Bool?
    var createdAt: Date
    var updatedAt: Date

    init(_ value: AIMProject) {
        id = value.id.uuidString
        name = value.name
        instructions = value.instructions
        usesGlobalMemory = value.usesGlobalMemory
        isPinned = value.isPinned
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }

    var value: AIMProject? {
        UUID(uuidString: id).map {
            var project = AIMProject(id: $0, name: name, instructions: instructions, createdAt: createdAt, updatedAt: updatedAt)
            project.usesGlobalMemory = usesGlobalMemory
            project.isPinned = isPinned
            return project
        }
    }
}

private struct ProjectSourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projectSources"
    var id: String
    var projectID: String
    var canonicalPath: String
    var displayName: String
    var createdAt: Date
    var lastScannedAt: Date?
    var writeAccessGranted: Bool

    init(_ value: ProjectSource) {
        id = value.id.uuidString
        projectID = value.projectID.uuidString
        canonicalPath = value.canonicalPath
        displayName = value.displayName
        createdAt = value.createdAt
        lastScannedAt = value.lastScannedAt
        writeAccessGranted = value.writeAccessGranted
    }

    var value: ProjectSource? {
        guard let id = UUID(uuidString: id), let projectID = UUID(uuidString: projectID) else { return nil }
        return ProjectSource(id: id, projectID: projectID, canonicalPath: canonicalPath, displayName: displayName, createdAt: createdAt, lastScannedAt: lastScannedAt, writeAccessGranted: writeAccessGranted)
    }
}

public actor SQLiteProjectRepository: ProjectRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func list() throws -> [AIMProject] {
        try database.pool.read { db in try ProjectRecord.order(Column("updatedAt").desc).fetchAll(db).compactMap(\.value) }
    }

    public func save(_ project: AIMProject) throws {
        try database.pool.write { db in try ProjectRecord(project).save(db) }
    }

    public func delete(id: UUID) throws {
        try database.pool.write { db in _ = try ProjectRecord.deleteOne(db, key: id.uuidString) }
    }

    public func sources(projectID: UUID) throws -> [ProjectSource] {
        try database.pool.read { db in
            try ProjectSourceRecord.filter(Column("projectID") == projectID.uuidString).order(Column("displayName")).fetchAll(db).compactMap(\.value)
        }
    }

    public func save(source: ProjectSource) throws {
        try database.pool.write { db in try ProjectSourceRecord(source).save(db) }
    }

    public func deleteSource(id: UUID) throws {
        try database.pool.write { db in _ = try ProjectSourceRecord.deleteOne(db, key: id.uuidString) }
    }
}

private struct MemoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memoryItemsV2"
    var id: String
    var kind: String
    var scope: String
    var scopeKey: String
    var subjectKey: String
    var content: String
    var evidenceQuote: String?
    var sourceMessageID: String?
    var status: String
    var confidence: Double
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(_ value: MemoryItem) {
        id = value.id.uuidString
        kind = value.kind.rawValue
        scope = value.scope
        scopeKey = value.scopeKey
        subjectKey = value.subjectKey
        content = value.content
        evidenceQuote = value.evidenceQuote
        sourceMessageID = value.sourceMessageID?.uuidString
        status = value.status.rawValue
        confidence = value.confidence
        isPinned = value.isPinned
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }

    var value: MemoryItem? {
        guard let id = UUID(uuidString: id), let kind = MemoryKind(rawValue: kind), let status = MemoryStatus(rawValue: status) else { return nil }
        return MemoryItem(id: id, kind: kind, scope: scope, scopeKey: scopeKey, subjectKey: subjectKey,
                          content: content, evidenceQuote: evidenceQuote, sourceMessageID: sourceMessageID.flatMap(UUID.init(uuidString:)),
                          status: status, confidence: confidence, isPinned: isPinned, createdAt: createdAt, updatedAt: updatedAt)
    }
}

public actor SQLiteMemoryRepository: MemoryRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func list(status: MemoryStatus?) throws -> [MemoryItem] {
        try database.pool.read { db in
            var request = MemoryRecord.order(Column("isPinned").desc, Column("updatedAt").desc)
            if let status { request = request.filter(Column("status") == status.rawValue) }
            return try request.fetchAll(db).compactMap(\.value)
        }
    }

    public func save(_ item: MemoryItem) throws {
        let text = item.subjectKey + " " + item.content
        let vector = HybridMemorySearch.vector(text).flatMap { try? JSONEncoder().encode($0) }
        try database.pool.write { db in
            try MemoryRecord(item).save(db)
            try db.execute(sql: "DELETE FROM memorySearch WHERE memoryID = ?", arguments: [item.id.uuidString])
            if item.status == .archived {
                try db.execute(sql: "DELETE FROM memorySemanticIndex WHERE memoryID = ?", arguments: [item.id.uuidString])
                return
            }
            try db.execute(sql: "INSERT INTO memorySearch(memoryID, content) VALUES (?, ?)",
                           arguments: [item.id.uuidString, item.subjectKey + " " + item.content])
            try db.execute(sql: "INSERT OR REPLACE INTO memorySemanticIndex(memoryID, contentHash, vector, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [item.id.uuidString, HybridMemorySearch.fingerprint(text), vector, Date()])
        }
    }

    public func consolidateDuplicates(keeping: UUID, archiving: [UUID]) async throws {
        let ids = Set(archiving)
        guard !ids.isEmpty, !ids.contains(keeping) else { throw MemoryConsolidationError.staleProposal }
        try await database.pool.write { db in
            guard var keeper = try MemoryRecord.fetchOne(db, key: keeping.uuidString)?.value else { throw MemoryConsolidationError.staleProposal }
            let records = try MemoryRecord.filter(ids.map(\.uuidString).contains(Column("id"))).fetchAll(db).compactMap(\.value)
            let groups = HybridMemorySearch.duplicateGroups([keeper] + records)
            guard records.count == ids.count, groups.count == 1,
                  Set(groups[0]) == ids.union([keeping]) else { throw MemoryConsolidationError.staleProposal }
            keeper.status = .verified
            keeper.isPinned = keeper.isPinned || records.contains(where: \.isPinned)
            keeper.updatedAt = .now
            try MemoryRecord(keeper).save(db)
            for id in ids {
                try db.execute(sql: "UPDATE memoryItemsV2 SET status='archived',updatedAt=? WHERE id=?", arguments: [Date(), id.uuidString])
                try db.execute(sql: "DELETE FROM memorySemanticIndex WHERE memoryID=?", arguments: [id.uuidString])
                try db.execute(sql: "DELETE FROM memorySearch WHERE memoryID=?", arguments: [id.uuidString])
            }
            // Archived originals retain their exact evidence/source and are restorable.
        }
    }

    public func archive(id: UUID) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE memoryItemsV2 SET status = 'archived', updatedAt = ? WHERE id = ?", arguments: [Date(), id.uuidString])
            try db.execute(sql: "DELETE FROM memorySemanticIndex WHERE memoryID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM memorySearch WHERE memoryID = ?", arguments: [id.uuidString])
        }
    }

    public func delete(id: UUID) throws {
        try database.pool.write { db in
            _ = try MemoryRecord.deleteOne(db, key: id.uuidString)
            try db.execute(sql: "DELETE FROM memorySearch WHERE memoryID = ?", arguments: [id.uuidString])
        }
    }

    public func search(_ query: String, limit: Int) throws -> [MemoryItem] {
        let ids = try database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT memoryID FROM memorySearch WHERE memorySearch MATCH ? LIMIT ?", arguments: [query, min(max(limit, 1), 100)])
        }
        return try database.pool.read { db in
            try MemoryRecord.filter(ids.contains(Column("id"))).fetchAll(db).compactMap(\.value)
        }
    }

    public func searchScoped(_ query: String, projectID: UUID?, includeGlobal: Bool,
                             limit: Int) throws -> [MemoryItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try ranked(query, projectID: projectID, includeGlobal: includeGlobal, limit: limit, includeProfile: false)
    }

    public func contextCandidates(_ query: String, projectID: UUID?, includeGlobal: Bool) async throws -> [MemoryItem] {
        try ranked(query, projectID: projectID, includeGlobal: includeGlobal, limit: 48, includeProfile: true)
    }

    private func ranked(_ query: String, projectID: UUID?, includeGlobal: Bool, limit: Int, includeProfile: Bool) throws -> [MemoryItem] {
        let items = try database.pool.read { db in
            try MemoryRecord.fetchAll(db, sql: """
                SELECT * FROM memoryItemsV2 WHERE status IN ('verified', 'provisional')
                  AND ((? = 1 AND scope = 'global' AND scopeKey = 'self')
                       OR (scope = 'project' AND scopeKey = ?))
                """, arguments: [includeGlobal ? 1 : 0, projectID?.uuidString]).compactMap(\.value)
        }
        let indexed = try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT memoryID, contentHash, vector FROM memorySemanticIndex")
        }
        let rowsByID = Dictionary(indexed.map { (($0["memoryID"] as String), $0) }, uniquingKeysWith: { _, last in last })
        var vectors: [UUID: LocalMemoryVector] = [:]
        for item in items {
            let text = item.subjectKey + " " + item.content
            let hash = HybridMemorySearch.fingerprint(text)
            if let row = rowsByID[item.id.uuidString], (row["contentHash"] as String) == hash,
               let data: Data = row["vector"], let vector = try? JSONDecoder().decode(LocalMemoryVector.self, from: data) {
                vectors[item.id] = vector
            } else if let vector = HybridMemorySearch.vector(text) {
                vectors[item.id] = vector
                try database.pool.write { db in
                    try db.execute(sql: "INSERT OR REPLACE INTO memorySemanticIndex(memoryID, contentHash, vector, updatedAt) VALUES (?, ?, ?, ?)",
                        arguments: [item.id.uuidString, hash, try JSONEncoder().encode(vector), Date()])
                }
            }
        }
        return HybridMemorySearch.ranked(items, query: query, projectID: projectID,
            includeGlobal: includeGlobal, vectors: vectors, limit: min(max(limit, 1), 100), includeProfile: includeProfile)
    }
}

private struct ScheduledTaskRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scheduledTasks"
    var id: String
    var title: String
    var prompt: String
    var recurrenceRule: String?
    var nextRunAt: Date?
    var state: String
    var consecutiveFailures: Int
    var createdAt: Date
    var updatedAt: Date
    var specJSON: Data?
    var runningSince: Date?
    var lastRunAt: Date?
    var lastStatus: String?
    var pausedReason: String?

    init(_ value: ScheduledTask) {
        id = value.id.uuidString
        title = value.title
        prompt = value.prompt
        recurrenceRule = value.recurrenceRule
        nextRunAt = value.nextRunAt
        state = value.state.rawValue
        consecutiveFailures = value.consecutiveFailures
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        specJSON = value.spec.flatMap { try? JSONEncoder().encode($0) }
        runningSince = value.runningSince
        lastRunAt = value.lastRunAt
        lastStatus = value.lastStatus
        pausedReason = value.pausedReason
    }

    var value: ScheduledTask? {
        guard let id = UUID(uuidString: id), let state = ScheduledTaskState(rawValue: state) else { return nil }
        return ScheduledTask(id: id, title: title, prompt: prompt, recurrenceRule: recurrenceRule, nextRunAt: nextRunAt,
            state: state, consecutiveFailures: consecutiveFailures, createdAt: createdAt, updatedAt: updatedAt,
            spec: specJSON.flatMap { try? JSONDecoder().decode(ScheduledTaskSpec.self, from: $0) },
            runningSince: runningSince, lastRunAt: lastRunAt, lastStatus: lastStatus, pausedReason: pausedReason)
    }
}

public actor SQLiteSchedulerRepository: SchedulerRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func list() throws -> [ScheduledTask] {
        try database.pool.read { db in try ScheduledTaskRecord.order(Column("nextRunAt")).fetchAll(db).compactMap(\.value) }
    }

    public func due(before date: Date) throws -> [ScheduledTask] {
        try database.pool.read { db in
            try ScheduledTaskRecord
                .filter(Column("state") == ScheduledTaskState.enabled.rawValue && Column("nextRunAt") <= date)
                .order(Column("nextRunAt"))
                .fetchAll(db)
                .compactMap(\.value)
        }
    }

    public func save(_ task: ScheduledTask) throws {
        try database.pool.write { db in try ScheduledTaskRecord(task).save(db) }
    }

    public func delete(id: UUID) throws {
        try database.pool.write { db in _ = try ScheduledTaskRecord.deleteOne(db, key: id.uuidString) }
    }

    /// Atomically takes ownership of one due or triggered run: the task must be
    /// enabled and not already running. The next occurrence is advanced in the
    /// same transaction, so a crash can never replay the same slot repeatedly.
    public func claim(id: UUID, at now: Date, nextRunAt: Date?, conversationID: UUID,
                      durableCommandID: UUID? = nil, admission: Data? = nil, owner: UUID? = nil, sourceEventID: UUID? = nil) throws -> Int64? {
        try database.pool.write { db in
            if let owner { try checkRuntimeOwner(db, owner) }
            if let event = sourceEventID {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agentScheduleEvents WHERE id=? AND taskID=? AND consumedAt IS NULL", arguments: [event.uuidString, id.uuidString]) == 1 else { return nil }
            }
            guard var record = try ScheduledTaskRecord.fetchOne(db, key: id.uuidString),
                  record.state == ScheduledTaskState.enabled.rawValue, record.runningSince == nil else { return nil }
            record.state = ScheduledTaskState.running.rawValue
            record.runningSince = now
            record.nextRunAt = nextRunAt
            record.lastRunAt = now
            record.updatedAt = now
            try record.update(db)
            try db.execute(sql: """
                INSERT INTO scheduledExecutions (taskID, startedAt, conversationID, status) VALUES (?, ?, ?, NULL)
                """, arguments: [id.uuidString, now, conversationID.uuidString])
            let claimID = db.lastInsertedRowID
            if let command = durableCommandID, let admission, owner != nil {
                try db.execute(sql: "INSERT INTO agentScheduleAdmissions(commandID,taskID,conversationID,claimID,payload) VALUES(?,?,?,?,?)",
                    arguments: [command.uuidString, id.uuidString, conversationID.uuidString, claimID, admission])
                if let event = sourceEventID {
                    try db.execute(sql: "UPDATE agentScheduleEvents SET consumedAt=? WHERE id=?", arguments: [now, event.uuidString])
                }
            } else if durableCommandID != nil || admission != nil { throw ExecutionStoreError.invalidTransition }
            return claimID
        }
    }

    /// Ends the owned run. Success resets the failure streak; ten consecutive
    /// failures disable the task. A run that needs a person pauses the task.
    @discardableResult
    public func finish(id: UUID, executionID: Int64, status: ScheduledRunStatus, detail: String?, at now: Date) throws -> ScheduledTask? {
        try database.pool.write { db in
            guard var record = try ScheduledTaskRecord.fetchOne(db, key: id.uuidString) else { return nil }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduledExecutions WHERE id=? AND taskID=? AND endedAt IS NULL",
                                   arguments: [executionID, id.uuidString]) == 1 else { return record.value }
            try db.execute(sql: "UPDATE scheduledExecutions SET endedAt = ?, status = ?, error = ? WHERE id = ? AND taskID = ?",
                arguments: [now, status.rawValue, detail.map { String($0.prefix(2_000)) }, executionID, id.uuidString])
            record.runningSince = nil
            record.lastStatus = status.rawValue
            record.updatedAt = now
            switch status {
            case .succeeded:
                record.consecutiveFailures = 0
                record.state = ScheduledTaskState.enabled.rawValue
            case .failed, .spendCapped, .interrupted:
                record.consecutiveFailures += 1
                if record.consecutiveFailures >= ScheduledTask.failureLimit {
                    record.state = ScheduledTaskState.disabled.rawValue
                    record.pausedReason = "Disabled after \(record.consecutiveFailures) consecutive failed runs."
                } else {
                    record.state = ScheduledTaskState.enabled.rawValue
                }
            case .needsPerson:
                record.state = ScheduledTaskState.paused.rawValue
                record.pausedReason = detail.map { String($0.prefix(500)) } ?? "A person must review this task before it runs again."
            case .skipped:
                record.state = ScheduledTaskState.enabled.rawValue
            }
            // A one-shot task that has run does not stay enabled with no next time.
            if record.nextRunAt == nil, record.state == ScheduledTaskState.enabled.rawValue,
               let spec = record.specJSON.flatMap({ try? JSONDecoder().decode(ScheduledTaskSpec.self, from: $0) }),
               spec.trigger == nil {
                record.state = ScheduledTaskState.disabled.rawValue
            }
            try record.update(db)
            return record.value
        }
    }

    /// After a crash or quit, runs that never finished are recorded as
    /// interrupted (never replayed), and their tasks become runnable again.
    public func repairInterrupted(at now: Date) throws -> Int {
        try database.pool.write { db in
            let running = try ScheduledTaskRecord.filter(Column("runningSince") != nil)
                .filter(sql: "id NOT IN (SELECT taskID FROM agentScheduleAdmissions WHERE completed=0)").fetchAll(db)
            for var record in running {
                record.runningSince = nil
                record.consecutiveFailures += 1
                record.lastStatus = ScheduledRunStatus.interrupted.rawValue
                record.state = record.consecutiveFailures >= ScheduledTask.failureLimit
                    ? ScheduledTaskState.disabled.rawValue : ScheduledTaskState.enabled.rawValue
                record.updatedAt = now
                try record.update(db)
            }
            try db.execute(sql: "UPDATE scheduledExecutions SET endedAt = ?, status = ? WHERE endedAt IS NULL AND id NOT IN (SELECT claimID FROM agentScheduleAdmissions WHERE completed=0)",
                arguments: [now, ScheduledRunStatus.interrupted.rawValue])
            return running.count
        }
    }

    public func executions(taskID: UUID, limit: Int = 20) throws -> [ScheduledExecution] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, taskID, conversationID, startedAt, endedAt, status, error FROM scheduledExecutions
                WHERE taskID = ? ORDER BY id DESC LIMIT ?
                """, arguments: [taskID.uuidString, max(1, min(limit, 200))]).compactMap { row in
                guard let taskID = UUID(uuidString: row["taskID"]) else { return nil }
                return ScheduledExecution(id: row["id"], taskID: taskID,
                    conversationID: (row["conversationID"] as String?).flatMap(UUID.init(uuidString:)),
                    startedAt: row["startedAt"], endedAt: row["endedAt"],
                    status: (row["status"] as String?).flatMap(ScheduledRunStatus.init(rawValue:)),
                    detail: row["error"])
            }
        }
    }

    public func task(id: UUID) throws -> ScheduledTask? {
        try database.pool.read { db in try ScheduledTaskRecord.fetchOne(db, key: id.uuidString)?.value }
    }
    private func checkRuntimeOwner(_ db: Database, _ owner: UUID) throws {
        guard try String.fetchOne(db, sql: "SELECT generation FROM agentRuntimeOwner WHERE id=1") == owner.uuidString else {
            throw ExecutionStoreError.staleOwner
        }
    }
    public func runtimeAdmissions(owner: UUID) throws -> [ScheduledRuntimeAdmission] {
        try database.pool.read { db in
            try checkRuntimeOwner(db, owner)
            return try Row.fetchAll(db, sql: "SELECT * FROM agentScheduleAdmissions WHERE completed=0 ORDER BY claimID").map {
                guard let command = UUID(uuidString: $0["commandID"]), let task = UUID(uuidString: $0["taskID"]),
                      let conversation = UUID(uuidString: $0["conversationID"]) else { throw ExecutionStoreError.incompatibleCheckpoint }
                return ScheduledRuntimeAdmission(commandID: command, taskID: task, conversationID: conversation,
                    claimID: $0["claimID"], payload: $0["payload"])
            }
        }
    }
    public func completeRuntimeAdmission(_ commandID: UUID, owner: UUID) throws {
        try database.pool.write { db in
            try checkRuntimeOwner(db, owner)
            try db.execute(sql: "UPDATE agentScheduleAdmissions SET completed=1 WHERE commandID=?", arguments: [commandID.uuidString])
        }
    }
    public func enqueueRuntimeEvent(taskID: UUID, key: String, reason: String, payload: String?, owner: UUID) throws {
        try database.pool.write { db in
            try checkRuntimeOwner(db, owner)
            try db.execute(sql: "INSERT OR IGNORE INTO agentScheduleEvents(id,taskID,dedupKey,reason,payload,createdAt) VALUES(?,?,?,?,?,?)",
                arguments: [UUID().uuidString, taskID.uuidString, key, reason, payload.map { String($0.prefix(8000)) }, Date.now])
        }
    }
    public func runtimeEvents(owner: UUID) throws -> [ScheduledRuntimeEvent] {
        try database.pool.read { db in
            try checkRuntimeOwner(db, owner)
            return try Row.fetchAll(db, sql: "SELECT * FROM agentScheduleEvents WHERE consumedAt IS NULL ORDER BY rowid").map {
                guard let id = UUID(uuidString: $0["id"]), let task = UUID(uuidString: $0["taskID"]) else { throw ExecutionStoreError.incompatibleCheckpoint }
                return ScheduledRuntimeEvent(id: id, taskID: task, reason: $0["reason"], payload: $0["payload"])
            }
        }
    }
    public func consumeRuntimeEvent(_ id: UUID, owner: UUID) throws {
        try database.pool.write { db in
            try checkRuntimeOwner(db, owner)
            try db.execute(sql: "UPDATE agentScheduleEvents SET consumedAt=? WHERE id=?", arguments: [Date.now, id.uuidString])
        }
    }
    public func latestRuntimeEvent(taskID: UUID, reason: String, after date: Date) throws -> String? {
        try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT id,payload FROM agentScheduleEvents WHERE taskID=? AND reason=? AND createdAt>=? ORDER BY createdAt DESC LIMIT 1",
                arguments: [taskID.uuidString, reason, date]).map { row in
                    let id: String = row["id"]; let payload: String? = row["payload"]
                    return "Trigger event \(id), untrusted data: " + (payload ?? "")
                }
        }
    }
    /// Compare and enqueue atomically: a crash never advances a poll baseline while losing its event.
    public func observeRuntimeTrigger(taskID: UUID, sourceSignature: String, reason: String, output: String, newMail: Bool = false, owner: UUID) throws {
        let output = String(output.prefix(8000))
        try database.pool.write { db in
            try checkRuntimeOwner(db, owner)
            let row = try Row.fetchOne(db, sql: "SELECT sourceSignature,output FROM agentTriggerBaselines WHERE taskID=?", arguments: [taskID.uuidString])
            let oldSource: String? = row?["sourceSignature"], oldOutput: String? = row?["output"]
            if newMail, oldSource == sourceSignature, let old = oldOutput?.split(separator: "\t").first.flatMap({ Int($0) }),
               let next = output.split(separator: "\t").first.flatMap({ Int($0) }), next <= old { return }
            try db.execute(sql: "INSERT INTO agentTriggerBaselines(taskID,sourceSignature,output) VALUES(?,?,?) ON CONFLICT(taskID) DO UPDATE SET sourceSignature=excluded.sourceSignature, output=excluded.output",
                           arguments: [taskID.uuidString, sourceSignature, output])
            if oldSource == sourceSignature, oldOutput != output, !output.isEmpty {
                let id = UUID().uuidString
                try db.execute(sql: "INSERT INTO agentScheduleEvents(id,taskID,dedupKey,reason,payload,createdAt) VALUES(?,?,?,?,?,?)",
                    arguments: [id, taskID.uuidString, "observation:\(id)", reason, output, Date.now])
            }
        }
    }
}

private struct ActivityRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "activity"
    var id: Int64?
    var application: String
    var title: String
    var url: String?
    var startedAt: Date
    var endedAt: Date

    init(_ value: ActivityEntry) {
        id = value.id
        application = value.application
        title = value.title
        url = value.url
        startedAt = value.startedAt
        endedAt = value.endedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    var value: ActivityEntry { ActivityEntry(id: id, application: application, title: title, url: url, startedAt: startedAt, endedAt: endedAt) }
}

public actor SQLiteActivityRepository: ActivityRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func record(_ entry: ActivityEntry) throws {
        try database.pool.write { db in
            var record = ActivityRecord(entry)
            try record.insert(db)
        }
    }

    public func search(_ query: String, since: Date?, until: Date?, limit: Int) throws -> [ActivityEntry] {
        try database.pool.read { db in
            var request = ActivityRecord.order(Column("startedAt").desc)
            if !query.isEmpty {
                let pattern = "%\(query)%"
                request = request.filter(Column("application").like(pattern) || Column("title").like(pattern) || Column("url").like(pattern))
            }
            if let since { request = request.filter(Column("endedAt") >= since) }
            if let until { request = request.filter(Column("startedAt") <= until) }
            return try request.limit(min(max(limit, 1), 200)).fetchAll(db).map(\.value)
        }
    }

    public func purge(olderThan date: Date) throws -> Int {
        try database.pool.write { db in try ActivityRecord.filter(Column("endedAt") < date).deleteAll(db) }
    }
}
