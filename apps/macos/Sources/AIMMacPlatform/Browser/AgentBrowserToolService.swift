import AIMAgentKit
import AIMApplication
import Foundation

/// Playwright's Chrome extension grants a selected tab group, not global Chrome
/// access. Every AIM browser action is still reviewed by the host dispatcher.
public actor AgentBrowserToolService: BrowserToolServing, MissionIntentProviding, ToolSessionClosing {
    public nonisolated let supportedTools: Set<String> = [
        "browser_snapshot", "browser_navigate", "browser_click", "browser_type",
        "browser_press_key", "browser_tabs", "browser_find", "browser_hover",
        "browser_select_option", "browser_navigate_back", "browser_take_screenshot",
        "browser_handle_dialog", "browser_wait_for", "browser_file_upload",
        "browser_drag", "browser_drop", "browser_console_messages", "browser_network_requests"
    ]
    private var client: PlaywrightMCPClient?
    private var available: Set<String> = []
    private var executing = false
    /// Issued only for a model-visible inline DOM observation. It is retired
    /// before any action that can change the page or selected tab.
    private var observation = BrowserObservationLease()
    private let configuration: AgentBrowserConfiguration

    public init(configuration: AgentBrowserConfiguration = AgentBrowserConfiguration()) {
        self.configuration = configuration
    }

    public nonisolated var mode: AgentBrowserMode { configuration.mode }

    /// A web-origin grant covers only explicit navigation to a requested URL.
    /// DOM actions remain exact approvals until the bridge can attest the
    /// selected tab's URL and generation independently of webpage content.
    public func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        let rawURL: String
        switch request.name {
        case "browser_navigate":
            guard let url = request.arguments["url"] else { throw BrowserError.invalidURL }
            rawURL = url
        case "browser_tabs" where request.arguments["action"] == "new":
            guard let url = request.arguments["url"] else { return nil }
            rawURL = url
        default:
            return nil
        }
        guard Self.allowedURL(rawURL), let components = URLComponents(string: rawURL),
              let scheme = components.scheme, let host = components.host else {
            throw BrowserError.invalidURL
        }
        var origin = URLComponents()
        origin.scheme = scheme.lowercased()
        origin.host = host.lowercased()
        origin.port = components.port
        guard let identifier = origin.string else { throw BrowserError.invalidURL }
        return MissionToolIntent(operation: .navigate,
            target: try MissionResource(kind: .webOrigin, identifier: identifier))
    }

    public nonisolated static var isBundled: Bool {
        guard let root = HostBundleResources.resourceURL?.appendingPathComponent("Playwright") else { return false }
        return FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("node").path) &&
            FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules/@playwright/mcp/cli.js").path)
    }

    /// Set when the extension refused or never answered: later calls of this
    /// session fail at once instead of reopening the connect page each time.
    private var extensionFailure: String?

    nonisolated static func redactingSecrets(_ text: String) -> String {
        text.replacingOccurrences(of: #"(token(=|%3D))[A-Za-z0-9_\-]{8,}"#, with: "$1<redacted>", options: .regularExpression)
    }

    /// The browser tools' descriptions name the person's Chrome; in isolated mode they act in
    /// AIM's own Chrome window, without the person's logins or tabs.
    public nonisolated static func descriptions(_ all: [String: String], mode: AgentBrowserMode) -> [String: String] {
        guard mode == .isolated else { return all }
        var result = all
        for (name, text) in all where name.hasPrefix("browser_") {
            result[name] = text
                .replacingOccurrences(of: "the Chrome tab explicitly connected to AIM through the official Playwright Extension",
                                      with: "the page in AIM's own Chrome window (a separate empty profile: the person's logins and tabs are not there)")
                .replacingOccurrences(of: "in AIM's Playwright Extension tab group", with: "in AIM's own Chrome window")
                .replacingOccurrences(of: "The user selects an allowed tab in the extension; never", with: "Never")
                .replacingOccurrences(of: "the connected Chrome tab's", with: "AIM's Chrome window's")
                .replacingOccurrences(of: "the connected Chrome tab", with: "AIM's Chrome window")
                .replacingOccurrences(of: "the connected tab", with: "AIM's Chrome window")
        }
        return result
    }

    nonisolated static func isExtensionConnectionFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("did not connect within") || lower.contains("invalid token") ||
            lower.contains("playwright extension not found") || lower.contains("extension connection")
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        if let extensionFailure {
            return ToolResult(requestID: request.id,
                content: "The Chrome extension connection already failed in this session (\(extensionFailure)). Nothing was opened again. Check the extension token in AIM's Computer Use window, then start a new run.",
                isError: true, metadata: ["browser_connection_failed": "true"])
        }
        guard !executing else {
            return ToolResult(requestID: request.id, content: "Browser operation already in progress; wait for its result.", isError: true)
        }
        executing = true
        defer { executing = false }
        var bridgeCallStarted = false
        // AIM's own argument refusal sends nothing, so it must not end the browser session.
        let arguments: [String: Any]
        do {
            arguments = try Self.validate(request)
        } catch {
            var result = ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
            result.actionOutcome = Self.outcome(name: request.name, tabAction: request.arguments["action"],
                callStarted: false, isError: true)
            return result
        }
        do {
            if Self.requiresSnapshot(request.name),
               !observation.matches(request.arguments["observation_id"]) {
                return ToolResult(requestID: request.id,
                    content: "The browser observation is missing or stale. Call browser_snapshot or browser_find, then pass its exact observation_id with the target action.",
                    isError: true, metadata: ["stale_browser_target": "true"])
            }
            let bridge = try await connect()
            guard available.contains(request.name) else { throw BrowserError.toolUnavailable }
            if Self.requiresSnapshot(request.name) {
                let current = try await currentTab(using: bridge)
                guard observation.matches(request.arguments["observation_id"], tab: current) else {
                    observation.revoke()
                    return ToolResult(requestID: request.id,
                        content: "The selected browser tab or its URL changed since the observation. Call browser_snapshot again before acting.",
                        isError: true, metadata: ["stale_browser_target": "true"])
                }
            }
            let priorTab = observation.tab
            if request.name == "browser_snapshot" || request.name == "browser_find" {
                observation.revoke()
            }
            // A mutation or tab switch may invalidate every target reference,
            // even when MCP later reports a timeout or an ambiguous error.
            if Self.invalidatesSnapshot(request.name, arguments: arguments) { observation.revoke() }
            bridgeCallStarted = true
            var result = try await bridge.callTool(request.name, arguments: arguments, requestID: request.id)
            try Task.checkCancellation()
            // The extension's connect tab URL carries its token: never show it to the model.
            result.content = Self.redactingSecrets(result.content)
            if configuration.mode == .extensionConnected, result.isError, Self.isExtensionConnectionFailure(result.content) {
                extensionFailure = String(result.content.replacingOccurrences(of: "### Error\n", with: "").prefix(240))
                client?.stop()
                client = nil
                available = []
                observation.revoke()
                result.metadata["browser_connection_failed"] = "true"
                result.actionOutcome = .suspectedAbsent
                result.content += "\n\nAIM reaches the person's browser only in Google Chrome, through the Playwright extension connected in AIM's Computer Use window (Safari, Arc and other browsers are not supported). Tell the person; for public pages use web_fetch instead."
                return result
            }
            if Self.hasActionableObservation(name: request.name, result: result) {
                let current = try await currentTab(using: bridge)
                let observedURL = Self.pageURL(in: result.content)
                if (request.name == "browser_snapshot" && observedURL == current?.url) ||
                    (request.name == "browser_find" && priorTab == current && current != nil) {
                    result.metadata["observation_id"] = observation.accept(tab: current!)
                } else {
                    observation.revoke()
                    result.content += "\nBrowser target identity could not be verified. Call browser_snapshot before acting."
                    result.metadata["observation_unavailable"] = "true"
                }
            }
            if request.name == "browser_take_screenshot", result.imagePNG == nil, !result.isError {
                return ToolResult(requestID: request.id,
                    content: "Playwright did not return PNG pixels. The screenshot cannot be inspected by this model. " + result.content,
                    isError: true, metadata: ["image_unavailable": "true"])
            }
            result.actionOutcome = Self.outcome(name: request.name,
                tabAction: arguments["action"] as? String, callStarted: true, isError: result.isError)
            return result
        } catch {
            client?.stop()
            client = nil
            available = []
            observation.revoke()
            var result = ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
            result.actionOutcome = Self.outcome(name: request.name,
                tabAction: request.arguments["action"], callStarted: bridgeCallStarted, isError: true)
            return result
        }
    }

    public func cancel(requestID: String) async {
        await closeSession()
    }

    public func closeSession() async {
        client?.stop()
        client = nil
        available = []
        observation.revoke()
    }

    private func connect() async throws -> PlaywrightMCPClient {
        if let client { return client }
        guard let root = HostBundleResources.resourceURL?.appendingPathComponent("Playwright") else {
            throw PlaywrightError.runtimeMissing
        }
        var launch = configuration
        if launch.mode == .isolated && launch.outputDirectory == nil {
            launch.outputDirectory = AgentBrowserPreferences.sessionDirectory()
        }
        let bridge = try PlaywrightMCPClient(node: root.appendingPathComponent("node"),
            cli: root.appendingPathComponent("node_modules/@playwright/mcp/cli.js"), configuration: launch)
        do {
            try await bridge.initialize()
            available = try await bridge.listTools()
            client = bridge
            return bridge
        } catch {
            bridge.stop()
            throw error
        }
    }

    private func currentTab(using bridge: PlaywrightMCPClient) async throws -> BrowserTabIdentity? {
        guard available.contains("browser_tabs") else { return nil }
        let listing = try await bridge.callTool("browser_tabs", arguments: ["action": "list"],
                                                requestID: UUID().uuidString)
        guard !listing.isError else { return nil }
        return Self.currentTab(in: listing.content)
    }

    nonisolated static func currentTab(in content: String) -> BrowserTabIdentity? {
        guard content.hasPrefix("### Result\n") else { return nil }
        let remainder = content.dropFirst("### Result\n".count)
        let block = remainder[..<(remainder.range(of: "\n### ")?.lowerBound ?? remainder.endIndex)]
        let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }
        var selected: BrowserTabIdentity?
        var seenIndexes: Set<Int> = []
        for line in lines {
            guard line.hasPrefix("- "), let separator = line.range(of: ": "),
                  let index = Int(line[line.index(line.startIndex, offsetBy: 2)..<separator.lowerBound]),
                  index >= 0, index < 1_000, seenIndexes.insert(index).inserted,
                  let link = line.range(of: "](", options: .backwards), line.hasSuffix(")") else { return nil }
            let marker = line[separator.upperBound..<link.lowerBound]
            let current = marker.hasPrefix("(current) [")
            guard current || marker.hasPrefix("["),
                  let url = URL(string: String(line[link.upperBound..<line.index(before: line.endIndex)])) else {
                return nil
            }
            if current {
                guard selected == nil,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, url.user == nil, url.password == nil else { return nil }
                selected = BrowserTabIdentity(index: index, url: url.absoluteString)
            }
        }
        return selected
    }

    nonisolated static func pageURL(in content: String) -> String? {
        guard let page = content.range(of: "### Page\n") else { return nil }
        let remainder = content[page.upperBound...]
        guard let line = remainder.split(separator: "\n", maxSplits: 1).first,
              line.hasPrefix("- Page URL: ") else { return nil }
        return String(line.dropFirst("- Page URL: ".count))
    }

    private nonisolated static func validate(_ request: ToolRequest) throws -> [String: Any] {
        let values = request.arguments
        switch request.name {
        case "browser_snapshot": return [:]
        case "browser_take_screenshot":
            // Do not expose arbitrary output paths, formats or device-scale
            // captures to the model. The screenshot must return PNG pixels.
            var result: [String: Any] = ["type": "png", "scale": "css"]
            if let fullPage = values["fullPage"] {
                guard ["true", "false"].contains(fullPage) else { throw BrowserError.invalidArgument }
                result["fullPage"] = fullPage == "true"
            }
            return result
        case "browser_handle_dialog":
            guard let accept = values["accept"], ["true", "false"].contains(accept) else {
                throw BrowserError.invalidArgument
            }
            var result: [String: Any] = ["accept": accept == "true"]
            if let text = values["promptText"] {
                guard accept == "true", let prompt = bounded(text, limit: 4_000) else { throw BrowserError.invalidArgument }
                result["promptText"] = prompt
            }
            return result
        case "browser_file_upload":
            // Without paths the pending file chooser is cancelled (it blocks every other tool).
            guard let rawPaths = values["paths"] else { return [:] }
            return ["paths": try uploadPaths(rawPaths, workspacePath: request.workspacePath)]
        case "browser_drag":
            guard let start = bounded(values["startTarget"], limit: 1_000),
                  let end = bounded(values["endTarget"], limit: 1_000) else {
                throw BrowserError.invalidArgument
            }
            var result: [String: Any] = ["startTarget": start, "endTarget": end]
            if let description = values["startElement"] {
                guard let bounded = bounded(description, limit: 500) else { throw BrowserError.invalidArgument }
                result["startElement"] = bounded
            }
            if let description = values["endElement"] {
                guard let bounded = bounded(description, limit: 500) else { throw BrowserError.invalidArgument }
                result["endElement"] = bounded
            }
            return result
        case "browser_drop":
            guard let target = bounded(values["target"], limit: 1_000),
                  let rawPaths = values["paths"] else { throw BrowserError.invalidArgument }
            var result: [String: Any] = ["target": target,
                                         "paths": try uploadPaths(rawPaths, workspacePath: request.workspacePath)]
            if let description = values["element"] {
                guard let bounded = bounded(description, limit: 500) else { throw BrowserError.invalidArgument }
                result["element"] = bounded
            }
            return result
        case "browser_console_messages":
            let level = values["level"] ?? "info"
            guard ["error", "warning", "info", "debug"].contains(level) else {
                throw BrowserError.invalidArgument
            }
            var result: [String: Any] = ["level": level]
            if let all = values["all"] {
                guard ["true", "false"].contains(all) else { throw BrowserError.invalidArgument }
                result["all"] = all == "true"
            }
            return result
        case "browser_network_requests":
            let includeStatic = values["static"] ?? "false"
            guard ["true", "false"].contains(includeStatic) else { throw BrowserError.invalidArgument }
            return ["static": includeStatic == "true"]
        case "browser_find":
            guard let query = bounded(values["text"], limit: 500) else { throw BrowserError.invalidArgument }
            return ["text": query]
        case "browser_wait_for":
            var result: [String: Any] = [:]
            if let time = values["time"] {
                guard let seconds = Double(time), seconds.isFinite,
                      seconds > 0, seconds <= 30 else { throw BrowserError.invalidArgument }
                result["time"] = seconds
            }
            if let text = values["text"] {
                guard let text = bounded(text, limit: 500) else { throw BrowserError.invalidArgument }
                result["text"] = text
            }
            if let gone = values["textGone"] {
                guard let gone = bounded(gone, limit: 500) else { throw BrowserError.invalidArgument }
                result["textGone"] = gone
            }
            guard !result.isEmpty else { throw BrowserError.invalidArgument }
            return result
        case "browser_navigate":
            guard let url = values["url"], allowedURL(url) else { throw BrowserError.invalidURL }
            if let host = URL(string: url)?.host, IntegrationPreferences.isBlocked(host: host) { throw BrowserError.blockedSite(host) }
            return ["url": url]
        case "browser_click":
            guard let target = bounded(values["target"], limit: 1_000) else { throw BrowserError.invalidArgument }
            var result: [String: Any] = ["target": target]
            if let element = bounded(values["element"], limit: 500) { result["element"] = element }
            return result
        case "browser_hover":
            guard let target = bounded(values["target"], limit: 1_000) else { throw BrowserError.invalidArgument }
            return ["target": target]
        case "browser_select_option":
            guard let target = bounded(values["target"], limit: 1_000),
                  let rawValues = values["values"], rawValues.utf8.count <= 4_000,
                  let data = rawValues.data(using: .utf8),
                  let selections = try? JSONSerialization.jsonObject(with: data) as? [String],
                  !selections.isEmpty, selections.count <= 20,
                  selections.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 500 }) else {
                throw BrowserError.invalidArgument
            }
            return ["target": target, "values": selections]
        case "browser_type":
            guard let target = bounded(values["target"], limit: 1_000),
                  let text = bounded(values["text"], limit: 16_000) else { throw BrowserError.invalidArgument }
            var result: [String: Any] = ["target": target, "text": text]
            if let submit = values["submit"] {
                guard ["true", "false"].contains(submit) else { throw BrowserError.invalidArgument }
                result["submit"] = submit == "true"
            }
            return result
        case "browser_press_key":
            guard let key = bounded(values["key"], limit: 100) else { throw BrowserError.invalidArgument }
            return ["key": key]
        case "browser_navigate_back": return [:]
        case "browser_tabs":
            guard let action = values["action"], ["list", "new", "select", "close"].contains(action) else {
                throw BrowserError.invalidArgument
            }
            var result: [String: Any] = ["action": action]
            if action == "new", let url = values["url"], let host = URL(string: url)?.host, IntegrationPreferences.isBlocked(host: host) {
                throw BrowserError.blockedSite(host)
            }
            if let index = values["index"] {
                guard let number = Int(index), number >= 0, number < 1_000 else { throw BrowserError.invalidArgument }
                result["index"] = number
            }
            if let url = values["url"] {
                guard action == "new", allowedURL(url) else { throw BrowserError.invalidURL }
                result["url"] = url
            }
            return result
        default: throw BrowserError.toolUnavailable
        }
    }

    private nonisolated static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= limit, !value.contains("\0") else { return nil }
        return value
    }

    /// The browser bridge receives only existing regular files inside the
    /// selected workspace. A path that escapes through a symlink is rejected.
    nonisolated static func uploadPaths(_ raw: String, workspacePath: String?) throws -> [String] {
        guard raw.utf8.count <= 32_768, let workspacePath, workspacePath.hasPrefix("/"),
              let data = raw.data(using: .utf8),
              let paths = try? JSONSerialization.jsonObject(with: data) as? [String],
              (1...10).contains(paths.count) else { throw BrowserError.invalidArgument }
        let root = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().standardizedFileURL
        guard root.path == workspacePath,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw BrowserError.invalidArgument
        }
        var resolved: [String] = []
        for path in paths {
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096 else {
                throw BrowserError.invalidArgument
            }
            let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/"),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isReadableFile(atPath: file.path) else {
                throw BrowserError.invalidArgument
            }
            resolved.append(file.path)
        }
        return resolved
    }

    private nonisolated static func requiresSnapshot(_ name: String) -> Bool {
        ["browser_click", "browser_hover", "browser_select_option", "browser_type", "browser_press_key",
         "browser_drag", "browser_drop"].contains(name)
    }

    nonisolated static func hasActionableObservation(name: String, result: ToolResult) -> Bool {
        guard !result.isError else { return false }
        switch name {
        case "browser_snapshot":
            // AIM does not request a snapshot filename. An output-file link
            // cannot supply the model with current references.
            return result.content.contains("### Snapshot\n") &&
                !result.content.contains("- [Snapshot](")
        case "browser_find":
            // Playwright returns a nonempty "No matches found" result too.
            return result.content.contains("[ref=")
        default:
            return false
        }
    }

    private nonisolated static func invalidatesSnapshot(_ name: String, arguments: [String: Any]) -> Bool {
        if name == "browser_tabs" { return arguments["action"] as? String != "list" }
        return ["browser_navigate", "browser_navigate_back", "browser_click", "browser_hover",
                "browser_select_option", "browser_type", "browser_press_key", "browser_drag", "browser_drop", "browser_handle_dialog",
                "browser_wait_for", "browser_file_upload"].contains(name)
    }

    private nonisolated static func mayChangeBrowserState(_ name: String,
                                                           tabAction: String?) -> Bool {
        if name == "browser_tabs" { return tabAction != "list" }
        return ["browser_navigate", "browser_navigate_back", "browser_click", "browser_hover",
                "browser_select_option", "browser_type", "browser_press_key", "browser_drag",
                "browser_drop", "browser_handle_dialog", "browser_file_upload"].contains(name)
    }

    nonisolated static func outcome(name: String, tabAction: String?,
                                    callStarted: Bool, isError: Bool) -> ActionOutcome? {
        guard callStarted, mayChangeBrowserState(name, tabAction: tabAction) else { return nil }
        return isError ? .unknown : .unverified
    }

    private nonisolated static func allowedURL(_ raw: String) -> Bool {
        guard raw.utf8.count <= 4_096, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }
}

/// The nonce and selected-tab fingerprint prevent reuse after AIM actions or
/// an observable external tab switch/navigation. A same-URL reload or DOM
/// change still needs a bridge-level generation to be detected reliably.
struct BrowserObservationLease {
    private(set) var id: String?
    private(set) var tab: BrowserTabIdentity?

    mutating func accept(tab: BrowserTabIdentity) -> String {
        let next = UUID().uuidString
        id = next
        self.tab = tab
        return next
    }

    mutating func revoke() { id = nil; tab = nil }

    func matches(_ candidate: String?) -> Bool {
        guard let id, let candidate else { return false }
        return id == candidate
    }

    func matches(_ candidate: String?, tab: BrowserTabIdentity?) -> Bool {
        matches(candidate) && self.tab != nil && self.tab == tab
    }
}

struct BrowserTabIdentity: Equatable {
    let index: Int
    let url: String
}

private enum BrowserError: LocalizedError {
    case invalidURL, invalidArgument, toolUnavailable, blockedSite(String)
    var errorDescription: String? {
        switch self {
        case .blockedSite(let host): "\(host) is blocked in Settings › Browser. Do not open it; tell the person instead."
        case .invalidURL: "Browser navigation requires an HTTP or HTTPS URL without embedded credentials."
        case .invalidArgument: "Invalid Playwright browser arguments."
        case .toolUnavailable: "The installed Playwright server does not provide this tool."
        }
    }
}
