import AIMCore
import Foundation

/// A stale catalog is better than an empty picker while the network refreshes.
public actor ModelCatalogCache {
    public static let shared = ModelCatalogCache()

    private struct Snapshot: Codable {
        let savedAt: Date
        let models: [ChatModel]
    }

    private let directory: URL
    public private(set) var revision: UInt64 = 0
    private var memory: [ChatProvider: Snapshot] = [:]
    private let lifetime: TimeInterval = 24 * 60 * 60

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: AIMInstallationContext.legacyDirectoryName + "/ModelCatalogs", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    public func cached(_ provider: ChatProvider) -> [ChatModel]? {
        snapshot(provider)?.models
    }

    public func isFresh(_ provider: ChatProvider, now: Date = .now) -> Bool {
        guard let value = snapshot(provider) else { return false }
        return now.timeIntervalSince(value.savedAt) < lifetime
    }

    public func save(_ models: [ChatModel], for provider: ChatProvider, at date: Date = .now) throws {
        let value = Snapshot(savedAt: date, models: models)
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 20_000_000 else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: url(provider), options: .atomic)
        memory[provider] = value
        revision &+= 1
    }

    public func invalidate(_ provider: ChatProvider) {
        memory[provider] = nil
        revision &+= 1
        try? FileManager.default.removeItem(at: url(provider))
    }

    private func snapshot(_ provider: ChatProvider) -> Snapshot? {
        if let value = memory[provider] { return value }
        guard let data = try? Data(contentsOf: url(provider)), data.count <= 20_000_000,
              let value = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        memory[provider] = value
        return value
    }

    private func url(_ provider: ChatProvider) -> URL {
        // v2: full OpenRouter catalog (all output modalities) with prices and reasoning levels.
        directory.appending(path: provider.rawValue + "-v2.json")
    }
}
