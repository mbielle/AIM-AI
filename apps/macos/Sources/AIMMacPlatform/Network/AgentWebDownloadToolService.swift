import AIMCore
import AIMAgentKit
import AIMApplication
import CryptoKit
import Darwin
import Foundation

/// Downloads a public HTTP(S) resource into a new regular workspace file.
/// No browser cookies, provider credentials, redirects or overwrite are used.
public actor AgentWebDownloadToolService: ToolExecutor, MissionIntentProviding {
    public nonisolated let supportedTools: Set<String> = ["web_download"]
    private let session: URLSession
    private var running: [String: Task<DownloadReceipt, Error>] = [:]
    private static let maximumBytes = 50 * 1_024 * 1_024

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            self.session = RuntimeManagedNetworkSession.make(configuration: config, delegate: DownloadNoRedirectDelegate(), delegateQueue: nil)
        }
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            guard request.name == "web_download", let rawURL = request.arguments["url"],
                  let destination = request.arguments["destination"],
                  let workspace = request.workspacePath else { throw DownloadError.invalidArgument }
            let url = try Self.allowedURL(rawURL)
            let parts = try Self.components(destination)
            let task = Task { try await download(url, parts: parts, workspace: workspace) }
            running[request.id] = task
            defer { running.removeValue(forKey: request.id) }
            let receipt = try await task.value
            return ToolResult(requestID: request.id,
                content: "Downloaded \(receipt.bytes) bytes to \(destination). SHA-256: \(receipt.sha256). The destination was new; inspect it before claiming that its contents meet the mission.",
                metadata: ["bytes": String(receipt.bytes), "sha256": receipt.sha256,
                           "path": destination, "action_outcome": ActionOutcome.confirmed.rawValue])
        } catch {
            var result = ToolResult(requestID: request.id,
                content: "Download did not complete: \(error.localizedDescription). Inspect the destination before retrying; a failed cleanup may leave a partial file.", isError: true)
            result.actionOutcome = .unknown
            return result
        }
    }

    public func cancel(requestID: String) async { running[requestID]?.cancel() }

    public nonisolated func missionIntent(for request: ToolRequest) throws -> MissionToolIntent? {
        guard request.name == "web_download" else { return nil }
        guard let rawURL = request.arguments["url"], let destination = request.arguments["destination"],
              let workspace = request.workspacePath else { throw DownloadError.invalidArgument }
        let url = try Self.allowedURL(rawURL)
        let parts = try Self.components(destination)
        let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard root.path == workspace else { throw DownloadError.invalidWorkspace }
        let file = parts.reduce(root) { $0.appendingPathComponent($1) }
        let origin = try Self.origin(for: url)
        return try MissionToolIntent(needs: [
            MissionPermissionNeed(operation: .observe,
                target: MissionResource(kind: .webOrigin, identifier: origin)),
            MissionPermissionNeed(operation: .edit,
                target: MissionResource(kind: .directory, identifier: file.path))
        ])
    }

    private func download(_ url: URL, parts: [String], workspace: String) async throws -> DownloadReceipt {
        try Task.checkCancellation()
        let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard root.path == workspace else { throw DownloadError.invalidWorkspace }
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw DownloadError.invalidWorkspace }
        defer { Darwin.close(rootFD) }
        let parent = try Self.parentDescriptor(rootFD: rootFD, parts: parts)
        defer { Darwin.close(parent) }
        var existing = stat()
        if Darwin.fstatat(parent, parts.last!, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            throw DownloadError.alreadyExists
        }
        guard errno == ENOENT else { throw DownloadError.cannotCreate }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url == url else { throw DownloadError.invalidResponse }
        guard response.expectedContentLength <= Self.maximumBytes else { throw DownloadError.tooLarge }
        try Task.checkCancellation()

        let fd = Darwin.openat(parent, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw DownloadError.alreadyExists }
            throw DownloadError.cannotCreate
        }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard Darwin.fstat(fd, &opened) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw DownloadError.cannotCreate }
        var completed = false
        defer {
            if !completed {
                var current = stat()
                if Darwin.fstatat(parent, parts.last!, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == opened.st_dev, current.st_ino == opened.st_ino {
                    _ = Darwin.unlinkat(parent, parts.last!, 0)
                }
            }
        }

        var digest = SHA256()
        var total = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard total < Self.maximumBytes else { throw DownloadError.tooLarge }
            buffer.append(byte)
            total += 1
            if buffer.count == 64 * 1_024 {
                try Self.write(buffer, to: fd)
                digest.update(data: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try Self.write(buffer, to: fd)
            digest.update(data: buffer)
        }
        try Task.checkCancellation()
        guard Darwin.fsync(fd) == 0 else { throw DownloadError.cannotWrite }
        completed = true
        return DownloadReceipt(bytes: total, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private nonisolated static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DownloadError.cannotWrite
                }
                guard written > 0 else { throw DownloadError.cannotWrite }
                offset += written
            }
        }
    }

    private nonisolated static func allowedURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 4_096, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else {
            throw DownloadError.invalidURL
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") ||
            host.hasSuffix(".internal") || host.contains(":") || host.hasPrefix("0x") ||
            host.allSatisfy(\.isNumber) { throw DownloadError.invalidURL }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            let a = octets[0], b = octets[1]
            if a == 0 || a == 10 || a == 127 || a >= 224 ||
                (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) ||
                (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) {
                throw DownloadError.invalidURL
            }
        }
        return url
    }

    private nonisolated static func origin(for url: URL) throws -> String {
        guard let scheme = url.scheme, let host = url.host else { throw DownloadError.invalidURL }
        var value = URLComponents()
        value.scheme = scheme.lowercased()
        value.host = host.lowercased()
        value.port = url.port
        guard let result = value.string else { throw DownloadError.invalidURL }
        return result
    }

    private nonisolated static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains("\0"), !path.contains("\\") else { throw DownloadError.invalidArgument }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DownloadError.invalidArgument
        }
        return parts
    }

    private nonisolated static func parentDescriptor(rootFD: Int32, parts: [String]) throws -> Int32 {
        var fd = Darwin.dup(rootFD)
        guard fd >= 0 else { throw DownloadError.invalidWorkspace }
        for part in parts.dropLast() {
            let next = Darwin.openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw DownloadError.invalidParent }
            fd = next
        }
        return fd
    }
}

private struct DownloadReceipt: Sendable {
    let bytes: Int
    let sha256: String
}

private final class DownloadNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum DownloadError: LocalizedError {
    case invalidArgument, invalidURL, invalidWorkspace, invalidParent, invalidResponse
    case alreadyExists, cannotCreate, cannotWrite, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidArgument: "Provide a relative destination inside the selected workspace, without . or .. components."
        case .invalidURL: "Download requires a public HTTP or HTTPS URL without embedded credentials."
        case .invalidWorkspace: "The selected workspace is unavailable or changed."
        case .invalidParent: "The destination parent must exist inside the workspace and cannot be a symbolic link."
        case .invalidResponse: "The server did not return a successful response from the approved URL. Redirects are refused."
        case .alreadyExists: "The destination already exists; no file was overwritten."
        case .cannotCreate: "A new regular destination file could not be created."
        case .cannotWrite: "The downloaded file could not be written completely."
        case .tooLarge: "The download exceeds the 50 MiB per-file safety limit."
        }
    }
}
