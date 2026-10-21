import Foundation

/// What Auto's safety check concluded about a command before it runs.
public enum AutoSafetyDecision: Equatable, Sendable {
    /// Runs without asking; the reason is recorded with the action.
    case allow(String)
    /// The person is asked, with this explanation on the card.
    case ask(String)
}

/// The local rules' verdict: clear either way, or a doubt left to a judge.
public enum AutoSafetyRule: Equatable, Sendable {
    case safe(String)
    case risky(String)
    case doubt(String)
}

/// A judge's answer for a doubtful command.
public struct AutoSafetyJudgement: Equatable, Sendable {
    public var safe: Bool
    /// Probability (0…1) that running it without asking is safe.
    public var confidence: Double
    public var reason: String
    /// Who judged: "Jev", or a model name.
    public var judge: String
    public init(safe: Bool, confidence: Double, reason: String, judge: String) {
        self.safe = safe; self.confidence = confidence; self.reason = reason; self.judge = judge
    }
}

/// A fast second opinion (Jev, or a small connected model) for commands the rules cannot settle.
public protocol AutoSafetyJudging: Sendable {
    func judge(command: String, workspace: String?, doubt: String) async -> AutoSafetyJudgement?
}

/// Auto's safety agent for shell commands: local rules first; a judge only when in doubt; the
/// person is asked whenever a command is risky or nobody could vouch for it. Catastrophic
/// commands never reach it (they are refused before any approval).
public struct AutoSafetyReviewer: Sendable {
    public static let requiredConfidence = 0.8
    private let judge: (any AutoSafetyJudging)?
    public init(judge: (any AutoSafetyJudging)?) { self.judge = judge }

    public func decide(command: String, workspace: String?) async -> AutoSafetyDecision {
        switch Self.rules(command: command, workspace: workspace) {
        case let .safe(reason): return .allow(reason)
        case let .risky(reason): return .ask(reason)
        case let .doubt(reason):
            guard let judge else { return .ask(reason + " No safety judge is available, so AIM asks you.") }
            guard let answer = await judge.judge(command: command, workspace: workspace, doubt: reason) else {
                return .ask(reason + " The safety judge did not answer, so AIM asks you.")
            }
            let percent = Int((answer.confidence * 100).rounded())
            if answer.safe && answer.confidence >= Self.requiredConfidence {
                return .allow("\(answer.judge) judged it safe (\(percent)%): \(answer.reason)")
            }
            return .ask("\(answer.judge) could not confirm it is safe (\(percent)%): \(answer.reason)")
        }
    }

    // MARK: Rules

    private static let readers: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "ag", "file", "stat", "du", "df", "which", "whereis", "type",
        "echo", "printf", "pwd", "tree", "sort", "uniq", "diff", "cmp", "cut", "tr", "awk", "sed", "jq", "yq", "date", "uname", "sw_vers",
        "basename", "dirname", "realpath", "readlink", "true", "false", "test", "[", "cd", "less", "more", "column", "nl", "md5", "shasum",
        "sha256sum", "xxd", "hexdump", "strings", "otool", "nm", "lipo", "plutil", "mdls", "sleep", "seq", "tee", "find", "xargs", "open"
    ]
    private static let builders: Set<String> = [
        "swift", "swiftc", "xcodebuild", "xcrun", "xcodegen", "tuist", "make", "cmake", "ninja", "meson", "bazel", "cargo", "rustc",
        "rustup", "go", "gcc", "g++", "clang", "clang++", "javac", "java", "mvn", "gradle", "gradlew", "kotlinc", "dotnet",
        "npm", "npx", "pnpm", "yarn", "bun", "deno", "node", "tsc", "eslint", "prettier", "jest", "vitest", "mocha", "playwright",
        "python", "python3", "pip", "pip3", "uv", "poetry", "pytest", "ruff", "black", "mypy", "ruby", "bundle", "rake", "rspec",
        "php", "composer", "flutter", "dart", "pod", "carthage", "swiftlint", "swiftformat", "brew"
    ]
    private static let localFiles: Set<String> = ["mkdir", "touch", "cp", "mv", "ln", "chmod", "zip", "unzip", "tar", "gzip", "gunzip"]
    private static let writers: Set<String> = ["mkdir", "touch", "cp", "mv", "ln", "chmod", "tee", "rm", "rmdir", "zip", "unzip", "tar", "sed", "install"]
    private static let remote: Set<String> = ["ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp", "socat"]
    private static let credentialMarkers = [".ssh/", "/.ssh", ".aws/", ".netrc", "id_rsa", "id_ed25519", ".gnupg", "Library/Keychains",
                                            "Cookies", ".kube/config", ".docker/config.json", ".npmrc", ".pypirc"]

    /// The rules alone. Every segment of a chained command must be safe for the whole to be.
    public static func rules(command raw: String, workspace: String?) -> AutoSafetyRule {
        // "2>&1" and "&>" are redirections, not command separators.
        let command = raw.replacingOccurrences(of: #"\d*>&(\d+|-)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&>", with: ">")
        let verdict = ShellCommandClassifier.classify(command)
        if let refusal = verdict.refusal { return .risky("AIM refuses this command because \(refusal).") }
        if let warning = verdict.warnings.first { return .risky(warning) }
        if let marker = credentialMarkers.first(where: { command.contains($0) }) {
            return .risky("Touches credentials (\(marker.trimmingCharacters(in: CharacterSet(charactersIn: "/")))).")
        }
        var doubt: String?
        for segment in ShellCommandClassifier.segments(command) {
            var words = ShellCommandClassifier.tokens(segment)
            while let first = words.first, ["nohup", "time", "command", "exec", "nice", "env"].contains(first)
                    || (first.contains("=") && !first.hasPrefix("-")) { words.removeFirst() }
            if words.first == "sudo" || words.first == "doas" { return .risky("Runs with administrator privileges (sudo).") }
            guard let first = words.first else { continue }
            let program = (first as NSString).lastPathComponent
            let arguments = Array(words.dropFirst())
            switch check(program: program, arguments: arguments, workspace: workspace) {
            case .risky(let reason): return .risky(reason)
            case .doubt(let reason): doubt = doubt ?? reason
            case .safe: break
            }
        }
        if let doubt { return .doubt(doubt) }
        return .safe("Reads, builds or tests inside the chosen folder.")
    }

    private static func check(program: String, arguments: [String], workspace: String?) -> AutoSafetyRule {
        // Redirections: "> file", ">> file", "2>file", "&>file".
        var writes: [String] = []
        var operands: [String] = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if let range = word.range(of: #"^[0-9&]?>>?"#, options: .regularExpression) {
                let rest = String(word[range.upperBound...])
                if rest.hasPrefix("&") { index += 1; continue }
                if !rest.isEmpty { writes.append(rest) } else if index + 1 < arguments.count { writes.append(arguments[index + 1]); index += 1 }
            } else if !word.hasPrefix("-") { operands.append(word) }
            index += 1
        }
        if writers.contains(program) { writes += operands.filter { $0.contains("/") || $0.hasPrefix("~") || $0.hasPrefix("$") } }
        for target in writes {
            switch place(target, workspace: workspace) {
            case .outside: return .risky("Writes outside the chosen folder (\(target)).")
            case .unknown: return .doubt("Writes to a path AIM cannot place (\(target)).")
            case .inside: break
            }
        }
        if remote.contains(program) { return .risky("Connects to another machine (\(program)).") }
        switch program {
        case "curl", "wget", "http", "https":
            let upload = ["-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "-F", "--form", "-T", "--upload-file",
                          "--post-data", "--post-file", "--json"]
            if arguments.contains(where: { argument in upload.contains { argument == $0 || argument.hasPrefix($0 + "=") } }) ||
                zip(arguments, arguments.dropFirst()).contains(where: { $0 == "-X" && ["POST", "PUT", "PATCH", "DELETE"].contains($1.uppercased()) }) {
                return .risky("Sends data from this Mac to a server (\(program)).")
            }
            return .doubt("Downloads from the internet (\(program)).")
        case "git":
            let rest = arguments.drop { $0.hasPrefix("-") }
            guard let subcommand = rest.first else { return .safe("") }
            if subcommand == "push" {
                if rest.contains(where: { $0 == "-f" || $0.hasPrefix("--force") || $0.hasPrefix("+") || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f")) }) {
                    return .risky("Rewrites history on the remote (git push --force).")
                }
                return .doubt("Publishes commits to the remote repository (git push).")
            }
            if ["config", "credential", "filter-branch", "gc", "prune", "reflog"].contains(subcommand) { return .doubt("Changes Git's configuration or history (git \(subcommand)).") }
            return .safe("")
        case "rm", "rmdir", "unlink", "trash":
            return .doubt("Deletes files permanently (\(program)).")
        case "npm", "pnpm", "yarn", "bun":
            if arguments.contains(where: { ["publish", "login", "adduser", "token", "unpublish", "deprecate", "owner"].contains($0) }) {
                return .risky("Publishes or changes a package registry account (\(program)).")
            }
            if arguments.contains(where: { $0 == "-g" || $0 == "--global" }) { return .doubt("Installs a package for the whole Mac (\(program) -g).") }
            return .safe("")
        case "brew":
            return ["list", "info", "search", "--version", "config", "outdated", "deps"].contains(arguments.first ?? "")
                ? .safe("") : .doubt("Changes software installed on this Mac (brew).")
        case "pip", "pip3":
            return arguments.contains("--user") || arguments.contains("--break-system-packages")
                ? .doubt("Installs Python packages outside the project.") : .safe("")
        case "python", "python3", "node", "ruby", "perl", "php", "deno", "bun", "swift":
            if arguments.contains(where: { ["-c", "-e", "--eval", "-p", "--print", "-r"].contains($0) }) {
                return .doubt("Runs code written inline (\(program) \(arguments.first ?? "")).")
            }
            return .safe("")
        case "find":
            return arguments.contains("-delete") || arguments.contains("-exec") || arguments.contains("-execdir")
                ? .doubt("Runs an action on every file found (find -exec).") : .safe("")
        case "sed":
            return .safe("")
        case "open":
            return operands.contains(where: { $0.hasPrefix("http") }) ? .doubt("Opens a web page.") : .safe("")
        case "xargs":
            return .doubt("Runs a command on each input line (xargs).")
        default:
            if readers.contains(program) || builders.contains(program) || localFiles.contains(program) { break }
            if program.hasPrefix("./") || program == "gradlew" { break }
            return .doubt("Runs a program AIM does not recognize (\(program)).")
        }
        // Reading files elsewhere on the Mac is not a write, but deserves a second look.
        if let outside = operands.first(where: { place($0, workspace: workspace) == .outside && !$0.hasPrefix("-") && !$0.hasPrefix("http") }) {
            return .doubt("Uses a path outside the chosen folder (\(outside)).")
        }
        return .safe("")
    }

    private enum Place { case inside, outside, unknown }

    /// Where a path points relative to the workspace. Temporary folders count as inside.
    private static func place(_ raw: String, workspace: String?) -> Place {
        let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if path.isEmpty || path == "/dev/null" || path == "/dev/stdout" || path == "/dev/stderr" { return .inside }
        if path.hasPrefix("$") && !path.hasPrefix("$HOME") && !path.hasPrefix("${HOME}") {
            return path.hasPrefix("$TMPDIR") || path.hasPrefix("${TMPDIR}") ? .inside : .unknown
        }
        let temporary = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        if path.hasPrefix("~") || path.hasPrefix("$HOME") || path.hasPrefix("${HOME}") {
            guard let workspace else { return .outside }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let expanded = home + path.drop { $0 != "/" }
            return isInside(expanded, workspace) ? .inside : .outside
        }
        if path.hasPrefix("/") {
            if temporary.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .inside }
            guard let workspace else { return .outside }
            return isInside(path, workspace) ? .inside : .outside
        }
        // Relative: inside unless it climbs out.
        guard let workspace else { return path.hasPrefix("..") ? .outside : .inside }
        let resolved = URL(fileURLWithPath: workspace).appending(path: path).standardizedFileURL.path
        return isInside(resolved, workspace) ? .inside : .outside
    }

    private static func isInside(_ path: String, _ workspace: String) -> Bool {
        let base = URL(fileURLWithPath: workspace).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
