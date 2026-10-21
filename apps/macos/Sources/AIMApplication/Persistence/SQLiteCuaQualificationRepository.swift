import CryptoKit
import Foundation
import GRDB

private struct CuaQualificationRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cuaQualifications"
    var id: String
    var keyDigest: String
    var driverVersion: String
    var driverSHA256: String
    var osBuild: String
    var adapterContract: String
    var capability: String
    var schemaDigest: String
    var qualifiedAt: Date
    var evidence: String
    var disqualifiedAt: Date?
    var disqualificationReason: String?
}

/// Local, per-machine record of field-qualified CUA capabilities. A newer
/// qualification for the same key replaces an older or disqualified one.
public actor SQLiteCuaQualificationRepository: CuaQualificationRepository {
    private let database: AIMDatabase
    public init(database: AIMDatabase) { self.database = database }

    public func record(_ record: CuaQualificationRecord) throws {
        let key = record.key
        guard [key.driverVersion, key.driverSHA256, key.osBuild, key.adapterContract, record.schemaDigest]
                .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              record.evidence.utf8.count <= 64 * 1_024 else {
            throw WorkspaceHistoryError.invalidRecord
        }
        let digest = Self.digest(key)
        let row = CuaQualificationRow(id: "\(digest):\(record.capability.rawValue)", keyDigest: digest,
            driverVersion: key.driverVersion, driverSHA256: key.driverSHA256, osBuild: key.osBuild,
            adapterContract: key.adapterContract, capability: record.capability.rawValue,
            schemaDigest: record.schemaDigest, qualifiedAt: record.qualifiedAt, evidence: record.evidence,
            disqualifiedAt: nil, disqualificationReason: nil)
        try database.pool.write { db in try row.save(db) }
    }

    public func qualified(for key: CuaQualificationKey) throws -> [CuaCapability: String] {
        let digest = Self.digest(key)
        let rows = try database.pool.read { db in
            try CuaQualificationRow.filter(Column("keyDigest") == digest && Column("disqualifiedAt") == nil)
                .fetchAll(db)
        }
        var result: [CuaCapability: String] = [:]
        for row in rows where row.driverSHA256 == key.driverSHA256 && row.osBuild == key.osBuild &&
            row.adapterContract == key.adapterContract && row.driverVersion == key.driverVersion {
            if let capability = CuaCapability(rawValue: row.capability) { result[capability] = row.schemaDigest }
        }
        return result
    }

    public func disqualify(_ capability: CuaCapability, for key: CuaQualificationKey, reason: String) throws {
        let id = "\(Self.digest(key)):\(capability.rawValue)"
        let bounded = String(reason.prefix(1_000))
        try database.pool.write { db in
            guard var row = try CuaQualificationRow.fetchOne(db, key: id) else { return }
            row.disqualifiedAt = .now
            row.disqualificationReason = bounded
            try row.update(db)
        }
    }

    /// Adopts release-manifest records only where this Mac has no record yet
    /// (qualified or disqualified) for that key and capability. Returns how many were adopted.
    @discardableResult
    public func adopt(_ records: [CuaQualificationRecord]) throws -> Int {
        var adopted = 0
        for record in records {
            let id = "\(Self.digest(record.key)):\(record.capability.rawValue)"
            let exists = try database.pool.read { db in try CuaQualificationRow.fetchOne(db, key: id) != nil }
            guard !exists else { continue }
            try self.record(record)
            adopted += 1
        }
        return adopted
    }

    /// Every non-disqualified record, for exporting a release manifest.
    public func allQualified() throws -> [CuaQualificationRecord] {
        try database.pool.read { db in
            try CuaQualificationRow.filter(Column("disqualifiedAt") == nil).fetchAll(db)
        }.compactMap { row in
            CuaCapability(rawValue: row.capability).map {
                CuaQualificationRecord(key: CuaQualificationKey(driverVersion: row.driverVersion, driverSHA256: row.driverSHA256,
                    osBuild: row.osBuild, adapterContract: row.adapterContract), capability: $0,
                    schemaDigest: row.schemaDigest, qualifiedAt: row.qualifiedAt, evidence: row.evidence)
            }
        }
    }

    static func digest(_ key: CuaQualificationKey) -> String {
        let text = [key.driverVersion, key.driverSHA256, key.osBuild, key.adapterContract].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
