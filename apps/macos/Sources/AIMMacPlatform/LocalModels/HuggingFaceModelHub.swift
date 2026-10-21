import AIMCore
import AIMApplication
import Foundation

/// Finding and downloading open models from Hugging Face, as LM Studio and
/// Otto do. MLX models land in the standard Hugging Face cache
/// (`~/.cache/huggingface/hub`, or `$HF_HOME/hub`), which oMLX (`--hf-cache`),
/// mlx-lm and the `huggingface_hub` tools all read. GGUF files land in LM
/// Studio's models folder, where LM Studio (and llama.cpp) pick them up.
public enum HuggingFaceModelHub {
    public enum Format: String, Sendable, CaseIterable { case mlx, gguf }

    public struct ModelSummary: Equatable, Sendable, Identifiable {
        public let id: String
        public let downloads: Int
        public let likes: Int
        public let lastModified: String?
        public let tags: [String]
        public var supportsTools: Bool { tags.contains { ["tool-use", "function-calling", "tools"].contains($0) } }
    }

    public struct FileEntry: Equatable, Sendable {
        public let path: String
        public let size: Int64
    }

    public struct ModelDetail: Equatable, Sendable {
        public let id: String
        public let sha: String
        public let files: [FileEntry]
        public let gated: Bool
        public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    /// How a model fits this Mac's unified memory.
    public enum Fit: String, Sendable { case comfortable, tight, tooLarge = "too_large" }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public static let defaultFetch: Fetch = { try await RuntimeManagedNetworkSession.shared.data(for: $0) }
    static let api = URL(string: "https://huggingface.co")!

    // MARK: Search

    public static func search(_ query: String, format: Format, limit: Int = 30,
                              fetch: Fetch = defaultFetch) async throws -> [ModelSummary] {
        var components = URLComponents(url: api.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "filter", value: format.rawValue),
            URLQueryItem(name: "pipeline_tag", value: "text-generation"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))
        ]
        let data = try await get(components.url!, fetch: fetch)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HubError.invalidResponse }
        return rows.compactMap { row in
            guard let id = (row["id"] ?? row["modelId"]) as? String else { return nil }
            return ModelSummary(id: id, downloads: row["downloads"] as? Int ?? 0, likes: row["likes"] as? Int ?? 0,
                                lastModified: row["lastModified"] as? String, tags: row["tags"] as? [String] ?? [])
        }
    }

    public enum Sort: String, Sendable, CaseIterable {
        case downloads, likes, lastModified
        public var title: String {
            switch self { case .downloads: "Most downloaded"; case .likes: "Most liked"; case .lastModified: "Recently updated" }
        }
    }

    /// One page of the full catalog (text and image-text chat models), with the next page's
    /// address from the `Link` header; Hugging Face pages every result this way.
    public static func searchPage(_ query: String, format: Format, sort: Sort = .downloads, next: URL? = nil,
                                  fetch: Fetch = defaultFetch) async throws -> (models: [ModelSummary], next: URL?) {
        let url: URL
        if let next, next.host == api.host { url = next } else {
            var components = URLComponents(url: api.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "filter", value: format.rawValue),
                         URLQueryItem(name: "sort", value: sort.rawValue),
                         URLQueryItem(name: "limit", value: "60")]
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: trimmed)) }
            components.queryItems = items
            url = components.url!
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("AIM-AI", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HubError.invalidResponse }
        let chatTasks: Set<String> = ["text-generation", "image-text-to-text", "conversational"]
        let models = rows.compactMap { row -> ModelSummary? in
            guard let id = (row["id"] ?? row["modelId"]) as? String else { return nil }
            if let task = row["pipeline_tag"] as? String, !chatTasks.contains(task) { return nil }
            return ModelSummary(id: id, downloads: row["downloads"] as? Int ?? 0, likes: row["likes"] as? Int ?? 0,
                                lastModified: row["lastModified"] as? String, tags: row["tags"] as? [String] ?? [])
        }
        let link = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link")
        return (models, link.flatMap(nextLink))
    }

    static func nextLink(_ header: String) -> URL? {
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">") else { continue }
            return URL(string: String(part[part.index(after: start)..<end]))
        }
        return nil
    }

    /// What the repository page shows: size, license, base model, languages, tags, dates.
    public struct RepositoryInfo: Equatable, Sendable {
        public let id: String
        public let author: String?
        public let task: String?
        public let parameters: Int64?
        public let tensorTypes: [String]
        public let license: String?
        public let baseModels: [String]
        public let languages: [String]
        public let tags: [String]
        public let lastModified: String?
        public let contextLength: Int?
        public let architecture: String?
        public let downloads: Int
        public let likes: Int
    }

    public static func info(_ repo: String, fetch: Fetch = defaultFetch) async throws -> RepositoryInfo {
        guard isValidRepo(repo) else { throw HubError.invalidRepo }
        let data = try await get(api.appendingPathComponent("api/models/\(repo)"), fetch: fetch)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HubError.invalidResponse }
        let card = root["cardData"] as? [String: Any] ?? [:]
        let safetensors = root["safetensors"] as? [String: Any]
        let gguf = root["gguf"] as? [String: Any]
        func list(_ value: Any?) -> [String] {
            if let array = value as? [String] { return array }
            if let single = value as? String { return [single] }
            return []
        }
        let parameters = (safetensors?["total"] as? NSNumber)?.int64Value ?? (gguf?["total"] as? NSNumber)?.int64Value
        return RepositoryInfo(
            id: repo, author: root["author"] as? String, task: root["pipeline_tag"] as? String, parameters: parameters,
            tensorTypes: ((safetensors?["parameters"] as? [String: Any])?.keys.sorted()) ?? [],
            license: (card["license"] as? String) ?? list(card["license_name"]).first,
            baseModels: list(card["base_model"]), languages: list(card["language"]),
            tags: (root["tags"] as? [String] ?? []).filter { !$0.contains(":") }.prefix(14).map { $0 },
            lastModified: root["lastModified"] as? String,
            contextLength: (gguf?["context_length"] as? NSNumber)?.intValue, architecture: gguf?["architecture"] as? String,
            downloads: root["downloads"] as? Int ?? 0, likes: root["likes"] as? Int ?? 0)
    }

    /// The repository's model card, without its YAML header, HTML and images.
    public static func readme(_ repo: String, fetch: Fetch = defaultFetch) async throws -> String {
        guard isValidRepo(repo) else { throw HubError.invalidRepo }
        let data = try await get(api.appendingPathComponent("\(repo)/raw/main/README.md"), fetch: fetch)
        var text = String(decoding: data.prefix(400_000), as: UTF8.self)
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func detail(_ repo: String, fetch: Fetch = defaultFetch) async throws -> ModelDetail {
        guard isValidRepo(repo) else { throw HubError.invalidRepo }
        let data = try await get(api.appendingPathComponent("api/models/\(repo)").appending(queryItems: [URLQueryItem(name: "blobs", value: "true")]), fetch: fetch)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let sha = root["sha"] as? String,
              let siblings = root["siblings"] as? [[String: Any]] else { throw HubError.invalidResponse }
        let files = siblings.compactMap { item -> FileEntry? in
            guard let path = item["rfilename"] as? String, isSafeRelativePath(path) else { return nil }
            return FileEntry(path: path, size: (item["size"] as? NSNumber)?.int64Value ?? 0)
        }
        let gated = (root["gated"] as? Bool) == true || (root["gated"] as? String).map { $0 != "false" } == true
        return ModelDetail(id: repo, sha: sha, files: files, gated: gated)
    }

    // MARK: Fit

    /// Weights plus a working margin (KV cache, runtime, the rest of macOS) against unified memory.
    public static func fit(weightsBytes: Int64, memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Fit {
        let weights = Double(weightsBytes)
        let usable = Double(memoryBytes) * 0.75 // Metal's default working-set ceiling is about 75 %.
        let needed = weights * 1.15 + 1.5e9
        if needed <= usable * 0.7 { return .comfortable }
        if needed <= usable { return .tight }
        return .tooLarge
    }

    /// The files a runtime needs: for MLX everything but docs and images;
    /// for GGUF one chosen quantization file.
    public static func files(for detail: ModelDetail, format: Format, ggufFile: String? = nil) -> [FileEntry] {
        switch format {
        case .mlx:
            return detail.files.filter { file in
                let lower = file.path.lowercased()
                return !lower.hasSuffix(".md") && !lower.hasSuffix(".png") && !lower.hasSuffix(".jpg")
                    && !lower.hasSuffix(".gguf") && !lower.hasPrefix(".") && !lower.contains("/.")
            }
        case .gguf:
            let quantizations = ggufQuantizations(detail)
            if let ggufFile { return quantizations.first { $0.files.contains { $0.path == ggufFile } || $0.name == ggufFile }?.files ?? [] }
            return bestQuantization(quantizations)?.files ?? []
        }
    }

    /// One downloadable variant of a GGUF repository (a split model counts as one).
    public struct Quantization: Equatable, Sendable, Identifiable {
        public let name: String
        public let files: [FileEntry]
        public var id: String { name }
        public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    /// GGUF variants (vision projectors excluded), smallest first.
    public static func ggufQuantizations(_ detail: ModelDetail) -> [Quantization] {
        let ggufs = detail.files.filter { $0.path.lowercased().hasSuffix(".gguf") && !$0.path.lowercased().contains("mmproj") }
        let groups = Dictionary(grouping: ggufs) { file -> String in
            // "model-Q4_K_M-00001-of-00003.gguf" and its siblings form one variant.
            file.path.replacingOccurrences(of: #"-\d{5}-of-\d{5}\.gguf$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
        }
        return groups.map { name, files in
            Quantization(name: String(name.split(separator: "/").last ?? Substring(name)), files: files.sorted { $0.path < $1.path })
        }.sorted { $0.bytes < $1.bytes }
    }

    /// Q4_K_M when it fits this Mac, else the best common variant that fits, else the smallest.
    public static func bestQuantization(_ variants: [Quantization], memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Quantization? {
        let order = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "IQ4_XS", "Q4_0", "Q3_K_M", "Q6_K", "Q8_0"]
        for tag in order {
            if let match = variants.first(where: { $0.name.uppercased().contains(tag) }),
               fit(weightsBytes: match.bytes, memoryBytes: memoryBytes) != .tooLarge { return match }
        }
        return variants.first
    }

    // MARK: Locations

    public static var cacheRoot: URL {
        if let home = ProcessInfo.processInfo.environment["HF_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    public static var lmStudioRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/models", isDirectory: true)
    }

    /// Where AIM keeps the GGUF models its built-in engine runs.
    public static var aimModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AIMInstallationContext.legacyDirectoryName + "/Models", isDirectory: true)
    }

    /// A GGUF model downloaded for the built-in engine.
    public struct InstalledModel: Equatable, Sendable, Identifiable {
        public let repo: String
        public let file: URL
        public let bytes: Int64
        public var id: String { file.path }
        public var name: String { file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: #"-00001-of-\d{5}$"#, with: "", options: .regularExpression) }
    }

    /// Complete GGUF models in AIM's folder (the first part of a split model represents it).
    public static func installedGGUFModels(root: URL = aimModelsRoot) -> [InstalledModel] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        var result: [InstalledModel] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "gguf" {
            let name = url.lastPathComponent
            if name.lowercased().contains("mmproj") { continue }
            if name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) != nil, !name.contains("-00001-of-") { continue }
            let relative = url.deletingLastPathComponent().path.replacingOccurrences(of: root.path + "/", with: "")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            result.append(InstalledModel(repo: relative, file: url, bytes: size))
        }
        return result.sorted { $0.repo < $1.repo }
    }

    static func cacheFolder(_ repo: String, root: URL = cacheRoot) -> URL {
        root.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// Where a model's files go for a format.
    public static func destination(repo: String, sha: String, format: Format, cache: URL = cacheRoot, lmStudio: URL = lmStudioRoot) -> URL {
        switch format {
        case .mlx: cacheFolder(repo, root: cache).appendingPathComponent("snapshots/\(sha)", isDirectory: true)
        case .gguf: lmStudio.appendingPathComponent(repo, isDirectory: true)
        }
    }

    /// Where the built-in engine's GGUF files go.
    public static func ggufDestination(repo: String) -> URL { aimModelsRoot.appendingPathComponent(repo, isDirectory: true) }

    /// MLX models already in the Hugging Face cache (complete snapshots only).
    public static func installedMLXModels(cache: URL = cacheRoot) -> [(repo: String, bytes: Int64)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: cache.path) else { return [] }
        return entries.filter { $0.hasPrefix("models--") }.compactMap { folder in
            let base = cache.appendingPathComponent(folder)
            guard let sha = try? String(contentsOf: base.appendingPathComponent("refs/main"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  FileManager.default.fileExists(atPath: base.appendingPathComponent("snapshots/\(sha)/config.json").path),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("snapshots/\(sha)").path),
                  files.contains(where: { $0.hasSuffix(".safetensors") }) else { return nil }
            let repo = folder.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            return (repo, directorySize(base.appendingPathComponent("blobs")) + directorySize(base.appendingPathComponent("snapshots/\(sha)")))
        }.sorted { $0.repo < $1.repo }
    }

    /// The complete snapshot folder of a downloaded MLX model (what the MLX engine loads).
    public static func mlxSnapshotFolder(_ repo: String, cache: URL = cacheRoot) -> URL? {
        let base = cacheFolder(repo, root: cache)
        guard let sha = try? String(contentsOf: base.appendingPathComponent("refs/main"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let folder = base.appendingPathComponent("snapshots/\(sha)", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) ? folder : nil
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink != true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Download

    public struct Progress: Sendable, Equatable {
        public let completedBytes: Int64
        public let totalBytes: Int64
        public let file: String
    }

    /// Downloads the files (resuming `.part` files), then marks an MLX snapshot complete
    /// with `refs/main`. Cancelling the task stops it; a later call resumes.
    public static func download(_ detail: ModelDetail, files: [FileEntry], format: Format,
                                cache: URL = cacheRoot, lmStudio: URL = aimModelsRoot,
                                session: URLSession = RuntimeManagedNetworkSession.make(configuration: .default),
                                progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        guard !files.isEmpty else { throw HubError.noFiles }
        if detail.gated { throw HubError.gated }
        let folder = destination(repo: detail.id, sha: detail.sha, format: format, cache: cache, lmStudio: lmStudio)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = files.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = folder.appendingPathComponent(file.path)
            if let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int64,
               file.size > 0, size == file.size {
                done += size
                progress(Progress(completedBytes: done, totalBytes: total, file: file.path))
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let part = target.appendingPathExtension("part")
            let offset = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64 ?? 0
            // A part file that already holds every byte (e.g. AIM quit before renaming it) needs no request.
            if file.size > 0, offset == file.size {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: part, to: target)
                done += offset
                progress(Progress(completedBytes: done, totalBytes: total, file: file.path))
                continue
            }
            if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
            let encodedPath = file.path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            var request = URLRequest(url: api.appendingPathComponent("\(detail.id)/resolve/\(detail.sha)/").appendingPathComponent(encodedPath, isDirectory: false),
                                     timeoutInterval: 120)
            request.setValue("AIM-AI", forHTTPHeaderField: "User-Agent")
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let fileDone = done
            let written = try await ChunkedFileDownload(request: request, part: part, offset: offset,
                configuration: session.configuration) { bytesOnDisk in
                progress(Progress(completedBytes: fileDone + bytesOnDisk, totalBytes: total, file: file.path))
            }.run()
            if file.size > 0, written != file.size { throw HubError.incomplete(file.path) }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: part, to: target)
            done += written
            progress(Progress(completedBytes: done, totalBytes: total, file: file.path))
        }
        if format == .mlx {
            let refs = cacheFolder(detail.id, root: cache).appendingPathComponent("refs", isDirectory: true)
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            try Data(detail.sha.utf8).write(to: refs.appendingPathComponent("main"))
        }
        return folder
    }

    // MARK: Helpers

    public static func isValidRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 96 && part != "." && part != ".." &&
                part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.count <= 512 &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func get(_ url: URL, fetch: Fetch) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("AIM-AI", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw HubError.invalidResponse }
        if status == 401 || status == 403 { throw HubError.gated }
        guard status == 200 else { throw HubError.http(status) }
        return data
    }

    public enum HubError: LocalizedError, Equatable {
        case invalidResponse, invalidRepo, noFiles, gated, http(Int), incomplete(String)
        public var errorDescription: String? {
            switch self {
            case .invalidResponse: "Hugging Face returned an unexpected answer."
            case .invalidRepo: "That is not a Hugging Face model ID (owner/name)."
            case .noFiles: "No downloadable model files were found for that format."
            case .gated: "This model requires accepting its license on huggingface.co with your account; AIM downloads only open models."
            case .http(let status): "Hugging Face answered HTTP \(status)."
            case .incomplete(let file): "The download of \(file) was incomplete; try again to resume it."
            }
        }
    }
}

/// Streams one HTTP response into a `.part` file (appending after a 206), with
/// throttled progress; cancellation of the calling task cancels the transfer.
final class ChunkedFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let part: URL
    private let configuration: URLSessionConfiguration
    private let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<Int64, Error>?
    private var failure: Error?
    private var task: URLSessionDataTask?

    init(request: URLRequest, part: URL, offset: Int64, configuration: URLSessionConfiguration,
         report: @escaping @Sendable (Int64) -> Void) {
        self.request = request
        self.part = part
        self.written = offset
        self.configuration = configuration
        self.report = report
    }

    func run() async throws -> Int64 {
        let session = RuntimeManagedNetworkSession.make(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                let task = session.dataTask(with: request)
                lock.withLock { self.task = task }
                task.resume()
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(HuggingFaceModelHub.HubError.invalidResponse); completionHandler(.cancel); return
        }
        if http.statusCode == 401 || http.statusCode == 403 { fail(HuggingFaceModelHub.HubError.gated); completionHandler(.cancel); return }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            fail(HuggingFaceModelHub.HubError.http(http.statusCode)); completionHandler(.cancel); return
        }
        do {
            let handle = try FileHandle(forWritingTo: part)
            if http.statusCode == 200 { try handle.truncate(atOffset: 0); lock.withLock { written = 0 } } else { try handle.seekToEnd() }
            lock.withLock { self.handle = handle }
            completionHandler(.allow)
        } catch {
            fail(error); completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try lock.withLock { try handle?.write(contentsOf: data) }
        } catch {
            fail(error); dataTask.cancel(); return
        }
        let (total, due) = lock.withLock { () -> (Int64, Bool) in
            written += Int64(data.count)
            let due = Date.now.timeIntervalSince(lastReport) > 0.25
            if due { lastReport = .now }
            return (written, due)
        }
        if due { report(total) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure, total) = lock.withLock { () -> (CheckedContinuation<Int64, Error>?, Error?, Int64) in
            try? handle?.close()
            handle = nil
            defer { self.continuation = nil }
            return (self.continuation, self.failure, written)
        }
        if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error) }
        else { report(total); continuation?.resume(returning: total) }
    }

    private func fail(_ error: Error) { lock.withLock { if failure == nil { failure = error } } }
}
