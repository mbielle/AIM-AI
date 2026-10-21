import Foundation

/// A multi-file patch in the Codex envelope (`*** Begin Patch` … `*** End Patch`
/// with Add/Update/Delete File sections) or a git-style unified diff. Hunks are
/// located by their context and removed lines, not by line numbers, so a patch
/// still applies when unrelated lines moved; exact text is preferred, then a
/// match ignoring trailing whitespace, then one ignoring indentation.
public enum WorkspacePatch {
    public enum Change: Equatable, Sendable {
        case add(path: String, content: String)
        case update(path: String, chunks: [Chunk])
        case delete(path: String)

        public var path: String {
            switch self { case .add(let path, _), .update(let path, _), .delete(let path): path }
        }
    }

    public struct Chunk: Equatable, Sendable {
        public var old: [String]
        public var new: [String]
    }

    public enum PatchError: LocalizedError, Equatable {
        case empty, malformed(String), contextNotFound(path: String, firstLine: String), duplicatePath(String)
        public var errorDescription: String? {
            switch self {
            case .empty: "The patch contains no file changes."
            case .malformed(let detail): "The patch is malformed: \(detail). Use *** Begin Patch / *** Update File: path / @@ / lines prefixed with space, - or + / *** End Patch, or a unified diff."
            case .contextNotFound(let path, let line): "A hunk for \(path) does not match the current file (first expected line: \"\(line.prefix(120))\"). Read the file again and regenerate that hunk; nothing was changed."
            case .duplicatePath(let path): "\(path) appears twice in the patch; combine its changes in one section."
            }
        }
    }

    public static func parse(_ text: String) throws -> [Change] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let changes = lines.contains(where: { $0.hasPrefix("*** Begin Patch") }) ? try parseEnvelope(lines) : try parseUnified(lines)
        guard !changes.isEmpty else { throw PatchError.empty }
        var seen: Set<String> = []
        for change in changes where !seen.insert(change.path).inserted { throw PatchError.duplicatePath(change.path) }
        return changes
    }

    private static func parseEnvelope(_ lines: [String]) throws -> [Change] {
        var changes: [Change] = []
        var index = 0
        while index < lines.count, !lines[index].hasPrefix("*** Begin Patch") { index += 1 }
        index += 1
        func isHeader(_ line: String) -> Bool { line.hasPrefix("*** ") }
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("*** End Patch") { return changes }
            if line.hasPrefix("*** Add File: ") {
                let path = String(line.dropFirst("*** Add File: ".count)).trimmingCharacters(in: .whitespaces)
                index += 1
                var content: [String] = []
                while index < lines.count, !isHeader(lines[index]) {
                    guard lines[index].hasPrefix("+") else { throw PatchError.malformed("added file lines must start with +") }
                    content.append(String(lines[index].dropFirst()))
                    index += 1
                }
                changes.append(.add(path: path, content: content.joined(separator: "\n") + (content.isEmpty ? "" : "\n")))
            } else if line.hasPrefix("*** Delete File: ") {
                changes.append(.delete(path: String(line.dropFirst("*** Delete File: ".count)).trimmingCharacters(in: .whitespaces)))
                index += 1
            } else if line.hasPrefix("*** Update File: ") {
                let path = String(line.dropFirst("*** Update File: ".count)).trimmingCharacters(in: .whitespaces)
                index += 1
                if index < lines.count, lines[index].hasPrefix("*** Move to:") {
                    throw PatchError.malformed("moves are not supported in a patch; use move_file")
                }
                var body: [String] = []
                while index < lines.count, !isHeader(lines[index]) || lines[index] == "*** End of File" {
                    if lines[index] != "*** End of File" { body.append(lines[index]) }
                    index += 1
                }
                changes.append(.update(path: path, chunks: try chunks(body)))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            } else {
                throw PatchError.malformed("unexpected line \"\(line.prefix(80))\"")
            }
        }
        throw PatchError.malformed("missing *** End Patch")
    }

    private static func parseUnified(_ lines: [String]) throws -> [Change] {
        var changes: [Change] = []
        var index = 0
        func stripPrefix(_ raw: String) -> String {
            let value = raw.split(separator: "\t").first.map(String.init) ?? raw
            if value.hasPrefix("a/") || value.hasPrefix("b/") { return String(value.dropFirst(2)) }
            return value
        }
        while index < lines.count {
            guard lines[index].hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") else { index += 1; continue }
            let oldPath = stripPrefix(String(lines[index].dropFirst(4)))
            let newPath = stripPrefix(String(lines[index + 1].dropFirst(4)))
            index += 2
            var body: [String] = []
            while index < lines.count, !(lines[index].hasPrefix("--- ") && index + 1 < lines.count && lines[index + 1].hasPrefix("+++ ")),
                  !lines[index].hasPrefix("diff --git") {
                body.append(lines[index])
                index += 1
            }
            if newPath == "/dev/null" {
                changes.append(.delete(path: oldPath))
            } else if oldPath == "/dev/null" {
                let added = body.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }
                changes.append(.add(path: newPath, content: added.joined(separator: "\n") + (added.isEmpty ? "" : "\n")))
            } else {
                guard oldPath == newPath else { throw PatchError.malformed("renames are not supported; use move_file") }
                changes.append(.update(path: newPath, chunks: try chunks(body.filter { !$0.hasPrefix("\\ No newline") })))
            }
            while index < lines.count, !lines[index].hasPrefix("--- "), lines[index].hasPrefix("diff --git") || lines[index].hasPrefix("index ") ||
                    lines[index].hasPrefix("new file") || lines[index].hasPrefix("deleted file") || lines[index].isEmpty { index += 1 }
        }
        return changes
    }

    /// Splits an update body into chunks at `@@` lines.
    private static func chunks(_ body: [String]) throws -> [Chunk] {
        var result: [Chunk] = []
        var current = Chunk(old: [], new: [])
        func flush() {
            if !current.old.isEmpty || !current.new.isEmpty { result.append(current) }
            current = Chunk(old: [], new: [])
        }
        for line in body {
            if line.hasPrefix("@@") { flush(); continue }
            if line.isEmpty { current.old.append(""); current.new.append(""); continue }
            switch line.first {
            case " ": current.old.append(String(line.dropFirst())); current.new.append(String(line.dropFirst()))
            case "-": current.old.append(String(line.dropFirst()))
            case "+": current.new.append(String(line.dropFirst()))
            default: throw PatchError.malformed("update lines must start with space, - or + (\"\(line.prefix(60))\")")
            }
        }
        flush()
        // Trailing blank lines produced by the envelope are not part of the context.
        for index in result.indices {
            while let last = result[index].old.last, last.isEmpty, result[index].new.last == "" {
                result[index].old.removeLast(); result[index].new.removeLast()
            }
        }
        guard !result.isEmpty, result.allSatisfy({ !$0.old.isEmpty || !$0.new.isEmpty }) else { throw PatchError.malformed("an update has no hunk") }
        return result
    }

    /// Applies update chunks to a file's text, in order.
    public static func apply(_ chunks: [Chunk], to text: String, path: String) throws -> String {
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline { lines.removeLast() }
        var cursor = 0
        for chunk in chunks {
            if chunk.old.isEmpty {
                // Pure insertion without context: append at the end.
                lines.append(contentsOf: chunk.new)
                cursor = lines.count
                continue
            }
            guard let start = locate(chunk.old, in: lines, from: cursor) ?? locate(chunk.old, in: lines, from: 0) else {
                throw PatchError.contextNotFound(path: path, firstLine: chunk.old.first ?? "")
            }
            lines.replaceSubrange(start..<(start + chunk.old.count), with: chunk.new)
            cursor = start + chunk.new.count
        }
        return lines.joined(separator: "\n") + (endsWithNewline || text.isEmpty ? "\n" : "")
    }

    private static func locate(_ needle: [String], in lines: [String], from start: Int) -> Int? {
        guard needle.count <= lines.count, start <= lines.count - needle.count else { return nil }
        let normalizers: [(String) -> String] = [
            { $0 },
            { String($0.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) },
            { $0.trimmingCharacters(in: .whitespaces) }
        ]
        for normalize in normalizers {
            let target = needle.map(normalize)
            var found: Int?
            for index in max(0, start)...(lines.count - needle.count) {
                if zip(lines[index..<(index + needle.count)], target).allSatisfy({ normalize($0) == $1 }) {
                    found = index
                    break
                }
            }
            if let found { return found }
        }
        return nil
    }
}
