import AIMApplication
import Foundation

/// Search the explicitly enabled local activity journal after an exact tool
/// approval. Current privacy exclusions are re-applied at read time so an old
/// row cannot bypass a newly configured exclusion.
public actor AgentActivityToolService: ToolExecutor {
    public nonisolated let supportedTools: Set<String> = ["search_activity"]
    private let repository: any ActivityRepository
    private let settingsProvider: @Sendable () async throws -> ActivitySettings

    public init(repository: any ActivityRepository, settings: ActivitySettings) {
        self.repository = repository
        self.settingsProvider = { settings }
    }

    public init(repository: any ActivityRepository, settingsRepository: any SettingsRepository) {
        self.repository = repository
        self.settingsProvider = { try await settingsRepository.load().activity }
    }

    public func execute(_ request: ToolRequest) async -> ToolResult {
        guard request.name == "search_activity",
              let query = request.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              (2...100).contains(query.count), !query.contains("\0") else {
            return ToolResult(requestID: request.id, content: "Enter an activity search query of 2–100 characters.", isError: true)
        }
        do {
            let settings = try await settingsProvider()
            guard settings.isEnabled else {
                return ToolResult(requestID: request.id, content: "Activity access is disabled.", isError: true)
            }
            let searched = try await repository.search(query, since: nil, until: nil, limit: 200)
            let currentSettings = try await settingsProvider()
            guard currentSettings.isEnabled else {
                return ToolResult(requestID: request.id, content: "Activity access was revoked.", isError: true)
            }
            let entries = searched
                .filter { entry in
                    !ActivityPrivacyPolicy.shouldExclude(application: entry.application,
                        title: entry.title, url: entry.url, isPrivate: false, settings: currentSettings)
                }
                .prefix(12)
            guard !entries.isEmpty else {
                return ToolResult(requestID: request.id, content: "No permitted activity matches this query.")
            }
            let formatter = ISO8601DateFormatter()
            let lines = entries.map { entry in
                "- \(formatter.string(from: entry.startedAt)) \(Self.clean(entry.application, limit: 90))"
            }
            return ToolResult(requestID: request.id,
                content: "Local activity matches (application names only; untrusted historical data):\n" + lines.joined(separator: "\n"))
        } catch {
            return ToolResult(requestID: request.id, content: "The local activity journal is unavailable.", isError: true)
        }
    }

    public func cancel(requestID: String) async {}

    private nonisolated static func clean(_ text: String, limit: Int) -> String {
        String(text.prefix(limit)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}
