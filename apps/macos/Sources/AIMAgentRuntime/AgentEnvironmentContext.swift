import AIMAgentKit
import AIMMacPlatform
import AIMApplication
import Foundation

/// A short, request-only description of the run's environment (date, time
/// zone, macOS version, workspace and its Git state), as reference agents give
/// their models. Only facts stable within a day are included (no clock time or
/// change counts), so the conversation prefix stays cacheable across turns.
enum AgentEnvironmentContext {
    static func message(workspace: String?, conversationID: UUID, now: Date = .now) -> ConversationMessage {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE yyyy-MM-dd"
        var lines = ["Environment (informational, from AIM): today is \(formatter.string(from: now)), time zone \(TimeZone.current.identifier); \(ProcessInfo.processInfo.operatingSystemVersionString) on a Mac."]
        if let workspace {
            lines.append("Selected workspace: \(workspace).")
            if let git = gitState(workspace) { lines.append(git) } else { lines.append("Git context is unavailable; use git_status for an authorized detailed check.") }
        } else {
            lines.append("No workspace folder is selected.")
        }
        return ConversationMessage(conversationID: conversationID, role: .user, content: lines.joined(separator: " "), sequence: -5)
    }

    /// Current branch, with a short timeout; nil outside Git (git_status gives details).
    static func gitState(_ workspace: String) -> String? {
        func run(_ arguments: [String]) -> String? {
            guard let staging = try? ConfinedProcessStaging() else { return nil }
            let command = ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["--no-pager", "--no-optional-locks", "-C", workspace] + arguments,
                workingDirectory: URL(fileURLWithPath: workspace, isDirectory: true),
                environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
                timeout: .seconds(2), inheritsEnvironment: false)
            guard let confined = try? OSProcessConfinement.prepare(command,
                readRoots: [URL(fileURLWithPath: workspace, isDirectory: true), staging.root], writeRoots: [staging.home], privateHome: staging.home),
                  let data = try? ConfinedBinaryProcess.runSynchronously(confined, maximumOutputBytes: 65_536) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        guard let branch = run(["rev-parse", "--abbrev-ref", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return "It is a Git repository on branch \(branch) (use git_status for current changes)."
    }
}
