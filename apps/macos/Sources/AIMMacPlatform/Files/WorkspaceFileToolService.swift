import AIMAgentKit
import Foundation

public struct WorkspaceEntry: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public init(path: String, name: String, isDirectory: Bool) {
        self.path = path; self.name = name; self.isDirectory = isDirectory
    }
}

public struct WorkspaceSearchMatch: Identifiable, Sendable {
    public var id: String { "\(path):\(line)" }
    public let path: String
    public let line: Int
    public let excerpt: String
}

public struct WorkspaceSearchResult: Sendable {
    public let matches: [WorkspaceSearchMatch]
    public let isTruncated: Bool
    public let visitedEntries: Int
}

public actor WorkspaceFileToolService: FileToolServing {
    public nonisolated let supportedTools: Set<String> = [
        "read_file", "list_dir", "search_files", "find_files",
    ]

    private let fileManager: FileManager
    private let maximumReadBytes = 1_000_000

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            guard let workspace = request.workspacePath else { throw WorkspaceError.missingWorkspace }
            let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            switch request.name {
            case "read_file":
                let target = try resolve(request.arguments["path"], within: root)
                if request.arguments["start_line"] != nil || request.arguments["end_line"] != nil {
                    let start = try parseLine(request.arguments["start_line"]) ?? 1
                    let end = try parseLine(request.arguments["end_line"]) ?? Int.max
                    guard end >= start else { throw WorkspaceError.invalidLineRange }
                    return success(request, try readTextLines(target, from: start, through: end))
                }
                return success(request, try readText(target))
            case "list_dir":
                let target = try resolve(request.arguments["path"] ?? ".", within: root)
                let entries = try fileManager.contentsOfDirectory(at: target, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    .prefix(1_000)
                    .map { url in
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        return "\(values?.isDirectory == true ? "dir" : "file")\t\(values?.fileSize ?? 0)\t\(url.lastPathComponent)"
                    }
                return success(request, entries.joined(separator: "\n"))
            case "search_files":
                let caseSensitive: Bool
                switch request.arguments["case_sensitive"] {
                case nil, "false": caseSensitive = false
                case "true": caseSensitive = true
                default: throw WorkspaceError.invalidSearchOption
                }
                let regex: Bool
                switch request.arguments["regex"] {
                case nil, "false": regex = false
                case "true": regex = true
                default: throw WorkspaceError.invalidSearchOption
                }
                let result = try searchText(request.arguments["query"] ?? "", workspace: root.path,
                                            filePattern: request.arguments["file_pattern"], caseSensitive: caseSensitive,
                                            regex: regex)
                let lines = result.matches.map { "\($0.path):\($0.line):\($0.excerpt)" }
                return success(request, (lines + (result.isTruncated ? ["[Search limit reached; results are incomplete. Narrow the search.]"] : [])).joined(separator: "\n"))
            case "find_files":
                let result = try findFiles(matching: request.arguments["pattern"] ?? "", workspace: root.path)
                let lines = result.matches.map(\.path)
                return success(request, (lines + (result.isTruncated ? ["[File listing is incomplete; narrow the pattern.]"] : [])).joined(separator: "\n"))
            default:
                return ToolResult(requestID: request.id, content: "Unsupported file tool: \(request.name)", isError: true)
            }
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    /// Shared bounded local preview; does not upload contents or grant tool execution rights.
    public func previewText(workspace: String, path: String) throws -> String {
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        return try readText(resolve(path, within: root))
    }

    /// Local browsing only: results are never sent to a provider by this service.
    public func entries(workspace: String, path: String = ".") throws -> [WorkspaceEntry] {
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        let directory = try resolve(path, within: root)
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try urls.prefix(1_000).compactMap { url in
            // Do not expose shortcuts into folders outside the selected workspace.
            guard (try? resolve(url.path, within: root)) != nil else { return nil }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let components = Array(directory.pathComponents.dropFirst(root.pathComponents.count)) + [url.lastPathComponent]
            return WorkspaceEntry(path: components.joined(separator: "/"), name: url.lastPathComponent, isDirectory: values.isDirectory == true)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func readText(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw WorkspaceError.expectedFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumReadBytes + 1) ?? Data()
        guard data.count <= maximumReadBytes else { throw WorkspaceError.fileTooLarge(data.count) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.unsupportedEncoding }
        return text
    }

    private func parseLine(_ value: String?) throws -> Int? {
        guard let value else { return nil }
        guard let line = Int(value), line > 0 else { throw WorkspaceError.invalidLineRange }
        return line
    }

    private func readTextLines(_ url: URL, from start: Int, through end: Int) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw WorkspaceError.expectedFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let scanLimit = 64 * 1_024 * 1_024
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let outputLimit = 120_000
        var output = ""
        var currentLine = Data()
        var lineNumber = 1
        var scanned = 0
        var lastWasNewline = false
        func appendLine() throws -> Bool {
            guard lineNumber >= start, lineNumber <= end else { return false }
            guard let line = String(data: currentLine, encoding: .utf8) else { throw WorkspaceError.unsupportedEncoding }
            let next = "\(lineNumber): \(line.hasSuffix("\r") ? String(line.dropLast()) : line)\n"
            if output.utf8.count + next.utf8.count > outputLimit {
                output += "[Range output truncated; request a narrower line range.]"
                return true
            }
            output += next
            return false
        }
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard scanned + chunk.count <= scanLimit, ContinuousClock.now < deadline else { throw WorkspaceError.readScanLimit }
            scanned += chunk.count
            for byte in chunk {
                if byte == 0 { throw WorkspaceError.unsupportedEncoding }
                if byte == 10 {
                    if try appendLine() { return output }
                    currentLine.removeAll(keepingCapacity: true)
                    lineNumber += 1
                    lastWasNewline = true
                    if lineNumber > end { return output }
                } else {
                    lastWasNewline = false
                    if lineNumber >= start && lineNumber <= end {
                        currentLine.append(byte)
                        if currentLine.count > outputLimit {
                            return output + "\(lineNumber): [Line exceeds the preview limit; inspect a smaller source.]\n"
                        }
                    }
                }
            }
        }
        if !lastWasNewline || scanned == 0 { if try appendLine() { return output } }
        return output.isEmpty ? "[No lines in the requested range; file has \(lineNumber - (lastWasNewline ? 1 : 0)) lines.]" : output
    }

    private func resolve(_ path: String?, within root: URL) throws -> URL {
        guard let path, !path.isEmpty else { throw WorkspaceError.missingPath }
        let unresolved = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appending(path: path)
        let target = unresolved.resolvingSymlinksInPath().standardizedFileURL
        guard target == root || target.path.hasPrefix(root.path + "/") else { throw WorkspaceError.outsideWorkspace }
        return target
    }

    public func searchText(_ query: String, workspace: String, maximumMatches: Int = 200, maximumEntries: Int = 10_000,
                           filePattern: String? = nil, caseSensitive: Bool = false,
                           regex: Bool = false) throws -> WorkspaceSearchResult {
        guard !query.isEmpty else { throw WorkspaceError.emptySearch }
        guard query.utf8.count <= 512, !query.contains("\0") else { throw WorkspaceError.invalidSearchQuery }
        let expression: NSRegularExpression?
        if regex {
            do { expression = try NSRegularExpression(pattern: query, options: caseSensitive ? [] : [.caseInsensitive]) }
            catch { throw WorkspaceError.invalidRegex }
        } else { expression = nil }
        // Very long lines (minified files) are skipped in regex mode to bound backtracking.
        func lineMatches(_ line: Substring) -> Bool {
            if let expression {
                guard line.utf16.count <= 4_096 else { return false }
                let text = String(line)
                return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
            return caseSensitive ? line.contains(query) : line.localizedCaseInsensitiveContains(query)
        }
        if let filePattern { try Self.validateFilePattern(filePattern) }
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw WorkspaceError.expectedDirectory }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw WorkspaceError.expectedDirectory }
        let matchLimit = min(max(maximumMatches, 1), 200)
        let entryLimit = min(max(maximumEntries, 1), 10_000)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var matches: [WorkspaceSearchMatch] = []
        var visited = 0
        var truncated = false
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if matches.count >= matchLimit || visited >= entryLimit || ContinuousClock.now >= deadline { truncated = true; break }
            visited += 1
            if ["node_modules", "build", ".build", "vendor"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let target = try? resolve(url.path, within: root) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true, (values?.fileSize ?? Int.max) <= maximumReadBytes else { continue }
            let relativePath = target.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            if let filePattern, !Self.globMatch(filePattern, relativePath) { continue }
            guard let text = try? readText(target), !text.contains("\0") else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where lineMatches(line) {
                try Task.checkCancellation()
                if matches.count >= matchLimit || ContinuousClock.now >= deadline { truncated = true; break }
                matches.append(WorkspaceSearchMatch(path: relativePath, line: index + 1, excerpt: String(line.prefix(300))))
            }
            if truncated { break }
        }
        return WorkspaceSearchResult(matches: matches, isTruncated: truncated, visitedEntries: visited)
    }

    /// A pattern without a slash matches file names at any depth. Path patterns
    /// match relative components: `**` spans directories, while `*`, `?` and
    /// bracket classes match within one component.
    public func findFiles(matching pattern: String, workspace: String, maximumMatches: Int = 200,
                          maximumEntries: Int = 10_000) throws -> WorkspaceSearchResult {
        try Self.validateFilePattern(pattern)
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw WorkspaceError.expectedDirectory }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw WorkspaceError.expectedDirectory }
        let matchLimit = min(max(maximumMatches, 1), 200)
        let entryLimit = min(max(maximumEntries, 1), 10_000)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var matches: [WorkspaceSearchMatch] = []
        var visited = 0
        var truncated = false
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if matches.count >= matchLimit || visited >= entryLimit || ContinuousClock.now >= deadline { truncated = true; break }
            visited += 1
            if ["node_modules", "build", ".build", "vendor"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let target = try? resolve(url.path, within: root) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            let relativePath = target.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            if Self.globMatch(pattern, relativePath) {
                matches.append(WorkspaceSearchMatch(path: relativePath, line: 0, excerpt: "File name match"))
            }
        }
        return WorkspaceSearchResult(matches: matches.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                                     isTruncated: truncated, visitedEntries: visited)
    }

    private static func validateFilePattern(_ pattern: String) throws {
        guard !pattern.isEmpty, pattern.utf8.count <= 256, !pattern.contains("\0"),
              !pattern.hasPrefix("/"),
              pattern.split(separator: "/", omittingEmptySubsequences: false)
                  .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw WorkspaceError.invalidPattern }
    }

    private static func globMatch(_ pattern: String, _ path: String) -> Bool {
        if !pattern.contains("/") {
            return segmentMatch(pattern, String(path.split(separator: "/").last ?? ""))
        }
        let components = pattern.split(separator: "/").map(String.init)
        let candidate = path.split(separator: "/").map(String.init)
        var reachable = Array(repeating: Array(repeating: false, count: candidate.count + 1),
                              count: components.count + 1)
        reachable[0][0] = true
        for index in components.indices {
            if components[index] == "**" {
                for depth in 0...candidate.count {
                    reachable[index + 1][depth] = reachable[index][depth]
                        || (depth > 0 && reachable[index + 1][depth - 1])
                }
            } else {
                for depth in candidate.indices where reachable[index][depth] {
                    if segmentMatch(components[index], candidate[depth]) {
                        reachable[index + 1][depth + 1] = true
                    }
                }
            }
        }
        return reachable[components.count][candidate.count]
    }

    private enum GlobToken {
        case literal(Character), any, star
        case characterClass([Character], [(Character, Character)], Bool)

        func matches(_ value: Character) -> Bool {
            switch self {
            case let .literal(expected): return value == expected
            case .any: return true
            case .star: return true
            case let .characterClass(members, ranges, negated):
                let included = members.contains(value) || ranges.contains { $0.0 <= value && value <= $0.1 }
                return negated ? !included : included
            }
        }
    }

    /// Dynamic programming keeps consecutive stars and bracket classes linear
    /// in pattern and filename length instead of running a backtracking regex.
    private static func segmentMatch(_ pattern: String, _ value: String) -> Bool {
        let tokens = globTokens(pattern)
        let characters = Array(value)
        var reachable = Array(repeating: false, count: characters.count + 1)
        reachable[0] = true
        for token in tokens {
            var next = Array(repeating: false, count: characters.count + 1)
            switch token {
            case .star:
                next[0] = reachable[0]
                for index in characters.indices { next[index + 1] = reachable[index + 1] || next[index] }
            default:
                for index in characters.indices where reachable[index] && token.matches(characters[index]) {
                    next[index + 1] = true
                }
            }
            reachable = next
        }
        return reachable[characters.count]
    }

    private static func globTokens(_ pattern: String) -> [GlobToken] {
        let characters = Array(pattern)
        var tokens: [GlobToken] = []
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "*": tokens.append(.star)
            case "?": tokens.append(.any)
            case "\\" where index + 1 < characters.count:
                index += 1
                tokens.append(.literal(characters[index]))
            case "[":
                let start = index + 1
                var end = start
                while end < characters.count && characters[end] != "]" { end += 1 }
                if end < characters.count && end > start {
                    var values = Array(characters[start..<end])
                    let negated = values.first == "!" || values.first == "^"
                    if negated { values.removeFirst() }
                    if !values.isEmpty {
                        var members: [Character] = []
                        var ranges: [(Character, Character)] = []
                        var position = 0
                        while position < values.count {
                            if position + 2 < values.count && values[position + 1] == "-" {
                                ranges.append((values[position], values[position + 2]))
                                position += 3
                            } else {
                                members.append(values[position])
                                position += 1
                            }
                        }
                        tokens.append(.characterClass(members, ranges, negated))
                        index = end
                    } else { tokens.append(.literal("[")) }
                } else { tokens.append(.literal("[")) }
            default: tokens.append(.literal(characters[index]))
            }
            index += 1
        }
        return tokens
    }

    private func success(_ request: ToolRequest, _ content: String) -> ToolResult {
        ToolResult(requestID: request.id, content: content)
    }
}

public enum WorkspaceError: LocalizedError {
    case missingWorkspace, missingPath, outsideWorkspace
    case fileTooLarge(Int), readScanLimit, emptySearch, invalidSearchQuery, invalidRegex, invalidSearchOption, invalidLineRange, invalidPattern, expectedFile, expectedDirectory, unsupportedEncoding

    public var errorDescription: String? {
        switch self {
        case .missingWorkspace: "No workspace is selected."
        case .missingPath: "A file path is required."
        case .outsideWorkspace: "The path is outside the selected workspace."
        case let .fileTooLarge(bytes): "The file is too large to read safely (\(bytes) bytes)."
        case .readScanLimit: "The requested line range could not be reached within the bounded file scan. Narrow the range or inspect the file another way."
        case .emptySearch: "The search text cannot be empty."
        case .invalidSearchQuery: "Search text must be valid UTF-8 without null characters and at most 512 bytes."
        case .invalidRegex: "The regular expression is not valid (ICU syntax, as in NSRegularExpression)."
        case .invalidSearchOption: "Use true or false for case_sensitive."
        case .invalidLineRange: "Use positive start_line/end_line values, with end_line at or after start_line."
        case .invalidPattern: "Enter a relative file pattern up to 256 bytes. Use *, ?, [abc] or ** directory components."
        case .expectedFile: "The target is not a file."
        case .expectedDirectory: "The target is not a directory."
        case .unsupportedEncoding: "Only UTF-8 text files can be previewed."
        }
    }
}
