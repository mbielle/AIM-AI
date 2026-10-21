import AIMCore
import AIMApplication
import Foundation

public struct CustomAgentProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var version = 1
    public var name: String
    public var instructions: String
    public var allowedModes: [AIMMode]
    public var readOnly: Bool
    public var allowedTools: [String]?
    public var maximumSpendUSD: String?
    public var providerPluginID: String?
    public init(name: String, instructions: String, allowedModes: [AIMMode] = [.agent, .code],
                readOnly: Bool = false, allowedTools: [String]? = nil, maximumSpendUSD: String? = nil, providerPluginID: String? = nil) {
        self.name = name; self.instructions = instructions; self.allowedModes = allowedModes
        self.readOnly = readOnly; self.allowedTools = allowedTools; self.maximumSpendUSD = maximumSpendUSD
        self.providerPluginID = providerPluginID
    }
    public func validate() throws {
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              instructions.utf8.count <= 16_000, !instructions.contains("\0"), !allowedModes.isEmpty,
              allowedTools?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0") }) != false,
              allowedTools?.count ?? 0 <= 512 else { throw CustomAgentError.invalidProfile }
        if let providerPluginID {
            guard !providerPluginID.isEmpty, providerPluginID.utf8.count <= 128,
                  providerPluginID.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { throw CustomAgentError.invalidProfile }
        }
        if let maximumSpendUSD { guard let value = Decimal(string: maximumSpendUSD), value > 0 else { throw CustomAgentError.invalidProfile } }
    }
    public func apply(to request: inout AgentRequest) throws {
        try validate()
        guard allowedModes.contains(request.mode) else { throw CustomAgentError.unsupportedMode }
        request.customAgentProfileID = id
        request.customAgentInstructions = instructions
        request.allowedToolNames = allowedTools
        request.providerPluginID = providerPluginID
        if readOnly {
            request.workspaceEditsEnabled = false; request.workspaceCommandsEnabled = false
            if request.workspaceToolsEnabled == true { request.workspacePlanOnly = true; request.approvalPolicy = .plan }
        }
        if let maximumSpendUSD {
            if let existing = request.continuityMaximumSpendUSD, let amount = Decimal(string: existing),
               let cap = Decimal(string: maximumSpendUSD), amount <= cap { return }
            request.continuityMaximumSpendUSD = maximumSpendUSD
        }
    }
}
public enum CustomAgentError: LocalizedError {
    case invalidProfile, unsupportedMode, missingProfile
    public var errorDescription: String? {
        switch self {
        case .invalidProfile: "The custom agent profile is invalid or uses an unsupported version."
        case .unsupportedMode: "The selected custom agent does not support this mode. Choose another profile in Personalization."
        case .missingProfile: "The selected custom agent was removed. Choose another profile in Personalization."
        }
    }
}
/// One file per profile preserves independent edits and makes export/import reviewable.
public struct CustomAgentLibrary: Sendable {
    public static let selectionKey = "AIMCustomAgentProfileID"
    public let directory: URL
    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: AIMInstallationContext.applicationSupportNamespace + "/CustomAgents")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    }
    public func list() throws -> [CustomAgentProfile] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]).filter { $0.pathExtension == "json" }.map {
            guard try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CustomAgentError.invalidProfile }
            let data = try Data(contentsOf: $0)
            guard data.count <= 64_000 else { throw CustomAgentError.invalidProfile }
            let item = try JSONDecoder().decode(CustomAgentProfile.self, from: data); try item.validate(); return item
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func save(_ item: CustomAgentProfile) throws {
        try item.validate()
        let destination = directory.appending(path: item.id.uuidString + ".json")
        try JSONEncoder().encode(item).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    public func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory.appending(path: id.uuidString + ".json")) }
    public func selected() throws -> CustomAgentProfile? {
        let defaults = AIMInstallationContext.sharedPreferences
        defaults.synchronize()
        guard let value = defaults.string(forKey: Self.selectionKey), !value.isEmpty else { return nil }
        guard let id = UUID(uuidString: value), let item = try list().first(where: { $0.id == id }) else { throw CustomAgentError.missingProfile }
        return item
    }
}
