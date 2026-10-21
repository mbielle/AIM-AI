import Foundation

/// Best-effort guardrail on top of mandatory command approval. Catastrophic
/// commands are refused even when approved; sensitive ones carry explicit
/// warnings in the approval (and no session-wide grant). A shell can always
/// obfuscate, so this never replaces the person's approval.
public enum ShellCommandClassifier {
    public struct Verdict: Equatable, Sendable {
        public var refusal: String?
        public var warnings: [String] = []
        /// The command may discard uncommitted work (AIM records a recovery point first).
        public var discardsLocalChanges = false

        public var isCatastrophic: Bool { refusal != nil }
        public var isSensitive: Bool { !warnings.isEmpty }
    }

    private static let protectedTargets: Set<String> = [
        "/", "/*", "~", "~/", "~/*", "$HOME", "${HOME}", "$HOME/", "${HOME}/", "$HOME/*",
        "/System", "/Users", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private",
        "/var", "/opt", "/Volumes", "/cores", "/dev"
    ]
    private static let wholeWorkspaceTargets: Set<String> = [".", "./", "./*", "*", "..", "../", "../*", ".*"]

    public static func classify(_ command: String) -> Verdict {
        var verdict = Verdict()
        let compact = command.replacingOccurrences(of: " ", with: "")
        if compact.contains(":(){:|:&};:") || compact.contains(":(){:|:&};") {
            verdict.refusal = "a fork bomb would exhaust the system's processes"
            return verdict
        }
        if command.range(of: #"(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|perl|ruby)\b"#, options: .regularExpression) != nil {
            verdict.warnings.append("Runs code downloaded from the internet without saving or inspecting it first.")
        }
        for segment in segments(command) {
            var words = tokens(segment)
            var elevated = false
            while let first = words.first, ["sudo", "doas", "nohup", "time", "command", "exec", "nice", "env", "xargs"].contains(first)
                    || (first.contains("=") && !first.hasPrefix("-")) {
                if first == "sudo" || first == "doas" { elevated = true }
                words.removeFirst()
                while elevated, let flag = words.first, flag.hasPrefix("-") { words.removeFirst() }
            }
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let arguments = Array(words.dropFirst())
            if elevated { verdict.warnings.append("Runs with administrator privileges (sudo).") }
            inspect(program: program, arguments: arguments, into: &verdict)
            if verdict.isCatastrophic { return verdict }
        }
        verdict.warnings = Array(NSOrderedSet(array: verdict.warnings)) as? [String] ?? verdict.warnings
        return verdict
    }

    private static func inspect(program: String, arguments: [String], into verdict: inout Verdict) {
        let flags = arguments.filter { $0.hasPrefix("-") }
        let operands = arguments.filter { !$0.hasPrefix("-") }
        func shortFlag(_ letter: Character) -> Bool {
            flags.contains { !$0.hasPrefix("--") && $0.dropFirst().contains(letter) }
        }
        switch program {
        case "rm":
            let recursive = shortFlag("r") || shortFlag("R") || flags.contains("--recursive")
            if flags.contains("--no-preserve-root") { verdict.refusal = "it disables rm's protection of the root folder" }
            else if recursive, let target = operands.first(where: { protectedTargets.contains(normalizedTarget($0)) }) {
                verdict.refusal = "it recursively deletes \(target), outside any project"
            } else if recursive, operands.contains(where: { wholeWorkspaceTargets.contains($0) }) {
                verdict.warnings.append("Recursively deletes the whole current folder.")
            } else if recursive {
                verdict.warnings.append("Recursively deletes files (not moved to the Trash).")
            } else if shortFlag("f") {
                verdict.warnings.append("Force-deletes files (not moved to the Trash).")
            }
        case "chmod", "chown", "chgrp":
            let recursive = shortFlag("R")
            if recursive, let target = operands.first(where: { protectedTargets.contains(normalizedTarget($0)) }) {
                verdict.refusal = "it recursively changes permissions or ownership of \(target)"
            } else if recursive {
                verdict.warnings.append("Recursively changes permissions or ownership.")
            }
        case "dd":
            if arguments.contains(where: { $0.hasPrefix("of=/dev/") }) { verdict.refusal = "it writes raw data to a disk device" }
        case "diskutil":
            let destructive = ["erasedisk", "erasevolume", "zerodisk", "secureerase", "partitiondisk", "reformat",
                               "randomdisk", "deletecontainer", "deletevolume", "erase"]
            if arguments.contains(where: { destructive.contains($0.lowercased()) }) { verdict.refusal = "it erases or repartitions a disk" }
        case _ where program.hasPrefix("mkfs") || program.hasPrefix("newfs"):
            verdict.refusal = "it formats a file system"
        case "csrutil", "nvram", "fdesetup":
            verdict.refusal = "it changes system security or firmware settings"
        case "spctl", "tmutil":
            if arguments.contains(where: { ["--master-disable", "--global-disable", "disable", "delete", "deletelocalsnapshots"].contains($0) }) {
                verdict.refusal = "it disables system protection or deletes backups"
            }
        case "shutdown", "reboot", "halt":
            verdict.refusal = "it shuts down or restarts the Mac"
        case "kill":
            if arguments.last == "-1" { verdict.refusal = "it signals every process of the user" }
        case "git":
            inspectGit(arguments, into: &verdict)
        case "find":
            if arguments.contains("-delete") || (arguments.contains("-exec") && arguments.contains("rm")) {
                verdict.warnings.append("Deletes every file the search matches.")
            }
        case "launchctl":
            verdict.warnings.append("Changes macOS services (launchctl).")
        case "defaults":
            if ["write", "delete", "import"].contains(arguments.first ?? "") {
                verdict.warnings.append("Changes macOS or app preferences.")
            }
        case "security":
            verdict.warnings.append("Accesses the Keychain (passwords and certificates).")
        case "osascript":
            verdict.warnings.append("Runs AppleScript, which can control other apps.")
        case "pkill", "killall":
            verdict.warnings.append("Stops processes by name, possibly outside this project.")
        case "npm", "pnpm", "yarn", "cargo", "gem", "twine", "pod":
            if operands.first == "publish" || (program == "gem" && operands.first == "push") ||
                (program == "twine" && operands.first == "upload") || (program == "pod" && operands.prefix(2) == ["trunk", "push"]) {
                verdict.warnings.append("Publishes a package to a public registry.")
            }
        case "gh":
            let action = Array(operands.prefix(2))
            if action.first == "release" || action == ["pr", "merge"] || action == ["repo", "delete"] {
                verdict.warnings.append("Changes a GitHub repository (release, merge or deletion).")
            }
        default:
            break
        }
    }

    private static func inspectGit(_ arguments: [String], into verdict: inout Verdict) {
        // Skip global options such as -C <dir> or -c key=value.
        var rest = arguments[...]
        while let first = rest.first, first.hasPrefix("-") {
            rest = rest.dropFirst(first == "-C" || first == "-c" ? 2 : 1)
        }
        guard let subcommand = rest.first else { return }
        let options = Array(rest.dropFirst())
        switch subcommand {
        case "reset" where options.contains("--hard"):
            verdict.warnings.append("Discards uncommitted changes (git reset --hard).")
            verdict.discardsLocalChanges = true
        case "clean" where options.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f") } || options.contains("--force"):
            verdict.warnings.append("Deletes untracked files (git clean).")
            verdict.discardsLocalChanges = true
        case "checkout" where options.contains("--") || options.contains(".") || options.contains("-f") || options.contains("--force"):
            verdict.warnings.append("Overwrites uncommitted changes in the working tree (git checkout).")
            verdict.discardsLocalChanges = true
        case "restore" where !options.contains("--staged") || options.contains("--worktree"):
            verdict.warnings.append("Discards uncommitted changes in the working tree (git restore).")
            verdict.discardsLocalChanges = true
        case "stash" where ["drop", "clear"].contains(options.first ?? ""):
            verdict.warnings.append("Permanently deletes stashed changes.")
        case "branch" where options.contains("-D") || (options.contains("--delete") && options.contains("--force")):
            verdict.warnings.append("Force-deletes a branch, even if it is not merged.")
        case "push":
            if options.contains(where: { ["--force", "-f", "--force-with-lease", "--mirror", "--delete", "-d", "--prune"].contains($0) || $0.hasPrefix("--force-with-lease=") || $0.hasPrefix("+") }) {
                verdict.warnings.append("Rewrites or deletes history on a remote (forced or deleting push).")
            } else {
                verdict.warnings.append("Sends commits to a remote repository.")
            }
        case "rebase", "filter-branch", "filter-repo":
            verdict.warnings.append("Rewrites commit history.")
        case "reflog" where options.first == "expire",
             "gc" where options.contains(where: { $0.hasPrefix("--prune") }):
            verdict.warnings.append("Removes Git's ability to recover lost commits.")
        case "commit" where options.contains("--amend"):
            verdict.warnings.append("Rewrites the latest commit.")
        default:
            break
        }
    }

    private static func normalizedTarget(_ target: String) -> String {
        var value = target
        while value.count > 1 && value.hasSuffix("/") && !value.hasSuffix("*/") { value.removeLast() }
        return value == "~/" ? "~" : value
    }

    /// Splits on command separators (outside quotes): ; && || | & and newlines.
    static func segments(_ command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; current.append(character); continue }
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            if character == "'" || character == "\"" { quote = character; current.append(character); continue }
            if ";|&\n".contains(character) || character == "(" || character == ")" || character == "`" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts.map { $0.replacingOccurrences(of: "$(", with: " ") }
    }

    /// Whitespace tokens with surrounding quotes removed (no expansion).
    static func tokens(_ segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var hasToken = false
        for character in segment {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; hasToken = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; hasToken = true; continue }
            if character == " " || character == "\t" {
                if hasToken || !current.isEmpty { words.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(character)
        }
        if hasToken || !current.isEmpty { words.append(current) }
        return words
    }
}
