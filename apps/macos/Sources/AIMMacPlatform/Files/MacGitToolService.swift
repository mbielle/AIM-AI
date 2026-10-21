import AIMAgentKit
import Foundation

public actor MacGitToolService: GitToolServing {
    public nonisolated let supportedTools: Set<String> = [
        "git_inspect", "git_status", "git_diff", "git_worktree_list",
    ]

    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning) { self.runner = runner }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard let workspace = request.workspacePath else {
            return ToolResult(requestID: request.id, content: "No workspace is selected.", isError: true)
        }
        let arguments: [String]
        switch request.name {
        case "git_inspect": arguments = ["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"]
        case "git_status": arguments = ["status", "--short", "--branch", "--", "."]
        case "git_diff": arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--", "."]
        case "git_worktree_list": arguments = ["worktree", "list", "--porcelain"]
        default: return ToolResult(requestID: request.id, content: "Unsupported Git tool: \(request.name)", isError: true)
        }
        do {
            let output = try await runner.run(ProcessCommand(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments,
                workingDirectory: URL(fileURLWithPath: workspace, isDirectory: true),
                environment: ["GIT_TERMINAL_PROMPT": "0"],
                timeout: .seconds(60)
            ))
            return ToolResult(
                requestID: request.id,
                content: (output.exitCode == 0 ? output.stdout : output.stderr)
                    + (output.wasTruncated ? "\n[Output truncated; not a complete Git result.]" : ""),
                isError: output.exitCode != 0,
                metadata: ["exitCode": String(output.exitCode)]
            )
        } catch {
            return ToolResult(requestID: request.id, content: error.localizedDescription, isError: true)
        }
    }

    public func cancel(requestID: String) async { await runner.terminateAll() }
}
