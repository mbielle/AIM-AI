#if DEBUG
import CryptoKit
import Darwin
import Foundation
import Security

/// Debug-only field-qualification report. It records host identity and facts
/// about AIM's disposable fixtures, never user pixels, user AX text or
/// personal data. A partial copy is written as the suite progresses so an
/// interrupted run still leaves evidence.
public final class QualificationReport: @unchecked Sendable {
    private let lock = NSLock()
    private var fields: [String: Any]
    private let destination: URL?

    public init(suite: String, destination: URL?) {
        self.destination = destination
        var initial = Self.hostFacts()
        initial["suite"] = suite
        initial["started_at"] = ISO8601DateFormatter().string(from: .now)
        initial["complete"] = false
        fields = initial
    }

    public func set(_ key: String, _ value: Any?) {
        lock.withLock { fields[key] = value ?? NSNull() }
    }

    public func append(_ key: String, _ value: Any) {
        lock.withLock {
            var list = fields[key] as? [Any] ?? []
            list.append(value)
            fields[key] = list
        }
    }

    public func value(_ key: String) -> Any? { lock.withLock { fields[key] } }

    public func checkpoint() {
        guard let destination else { return }
        try? encoded().write(to: destination.appendingPathExtension("partial"), options: [.atomic])
    }

    @discardableResult
    public func finish() -> Data {
        lock.withLock {
            fields["complete"] = true
            fields["finished_at"] = ISO8601DateFormatter().string(from: .now)
        }
        let data = encoded()
        if let destination {
            try? data.write(to: destination, options: [.atomic])
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
        }
        return data
    }

    public func encoded() -> Data {
        let snapshot = lock.withLock { fields }
        return (try? JSONSerialization.data(withJSONObject: Self.sanitized(snapshot),
            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: Host facts

    public static func hostFacts() -> [String: Any] {
        var facts: [String: Any] = [
            "bundle": Bundle.main.bundleURL.path,
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "os_build": osBuild() ?? ""
        ]
        if let executable = Bundle.main.executableURL {
            facts["aim_executable_sha256"] = sha256(fileAt: executable) ?? ""
        }
        let signing = selfSigning()
        facts["aim_team_id"] = signing.team ?? ""
        facts["aim_designated_requirement"] = redactingCertificateNames(signing.requirement ?? "")
        return facts
    }

    /// Reports are shared: keep the requirement's shape, not the developer's name.
    static func redactingCertificateNames(_ requirement: String) -> String {
        requirement.replacingOccurrences(of: #"subject\.CN\] = "[^"]*""#, with: #"subject.CN] = "<redacted>""#,
                                         options: .regularExpression)
    }

    public static func osBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public static func sha256(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Static signing facts of a nested helper: team, hardened runtime and entitlement keys.
    public static func signingFacts(path: URL) -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code else {
            return ["error": "unsigned or unreadable"]
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return ["error": "signing information unavailable"] }
        var facts: [String: Any] = [:]
        facts["identifier"] = dictionary[kSecCodeInfoIdentifier as String] as? String ?? ""
        facts["team_id"] = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        let codeFlags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        facts["hardened_runtime"] = codeFlags & 0x10000 != 0
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        facts["entitlements"] = entitlements.keys.sorted()
        return facts
    }

    private static func selfSigning() -> (team: String?, requirement: String?) {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return (nil, nil) }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return (nil, nil) }
        var info: CFDictionary?
        _ = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        var requirement: SecRequirement?
        var text: CFString?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
           SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
            return (team, text as String?)
        }
        return (team, nil)
    }

    /// JSONSerialization rejects non-JSON values; keep the report writable.
    private static func sanitized(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { sanitized($0) }
        case let array as [Any]:
            return array.map { sanitized($0) }
        case is String, is NSNumber, is NSNull, is Bool, is Int, is Double:
            return value
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            return String(describing: value)
        }
    }
}
#endif
