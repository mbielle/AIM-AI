import AIMCore
import AIMAgentKit
import AIMApplication
import Foundation

/// Lets the agent author a small MCP server when no tool covers a need (as
/// Otto's mcp_builder does), within strict limits:
/// - each tool is a JavaScript async function body `(args, env, fetch)` with no
///   imports; network only through `fetch` to the declared HTTPS hosts;
/// - a static audit rejects modules, `process`, code generation, prototype
///   tricks and literal secrets; at run time the Function constructors are
///   neutered and `process` hidden before any tool code loads;
/// - Node runs with `--permission`: no file access outside the server's own
///   folder, no child processes, workers or native addons;
/// - secrets are only names, filled from the Keychain by the person;
/// - creating or replacing a server is always an exact approval showing the
///   full generated source, and the server is registered untrusted.
public actor AgentMCPBuilder: ToolExecutor, ToolReviewProviding {
    public nonisolated let supportedTools: Set<String> = ["create_mcp_server"]

    public struct ToolSpec: Codable, Equatable, Sendable {
        public let name: String
        public let description: String
        public let input_schema: ToolJSONValue?
        public let code: String
    }

    public struct Spec: Equatable, Sendable {
        public let name: String
        public let description: String
        public let tools: [ToolSpec]
        public let allowedHosts: [String]
        public let secretNames: [String]
    }

    private let root: URL
    private let node: URL?
    private let repository: (any MCPServerRepository)?
    private let verify: @Sendable (MCPServerConfiguration) async throws -> Int

    public static var defaultRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent(AIMInstallationContext.applicationSupportNamespace + "/MCP/custom", isDirectory: true)
    }

    public init(root: URL = AgentMCPBuilder.defaultRoot,
                node: URL? = HostBundleResources.resourceURL?.appendingPathComponent("Playwright/node"),
                repository: (any MCPServerRepository)?,
                verify: @escaping @Sendable (MCPServerConfiguration) async throws -> Int = { server in
                    await MCPServerManager.shared.disconnect(server.id)
                    return try await MCPServerManager.shared.tools(of: server).count
                }) {
        self.root = root
        self.node = node
        self.repository = repository
        self.verify = verify
    }

    // MARK: Review

    public func review(_ request: ToolRequest) async throws -> ToolReview? {
        let spec = try Self.parse(request.arguments)
        return ToolReview(path: "New MCP server “\(spec.name)” (network: \(spec.allowedHosts.isEmpty ? "none" : spec.allowedHosts.joined(separator: ", ")); secrets: \(spec.secretNames.isEmpty ? "none" : spec.secretNames.joined(separator: ", ")))",
                          before: "", after: try Self.render(spec))
    }

    // MARK: Execute

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            guard let node, FileManager.default.isExecutableFile(atPath: node.path) else {
                throw BuilderError.invalid("AIM's bundled Node runtime is missing; MCP servers cannot be created.")
            }
            let spec = try Self.parse(request.arguments)
            let source = try Self.render(spec)
            var folder = root.appendingPathComponent(spec.name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Node's permission model compares real paths (e.g. /private/var, not /var).
            if let real = realpath(folder.path, nil) {
                folder = URL(fileURLWithPath: String(cString: real), isDirectory: true)
                free(real)
            }
            let existing = try await repository?.list().first { $0.name == spec.name }
            // Only a server AIM generated earlier may be replaced, never one the person configured.
            if let existing, !existing.arguments.contains(where: { $0.hasPrefix(folder.path + "/server") }) {
                throw BuilderError.invalid("A connector named “\(spec.name)” already exists and was not created by AIM. Choose another name.")
            }
            // A new versioned file: the current server keeps working until the new one is verified.
            let script = folder.appendingPathComponent("server-\(Int(Date.now.timeIntervalSince1970 * 1_000)).mjs")
            try Data(source.utf8).write(to: script, options: .atomic)
            var configuration = MCPServerConfiguration(id: existing?.id ?? UUID(), name: spec.name, transport: .stdio,
                command: node.path,
                arguments: ["--permission", "--allow-fs-read=\(folder.path)", script.path],
                secretNames: spec.secretNames, trusted: false, enabled: true,
                createdAt: existing?.createdAt ?? .now)
            configuration.updatedAt = .now
            let count: Int
            do {
                guard configuration.isValid else { throw BuilderError.invalid("The generated server configuration is invalid.") }
                count = try await verify(configuration)
                try await repository?.save(configuration)
            } catch {
                try? FileManager.default.removeItem(at: script)
                throw error
            }
            for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where old.lastPathComponent.hasPrefix("server") && old.pathExtension == "mjs" && old != script {
                try? FileManager.default.removeItem(at: old)
            }
            let manifest: [String: Any] = ["name": spec.name, "description": spec.description,
                                           "allowed_hosts": spec.allowedHosts, "secret_names": spec.secretNames,
                                           "created_at": ISO8601DateFormatter().string(from: .now), "origin": "agent"]
            try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("manifest.json"))
            var text = "Created the MCP server “\(spec.name)” with \(count) tool(s) (handshake verified). Its tools are available from the next Agent turn as mcp__\(spec.name)__<tool>; it is untrusted, so each call needs approval."
            if !spec.secretNames.isEmpty {
                text += " Before use, the person must enter \(spec.secretNames.joined(separator: ", ")) in Settings → Connectors (Keychain); never ask for them in chat."
            }
            return ToolResult(requestID: request.id, content: text, metadata: ["server": spec.name])
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    // MARK: Parsing and audit

    static let forbiddenIdentifiers = ["require", "import", "process", "globalThis", "global", "eval", "Function",
        "constructor", "__proto__", "prototype", "child_process", "WebSocket", "EventSource", "XMLHttpRequest",
        "Deno", "Bun", "module", "exports", "Reflect", "Proxy", "setPrototypeOf", "getPrototypeOf",
        "defineProperty", "WebAssembly", "Worker", "SharedArrayBuffer", "Atomics", "vm", "Buffer", "queueMicrotask"]

    static func parse(_ arguments: [String: String]) throws -> Spec {
        guard let name = arguments["name"], MCPServerConfiguration.isValidName(name), !name.hasPrefix("playwright") else {
            throw BuilderError.invalid("name must be 1–40 letters, digits, - or _.")
        }
        let description = String((arguments["description"] ?? "").prefix(500))
        guard let raw = arguments["tools_json"], let data = raw.data(using: .utf8),
              let tools = try? JSONDecoder().decode([ToolSpec].self, from: data), (1...20).contains(tools.count) else {
            throw BuilderError.invalid("tools_json must be a JSON array of 1–20 {name, description, input_schema, code}.")
        }
        let hosts = (arguments["allowed_hosts"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard hosts.count <= 10, hosts.allSatisfy({ host in
            host.count <= 253 && host.contains(".") && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        }) else { throw BuilderError.invalid("allowed_hosts must be up to 10 host names such as api.example.com.") }
        let secrets = (arguments["secret_names"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard secrets.count <= 8, secrets.allSatisfy({ name in
            (1...64).contains(name.count) && name.allSatisfy { ($0.isUppercase && $0.isASCII) || $0.isNumber || $0 == "_" }
        }) else { throw BuilderError.invalid("secret_names must be up to 8 UPPER_SNAKE_CASE names.") }
        var seen: Set<String> = []
        for tool in tools {
            guard (1...64).contains(tool.name.count), tool.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  seen.insert(tool.name).inserted else { throw BuilderError.invalid("Tool names must be unique letters, digits or _.") }
            guard tool.code.utf8.count <= 20_000 else { throw BuilderError.invalid("The code of \(tool.name) exceeds 20 KB.") }
            try audit(tool.code, tool: tool.name)
        }
        return Spec(name: name, description: description, tools: tools, allowedHosts: hosts, secretNames: secrets)
    }

    static func audit(_ code: String, tool: String) throws {
        for identifier in forbiddenIdentifiers where code.range(of: "\\b\(identifier)\\b", options: .regularExpression) != nil {
            throw BuilderError.invalid("The code of \(tool) uses “\(identifier)”, which generated servers may not use. Use only args, env and fetch.")
        }
        if code.range(of: #"\\u\{?[0-9a-fA-F]"#, options: .regularExpression) != nil || code.range(of: #"\\x[0-9a-fA-F]{2}"#, options: .regularExpression) != nil {
            throw BuilderError.invalid("The code of \(tool) uses escape sequences that could hide identifiers.")
        }
        if SecretRedactor.redact(code).count > 0 {
            throw BuilderError.invalid("The code of \(tool) contains a literal secret. Declare its name in secret_names and read env.NAME.")
        }
    }

    // MARK: Rendering

    static func render(_ spec: Spec) throws -> String {
        func literal(_ value: some Encodable) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        let definitions = try spec.tools.map { tool -> String in
            let schema = tool.input_schema ?? .object(["type": .string("object"), "properties": .object([:])])
            return "{ name: \(try literal(tool.name)), description: \(try literal(tool.description)), inputSchema: \(try literal(schema)), code: \(try literal(tool.code)) }"
        }.joined(separator: ",\n  ")
        return """
        // Generated by AIM for the MCP server \(try literal(spec.name)). Do not edit: AIM regenerates it.
        // \(spec.description.replacingOccurrences(of: "\n", with: " "))
        import { compileFunction } from 'node:vm';
        import { createInterface } from 'node:readline';

        const TOOLS = [
          \(definitions)
        ];
        const ALLOWED_HOSTS = \(try literal(spec.allowedHosts));
        const SECRET_NAMES = \(try literal(spec.secretNames));

        const stdout = process.stdout;
        const stdin = process.stdin;
        const env = Object.freeze(Object.fromEntries(SECRET_NAMES.map((n) => [n, process.env[n] ?? ''])));
        const realFetch = globalThis.fetch;
        const guardedFetch = async (input, init) => {
          const url = new URL(typeof input === 'string' || input instanceof URL ? String(input) : input.url);
          if (url.protocol !== 'https:' || !ALLOWED_HOSTS.some((h) => url.hostname === h || url.hostname.endsWith('.' + h))) {
            throw new Error('This MCP server may not contact ' + url.hostname);
          }
          return realFetch(url, { ...(init ?? {}), redirect: 'error' });
        };
        // Close the usual escape routes before any tool code is compiled.
        for (const fn of [function () {}, async function () {}, function* () {}, async function* () {}]) {
          Object.defineProperty(Object.getPrototypeOf(fn), 'constructor', { value: undefined });
        }
        for (const name of ['process', 'fetch', 'WebSocket', 'EventSource', 'WebAssembly', 'Buffer']) {
          try { Object.defineProperty(globalThis, name, { value: undefined, configurable: false, writable: false }); } catch {}
        }
        const handlers = new Map(TOOLS.map((t) => [t.name, compileFunction('"use strict"; return (async () => {\\n' + t.code + '\\n})();', ['args', 'env', 'fetch'])]));

        function send(message) { stdout.write(JSON.stringify(message) + '\\n'); }
        async function handle(message) {
          const { id, method, params } = message;
          if (id === undefined) return;
          try {
            if (method === 'initialize') {
              return send({ jsonrpc: '2.0', id, result: { protocolVersion: params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: \(try literal(spec.name)), version: '1.0.0' } } });
            }
            if (method === 'ping') return send({ jsonrpc: '2.0', id, result: {} });
            if (method === 'tools/list') {
              return send({ jsonrpc: '2.0', id, result: { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) } });
            }
            if (method === 'tools/call') {
              const handler = handlers.get(params?.name);
              if (!handler) return send({ jsonrpc: '2.0', id, error: { code: -32602, message: 'Unknown tool' } });
              try {
                const value = await handler(params.arguments ?? {}, env, guardedFetch);
                const text = typeof value === 'string' ? value : JSON.stringify(value ?? null, null, 2);
                return send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: String(text).slice(0, 200000) }] } });
              } catch (error) {
                return send({ jsonrpc: '2.0', id, result: { isError: true, content: [{ type: 'text', text: String(error?.message ?? error) }] } });
              }
            }
            send({ jsonrpc: '2.0', id, error: { code: -32601, message: 'Method not found' } });
          } catch (error) {
            send({ jsonrpc: '2.0', id, error: { code: -32603, message: String(error?.message ?? error) } });
          }
        }
        createInterface({ input: stdin }).on('line', (line) => {
          if (!line.trim()) return;
          try { handle(JSON.parse(line)); } catch { /* ignore malformed input */ }
        });

        """
    }

    enum BuilderError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let detail) = self { detail } else { nil } }
    }
}
