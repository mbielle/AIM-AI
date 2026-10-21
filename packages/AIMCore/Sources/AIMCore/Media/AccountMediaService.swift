import Foundation
import Supabase

/// Uses the existing authenticated client; no service role, provider key or public bucket.
public actor AccountMediaService {
    public static let bucket = "account-media"
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }
    private func requireOwner(_ accountID: UUID) async throws {
        try AIMNetworkPrivacyPolicy.requireNetwork()
        guard try await client.auth.session.user.id == accountID else { throw AccountServiceError.unavailable }
    }
    public func assets(accountID: UUID) async throws -> [MediaAsset] {
        try await requireOwner(accountID)
        var result: [MediaAsset] = [], offset = 0
        while true {
            let page: [Row] = try await client.from("account_media_assets").select("payload")
                .eq("account_id", value: accountID.uuidString).order("id").range(from: offset, to: offset + 199).execute().value
            result.append(contentsOf: page.map(\.payload)); offset += page.count
            if page.count < 200 { break }
        }
        try await requireOwner(accountID)
        return MediaAsset.merge(result, accountID: accountID)
    }
    public func upload(_ asset: MediaAsset, file: URL) async throws {
        guard asset.valid else { throw MediaGenerationError.invalidResponse }
        try await requireOwner(asset.accountID)
        guard asset.deletedAt == nil else { return }
        // Unique immutable object path; only retrying this same asset may replace its bytes.
        _ = try await client.storage.from(Self.bucket).upload(asset.objectPath, fileURL: file,
                    options: .init(contentType: asset.mimeType, upsert: true))
        try await requireOwner(asset.accountID)
        try await save(asset)
    }
    public func save(_ asset: MediaAsset) async throws {
        guard asset.valid else { throw MediaGenerationError.invalidResponse }
        try await requireOwner(asset.accountID)
        try await client.rpc("aim_put_media_asset", params: Write(p_account_id: asset.accountID, p_asset: asset)).execute()
    }
    /// Disk-backed download avoids materializing a complete video in iPhone RAM.
    public func downloadFile(_ asset: MediaAsset) async throws -> URL {
        guard asset.valid else { throw MediaGenerationError.invalidResponse }
        try await requireOwner(asset.accountID)
        guard asset.deletedAt == nil else { throw AccountServiceError.unavailable }
        let signed = try await client.storage.from(Self.bucket).createSignedURL(path: asset.objectPath, expiresIn: 60)
        guard signed.scheme == "https", signed.user == nil, signed.password == nil else { throw MediaGenerationError.unsafeURL }
        let file = try await MediaTransport().download(URLRequest(url: signed), kind: asset.kind)
        do { try await requireOwner(asset.accountID); return file }
        catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    /// Persist tombstone first; retrying file cleanup can never resurrect the asset.
    public func delete(_ asset: MediaAsset) async throws {
        var deleted = asset; deleted.deletedAt = asset.deletedAt ?? .now
        try await save(deleted)
        _ = try await client.storage.from(Self.bucket).remove(paths: [asset.objectPath])
    }
    private struct Row: Decodable { let payload: MediaAsset }
    private struct Write: Encodable { let p_account_id: UUID; let p_asset: MediaAsset }
}
