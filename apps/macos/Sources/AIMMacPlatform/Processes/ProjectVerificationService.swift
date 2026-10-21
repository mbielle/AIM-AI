import AIMAgentKit
import Foundation

/// One approvable action that detects how a project is built and tested and
/// runs those standard commands, returning a compact verdict (exit status,
/// failure counts, first errors and the end of the output) instead of several
/// separate shell approvals. Commands are shown in the approval review.
public actor ProjectVerificationService: ToolExecutor, ToolReviewProviding {
    public nonisolated let supportedTools: Set<String> = ["verify_project"]

    public struct Step: Equatable, Sendable {
        public let kind: String      // build, test, lint
        public let command: String
    }

    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = MacProcessRunner()) { self.runner = runner }

    // MARK: Detection

    /// Standard steps for the project at `workspace`, in build → lint → test order.
    public nonisolated static func recipe(for workspace: URL) -> (project: String, steps: [Step])? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: workspace.appendingPathComponent(name).path) }
        if exists("Package.swift") {
            return ("Swift package", [Step(kind: "build", command: "swift build"), Step(kind: "test", command: "swift test")])
        }
        if exists("package.json"),
           let data = try? Data(contentsOf: workspace.appendingPathComponent("package.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scripts = manifest["scripts"] as? [String: Any] ?? [:]
            let manager = exists("pnpm-lock.yaml") ? "pnpm" : exists("yarn.lock") ? "yarn"
                : (exists("bun.lockb") || exists("bun.lock")) ? "bun" : "npm"
            var steps: [Step] = []
            if scripts["build"] != nil { steps.append(Step(kind: "build", command: "\(manager) run build")) }
            if scripts["lint"] != nil { steps.append(Step(kind: "lint", command: "\(manager) run lint")) }
            if let test = scripts["test"] as? String, !test.contains("no test specified") {
                steps.append(Step(kind: "test", command: manager == "npm" ? "npm test" : "\(manager) test"))
            }
            return steps.isEmpty ? nil : ("JavaScript package (\(manager))", steps)
        }
        if exists("Cargo.toml") {
            return ("Rust crate", [Step(kind: "build", command: "cargo build"), Step(kind: "test", command: "cargo test")])
        }
        if exists("go.mod") {
            return ("Go module", [Step(kind: "build", command: "go build ./..."), Step(kind: "test", command: "go test ./...")])
        }
        if exists("pyproject.toml") || exists("pytest.ini") || exists("setup.py") || exists("tox.ini") {
            return ("Python project", [Step(kind: "test", command: "python3 -m pytest -q")])
        }
        // Xcode apps: the workspace (CocoaPods/SPM workspaces) wins over the project; the first
        // shared scheme is built and tested.
        let entries = (try? fm.contentsOfDirectory(atPath: workspace.path)) ?? []
        if let container = entries.filter({ $0.hasSuffix(".xcworkspace") }).sorted().first.map({ ("-workspace", $0) })
            ?? entries.filter({ $0.hasSuffix(".xcodeproj") }).sorted().first.map({ ("-project", $0) }) {
            let target = "\(container.0) '\(container.1.replacingOccurrences(of: "'", with: "'\\''"))'"
            let scheme = "scheme=$(xcodebuild -list -json \(target) 2>/dev/null | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get(\"workspace\") or d.get(\"project\"))[\"schemes\"][0])')"
            return ("Xcode project", [Step(kind: "build", command: "\(scheme) && xcodebuild \(target) -scheme \"$scheme\" -quiet build"),
                                      Step(kind: "test", command: "\(scheme) && xcodebuild \(target) -scheme \"$scheme\" -quiet test")])
        }
        if exists("Makefile"), let text = try? String(contentsOf: workspace.appendingPathComponent("Makefile"), encoding: .utf8) {
            var steps = [Step(kind: "build", command: "make")]
            if text.range(of: #"(?m)^test\s*:"#, options: .regularExpression) != nil { steps.append(Step(kind: "test", command: "make test")) }
            return ("Makefile project", steps)
        }
        return nil
    }

    nonisolated static func selected(_ steps: [Step], scope: String?) -> [Step] {
        switch scope ?? "all" {
        case "build": steps.filter { $0.kind == "build" }
        case "test": steps.filter { $0.kind == "test" }
        case "lint": steps.filter { $0.kind == "lint" }
        default: steps
        }
    }

    // MARK: Tool

    public func review(_ request: ToolRequest) async throws -> ToolReview? {
        guard let workspace = request.workspacePath,
              let recipe = Self.recipe(for: URL(fileURLWithPath: workspace, isDirectory: true)) else { return nil }
        let steps = Self.selected(recipe.steps, scope: request.arguments["scope"])
        return ToolReview(path: "Verify \(recipe.project) in \(URL(fileURLWithPath: workspace).lastPathComponent)", before: "",
                          after: steps.map(\.command).joined(separator: "\n") +
                            "\n\nThese commands run the project's own build and test code, not sandboxed.")
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard let path = request.workspacePath else {
            return ToolResult(requestID: request.id, content: "Select a workspace first.", isError: true)
        }
        let workspace = URL(fileURLWithPath: path, isDirectory: true)
        guard let recipe = Self.recipe(for: workspace) else {
            return ToolResult(requestID: request.id,
                content: "No standard build or test setup was recognized (Package.swift, package.json scripts, Cargo.toml, go.mod, pyproject.toml/pytest, Xcode project, Makefile). Use run_command with the project's own command.",
                isError: true)
        }
        let steps = Self.selected(recipe.steps, scope: request.arguments["scope"])
        guard !steps.isEmpty else {
            return ToolResult(requestID: request.id, content: "This \(recipe.project) has no \(request.arguments["scope"] ?? "") step.", isError: true)
        }
        let timeout = min(max(Int(request.arguments["timeout_seconds"] ?? "") ?? 900, 30), 3_600)
        var sections: [String] = []
        var failed = false
        for step in steps {
            let started = ContinuousClock.now
            do {
                let output = try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: ["-f", "-c", step.command], workingDirectory: workspace,
                    environment: Self.environment(), timeout: .seconds(timeout), inheritsEnvironment: false))
                let seconds = (ContinuousClock.now - started).components.seconds
                let combined = output.stdout + "\n" + output.stderr
                sections.append(Self.section(step, exitCode: output.exitCode, seconds: seconds, output: combined))
                if output.exitCode != 0 { failed = true; break }
            } catch {
                sections.append("## \(step.kind): \(step.command)\nDid not finish: \(error.localizedDescription)")
                failed = true
                break
            }
        }
        let verdict = failed ? "FAILED" : "PASSED"
        return ToolResult(requestID: request.id,
            content: "Verification of \(recipe.project): \(verdict)\n\n" + sections.joined(separator: "\n\n"),
            isError: failed, metadata: ["verification": verdict.lowercased(), "project": recipe.project])
    }

    public func cancel(requestID: String) async {}

    // MARK: Summaries

    nonisolated static func section(_ step: Step, exitCode: Int32, seconds: Int64, output: String) -> String {
        var lines = ["## \(step.kind): \(step.command) — exit \(exitCode) in \(seconds) s"]
        if let summary = summary(of: output) { lines.append("Summary: \(summary)") }
        let errors = output.split(separator: "\n").filter {
            $0.contains("error:") || $0.contains("Error:") || $0.hasPrefix("FAIL") || $0.contains("✗") || $0.contains("failed (")
        }.prefix(15)
        if !errors.isEmpty { lines.append("First errors:\n" + errors.map { String($0.prefix(300)) }.joined(separator: "\n")) }
        let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
        lines.append("End of output:\n" + String(tail.suffix(6_000)))
        return lines.joined(separator: "\n")
    }

    /// Test-runner totals in their own words (Swift/XCTest, Jest, Vitest, pytest, cargo, go).
    nonisolated static func summary(of output: String) -> String? {
        let patterns = [
            #"Executed \d+ tests?, with \d+ failures? \(\d+ unexpected\)"#,
            #"Test run with \d+ tests? (passed|failed)[^\n]*"#,
            #"Tests:\s+[^\n]+"#,
            #"Tests\s+\d+[^\n]*(passed|failed)[^\n]*"#,
            #"=+ [^\n]*(passed|failed|error)[^\n]* in [\d.]+s =+"#,
            #"test result: (ok|FAILED)\. \d+ passed; \d+ failed[^\n]*"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
            if let last = matches.last, let range = Range(last.range, in: output) { return String(output[range]) }
        }
        let goLines = output.split(separator: "\n").filter { $0.hasPrefix("ok ") || $0.hasPrefix("FAIL") || $0.hasPrefix("--- FAIL") }
        return goLines.isEmpty ? nil : goLines.prefix(10).joined(separator: "; ")
    }

    nonisolated static func environment() -> [String: String] {
        var environment = ["PATH": WorkspaceShellToolService.toolPath(), "TERM": "dumb",
                           "NO_COLOR": "1", "CI": "1"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_CTYPE"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        return environment
    }
}
