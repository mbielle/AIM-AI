import AIMAgentKit
import Foundation

public enum WorkspaceToolRegistry {
    /// Only read-only operations use the general file browser. Mutations have
    /// dedicated executors with their own path and approval contracts.
    public static func fileTools(executor: WorkspaceFileToolService = WorkspaceFileToolService()) -> [RegisteredTool] {
        [
            RegisteredTool(name: "read_file", risk: .readOnly, requiredArguments: ["path"], optionalArguments: ["start_line", "end_line"],
                           argumentKinds: ["start_line": .integer, "end_line": .integer], allowsSessionDecision: true, executor: executor),
            RegisteredTool(name: "list_dir", risk: .readOnly, optionalArguments: ["path"], allowsSessionDecision: true, executor: executor),
            RegisteredTool(name: "search_files", risk: .readOnly, requiredArguments: ["query"], optionalArguments: ["file_pattern", "case_sensitive", "regex"],
                           argumentKinds: ["case_sensitive": .boolean, "regex": .boolean], allowsSessionDecision: true, executor: executor),
            RegisteredTool(name: "find_files", risk: .readOnly, requiredArguments: ["pattern"], allowsSessionDecision: true, executor: executor),
        ]
    }

    public static func gitTools(executor: MacGitToolService = MacGitToolService(runner: MacProcessRunner())) -> [RegisteredTool] {
        executor.supportedTools.sorted().map {
            RegisteredTool(name: $0, risk: .readOnly, allowsSessionDecision: true, executor: executor)
        }
    }
}
