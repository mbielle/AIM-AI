import AIMApplication
@testable import AIMMacPlatform
import XCTest

/// A local Node fixture playing an OAuth-protected MCP server with both the
/// Streamable HTTP endpoint and the legacy SSE transport.
final class MCPRemoteTransportTests: XCTestCase {
    static let fixture = #"""
    const http = require('http'); const crypto = require('crypto');
    const port = Number(process.argv[2]); const base = `http://127.0.0.1:${port}`;
    let challenge = null; let sseResponse = null; let issued = new Set();
    const json = (res, status, body, headers = {}) => { res.writeHead(status, {'Content-Type': 'application/json', ...headers}); res.end(JSON.stringify(body)); };
    const authorized = (req) => issued.has((req.headers.authorization || '').replace('Bearer ', ''));
    function rpc(msg) {
      if (msg.method === 'initialize') return {jsonrpc: '2.0', id: msg.id, result: {protocolVersion: msg.params.protocolVersion, capabilities: {tools: {}}, serverInfo: {name: 'fixture', version: '1'}}};
      if (msg.method === 'tools/list') return {jsonrpc: '2.0', id: msg.id, result: {tools: [{name: 'echo', description: 'Echo', inputSchema: {type: 'object', properties: {text: {type: 'string'}}}, annotations: {readOnlyHint: true}}]}};
      if (msg.method === 'tools/call') return {jsonrpc: '2.0', id: msg.id, result: {content: [{type: 'text', text: 'echo:' + msg.params.arguments.text}]}};
      return null;
    }
    http.createServer((req, res) => {
      const url = new URL(req.url, base); let body = '';
      req.on('data', c => body += c); req.on('end', () => {
        if (url.pathname === '/.well-known/oauth-protected-resource/mcp') return json(res, 200, {resource: base + '/mcp', authorization_servers: [base]});
        if (url.pathname === '/.well-known/oauth-authorization-server') return json(res, 200, {issuer: base, authorization_endpoint: base + '/authorize', token_endpoint: base + '/token', registration_endpoint: base + '/register', scopes_supported: ['mcp']});
        if (url.pathname === '/register') return json(res, 201, {client_id: 'client-1'});
        if (url.pathname === '/authorize') {
          challenge = url.searchParams.get('code_challenge');
          if (url.searchParams.get('resource') !== base + '/mcp') { res.writeHead(400); return res.end(); }
          res.writeHead(302, {Location: `${url.searchParams.get('redirect_uri')}?code=code-1&state=${url.searchParams.get('state')}`}); return res.end();
        }
        if (url.pathname === '/token') {
          const form = new URLSearchParams(body);
          if (form.get('grant_type') === 'authorization_code') {
            const expected = crypto.createHash('sha256').update(form.get('code_verifier')).digest('base64url');
            if (expected !== challenge || form.get('code') !== 'code-1') return json(res, 400, {error: 'invalid_grant'});
            issued.add('at-1'); return json(res, 200, {access_token: 'at-1', refresh_token: 'rt-1', expires_in: 1, token_type: 'Bearer'});
          }
          if (form.get('grant_type') === 'refresh_token' && form.get('refresh_token') === 'rt-1') { issued.add('at-2'); return json(res, 200, {access_token: 'at-2', expires_in: 3600}); }
          return json(res, 400, {error: 'invalid_grant'});
        }
        if (url.pathname === '/mcp') {
          if (!authorized(req)) return json(res, 401, {error: 'unauthorized'}, {'WWW-Authenticate': `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp"`});
          const msg = JSON.parse(body); const reply = rpc(msg);
          if (!reply) { res.writeHead(202); return res.end(); }
          if (msg.method === 'tools/call') {
            res.writeHead(200, {'Content-Type': 'text/event-stream'});
            res.write('event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\n');
            res.write('event: message\ndata: ' + JSON.stringify(reply) + '\n\n'); return res.end();
          }
          return json(res, 200, reply, {'Mcp-Session-Id': 's-1'});
        }
        if (url.pathname === '/sse') {
          res.writeHead(200, {'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache'});
          res.write('event: endpoint\ndata: /messages?session=1\n\n'); sseResponse = res; return;
        }
        if (url.pathname === '/messages') {
          const reply = rpc(JSON.parse(body)); res.writeHead(202); res.end();
          if (reply && sseResponse) sseResponse.write('event: message\ndata: ' + JSON.stringify(reply) + '\n\n');
          return;
        }
        res.writeHead(404); res.end();
      });
    }).listen(port, '127.0.0.1', () => console.log('ready'));
    """#

    private var process: Process?

    override func tearDown() {
        process?.terminate()
        super.tearDown()
    }

    private func startFixture() async throws -> Int {
        guard let node = ProcessInfo.processInfo.environment["AIM_TEST_NODE_RUNTIME"],
              FileManager.default.isExecutableFile(atPath: node) else {
            throw XCTSkip("AIM_TEST_NODE_RUNTIME is required for the remote MCP fixture")
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("aim-mcp-remote-\(UUID().uuidString).js")
        try Data(Self.fixture.utf8).write(to: script)
        let port = Int.random(in: 49_100...49_900)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path, String(port)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        self.process = process
        for _ in 0..<50 {
            if let line = try? output.fileHandleForReading.availableData, String(decoding: line, as: UTF8.self).contains("ready") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return port
    }

    func testOAuthSignInThenStreamableHTTPAndRefresh() async throws {
        let port = try await startFixture()
        let server = MCPServerConfiguration(name: "remote", transport: .http, url: "http://127.0.0.1:\(port)/mcp")
        defer { MCPOAuth.signOut(serverID: server.id) }

        // Before sign-in the server answers 401 with a resource-metadata challenge.
        let anonymous = try MCPStreamableHTTPClient(url: URL(string: server.url!)!, authorization: nil,
                                                oauthServerID: server.id, serverName: server.name)
        do {
            try await anonymous.initialize()
            XCTFail("expected sign-in to be required")
        } catch let error as MCPOAuth.OAuthError {
            XCTAssertEqual(error, .needsSignIn("remote"))
        }

        // The "browser" follows the authorization redirect to AIM's loopback callback.
        let tokens = try await MCPOAuth.signIn(server: server, openBrowser: { url in
            _ = try? await URLSession.shared.data(from: url)
        })
        XCTAssertEqual(tokens.accessToken, "at-1")
        XCTAssertEqual(tokens.clientID, "client-1")

        // at-1 expires within a second: the client refreshes to at-2 before using it.
        try await Task.sleep(for: .milliseconds(1_100))
        let client = try MCPStreamableHTTPClient(url: URL(string: server.url!)!, authorization: nil,
                                             oauthServerID: server.id, serverName: server.name)
        try await client.initialize()
        XCTAssertEqual(MCPOAuth.storedTokens(serverID: server.id)?.accessToken, "at-2")
        let tools = try await client.toolDefinitions()
        XCTAssertEqual(tools.first?["name"] as? String, "echo")
        let result = try await client.call("echo", argumentsJSON: Data(#"{"text":"hi"}"#.utf8))
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("echo:hi"), "the reply after a progress event is found")
    }

    func testLegacySSETransport() async throws {
        let port = try await startFixture()
        let client = MCPLegacySSEClient(url: URL(string: "http://127.0.0.1:\(port)/sse")!, authorization: nil)
        try await client.initialize()
        let tools = try await client.toolDefinitions()
        XCTAssertEqual(tools.count, 1)
        let result = try await client.call("echo", argumentsJSON: Data(#"{"text":"sse"}"#.utf8))
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("echo:sse"))
        await client.close()
        let imported = try MCPServerImport.parse(Data(#"{"mcpServers": {"old": {"url": "https://example.com/sse"}}}"#.utf8))
        XCTAssertEqual(imported.first?.configuration.transport, .sse)
    }
}
