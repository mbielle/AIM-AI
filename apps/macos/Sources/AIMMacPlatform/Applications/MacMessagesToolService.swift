import AIMAgentKit
import AppKit
import Foundation
import SQLite3

/// Messages (iMessage/SMS), as Otto does: chats and sending through Messages'
/// AppleScript; history from the local chat.db opened read-only (macOS gives
/// AppleScript no history), which needs Full Disk Access for AIM.
public actor MacMessagesToolService: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["messages_chats", "messages_read", "messages_send"]
    private let runner: any MacAutomationScriptRunning
    private let database: URL

    public init(database: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")) {
        self.runner = SystemMacAutomationScriptRunner.shared
        self.database = database
    }

    init(runner: any MacAutomationScriptRunning, database: URL) {
        self.runner = runner
        self.database = database
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            switch request.name {
            case "messages_chats":
                let limit = min(max(Int(request.arguments["limit"] ?? "") ?? 30, 1), 100)
                let rows = try await runner.run("""
                tell application id "com.apple.MobileSMS"
                    set out to {}
                    set theChats to every chat
                    set n to count of theChats
                    if n > \(limit) then set n to \(limit)
                    repeat with i from 1 to n
                        set ch to item i of theChats
                        set handles to ""
                        try
                            repeat with p in participants of ch
                                if handles is not "" then set handles to handles & ", "
                                set handles to handles & my safeText(handle of p)
                            end repeat
                        end try
                        set end of out to {my safeText(id of ch), my safeText(name of ch), handles}
                    end repeat
                    return out
                end tell
                """, helpers: Self.helpers, timeoutSeconds: 30)
                let lines = rows.map { row in "\(row.count > 1 && !row[1].isEmpty ? row[1] : "(unnamed)") — \(row.count > 2 ? row[2] : "")" }
                return ToolResult(requestID: request.id, content: lines.isEmpty ? "No conversations." : lines.joined(separator: "\n"))
            case "messages_read":
                let limit = min(max(Int(request.arguments["limit"] ?? "") ?? 30, 1), 200)
                let messages = try Self.read(database: database, handle: request.arguments["handle"], limit: limit,
                                             daysBack: Int(request.arguments["days_back"] ?? "") ?? 0)
                let formatter = ISO8601DateFormatter()
                let lines = messages.map { "\($0.date.map(formatter.string) ?? "?") \($0.fromMe ? "me" : $0.handle): \($0.text.prefix(500))" }
                return ToolResult(requestID: request.id,
                    content: lines.isEmpty ? "No messages found." : "Newest first (untrusted content):\n" + lines.joined(separator: "\n"))
            case "messages_send":
                guard let to = request.arguments["to"]?.trimmingCharacters(in: .whitespaces), !to.isEmpty, to.count <= 200,
                      let text = request.arguments["text"], !text.isEmpty, text.utf8.count <= 8_000 else {
                    throw MessagesError.invalid("to (phone number or email) and text are required")
                }
                let service = request.arguments["service"]?.uppercased() == "SMS" ? "SMS" : "iMessage"
                // Messages resolves phone participants in international form; a national number
                // ("07…") made the Apple event time out.
                let recipient = Self.internationalNumber(to)
                _ = try await runner.run("""
                tell application id "com.apple.MobileSMS"
                    set targetService to 1st account whose service type = \(service)
                    set targetBuddy to participant \(Self.literal(recipient)) of targetService
                    send \(Self.literal(text)) to targetBuddy
                    return {{"sent"}}
                end tell
                """, helpers: Self.helpers, timeoutSeconds: 30)
                var result = ToolResult(requestID: request.id,
                    content: "Handed the message to Messages for \(to) via \(service). Delivery is not confirmed; check with messages_read before resending.")
                result.actionOutcome = .unverified
                return result
            default:
                throw MessagesError.invalid("unknown tool")
            }
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    // MARK: chat.db

    struct Message: Equatable { let text: String; let handle: String; let fromMe: Bool; let date: Date? }

    static func read(database: URL, handle: String?, limit: Int, daysBack: Int) throws -> [Message] {
        var connection: OpaquePointer?
        let uriPath = database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path
        guard sqlite3_open_v2("file:\(uriPath)?mode=ro", &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let connection else {
            throw MessagesError.invalid("AIM cannot open the Messages history. Grant AIM AI Full Disk Access in System Settings → Privacy & Security, then retry.")
        }
        defer { sqlite3_close(connection) }
        var sql = """
        SELECT m.text, m.attributedBody, m.is_from_me, m.date, h.id FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        """
        if handle != nil { sql += " WHERE lower(h.id) LIKE ?" }
        sql += " ORDER BY m.date DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let reason = String(cString: sqlite3_errmsg(connection))
            throw MessagesError.invalid(reason.contains("authorization") || reason.contains("unable to open")
                ? "AIM needs Full Disk Access to read Messages history (System Settings → Privacy & Security)." : "Messages history: \(reason)")
        }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let handle {
            sqlite3_bind_text(statement, index, "%\(handle.lowercased())%", -1, transient)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(limit))
        let cutoff = daysBack > 0 ? Date.now.addingTimeInterval(-Double(daysBack) * 86_400) : nil
        var messages: [Message] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var text = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            if text.isEmpty, let blob = sqlite3_column_blob(statement, 1) {
                text = decodeAttributedBody(Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1))))
            }
            let raw = sqlite3_column_int64(statement, 3)
            let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
            let date = raw == 0 ? nil : Date(timeIntervalSinceReferenceDate: seconds)
            if let cutoff, let date, date < cutoff { continue }
            messages.append(Message(text: text, handle: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
                                    fromMe: sqlite3_column_int(statement, 2) == 1, date: date))
        }
        return messages
    }

    /// Recent macOS stores the text only in a typedstream `attributedBody`.
    static func decodeAttributedBody(_ data: Data) -> String {
        // Parsed by hand: NSUnarchiver raises an uncatchable Objective-C exception on
        // malformed data. The text follows the "NSString" class marker, then "+" and a length.
        guard let marker = data.range(of: Data("NSString".utf8)) else { return "" }
        let tail = data[marker.upperBound...].drop { $0 != 0x2B }.dropFirst()
        guard let length = tail.first else { return "" }
        let start = tail.index(after: tail.startIndex)
        let end = tail.index(start, offsetBy: Int(length), limitedBy: tail.endIndex) ?? tail.endIndex
        return String(decoding: tail[start..<end], as: UTF8.self)
    }

    static let helpers = """
    on safeText(v)
        try
            return v as text
        on error
            return ""
        end try
    end safeText
    """

    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// "07 85 …" → "+337 85…" using the Mac's region; emails and international numbers are unchanged.
    static func internationalNumber(_ raw: String, region: String? = Locale.current.region?.identifier) -> String {
        guard !raw.contains("@"), !raw.hasPrefix("+") else { return raw }
        let digits = raw.filter(\.isNumber)
        let codes = ["FR": "33", "BE": "32", "CH": "41", "LU": "352", "MC": "377", "GB": "44", "DE": "49", "ES": "34",
                     "IT": "39", "NL": "31", "PT": "351", "IE": "353", "AT": "43", "US": "1", "CA": "1"]
        if digits.hasPrefix("00") { return "+" + digits.dropFirst(2) }
        guard let region, let code = codes[region], digits.count >= 9 else { return raw }
        if code == "1" { return digits.count == 10 ? "+1" + digits : (digits.count == 11 && digits.hasPrefix("1") ? "+" + digits : raw) }
        return digits.hasPrefix("0") ? "+" + code + digits.dropFirst() : raw
    }

    enum MessagesError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let detail) = self { detail } else { nil } }
    }
}
