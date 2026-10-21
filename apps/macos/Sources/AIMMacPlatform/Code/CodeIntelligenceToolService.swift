import AIMAgentKit
import Foundation

/// Language-aware code tools backed by installed language servers (as Hermes and
/// OpenClaw do): diagnostics, definition, references and symbols for a file in
/// the workspace. Swift uses sourcekit-lsp from the Xcode toolchain; TypeScript,
/// Python, Go and Rust servers are used when installed. Read-only.
public actor CodeIntelligenceToolService: ToolExecutor, ToolSessionClosing {
    public nonisolated let supportedTools: Set<String> = ["code_diagnostics", "code_definition", "code_references", "code_symbols"]

    struct Server { let language: String; let command: [String] }

    private var clients: [String: LanguageServerClient] = [:]
    private var versions: [String: Int] = [:]

    public init() {}

    public nonisolated static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") || server(forExtension: "ts") != nil
    }

    nonisolated static func server(forExtension ext: String) -> Server? {
        func onPath(_ name: String) -> String? {
            ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/go/bin",
             "\(NSHomeDirectory())/.cargo/bin"].map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        switch ext.lowercased() {
        case "swift": return Server(language: "swift", command: ["/usr/bin/xcrun", "sourcekit-lsp"])
        case "ts", "tsx", "js", "jsx", "mjs", "cjs":
            return onPath("typescript-language-server").map { Server(language: "typescript", command: [$0, "--stdio"]) }
        case "py":
            if let pyright = onPath("pyright-langserver") { return Server(language: "python", command: [pyright, "--stdio"]) }
            return onPath("pylsp").map { Server(language: "python", command: [$0]) }
        case "go": return onPath("gopls").map { Server(language: "go", command: [$0]) }
        case "rs": return onPath("rust-analyzer").map { Server(language: "rust", command: [$0]) }
        default: return nil
        }
    }

    nonisolated static func languageID(_ ext: String) -> String {
        switch ext.lowercased() {
        case "ts": "typescript"; case "tsx": "typescriptreact"; case "jsx": "javascriptreact"
        case "js", "mjs", "cjs": "javascript"; case "py": "python"; case "rs": "rust"
        default: ext.lowercased()
        }
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            guard let workspace = request.workspacePath else { throw CodeError.noWorkspace }
            let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard let path = request.arguments["path"] else { throw CodeError.invalid("path is required") }
            let file = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
                .resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"), let text = try? String(contentsOf: file, encoding: .utf8),
                  text.utf8.count <= 2_000_000 else { throw CodeError.invalid("path must be a UTF-8 text file inside the workspace") }
            guard let server = Self.server(forExtension: file.pathExtension) else {
                throw CodeError.invalid("no language server is installed for .\(file.pathExtension) files (Swift is supported through Xcode; install typescript-language-server, pyright, gopls or rust-analyzer for others)")
            }
            let client = try await client(server, root: root)
            let uri = file.absoluteString
            try open(client, uri: uri, text: text, language: Self.languageID(file.pathExtension))
            let relative = String(file.path.dropFirst(root.path.count + 1))
            switch request.name {
            case "code_diagnostics":
                var items = await client.diagnostics(for: uri, waitingUpTo: .seconds(25))
                if items.isEmpty { items = await client.diagnostics(for: uri, waitingUpTo: .seconds(5)) }
                let lines = text.components(separatedBy: "\n")
                let rendered = items.prefix(100).map { item -> String in
                    let severity = ["", "error", "warning", "info", "hint"][min(max(item["severity"] as? Int ?? 1, 0), 4)]
                    let (line, column) = Self.position(item["range"], lines: lines)
                    return "\(relative):\(line):\(column): \(severity): \((item["message"] as? String ?? "").prefix(400))"
                }
                return ToolResult(requestID: request.id, content: rendered.isEmpty
                    ? "No diagnostics reported for \(relative) by the \(server.language) language server (it may not see build errors outside this file; use verify_project to build)."
                    : rendered.joined(separator: "\n"), metadata: ["diagnostics": String(items.count)])
            case "code_symbols":
                let result = try await client.request("textDocument/documentSymbol", ["textDocument": ["uri": uri]])
                var lines: [String] = []
                Self.collectSymbols(result as? [[String: Any]] ?? [], depth: 0, into: &lines, text: text.components(separatedBy: "\n"))
                return ToolResult(requestID: request.id, content: lines.isEmpty ? "No symbols found." : lines.prefix(300).joined(separator: "\n"))
            default:
                guard let line = Int(request.arguments["line"] ?? ""), let column = Int(request.arguments["column"] ?? ""),
                      line >= 1, column >= 1 else { throw CodeError.invalid("line and column (1-based) are required") }
                let lines = text.components(separatedBy: "\n")
                guard line <= lines.count else { throw CodeError.invalid("line is beyond the end of the file") }
                let position = ["line": line - 1, "character": Self.utf16Offset(in: lines[line - 1], column: column)]
                let method = request.name == "code_definition" ? "textDocument/definition" : "textDocument/references"
                var params: [String: Any] = ["textDocument": ["uri": uri], "position": position]
                if request.name == "code_references" { params["context"] = ["includeDeclaration": true] }
                let result = try await client.request(method, params, timeout: .seconds(45))
                let locations = Self.locations(result)
                let rendered = locations.prefix(100).map { Self.describe($0, root: root) }
                return ToolResult(requestID: request.id, content: rendered.isEmpty ? "No location found (the server may need the project to be built first)." : rendered.joined(separator: "\n"))
            }
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    public func closeSession() async {
        for client in clients.values {
            _ = try? await client.request("shutdown", NSNull(), timeout: .seconds(3))
            try? client.notify("exit", NSNull())
            client.stop()
        }
        clients.removeAll()
        versions.removeAll()
    }

    // MARK: Helpers

    private func client(_ server: Server, root: URL) async throws -> LanguageServerClient {
        if let existing = clients[server.language] { return existing }
        let client = try LanguageServerClient(command: server.command, workspace: root)
        _ = try await client.request("initialize", [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
            "capabilities": ["textDocument": [
                "publishDiagnostics": ["relatedInformation": false],
                "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                "definition": [:], "references": [:]
            ]]
        ] as [String: Any], timeout: .seconds(60))
        try client.notify("initialized", [:] as [String: Any])
        clients[server.language] = client
        return client
    }

    private func open(_ client: LanguageServerClient, uri: String, text: String, language: String) throws {
        if let version = versions[uri] {
            versions[uri] = version + 1
            client.clearDiagnostics(for: uri)
            try client.notify("textDocument/didChange", ["textDocument": ["uri": uri, "version": version + 1],
                                                         "contentChanges": [["text": text]]] as [String: Any])
        } else {
            versions[uri] = 1
            try client.notify("textDocument/didOpen", ["textDocument": ["uri": uri, "languageId": language, "version": 1, "text": text]])
        }
    }

    static func utf16Offset(in line: String, column: Int) -> Int {
        let prefix = line.prefix(max(0, column - 1))
        return prefix.utf16.count
    }

    static func position(_ range: Any?, lines: [String]) -> (Int, Int) {
        guard let start = (range as? [String: Any])?["start"] as? [String: Any],
              let line = start["line"] as? Int, let character = start["character"] as? Int else { return (0, 0) }
        let text = line < lines.count ? lines[line] : ""
        let units = Array(text.utf16.prefix(character))
        let column = (String(utf16CodeUnits: units, count: units.count)).count + 1
        return (line + 1, column)
    }

    static func locations(_ result: Any) -> [[String: Any]] {
        if let single = result as? [String: Any] { return [single] }
        return (result as? [[String: Any]] ?? []).map { item in
            // LocationLink → Location
            if let target = item["targetUri"] { return ["uri": target, "range": item["targetSelectionRange"] ?? item["targetRange"] ?? [:]] }
            return item
        }
    }

    static func describe(_ location: [String: Any], root: URL) -> String {
        guard let uri = location["uri"] as? String, let url = URL(string: uri) else { return "?" }
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        let (line, column) = position(location["range"], lines: lines)
        let path = url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
        let excerpt = line >= 1 && line <= lines.count ? lines[line - 1].trimmingCharacters(in: .whitespaces).prefix(200) : ""
        return "\(path):\(line):\(column): \(excerpt)"
    }

    static func collectSymbols(_ symbols: [[String: Any]], depth: Int, into lines: inout [String], text: [String]) {
        let kinds = [5: "class", 6: "method", 8: "field", 9: "constructor", 10: "enum", 11: "interface", 12: "function",
                     13: "variable", 14: "constant", 22: "enum case", 23: "struct", 26: "type parameter", 7: "property"]
        for symbol in symbols {
            guard lines.count < 300 else { return }
            let name = symbol["name"] as? String ?? "?"
            let kind = kinds[symbol["kind"] as? Int ?? 0] ?? "symbol"
            let range = symbol["selectionRange"] ?? symbol["range"] ?? (symbol["location"] as? [String: Any])?["range"]
            let (line, _) = position(range, lines: text)
            lines.append(String(repeating: "  ", count: depth) + "\(kind) \(name) (line \(line))")
            collectSymbols(symbol["children"] as? [[String: Any]] ?? [], depth: depth + 1, into: &lines, text: text)
        }
    }

    enum CodeError: LocalizedError {
        case noWorkspace, invalid(String)
        var errorDescription: String? {
            switch self {
            case .noWorkspace: "Select a workspace first."
            case .invalid(let detail): detail
            }
        }
    }
}
