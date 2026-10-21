import AIMCore
import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit

/// One immutable account owner. Navigation only observes this store; it never submits.
@MainActor @Observable final class AIMMediaStore {
    let accountID: UUID
    var models: [MediaModel] = []
    var jobs: [MediaJob] = []
    var assets: [MediaAsset] = []
    var errorMessage: String?
    var syncMessage: String?
    var isLoadingCatalog = false
    private let directory: URL
    private let sync: AccountMediaService?
    private let transport: MediaTransport
    private let key: @MainActor (MediaRoute) throws -> String?
    private let budgetEnabled: @MainActor () -> Bool
    private let admission: (@MainActor (MediaJob) throws -> Void)?
    private let completion: @MainActor (MediaJob, MediaAsset) -> Void
    private let activity: @MainActor (MediaJob) -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var readable = true
    private var catalogDate: Date?
    private var syncing = false
    private var syncAgain = false
    private struct Archive: Codable {
        var jobs: [MediaJob]; var assets: [MediaAsset]; var models: [MediaModel]; var catalogDate: Date?
    }
    init(accountID: UUID, sync: AccountMediaService? = nil, directory: URL? = nil, transport: MediaTransport = .init(),
         key: @escaping @MainActor (MediaRoute) throws -> String?,
         budgetEnabled: @escaping @MainActor () -> Bool = { UserDefaults.standard.bool(forKey: "aim.budget.enabled") },
         admission: (@MainActor (MediaJob) throws -> Void)? = nil,
         completion: @escaping @MainActor (MediaJob, MediaAsset) -> Void = { _, _ in },
         activity: @escaping @MainActor (MediaJob) -> Void = { _ in }) {
        self.accountID = accountID; self.sync = sync; self.transport = transport; self.key = key
        self.budgetEnabled = budgetEnabled; self.admission = admission; self.completion = completion; self.activity = activity
        self.directory = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIMMedia", isDirectory: true)).appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let url = self.directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
                jobs = archive.jobs.filter { $0.accountID == accountID }; assets = MediaAsset.merge(archive.assets, accountID: accountID)
                models = archive.models; catalogDate = archive.catalogDate
                for index in jobs.indices { jobs[index].recoverAfterInterruption() }
            }
        } catch { readable = false; errorMessage = "Saved creations could not be read. Their files have been preserved; recover them before creating new media." }
    }
    var visibleAssets: [MediaAsset] { assets.filter { $0.deletedAt == nil } }
    func hasKey(_ route: MediaRoute) -> Bool { ((try? key(route)) ?? nil)?.isEmpty == false }
    func localURL(asset: MediaAsset) -> URL? {
        guard asset.accountID == accountID, asset.deletedAt == nil else { return nil }
        let url = directory.appendingPathComponent(asset.id.uuidString.lowercased())
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// Safe even while the same conversation is open elsewhere. This never performs POST generation.
    func refreshCatalog(force: Bool = false) async {
        guard !isLoadingCatalog, force || catalogDate == nil || Date.now.timeIntervalSince(catalogDate!) > 3_600 else { return }
        isLoadingCatalog = true; defer { isLoadingCatalog = false }
        do {
            async let images = transport.data(URLRequest(url: URL(string: "https://openrouter.ai/api/v1/images/models")!))
            async let videos = transport.data(URLRequest(url: URL(string: "https://openrouter.ai/api/v1/videos/models")!))
            let (imageData, videoData) = try await (images, videos)
            models = try MediaTransport.catalog(imageData, kind: .image) + MediaTransport.catalog(videoData, kind: .video)
            models += MediaModel.blackForestLabs; catalogDate = .now; try persist()
        } catch { errorMessage = "The media catalog could not refresh. Saved models remain available." }
    }
    func availableModel(id: String, route: MediaRoute, kind: MediaKind) -> MediaModel? {
        (models + MediaModel.blackForestLabs).first { $0.id == id && $0.route == route && $0.kind == kind }
    }
    func prepare(model: MediaModel) async {
        guard model.route == .openRouter, model.kind == .image,
              let encoded = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !model.id.contains("..") else { return }
        do {
            let request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/images/models/" + encoded + "/endpoints")!)
            let detail = try MediaTransport.imageDetails(try await transport.data(request), model: availableModel(id: model.id, route: model.route, kind: model.kind) ?? model)
            if let index = models.firstIndex(where: { $0.key == detail.key }) { models[index] = detail } else { models.append(detail) }
            try persist()
        } catch { /* Discovery facts remain unknown; do not invent a price or block unbudgeted generation. */ }
    }
    /// Explicit user action only. Intent is on disk BEFORE the first potentially billable byte.
    @discardableResult func create(model: MediaModel, prompt: String, options: MediaOptions = .init(), conversationID: UUID?) -> UUID? {
        guard readable else { return nil }
        if let existing = jobs.first(where: { [.submitting, .awaiting, .downloading].contains($0.status)
            && $0.conversationID == conversationID && $0.model.key == model.key && $0.prompt == prompt && $0.options == options }) { return existing.id }
        var job = MediaJob(accountID: accountID, conversationID: conversationID, model: model, prompt: prompt, options: options)
        var admitted = false
        do {
            guard let credential = try key(model.route) else { throw MediaGenerationError.missingKey }
            _ = try MediaTransport.submission(job, key: credential)
            if budgetEnabled() { guard let admission else { throw MediaGenerationError.strictBudgetUnavailable }; try admission(job); admitted = true }
            jobs.append(job); try persist(); activity(job)
            tasks[job.id] = Task { [weak self] in await self?.submit(job.id) }
            return job.id
        } catch {
            job.status = .failed; job.error = error.localizedDescription; errorMessage = job.error
            // No generation request has started. A failed intent write must not leave a strict reservation behind.
            jobs.removeAll { $0.id == job.id }
            if admitted { job.costUSD = 0; job.costConfirmed = true; activity(job) }
            return nil
        }
    }
    func resume(jobID: UUID) {
        guard tasks[jobID] == nil, let job = jobs.first(where: { $0.id == jobID }), job.canResume else { return }
        tasks[jobID] = Task { [weak self] in await self?.follow(jobID) }
    }
    /// Stops local observation, never claims that the provider cancelled or refunded a job.
    func cancelTracking(jobID: UUID) {
        tasks[jobID]?.cancel()
        mutate(jobID) { $0.status = $0.pollingURL == nil && $0.resultURL == nil ? .uncertain : .paused; $0.error = "Tracking stopped on this iPhone. The provider may still complete and bill the creation." }
    }
    func suspend() { for id in Array(tasks.keys) { cancelTracking(jobID: id) } }
    private func submit(_ id: UUID) async {
        defer { tasks.removeValue(forKey: id) }
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        do {
            guard let credential = try key(job.model.route) else { throw MediaGenerationError.missingKey }
            try Task.checkCancellation()
            let data = try await transport.data(MediaTransport.submission(job, key: credential))
            try Task.checkCancellation()
            try await receive(MediaTransport.decode(data, job: job), id: id)
            if jobs.first(where: { $0.id == id })?.canResume == true { await follow(id) }
        } catch {
            guard !Task.isCancelled else { return }
            // A definite HTTP rejection is not an uncertain successful generation.
            if case MediaGenerationError.rejected(let status) = error, [400, 401, 402, 403, 404, 422, 429].contains(status) {
                mutate(id) { $0.costUSD = 0; $0.costConfirmed = true }; fail(id, error: error)
            }
            else { mutate(id) { $0.status = .uncertain; $0.error = MediaGenerationError.unknownSubmission.localizedDescription }; activityIfPresent(id) }
        }
    }
    private func follow(_ id: UUID) async {
        defer { tasks.removeValue(forKey: id) }
        do {
            var refreshedExpiredResult = false
            while let job = jobs.first(where: { $0.id == id }), job.canResume {
                try Task.checkCancellation()
                guard let credential = try key(job.model.route) else { throw MediaGenerationError.missingKey }
                if let url = job.resultURL {
                    do {
                        let file = try await transport.download(MediaTransport.authorized(url, route: job.model.route, key: credential, download: true), kind: job.model.kind)
                        defer { try? FileManager.default.removeItem(at: file) }
                        try Task.checkCancellation(); try finish(id, file: file); return
                    } catch MediaGenerationError.rejected(let status) where [401, 403].contains(status) && job.model.route == .blackForestLabs && job.pollingURL != nil && !refreshedExpiredResult {
                        // BFL delivery URLs expire after ten minutes. Re-read the SAME job, never submit again.
                        refreshedExpiredResult = true; mutate(id) { $0.resultURL = nil }; continue
                    }
                }
                guard let url = job.pollingURL else { return }
                mutate(id) { $0.status = .awaiting; $0.error = nil }
                let result = try await transport.data(MediaTransport.authorized(url, route: job.model.route, key: credential))
                try Task.checkCancellation(); try await receive(MediaTransport.decode(result, job: job), id: id)
                if jobs.first(where: { $0.id == id })?.status == .completed { return }
                if jobs.first(where: { $0.id == id })?.resultURL != nil { continue }
                try await Task.sleep(for: job.model.kind == .video ? .seconds(30) : .seconds(2))
            }
        } catch {
            guard !Task.isCancelled else { return }
            if case MediaGenerationError.rejected(let status) = error, [404, 410].contains(status) {
                mutate(id) { $0.status = .failed; $0.error = "The provider no longer exposes this job or result. Check its dashboard; AIM will not launch another creation automatically." }
                activityIfPresent(id)
            } else {
                let message = (error as? MediaGenerationError)?.localizedDescription ?? "Tracking was interrupted. Resume retrieves the existing job and does not launch another creation."
                mutate(id) { $0.status = .paused; $0.error = message }
            }
        }
    }
    private func receive(_ result: MediaTransport.Result, id: UUID) async throws {
        switch result {
        case .pending(let providerID, let url):
            mutate(id) { $0.providerJobID = providerID; $0.pollingURL = url; $0.status = .awaiting }
            // Persisting the provider identifier is mandatory before further polling.
            try persist()
        case .failed(let text): fail(id, error: MediaGenerationError.invalidRequest(text))
        case .ready(let url, let bytes, let cost):
            mutate(id) { $0.resultURL = url; $0.costUSD = cost; $0.costConfirmed = cost != nil; $0.status = .downloading }
            try persist()
            if let bytes {
                guard bytes.count <= (jobs.first(where: { $0.id == id })?.model.kind == .video ? 512 : 64) * 1_024 * 1_024 else { throw MediaGenerationError.invalidResponse }
                let file = directory.appendingPathComponent(UUID().uuidString + ".partial")
                try bytes.write(to: file, options: [.atomic, .completeFileProtection]); defer { try? FileManager.default.removeItem(at: file) }
                try finish(id, file: file)
            }
        }
    }
    private func finish(_ id: UUID, file: URL) throws {
        guard var job = jobs.first(where: { $0.id == id }), job.accountID == accountID else { return }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 32) ?? Data()
        let mime = try MediaTransport.mimeType(prefix, kind: job.model.kind)
        if job.model.kind == .image {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, Double(width) * Double(height) <= 256_000_000 else { throw MediaGenerationError.invalidResponse }
        }
        try handle.seek(toOffset: 0); var digest = SHA256(); var count = 0
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty { digest.update(data: chunk); count += chunk.count }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let asset = MediaAsset(id: job.assetID ?? job.id, accountID: accountID, conversationID: job.conversationID, jobID: job.id,
            kind: job.model.kind, provider: job.model.route, modelID: job.model.id, title: job.prompt,
            mimeType: mime, byteCount: count, sha256: hash)
        let destination = directory.appendingPathComponent(asset.id.uuidString.lowercased())
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: file, to: destination) }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        assets = MediaAsset.merge(assets + [asset], accountID: accountID)
        job.status = .completed; job.assetID = asset.id; job.options.references = []; job.updatedAt = .now
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index] = job }
        try persist(); activity(job); completion(job, asset)
        Task { await synchronize() }
    }
    private func mutate(_ id: UUID, _ edit: (inout MediaJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[index]); jobs[index].updatedAt = .now
        do { try persist() } catch { errorMessage = "Creation tracking could not be saved. No new request will be launched automatically." }
    }
    private func fail(_ id: UUID, error: Error) { mutate(id) { $0.status = .failed; $0.error = error.localizedDescription }; activityIfPresent(id) }
    private func activityIfPresent(_ id: UUID) { if let job = jobs.first(where: { $0.id == id }) { activity(job) } }
    private func persist() throws {
        guard readable else { throw MediaGenerationError.invalidResponse }
        let archive = Archive(jobs: jobs, assets: assets, models: models, catalogDate: catalogDate)
        try JSONEncoder().encode(archive).write(to: directory.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
    }
    func delete(assetID: UUID) async {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        assets[index].deletedAt = assets[index].deletedAt ?? .now
        do { try persist() } catch { errorMessage = "Deletion could not be saved."; return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(assetID.uuidString.lowercased()))
        await synchronize()
    }
    func synchronize() async {
        guard let sync, readable else { return }
        if syncing { syncAgain = true; return }; syncing = true
        defer { syncing = false; if syncAgain { syncAgain = false; Task { await synchronize() } } }
        do {
            let remote = try await sync.assets(accountID: accountID)
            assets = MediaAsset.merge(assets + remote, accountID: accountID); try persist()
            for asset in assets {
                if asset.deletedAt != nil {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(asset.id.uuidString.lowercased()))
                    try await sync.delete(asset)
                } else if let url = localURL(asset: asset), !remote.contains(where: { $0.id == asset.id }) {
                    try await sync.upload(asset, file: url)
                } else if localURL(asset: asset) == nil {
                    let file = try await sync.downloadFile(asset)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                    var digest = SHA256(); var count = 0
                    while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty { digest.update(data: chunk); count += chunk.count }
                    guard count == asset.byteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw MediaGenerationError.invalidResponse }
                    let destination = directory.appendingPathComponent(asset.id.uuidString.lowercased())
                    try FileManager.default.copyItem(at: file, to: destination)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                }
            }
            syncMessage = "Creations synchronized"
        } catch { syncMessage = "Creations are saved on this iPhone. Account media sync is unavailable; retry after the media migration is configured." }
    }
}
