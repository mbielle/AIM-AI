import Foundation

/// A scope is issued by AIM's host UI. Tool arguments cannot create or widen it.
public struct MissionResource: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case application
        case directory
        case webOrigin
        case recipient
    }

    public let kind: Kind
    public let identifier: String

    public init(kind: Kind, identifier: String) throws {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2_048, !value.contains("\0") else {
            throw MissionAuthorizationError.invalidScope
        }
        self.kind = kind
        switch kind {
        case .application:
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count >= 2, components.allSatisfy({ !$0.isEmpty &&
                $0.utf8.allSatisfy { byte in (65...90).contains(byte) || (97...122).contains(byte) ||
                    (48...57).contains(byte) || byte == 45 } }) else {
                throw MissionAuthorizationError.invalidScope
            }
            self.identifier = value
        case .directory:
            guard value.hasPrefix("/"), !value.contains("/../"), !value.hasSuffix("/..") else {
                throw MissionAuthorizationError.invalidScope
            }
            self.identifier = URL(fileURLWithPath: value, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
        case .webOrigin:
            guard let url = URLComponents(string: value),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else {
                throw MissionAuthorizationError.invalidScope
            }
            let defaultPort = scheme == "https" ? 443 : 80
            self.identifier = "\(scheme)://\(host)" + (url.port == nil || url.port == defaultPort ? "" : ":\(url.port!)")
        case .recipient:
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
                  !value.contains(where: { $0.isWhitespace || $0.isNewline || "<>\"'*?".contains($0) }) else {
                throw MissionAuthorizationError.invalidScope
            }
            self.identifier = value.lowercased()
        }
    }

    /// The target is independently resolved by the trusted executor. A folder
    /// grant covers descendants only, never a sibling with a shared prefix.
    public func contains(_ target: MissionResource) -> Bool {
        guard kind == target.kind else { return false }
        if kind == .directory {
            return target.identifier == identifier || target.identifier.hasPrefix(identifier == "/" ? "/" : identifier + "/")
        }
        return target.identifier == identifier
    }
}

public enum MissionOperation: String, Codable, CaseIterable, Sendable {
    case observe
    case edit
    case input
    case navigate
    case submit
    case send
    case delegate
    case payment
    case commitment
    case administrator
    case permanentDelete

    public var requiresExactApproval: Bool {
        switch self {
        case .payment, .commitment, .administrator, .permanentDelete: true
        default: false
        }
    }
}

public struct MissionAuthorizationRule: Codable, Equatable, Hashable, Sendable {
    public let resource: MissionResource
    public let operations: Set<MissionOperation>

    public init(resource: MissionResource, operations: Set<MissionOperation>) throws {
        guard !operations.isEmpty, operations.allSatisfy({ !$0.requiresExactApproval }) else {
            throw MissionAuthorizationError.invalidScope
        }
        self.resource = resource
        self.operations = operations
    }
}

public struct MissionPermissionNeed: Equatable, Sendable {
    public let operation: MissionOperation
    public let target: MissionResource

    public init(operation: MissionOperation, target: MissionResource) {
        self.operation = operation
        self.target = target
    }
}

/// Every resource affected by an operation must be covered. A copy needs
/// permission to observe its source and edit its destination; a move edits both.
/// The model's own arguments are never an authorization claim.
public struct MissionToolIntent: Equatable, Sendable {
    public let needs: [MissionPermissionNeed]

    public init(operation: MissionOperation, target: MissionResource) {
        needs = [MissionPermissionNeed(operation: operation, target: target)]
    }

    public init(needs: [MissionPermissionNeed]) throws {
        guard (1...8).contains(needs.count),
              Set(needs.map { "\($0.operation.rawValue):\($0.target.kind.rawValue):\($0.target.identifier)" }).count == needs.count else {
            throw MissionAuthorizationError.invalidScope
        }
        self.needs = needs
    }

    public var operation: MissionOperation { needs[0].operation }
    public var target: MissionResource { needs[0].target }
}

public struct MissionAuthorization: Codable, Equatable, Sendable {
    public let missionID: UUID
    public let revision: Int
    public let rules: [MissionAuthorizationRule]
    public let createdAt: Date
    public let updatedAt: Date
    public let revokedAt: Date?

    public init(missionID: UUID, revision: Int, rules: [MissionAuthorizationRule],
                createdAt: Date, updatedAt: Date, revokedAt: Date?) {
        self.missionID = missionID
        self.revision = revision
        self.rules = rules
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revokedAt = revokedAt
    }

    public func covers(_ operation: MissionOperation, target: MissionResource) -> Bool {
        guard revokedAt == nil, !operation.requiresExactApproval else { return false }
        return rules.contains { $0.operations.contains(operation) && $0.resource.contains(target) }
    }

    public func covers(_ intent: MissionToolIntent) -> Bool {
        intent.needs.allSatisfy { covers($0.operation, target: $0.target) }
    }
}

public enum MissionAuthorizationError: LocalizedError, Sendable {
    case invalidScope, conflict, unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidScope: "The mission authorization has an invalid resource or operation."
        case .conflict: "The mission authorization changed. Reload it before retrying."
        case .unavailable: "The mission is unavailable or no longer active."
        }
    }
}
