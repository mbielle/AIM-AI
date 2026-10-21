import AIMAgentKit
import AIMApplication
import Foundation

/// Apple Notes has no EventKit equivalent. These fixed, typed AppleScript
/// operations run in AIM's process so Automation consent belongs to AIM.
/// No model-provided script is ever executed.
public actor MacNotesToolService: ToolExecutor, MissionIntentProviding {
    public nonisolated let supportedTools: Set<String> = [
        "notes_folders", "notes_list", "notes_search", "notes_get", "notes_create",
        "notes_replace", "notes_append", "notes_delete"
    ]

    private let runner: any MacAutomationScriptRunning

    public init() { runner = SystemMacAutomationScriptRunner.shared }
    init(runner: any MacAutomationScriptRunning) { self.runner = runner }

    private func run(_ script: String) async throws -> [[String]] {
        try await runner.run(script, helpers: NotesScripts.safeText, timeoutSeconds: 30)
    }

    public nonisolated func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        let operation: MissionOperation
        switch request.name {
        case "notes_folders", "notes_list", "notes_search", "notes_get": operation = .observe
        case "notes_create": operation = .edit
        case "notes_replace", "notes_append": operation = .edit
        case "notes_delete": operation = .permanentDelete
        default: return nil
        }
        _ = try NotesArguments(request)
        return MissionToolIntent(operation: operation,
            target: try MissionResource(kind: .application, identifier: "com.apple.Notes"))
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        var mutationStarted = false
        do {
            let arguments = try NotesArguments(request)
            try Task.checkCancellation()
            switch arguments {
            case .folders:
                let rows = try await run(NotesScripts.folders)
                guard let header = rows.first, header.count == 2, header[0] == "meta",
                      let total = Int(header[1]), total >= 0 else { throw NotesError.invalidReply }
                let folders = try rows.dropFirst().map { row -> NotesFolder in
                    guard row.count == 4 else { throw NotesError.invalidReply }
                    return NotesFolder(id: row[0], name: row[1], containerID: row[2], shared: row[3] == "true")
                }
                return try Self.encoded(NotesFolderPage(folders: folders, total: total,
                    returned: folders.count, truncated: total > folders.count), requestID: request.id)
            case let .list(folderID, offset, limit):
                let rows = try await run(NotesScripts.list(folderID: folderID, offset: offset, limit: limit))
                return try Self.page(rows, offset: offset, requestID: request.id)
            case let .search(query, folderID, offset, limit):
                let rows = try await run(NotesScripts.search(query: query, folderID: folderID,
                                                               offset: offset, limit: limit))
                return try Self.page(rows, offset: offset, requestID: request.id)
            case let .get(id):
                let rows = try await run(NotesScripts.get(id: id))
                guard rows.count == 1 else { throw NotesError.invalidReply }
                return try Self.encoded(try NotesDetail(rows[0]), requestID: request.id)
            case let .create(title, body, folderID):
                mutationStarted = true
                let rows = try await run(NotesScripts.create(title: title, body: body, folderID: folderID))
                guard rows.count == 1 else { throw NotesError.invalidReply }
                let detail = try NotesDetail(rows[0])
                guard detail.name == title, detail.plaintext.contains(title) else {
                    var result = ToolResult(requestID: request.id,
                        content: "Notes accepted the create request, but AIM could not verify its title. Inspect Notes before retrying.",
                        isError: true)
                    result.actionOutcome = .unknown
                    return result
                }
                var result = try Self.encoded(detail, requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .replace(id, expectedModified, title, body):
                mutationStarted = true
                let rows = try await run(NotesScripts.replace(id: id, expectedModified: expectedModified,
                                                                title: title, body: body))
                guard rows.count == 1 else { throw NotesError.invalidReply }
                let detail = try NotesDetail(rows[0])
                let expectedPlaintext = ([title] + body.components(separatedBy: "\n"))
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard detail.id == id,
                      detail.plaintext.trimmingCharacters(in: .whitespacesAndNewlines) == expectedPlaintext else {
                    throw NotesError.unverifiedMutation
                }
                var result = try Self.encoded(detail, requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .append(id, expectedModified, text):
                mutationStarted = true
                let rows = try await run(NotesScripts.append(id: id, expectedModified: expectedModified,
                                                               text: text))
                guard rows.count == 1, rows[0].count == 9 else { throw NotesError.invalidReply }
                let detail = try NotesDetail(Array(rows[0].prefix(8)))
                let oldPlaintext = rows[0][8]
                guard detail.id == id, detail.plaintext != oldPlaintext,
                      detail.plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasSuffix(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw NotesError.unverifiedMutation
                }
                var result = try Self.encoded(detail, requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            case let .delete(id, expectedModified):
                mutationStarted = true
                let rows = try await run(NotesScripts.delete(id: id, expectedModified: expectedModified))
                guard rows.count == 1, rows[0].count == 2, rows[0][0] == id,
                      rows[0][1] == "0" else { throw NotesError.unverifiedMutation }
                var result = try Self.encoded(NotesRemovalReceipt(id: id, removedFromOriginalFolder: true),
                                              requestID: request.id)
                result.actionOutcome = .confirmed
                return result
            }
        } catch {
            var result = ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
            if ["notes_create", "notes_replace", "notes_append", "notes_delete"].contains(request.name) {
                result.actionOutcome = mutationStarted ? .unknown : .suspectedAbsent
            }
            return result
        }
    }

    public func cancel(requestID: String) async {}

    private nonisolated static func page(_ rows: [[String]], offset: Int, requestID: String) throws -> ToolResult {
        guard let header = rows.first, header.count == 2, header[0] == "meta",
              let total = Int(header[1]), total >= 0 else { throw NotesError.invalidReply }
        let notes = try rows.dropFirst().map(NotesSummary.init)
        guard notes.count <= 100, offset <= total else { throw NotesError.invalidReply }
        return try encoded(NotesPage(notes: notes, total: total, returned: notes.count,
                                     nextOffset: offset + notes.count < total ? offset + notes.count : nil),
                           requestID: requestID)
    }

    private nonisolated static func encoded<T: Encodable>(_ value: T, requestID: String) throws -> ToolResult {
        ToolResult(requestID: requestID, content: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}

private enum NotesArguments {
    case folders
    case list(folderID: String?, offset: Int, limit: Int)
    case search(query: String, folderID: String?, offset: Int, limit: Int)
    case get(id: String)
    case create(title: String, body: String, folderID: String?)
    case replace(id: String, expectedModified: String, title: String, body: String)
    case append(id: String, expectedModified: String, text: String)
    case delete(id: String, expectedModified: String)

    init(_ request: ToolRequest) throws {
        let values = request.arguments
        func field(_ key: String, max: Int, allowEmpty: Bool = false) throws -> String? {
            guard let raw = values[key] else { return nil }
            let value = allowEmpty ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (allowEmpty || !value.isEmpty), value.utf8.count <= max,
                  !value.contains("\0"), !value.contains("\r"),
                  (allowEmpty || !value.contains("\n")) else { throw NotesError.invalidArgument }
            guard value.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar) ||
                    (allowEmpty && (scalar.value == 9 || scalar.value == 10))
            }) else { throw NotesError.invalidArgument }
            return value
        }
        func paging() throws -> (Int, Int) {
            guard let offset = Int(values["offset"] ?? "0"), (0...100_000).contains(offset),
                  let limit = Int(values["limit"] ?? "50"), (1...100).contains(limit) else {
                throw NotesError.invalidArgument
            }
            return (offset, limit)
        }
        switch request.name {
        case "notes_folders": self = .folders
        case "notes_list":
            let (offset, limit) = try paging()
            self = .list(folderID: try field("folder_id", max: 512), offset: offset, limit: limit)
        case "notes_search":
            guard let query = try field("query", max: 200), !query.contains("\n") else {
                throw NotesError.invalidArgument
            }
            let (offset, limit) = try paging()
            self = .search(query: query, folderID: try field("folder_id", max: 512),
                           offset: offset, limit: limit)
        case "notes_get":
            guard let id = try field("id", max: 512), !id.contains("\n") else { throw NotesError.invalidArgument }
            self = .get(id: id)
        case "notes_create":
            guard let title = try field("title", max: 500), !title.contains("\n"),
                  let body = try field("body", max: 64_000, allowEmpty: true) else {
                throw NotesError.invalidArgument
            }
            self = .create(title: title, body: body, folderID: try field("folder_id", max: 512))
        case "notes_replace":
            guard let id = try field("id", max: 512),
                  let expected = try field("expected_modified", max: 256),
                  let title = try field("title", max: 500),
                  let body = try field("body", max: 64_000, allowEmpty: true) else {
                throw NotesError.invalidArgument
            }
            self = .replace(id: id, expectedModified: expected, title: title, body: body)
        case "notes_append":
            guard let id = try field("id", max: 512),
                  let expected = try field("expected_modified", max: 256),
                  let text = try field("text", max: 16_000), !text.isEmpty else {
                throw NotesError.invalidArgument
            }
            self = .append(id: id, expectedModified: expected, text: text)
        case "notes_delete":
            guard let id = try field("id", max: 512),
                  let expected = try field("expected_modified", max: 256) else {
                throw NotesError.invalidArgument
            }
            self = .delete(id: id, expectedModified: expected)
        default: throw NotesError.invalidArgument
        }
    }
}

enum NotesScripts {
    static let safeText = """
    on safeText(v)
        try
            if v is missing value then return ""
            return v as string
        on error
            return ""
        end try
    end safeText
    """

    static func literal(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "&#9;")
            .replacingOccurrences(of: "\n", with: "&#10;")
        return "\"\(escaped)\""
    }

    static func html(_ title: String, _ body: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        return ([title] + body.components(separatedBy: "\n"))
            .map { $0.isEmpty ? "<div><br></div>" : "<div>\(escape($0))</div>" }
            .joined()
    }

    static let folders = """
    set out to {}
    tell application id "com.apple.Notes"
        set allFolders to every folder
        set total to count of allFolders
        set end of out to {"meta", total as string}
        set countToReturn to total
        if countToReturn > 100 then set countToReturn to 100
        repeat with i from 1 to countToReturn
            set f to item i of allFolders
            set parentID to ""
            try
                set parentID to my safeText(id of container of f)
            end try
            set end of out to {my safeText(id of f), my safeText(name of f), parentID, my safeText(shared of f)}
        end repeat
    end tell
    return out
    """

    private static func collection(_ folderID: String?) -> String {
        if let folderID { return "notes of (first folder whose id is \(literal(folderID)))" }
        return "every note"
    }

    private static func pageScript(collection: String, offset: Int, limit: Int) -> String {
        """
        set out to {}
        tell application id "com.apple.Notes"
            set foundNotes to \(collection)
            set total to count of foundNotes
            set end of out to {"meta", total as string}
            if total > \(offset) then
                set lastIndex to total
                if lastIndex > \(offset + limit) then set lastIndex to \(offset + limit)
                repeat with i from \(offset + 1) to lastIndex
                    set nt to item i of foundNotes
                    set folderID to ""
                    try
                        set folderID to my safeText(id of container of nt)
                    end try
                    set end of out to {my safeText(id of nt), my safeText(name of nt), my safeText(modification date of nt), folderID, my safeText(shared of nt), my safeText(password protected of nt)}
                end repeat
            end if
        end tell
        return out
        """
    }

    static func list(folderID: String?, offset: Int, limit: Int) -> String {
        pageScript(collection: collection(folderID), offset: offset, limit: limit)
    }

    static func search(query: String, folderID: String?, offset: Int, limit: Int) -> String {
        let base = folderID == nil ? "notes" : collection(folderID)
        return pageScript(collection: "(\(base) whose name contains \(literal(query)))",
                          offset: offset, limit: limit)
    }

    static func get(id: String) -> String {
        """
        tell application id "com.apple.Notes"
            set nt to first note whose id is \(literal(id))
            set noteText to my safeText(plaintext of nt)
            if (length of noteText) > 500000 then error "AIM_NOTE_TOO_LARGE"
            set folderID to ""
            try
                set folderID to my safeText(id of container of nt)
            end try
            return {{my safeText(id of nt), my safeText(name of nt), noteText, my safeText(modification date of nt), folderID, my safeText(count of attachments of nt), my safeText(shared of nt), my safeText(password protected of nt)}}
        end tell
        """
    }

    static func create(title: String, body: String, folderID: String?) -> String {
        let target = folderID.map { "(first folder whose id is \(literal($0)))" }
            ?? "default folder of default account"
        return """
        tell application id "com.apple.Notes"
            set targetFolder to \(target)
            if shared of targetFolder then error "AIM_SHARED_FOLDER"
            set nt to make new note at end of notes of targetFolder with properties {body:\(literal(html(title, body)))}
            set noteText to my safeText(plaintext of nt)
            if (length of noteText) > 500000 then error "AIM_NOTE_TOO_LARGE"
            set folderID to ""
            try
                set folderID to my safeText(id of container of nt)
            end try
            if folderID is "" then set folderID to my safeText(id of targetFolder)
            return {{my safeText(id of nt), my safeText(name of nt), noteText, my safeText(modification date of nt), folderID, my safeText(count of attachments of nt), my safeText(shared of nt), my safeText(password protected of nt)}}
        end tell
        """
    }

    private static func editableNotePrefix(id: String, expectedModified: String,
                                           rejectAttachments: Bool = true) -> String {
        """
        set nt to first note whose id is \(literal(id))
        if my safeText(modification date of nt) is not \(literal(expectedModified)) then error "AIM_STALE_NOTE"
        if shared of nt then error "AIM_SHARED_NOTE"
        if password protected of nt then error "AIM_LOCKED_NOTE"
        \(rejectAttachments ? "if (count of attachments of nt) > 0 then error \"AIM_NOTE_HAS_ATTACHMENTS\"" : "")
        """
    }

    // Notes on macOS 27 can fail to resolve a note's container right after an
    // edit; the folder is informational, so its absence is tolerated.
    private static let detailReturn = """
    set noteText to my safeText(plaintext of nt)
    if (length of noteText) > 500000 then error "AIM_NOTE_TOO_LARGE"
    set folderID to ""
    try
        set folderID to my safeText(id of container of nt)
    end try
    return {{my safeText(id of nt), my safeText(name of nt), noteText, my safeText(modification date of nt), folderID, my safeText(count of attachments of nt), my safeText(shared of nt), my safeText(password protected of nt)}}
    """

    static func replace(id: String, expectedModified: String, title: String, body: String) -> String {
        """
        tell application id "com.apple.Notes"
            \(editableNotePrefix(id: id, expectedModified: expectedModified))
            set body of nt to \(literal(html(title, body)))
            \(detailReturn)
        end tell
        """
    }

    static func append(id: String, expectedModified: String, text: String) -> String {
        let additionalHTML = html("", text)
        return """
        tell application id "com.apple.Notes"
            \(editableNotePrefix(id: id, expectedModified: expectedModified))
            set beforePlain to my safeText(plaintext of nt)
            set body of nt to (body of nt) & \(literal(additionalHTML))
            set noteText to my safeText(plaintext of nt)
            if (length of noteText) > 500000 then error "AIM_NOTE_TOO_LARGE"
            set folderID to ""
            try
                set folderID to my safeText(id of container of nt)
            end try
            return {{my safeText(id of nt), my safeText(name of nt), noteText, my safeText(modification date of nt), folderID, my safeText(count of attachments of nt), my safeText(shared of nt), my safeText(password protected of nt), beforePlain}}
        end tell
        """
    }

    static func delete(id: String, expectedModified: String) -> String {
        """
        tell application id "com.apple.Notes"
            \(editableNotePrefix(id: id, expectedModified: expectedModified, rejectAttachments: false))
            set originalFolder to missing value
            try
                set originalFolder to container of nt
            end try
            delete nt
            if originalFolder is missing value then
                set remaining to 0
                repeat with f in (every folder)
                    if (name of f) is not "Recently Deleted" then set remaining to remaining + (count of (notes of f whose id is \(literal(id))))
                end repeat
            else
                set remaining to count of (notes of originalFolder whose id is \(literal(id)))
            end if
            return {{\(literal(id)), remaining as string}}
        end tell
        """
    }
}

private struct NotesFolder: Encodable, Sendable {
    let id: String
    let name: String
    let containerID: String
    let shared: Bool
}

private struct NotesFolderPage: Encodable, Sendable {
    let folders: [NotesFolder]
    let total: Int
    let returned: Int
    let truncated: Bool
}

private struct NotesSummary: Encodable, Sendable {
    let id: String
    let name: String
    let modified: String
    let folderID: String
    let shared: Bool
    let passwordProtected: Bool

    init(_ row: [String]) throws {
        guard row.count == 6, !row[0].isEmpty else { throw NotesError.invalidReply }
        id = row[0]; name = row[1]; modified = row[2]; folderID = row[3]
        shared = row[4] == "true"; passwordProtected = row[5] == "true"
    }
}

private struct NotesDetail: Encodable, Sendable {
    let id: String
    let name: String
    let plaintext: String
    let modified: String
    let folderID: String
    let attachmentCount: Int
    let shared: Bool
    let passwordProtected: Bool

    init(_ row: [String]) throws {
        guard row.count == 8, !row[0].isEmpty,
              let attachmentCount = Int(row[5]), attachmentCount >= 0 else { throw NotesError.invalidReply }
        id = row[0]; name = row[1]; plaintext = row[2]; modified = row[3]
        folderID = row[4]; self.attachmentCount = attachmentCount
        shared = row[6] == "true"; passwordProtected = row[7] == "true"
    }
}

private struct NotesPage: Encodable, Sendable {
    let notes: [NotesSummary]
    let total: Int
    let returned: Int
    let nextOffset: Int?
}

private struct NotesRemovalReceipt: Encodable, Sendable {
    let id: String
    let removedFromOriginalFolder: Bool
}

private enum NotesError: LocalizedError {
    case invalidArgument, invalidReply, unverifiedMutation

    var errorDescription: String? {
        switch self {
        case .invalidArgument: "Invalid Notes arguments. Use exact IDs, a 1–100 page size, and a nonempty title; body is required but may be empty."
        case .invalidReply: "Notes returned an unexpected result. Inspect Notes before retrying a mutation."
        case .unverifiedMutation: "AIM could not verify the Notes mutation. Inspect the note before retrying."
        }
    }
}
