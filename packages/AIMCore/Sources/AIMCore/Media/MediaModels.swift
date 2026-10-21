import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable { case image, video }
public enum MediaRoute: String, Codable, Sendable, CaseIterable, Identifiable {
    case openRouter, blackForestLabs
    public var id: String { rawValue }
    public var title: String { self == .openRouter ? "OpenRouter" : "Black Forest Labs" }
}

/// Discovery facts belong to the selected billing route, never a substitute provider.
public struct MediaModel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: MediaKind
    public var route: MediaRoute
    public var description: String?
    public var aspectRatios: [String]
    public var resolutions: [String]
    public var durations: [Int]
    public var acceptsReferences: Bool
    public var supportsAudio: Bool
    public var priceUSD: Double?
    public var priceUnit: String?
    public var fixedPrice: Bool?
    public var bflEndpoint: String?
    public var key: String { "\(route.rawValue)|\(kind.rawValue)|\(id)" }
    public init(id: String, name: String, kind: MediaKind, route: MediaRoute, description: String? = nil,
                aspectRatios: [String] = [], resolutions: [String] = [], durations: [Int] = [],
                acceptsReferences: Bool = false, supportsAudio: Bool = false, priceUSD: Double? = nil,
                priceUnit: String? = nil, fixedPrice: Bool? = nil, bflEndpoint: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.route = route; self.description = description
        self.aspectRatios = aspectRatios; self.resolutions = resolutions; self.durations = durations
        self.acceptsReferences = acceptsReferences; self.supportsAudio = supportsAudio
        self.priceUSD = priceUSD; self.priceUnit = priceUnit; self.fixedPrice = fixedPrice; self.bflEndpoint = bflEndpoint
    }
    /// Only the image endpoints documented by BFL are enabled here. No invented FLUX.3 API.
    public static let blackForestLabs: [Self] = ["flux-2-pro-preview", "flux-2-pro", "flux-2-max", "flux-2-flex", "flux-2-klein-4b", "flux-2-klein-9b"].map {
        Self(id: "black-forest-labs/" + $0, name: $0.replacingOccurrences(of: "flux-", with: "FLUX.").replacingOccurrences(of: "-", with: " "),
             kind: .image, route: .blackForestLabs, aspectRatios: ["1:1", "16:9", "9:16", "4:3", "3:4"], bflEndpoint: $0)
    }
    public static func from(_ model: ChatModel, kind: MediaKind? = nil) -> Self? {
        let outputs = model.architecture?.outputModalities ?? []
        guard let selected = kind ?? (outputs.contains("video") ? .video : outputs.contains("image") ? .image : nil), outputs.contains(selected.rawValue) else { return nil }
        return .init(id: model.id, name: model.name, kind: selected, route: .openRouter)
    }
}

public struct MediaReference: Codable, Equatable, Sendable {
    public let name: String
    public let mimeType: String
    public let data: Data
    public var dataURL: String { "data:\(mimeType);base64," + data.base64EncodedString() }
    public init(name: String, mimeType: String, data: Data) throws {
        guard data.count <= 6 * 1_024 * 1_024, try MediaTransport.mimeType(data.prefix(32), kind: .image) == mimeType else { throw MediaGenerationError.invalidResponse }
        self.name = name; self.mimeType = mimeType; self.data = data
    }
}

public struct MediaOptions: Codable, Equatable, Sendable {
    public var aspectRatio: String?
    public var resolution: String?
    public var durationSeconds: Int?
    public var generateAudio: Bool?
    public var references: [MediaReference]
    public init(aspectRatio: String? = nil, resolution: String? = nil, durationSeconds: Int? = nil,
                generateAudio: Bool? = nil, references: [MediaReference] = []) {
        self.aspectRatio = aspectRatio; self.resolution = resolution; self.durationSeconds = durationSeconds
        self.generateAudio = generateAudio; self.references = references
    }
}

public struct MediaJob: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case submitting, awaiting, downloading, completed, failed, uncertain, paused }
    public var id: UUID
    public var accountID: UUID
    public var conversationID: UUID?
    public var model: MediaModel
    public var prompt: String
    public var options: MediaOptions
    public var status: Status
    public var providerJobID: String?
    public var pollingURL: URL?
    public var resultURL: URL?
    public var assetID: UUID?
    public var costUSD: Double?
    public var costConfirmed: Bool
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var canResume: Bool { status != .completed && status != .failed && (pollingURL != nil || resultURL != nil) }
    public init(id: UUID = UUID(), accountID: UUID, conversationID: UUID?, model: MediaModel, prompt: String, options: MediaOptions = .init()) {
        self.id = id; self.accountID = accountID; self.conversationID = conversationID; self.model = model
        self.prompt = prompt; self.options = options; status = .submitting; costConfirmed = false
        createdAt = .now; updatedAt = .now
    }
    /// A crash after intent was persisted must never issue another paid POST automatically.
    public mutating func recoverAfterInterruption() {
        if status == .submitting { status = .uncertain; error = "Submission was interrupted. Check the provider dashboard before starting another creation." }
        else if [.awaiting, .downloading].contains(status) { status = .paused }
    }
}

public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var conversationID: UUID?
    public var jobID: UUID
    public var kind: MediaKind
    public var provider: MediaRoute
    public var modelID: String
    public var title: String
    public var mimeType: String
    public var byteCount: Int
    public var sha256: String
    public var createdAt: Date
    public var deletedAt: Date?
    public var valid: Bool {
        id == jobID && byteCount > 0 && byteCount <= (kind == .image ? 64 : 512) * 1_024 * 1_024
            && sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && (kind == .video ? mimeType == "video/mp4" : ["image/png", "image/jpeg", "image/webp"].contains(mimeType))
    }
    public var objectPath: String { "\(accountID.uuidString.lowercased())/\(id.uuidString.lowercased())/result" }
    public init(id: UUID, accountID: UUID, conversationID: UUID?, jobID: UUID, kind: MediaKind, provider: MediaRoute,
                modelID: String, title: String, mimeType: String, byteCount: Int, sha256: String, createdAt: Date = .now, deletedAt: Date? = nil) {
        self.id = id; self.accountID = accountID; self.conversationID = conversationID; self.jobID = jobID
        self.kind = kind; self.provider = provider; self.modelID = modelID; self.title = title; self.mimeType = mimeType
        self.byteCount = byteCount; self.sha256 = sha256; self.createdAt = createdAt; self.deletedAt = deletedAt
    }
    private enum CodingKeys: String, CodingKey { case id, accountID, conversationID, jobID, kind, provider, modelID, title, mimeType, byteCount, sha256, createdAt, deletedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); accountID = try c.decode(UUID.self, forKey: .accountID)
        conversationID = try c.decodeIfPresent(UUID.self, forKey: .conversationID); jobID = try c.decode(UUID.self, forKey: .jobID)
        kind = try c.decode(MediaKind.self, forKey: .kind); provider = try c.decode(MediaRoute.self, forKey: .provider)
        modelID = try c.decode(String.self, forKey: .modelID); title = try c.decode(String.self, forKey: .title)
        mimeType = try c.decode(String.self, forKey: .mimeType); byteCount = try c.decode(Int.self, forKey: .byteCount); sha256 = try c.decode(String.self, forKey: .sha256)
        func date(_ key: CodingKeys) throws -> Date? {
            if try c.decodeNil(forKey: key) { return nil }
            if let seconds = try? c.decode(Double.self, forKey: key) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let value = try c.decode(String.self, forKey: key)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: value) { return date }; f.formatOptions = [.withInternetDateTime]
            guard let date = f.date(from: value) else { throw MediaGenerationError.invalidResponse }; return date
        }
        createdAt = try date(.createdAt) ?? .distantPast
        deletedAt = c.contains(.deletedAt) ? try date(.deletedAt) : nil
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(accountID, forKey: .accountID); try c.encodeIfPresent(conversationID, forKey: .conversationID)
        try c.encode(jobID, forKey: .jobID); try c.encode(kind, forKey: .kind); try c.encode(provider, forKey: .provider)
        try c.encode(modelID, forKey: .modelID); try c.encode(title, forKey: .title); try c.encode(mimeType, forKey: .mimeType)
        try c.encode(byteCount, forKey: .byteCount); try c.encode(sha256, forKey: .sha256)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try c.encode(f.string(from: createdAt), forKey: .createdAt)
        if let deletedAt { try c.encode(f.string(from: deletedAt), forKey: .deletedAt) }
    }
    /// Server tombstones dominate stale copies regardless of their device clocks.
    public static func merge(_ rows: [Self], accountID: UUID) -> [Self] {
        var result: [UUID: Self] = [:]
        for row in rows where row.accountID == accountID && row.valid {
            if let old = result[row.id], old.deletedAt != nil { continue }
            result[row.id] = row
        }
        return result.values.sorted { $0.createdAt > $1.createdAt }
    }
}

public enum MediaGenerationError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String), missingKey, rejected(Int), invalidResponse, unsafeURL, unknownSubmission, strictBudgetUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let text): text
        case .missingKey: "Connect the selected provider in Settings → Providers."
        case .rejected(let code): "The provider refused this creation (HTTP \(code)). Check its account, credits and model access."
        case .invalidResponse: "The provider returned an unreadable media result."
        case .unsafeURL: "The provider returned an unexpected download or polling address."
        case .unknownSubmission: "The submission result is unknown. No automatic retry will be sent; check the provider dashboard."
        case .strictBudgetUnavailable: "This creation cannot be admitted within the strict device budget. Choose a supported priced configuration or change the budget explicitly."
        }
    }
}
