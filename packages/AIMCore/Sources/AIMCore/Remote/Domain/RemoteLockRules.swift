import Foundation

public struct RemoteUnlockToken: Codable, Equatable, Sendable {
    public let token: String
    public let expiresAt: Date
    public let method: String?

    public var value: String { token }
    public var isExpired: Bool { expiresAt <= Date() }

    public init(value: String, expiresAt: Date, method: String? = nil) {
        token = value
        self.expiresAt = expiresAt
        self.method = method
    }

    public init(token: String, expiresAt: Date, method: String? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.method = method
    }

    enum CodingKeys: String, CodingKey { case token, expiresAt, method }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        let value = try container.decode(String.self, forKey: .expiresAt)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: container, debugDescription: "Invalid unlock expiry")
        }
        expiresAt = date
        method = try container.decodeIfPresent(String.self, forKey: .method)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(ISO8601DateFormatter().string(from: expiresAt), forKey: .expiresAt)
        try container.encodeIfPresent(method, forKey: .method)
    }
}

public struct RemoteLockServerState: Equatable, Sendable {
    public let ok: Bool
    public let passkeys: Int?
    public let hasPIN: Bool?
    public let lockedUntil: Date?
    public let enabled: Bool?
    public let error: String?

    public init(ok: Bool, passkeys: Int? = nil, hasPIN: Bool? = nil, lockedUntil: Date? = nil, enabled: Bool? = nil, error: String? = nil) {
        self.ok = ok; self.passkeys = passkeys; self.hasPIN = hasPIN; self.lockedUntil = lockedUntil; self.enabled = enabled; self.error = error
    }
}

public enum RemoteLockStep: Sendable { case loading, configuration, locked, blocked, unlocked, notPaired }

public enum RemoteLockRules {
    public static let backgroundTimeout: TimeInterval = 15 * 60

    public static func applies(to mode: RemoteMode) -> Bool { mode != .chat }
    public static func isValidPIN(_ pin: String) -> Bool { pin.utf8.count == 6 && pin.utf8.allSatisfy { (48...57).contains($0) } }
    public static func isExpired(token: RemoteUnlockToken?, now: Date) -> Bool { token?.expiresAt ?? .distantPast <= now }
    public static func shouldRelock(hiddenSince: Date?, now: Date) -> Bool { hiddenSince.map { now.timeIntervalSince($0) >= backgroundTimeout } ?? false }
    public static func blockEnd(server: RemoteLockServerState?, now: Date) -> Date? { guard let end = server?.lockedUntil, end > now else { return nil }; return end }

    public static func step(server: RemoteLockServerState?, token: RemoteUnlockToken?, now: Date) -> RemoteLockStep {
        if !isExpired(token: token, now: now) { return .unlocked }
        if server?.ok == true, server?.enabled == false { return .unlocked }
        guard let server else { return .loading }
        guard server.ok else { return server.error == "device_not_paired" ? .notPaired : .loading }
        let configured = (server.passkeys ?? 0) > 0 || server.hasPIN == true
        if !configured { return .configuration }
        if blockEnd(server: server, now: now) != nil, (server.passkeys ?? 0) == 0 { return .blocked }
        return .locked
    }

    public static func requiresUnlockToDisable(server: RemoteLockServerState?, token: RemoteUnlockToken?, now: Date) -> Bool {
        let configured = (server?.passkeys ?? 0) > 0 || server?.hasPIN == true
        return configured && isExpired(token: token, now: now)
    }

    public static func remainingMinutes(until end: Date, now: Date) -> Int {
        max(1, Int(ceil(end.timeIntervalSince(now) / 60)))
    }
}

public final class RemoteUnlockVault: @unchecked Sendable {
    public private(set) var token: RemoteUnlockToken?
    private var hiddenSince: Date?

    public init() {}
    public func setToken(_ token: RemoteUnlockToken?) { self.token = token }
    public func applicationDidEnterBackground(at date: Date) { hiddenSince = date }
    public func applicationWillEnterForeground(at date: Date) {
        if RemoteLockRules.shouldRelock(hiddenSince: hiddenSince, now: date), token != nil { token = nil }
        hiddenSince = nil
    }
}
