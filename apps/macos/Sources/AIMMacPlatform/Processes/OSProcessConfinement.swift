import AIMAgentKit
import AIMCore
import Foundation
import Darwin

public enum OSProcessNetworkPolicy: Sendable, Equatable { case deny, installationAllowed }
public enum OSProcessConfinementError: LocalizedError {
    case unavailable, invalidScope, inheritedCredential
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The system Seatbelt launcher is unavailable. AIM refuses to launch this worker without OS confinement."
        case .invalidScope: "The confined worker requires explicit existing filesystem scopes and a private home; no unrestricted user-home scope is allowed."
        case .inheritedCredential: "The confined worker environment contains a credential, proxy or injected loader setting. AIM refused the launch."
        }
    }
}
/// Only this factory creates the exact command consumed by runConfined. A JSON
/// claim or an external adapter's receipt cannot enable the private admission.
public struct ConfinedProcessCommand: Sendable {
    let command: ProcessCommand
    let permitsNetwork: Bool
    fileprivate init(command: ProcessCommand, permitsNetwork: Bool) {
        self.command = command; self.permitsNetwork = permitsNetwork
    }
}
public enum OSProcessConfinement {
    public static func prepare(_ command: ProcessCommand, readRoots: [URL], writeRoots: [URL],
        privateHome: URL, network: OSProcessNetworkPolicy = .deny) throws -> ConfinedProcessCommand {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw OSProcessConfinementError.unavailable }
        if network == .installationAllowed { try AIMNetworkPrivacyPolicy.requireNetwork() }
        let home = try directory(privateHome)
        let userHome = try canonicalPath(FileManager.default.homeDirectoryForCurrentUser)
        let reads = try readRoots.map(directory), writes = try writeRoots.map(directory)
        let support = userHome + "/Library/Application Support/" + AIMInstallationContext.applicationSupportNamespace
        let agents = support + "/Agents"
        let forbidden = [userHome + "/Library/Keychains", userHome + "/.ssh", userHome + "/.aws", userHome + "/.config/gcloud",
            userHome + "/Library/Preferences/" + AIMInstallationContext.preferencesSuite + ".plist",
            support + "/aim.sqlite", support + "/aim.sqlite-wal", support + "/aim.sqlite-shm", support + "/Privacy"]
        for path in reads + writes + [home] {
            guard path != "/", path != "/private/tmp", path != "/tmp", path != userHome, !userHome.hasPrefix(path + "/"),
                  (!path.hasPrefix(userHome + "/Library") || path.hasPrefix(agents + "/")),
                  (!path.hasPrefix(userHome + "/.") || path == home || path.hasPrefix(home + "/")),
                  (!path.hasPrefix(support + "/") || path.hasPrefix(agents + "/")), path != support,
                  !forbidden.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                throw OSProcessConfinementError.invalidScope
            }
        }
        guard writes.contains(where: { home == $0 || home.hasPrefix($0 + "/") }),
              command.executable.isFileURL, command.executable.path.hasPrefix("/"),
              !command.executable.path.contains("\0") else { throw OSProcessConfinementError.invalidScope }
        if let directory = command.workingDirectory {
            let path = try self.directory(directory)
            guard (reads + writes).contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { throw OSProcessConfinementError.invalidScope }
        }
        let executablePath = try canonicalPath(command.executable)
        let banned = ["TOKEN", "SECRET", "PASSWORD", "API_KEY", "APIKEY", "AUTHORIZATION", "COOKIE", "PROXY", "DYLD_", "LD_PRELOAD", "NODE_OPTIONS"]
        guard command.environment.keys.allSatisfy({ key in !banned.contains(where: { key.uppercased().contains($0) }) }) else {
            throw OSProcessConfinementError.inheritedCredential
        }
        var environment = command.environment
        environment["HOME"] = home; environment["TMPDIR"] = home + "/tmp"
        try FileManager.default.createDirectory(atPath: home + "/tmp", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // Default deny also blocks Mach/XPC/AppleEvent relay access to unrelated
        // apps/services, rather than merely prohibiting TCP sockets.
        // A worker may terminate its own children; the kernel relationship
        // filter does not authorize unrelated peers or all processes of the UID.
        var profile = "(version 1)\n(deny default)\n(allow process-fork)\n(allow process-exec)\n(allow signal (target self))\n(allow signal (target children))\n(allow sysctl-read)\n"
        // Apple's dyld-support.sb: libignition opens the root directory for
        // openat2. This literal permits metadata/root access, not descendants.
        profile += "(allow file-read* (literal \"/\"))\n"
        // Node/npm canonicalize absolute paths one component at a time. Permit
        // lstat of exactly these ancestors, never directory contents or data.
        var metadataAncestors = Set<String>()
        for path in reads + writes + [home, executablePath] {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            while parent != "/" && !parent.isEmpty {
                metadataAncestors.insert(parent)
                parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            }
        }
        for path in metadataAncestors.sorted() {
            profile += "(allow file-read-metadata (literal \(quoted(path))))\n"
        }
        for path in ["/System", "/usr/lib", "/usr/share", "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/private/var/db/dyld"] + reads + writes + [home] {
            profile += "(allow file-read* file-map-executable (subpath \(quoted(path))))\n"
        }
        profile += "(allow file-read* file-map-executable (literal \(quoted(executablePath))))\n"
        profile += "(allow file-read* (subpath \"/private/etc/ssl\"))\n"
        for path in ["/private/etc/hosts", "/private/etc/resolv.conf", "/private/etc/services", "/private/etc/protocols"] {
            let canonical = (try? canonicalPath(URL(fileURLWithPath: path))) ?? path
            profile += "(allow file-read* (literal \(quoted(path))) (literal \(quoted(canonical))))\n"
        }
        for path in writes + [home] { profile += "(allow file-write* (subpath \(quoted(path))))\n" }
        profile += "(allow file-read* file-write* (literal \"/dev/null\") (literal \"/dev/zero\") (subpath \"/dev/fd\"))\n"
        profile += "(allow file-read* (literal \"/dev/random\") (literal \"/dev/urandom\"))\n"
        for path in forbidden { profile += "(deny file-read* file-write* (subpath \(quoted(path))))\n" }
        // Secret files (~/.aws/credentials, .git-credentials, SSH keys), not every folder named
        // "credentials": SDK packages ship a lib/credentials folder that npm must extract and read.
        // Seatbelt regexes do not honour "\\." escapes (the previous ".env" rule never matched):
        // dots are written as [.] so these rules really deny.
        profile += "(deny file-read* (regex #\"(^|/)[.]env($|[./])\") (regex #\"/[.][^/]+/credentials$\") (regex #\"(^|/)([.]git-credentials|id_rsa|id_ed25519|login[.]keychain-db)$\"))\n"
        if network == .deny { profile += "(deny network*)\n" }
        else {
            profile += "(allow network-outbound)\n(allow mach-lookup (global-name \"com.apple.system.opendirectoryd.libinfo\"))\n"
            // getaddrinfo resolves /var/run/mDNSResponder through the system
            // /var symlink. Only its metadata/existence is needed; DNS remains
            // unavailable to deny-network workers. No new Mach service opens.
            profile += "(allow file-read-metadata file-test-existence (literal \"/var\"))\n"
        }
        let value = ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", profile, command.executable.path] + command.arguments,
            workingDirectory: command.workingDirectory, environment: environment, timeout: command.timeout,
            inheritsEnvironment: false, acceptsStandardInput: command.acceptsStandardInput)
        return ConfinedProcessCommand(command: value, permitsNetwork: network == .installationAllowed)
    }
    private static func directory(_ url: URL) throws -> String {
        guard url.isFileURL else { throw OSProcessConfinementError.invalidScope }
        let path = try canonicalPath(url)
        var directory: ObjCBool = false
        guard !path.contains("\0"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw OSProcessConfinementError.invalidScope
        }
        return path
    }
    /// Seatbelt compares kernel paths. Foundation can shorten /private/tmp to
    /// /tmp on macOS, which is unsuitable as the authority of an OS allow rule.
    private static func canonicalPath(_ url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              let resolved = Darwin.realpath(url.path, nil) else { throw OSProcessConfinementError.invalidScope }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
