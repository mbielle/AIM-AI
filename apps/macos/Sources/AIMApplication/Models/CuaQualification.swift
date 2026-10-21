import Foundation

/// Background-input capabilities of the embedded CUA driver. Each one is
/// offered to a model only after field qualification on AIM's fixture.
public enum CuaCapability: String, Codable, CaseIterable, Sendable {
    case observe
    case axClick = "ax_click"
    case pixelClick = "pixel_click"
    case typeText = "type_text"
    case setValue = "set_value"
    case scroll
    case pressKey = "press_key"
}

/// What a qualification is valid for. A different driver binary, macOS build
/// or AIM adapter contract invalidates every recorded capability.
public struct CuaQualificationKey: Codable, Equatable, Hashable, Sendable {
    public let driverVersion: String
    public let driverSHA256: String
    public let osBuild: String
    public let adapterContract: String

    public init(driverVersion: String, driverSHA256: String, osBuild: String, adapterContract: String) {
        self.driverVersion = driverVersion
        self.driverSHA256 = driverSHA256
        self.osBuild = osBuild
        self.adapterContract = adapterContract
    }
}

public struct CuaQualificationRecord: Codable, Equatable, Sendable {
    public let key: CuaQualificationKey
    public let capability: CuaCapability
    /// Digest of the live tool schemas used during qualification; a session
    /// whose driver reports different schemas must not use the capability.
    public let schemaDigest: String
    public let qualifiedAt: Date
    public let evidence: String

    public init(key: CuaQualificationKey, capability: CuaCapability, schemaDigest: String,
                qualifiedAt: Date, evidence: String) {
        self.key = key
        self.capability = capability
        self.schemaDigest = schemaDigest
        self.qualifiedAt = qualifiedAt
        self.evidence = evidence
    }
}

public protocol CuaQualificationRepository: Sendable {
    func record(_ record: CuaQualificationRecord) async throws
    /// Capabilities qualified for this exact key and not later disqualified.
    func qualified(for key: CuaQualificationKey) async throws -> [CuaCapability: String]
    func disqualify(_ capability: CuaCapability, for key: CuaQualificationKey, reason: String) async throws
}

/// CUA qualifications shipped inside the signed app bundle, recorded on the
/// machines where the fixture ladder passed. On launch AIM adopts the entry
/// matching this Mac's driver and adapter contract as local records (never
/// over a local record, so a local disqualification stays final): an exact
/// macOS build is qualified; another build of the same major macOS version is
/// provisional, guarded by the runtime disqualification of foreground or
/// silent deliveries; anything else is not offered.
public struct CuaReleaseManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let key: CuaQualificationKey
        /// Capability raw value → schema digest it was qualified with.
        public let capabilities: [String: String]
        public let qualifiedAt: Date

        public init(key: CuaQualificationKey, capabilities: [String: String], qualifiedAt: Date) {
            self.key = key; self.capabilities = capabilities; self.qualifiedAt = qualifiedAt
        }
    }

    public var version = 1
    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public static func decode(_ data: Data) throws -> CuaReleaseManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CuaReleaseManifest.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Replaces any entry for the same key and keeps the rest (manifests accumulate across Macs and builds).
    public func merging(_ entry: Entry) -> CuaReleaseManifest {
        CuaReleaseManifest(entries: entries.filter { $0.key != entry.key } + [entry])
    }

    public enum Match: Equatable, Sendable { case exact, sameMajorVersion }

    /// "aim-cua-adapter-2026-10-02:host=…" → "aim-cua-adapter-2026-10-02".
    public static func baseContract(_ contract: String) -> String {
        String(contract.prefix { $0 != ":" })
    }

    /// "26A428" → "26".
    public static func majorVersion(ofBuild build: String) -> String {
        String(build.prefix { $0.isNumber })
    }

    public func match(for key: CuaQualificationKey) -> (Entry, Match)? {
        // The release qualifies the driver binary and adapter contract; the app, a Test bundle
        // (":app=") and the permanent host (":host=") all run that same pair.
        let compatible = entries.filter {
            $0.key.driverVersion == key.driverVersion && $0.key.driverSHA256 == key.driverSHA256 &&
                Self.baseContract($0.key.adapterContract) == Self.baseContract(key.adapterContract)
        }
        if let exact = compatible.first(where: { $0.key.osBuild == key.osBuild }) { return (exact, .exact) }
        let major = Self.majorVersion(ofBuild: key.osBuild)
        guard !major.isEmpty else { return nil }
        return compatible.filter { Self.majorVersion(ofBuild: $0.key.osBuild) == major }
            .max { $0.qualifiedAt < $1.qualifiedAt }.map { ($0, .sameMajorVersion) }
    }

    /// Records to adopt for this Mac's key.
    public func adoptionRecords(for key: CuaQualificationKey, now: Date = .now) -> [CuaQualificationRecord] {
        guard let (entry, match) = match(for: key) else { return [] }
        let origin = match == .exact
            ? "Release manifest: qualified on macOS \(entry.key.osBuild)."
            : "Release manifest: qualified on macOS \(entry.key.osBuild); provisional on \(key.osBuild) until a foreground or silent delivery disqualifies it."
        return entry.capabilities.compactMap { raw, schema in
            CuaCapability(rawValue: raw).map {
                CuaQualificationRecord(key: key, capability: $0, schemaDigest: schema, qualifiedAt: now, evidence: origin)
            }
        }.sorted { $0.capability.rawValue < $1.capability.rawValue }
    }
}
