import AIMAgentKit
import AppKit
import Foundation

/// Finding and opening apps, web pages and files, as Otto's list_apps → launch_app
/// protocol. Apps open in the background by default so the person keeps focus;
/// the agent then works on them with the bg_ tools.
public actor AgentLaunchToolService: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["list_apps", "open_app", "open_url", "open_file"]

    public struct InstalledApp: Equatable, Sendable {
        public let name: String
        public let bundleID: String
        public let path: String
    }

    private let roots: [URL]

    public init(roots: [URL]? = nil) {
        self.roots = roots ?? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                               URL(fileURLWithPath: "/System/Applications/Utilities"),
                               URL(fileURLWithPath: "/Applications/Utilities"),
                               FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            switch request.name {
            case "list_apps":
                let query = request.arguments["query"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                let running = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
                let apps = installedApps().filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query) }
                let lines = apps.prefix(80).map { "\($0.name) — \($0.bundleID)\(running.contains($0.bundleID) ? " (running)" : "")" }
                return ToolResult(requestID: request.id, content: lines.isEmpty ? "No installed app matches “\(query)”." : lines.joined(separator: "\n"))
            case "open_app":
                let app = try resolve(request.arguments["app"])
                let activate = request.arguments["activate"] == "true"
                let pid = try await open(urls: [], with: app, activate: activate)
                return ToolResult(requestID: request.id,
                    content: "Opened \(app.name)\(activate ? " in front" : " in the background (the person keeps focus)") (pid \(pid)). Use bg_list_windows to work on its windows.",
                    metadata: ["bundle_id": app.bundleID, "pid": String(pid)])
            case "open_url":
                guard let raw = request.arguments["url"], let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                      ["http", "https", "mailto"].contains(scheme), raw.utf8.count <= 4_096 else {
                    throw LaunchError.invalid("url must be an http, https or mailto URL")
                }
                let app = try request.arguments["app"].map { try resolve($0) } ?? defaultApp(for: url)
                let activate = request.arguments["activate"] == "true"
                let pid = try await open(urls: [url], with: app, activate: activate)
                return ToolResult(requestID: request.id, content: "Opened \(raw) in \(app.name) (pid \(pid)).",
                                  metadata: ["bundle_id": app.bundleID])
            case "open_file":
                guard let path = request.arguments["path"] else { throw LaunchError.invalid("path is required") }
                let base = request.workspacePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                let file = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base?.appendingPathComponent(path)) ?? URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: file.path) else { throw LaunchError.invalid("no file at \(file.path)") }
                let app = try request.arguments["app"].map { try resolve($0) } ?? defaultApp(for: file)
                let activate = request.arguments["activate"] == "true"
                let pid = try await open(urls: [file], with: app, activate: activate)
                return ToolResult(requestID: request.id, content: "Opened \(file.lastPathComponent) in \(app.name) (pid \(pid)).",
                                  metadata: ["bundle_id": app.bundleID])
            default:
                throw LaunchError.invalid("unknown tool")
            }
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    // MARK: Helpers

    func installedApps() -> [InstalledApp] {
        var seen: Set<String> = []
        var apps: [InstalledApp] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for url in entries where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { continue }
                let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] ?? bundle.infoDictionary?["CFBundleDisplayName"]
                            ?? bundle.infoDictionary?["CFBundleName"]) as? String ?? url.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(name: name, bundleID: id, path: url.path))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An app by bundle ID, exact name or unique partial name.
    func resolve(_ value: String?) throws -> InstalledApp {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { throw LaunchError.invalid("app is required") }
        let apps = installedApps()
        if let exact = apps.first(where: { $0.bundleID.caseInsensitiveCompare(value) == .orderedSame || $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
            return exact
        }
        let partial = apps.filter { $0.name.localizedCaseInsensitiveContains(value) }
        guard partial.count == 1 else {
            throw LaunchError.invalid(partial.isEmpty ? "No installed app named “\(value)”; call list_apps."
                : "“\(value)” matches several apps: \(partial.prefix(6).map(\.name).joined(separator: ", ")).")
        }
        return partial[0]
    }

    private func defaultApp(for url: URL) throws -> InstalledApp {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url), let bundle = Bundle(url: appURL),
              let id = bundle.bundleIdentifier else { throw LaunchError.invalid("no app opens \(url.scheme ?? "this") links") }
        return InstalledApp(name: appURL.deletingPathExtension().lastPathComponent, bundleID: id, path: appURL.path)
    }

    private func open(urls: [URL], with app: InstalledApp, activate: Bool) async throws -> pid_t {
        let appURL = URL(fileURLWithPath: app.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.addsToRecentItems = false
        let running: NSRunningApplication
        if urls.isEmpty {
            running = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } else {
            running = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
        }
        return running.processIdentifier
    }

    enum LaunchError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let detail) = self { detail } else { nil } }
    }
}
