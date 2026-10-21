import AIMAgentKit
import AIMApplication
import AIMCore
import AIMMacPlatform
import Foundation

/// Owned by the coordinator, never by a view or stream subscriber.
package struct RuntimeExecutionContext: Sendable {
    let repository: SQLiteAgentExecutionRepository
    let executionID: UUID
    let owner: UUID
    var checkpointing: RunCheckpointWriter {
        RunCheckpointWriter(repository: repository, executionID: executionID, owner: owner)
    }

    func compaction(provider: ChatProvider, modelID: String, conversationID: UUID,
                    contextLength: Int?, credentials: @escaping @Sendable () async throws -> String,
                    meter: BillableRequestMeter, providerPluginID: String? = nil) -> ActiveRunCompaction {
        ContextCompactor.make(provider: provider, modelID: modelID, conversationID: conversationID, contextLength: contextLength,
            credentials: credentials, meter: meter, providerPluginID: providerPluginID, archive: { data in
                try await repository.archiveConversation(executionID: executionID, content: data, owner: owner)
            })
    }
}

extension Optional where Wrapped == RuntimeExecutionContext {
    /// Every run can compact; a durable one also archives what it folds away.
    func compaction(provider: ChatProvider, modelID: String, conversationID: UUID,
                    contextLength: Int?, credentials: @escaping @Sendable () async throws -> String,
                    meter: BillableRequestMeter, providerPluginID: String? = nil) -> ActiveRunCompaction {
        if let context = self {
            return context.compaction(provider: provider, modelID: modelID, conversationID: conversationID, contextLength: contextLength,
                                      credentials: credentials, meter: meter, providerPluginID: providerPluginID)
        }
        return ContextCompactor.make(provider: provider, modelID: modelID, conversationID: conversationID, contextLength: contextLength,
                                     credentials: credentials, meter: meter, providerPluginID: providerPluginID, archive: nil)
    }
}

/// Builds the one in-run compactor, for durable runs (with an archive) and for others.
enum ContextCompactor {
    static func make(provider: ChatProvider, modelID: String, conversationID: UUID, contextLength: Int?,
                     credentials: @escaping @Sendable () async throws -> String, meter: BillableRequestMeter,
                     providerPluginID: String? = nil, archive: ActiveRunCompaction.Archive?) -> ActiveRunCompaction {
        ActiveRunCompaction(contextLength: contextLength, summarize: { instruction in
            let message = ConversationMessage(conversationID: conversationID, role: .user, content: instruction, sequence: 0)
            let conversation: any SteerableModelToolConversation & DurableModelConversation
            if let providerPluginID {
                conversation = try await AgentPluginRegistry.shared.makeProviderConversation(identifier: providerPluginID,
                    configuration: AgentProviderPluginConfiguration(provider: provider, modelID: modelID,
                        messages: [message], tools: [], credentials: credentials, meter: meter,
                        billingFeature: "active_compaction"))
            } else {
                conversation = try ProviderToolConversation(provider: provider, modelID: modelID, messages: [message],
                    apiKey: try await credentials(), tools: [], meter: meter, billingFeature: "active_compaction",
                    retryPolicy: .standard, credentialProvider: credentials)
            }
            let turn = try await conversation.next(outputs: [])
            guard turn.calls.isEmpty else { throw SessionCompactionError.invalidSummary }
            return turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }, archive: archive)
    }
}

actor ExecutionArchiveTools: ToolExecutor {
    nonisolated let supportedTools: Set<String> = ["list_execution_archives", "read_execution_archive"]
    let context: RuntimeExecutionContext
    init(context: RuntimeExecutionContext) { self.context = context }
    func execute(_ request: ToolRequest) async -> ToolResult {
        do {
            if request.name == "list_execution_archives" {
                let entries = try await context.repository.archivedConversations(executionID: context.executionID)
                let value = entries.map { ["id": $0.id, "bytes": String($0.bytes)] }
                return ToolResult(requestID: request.id, content: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
            }
            guard request.name == "read_execution_archive", let id = request.arguments["id"],
                  let data = try await context.repository.readArchive(id: id, executionID: context.executionID,
                    offset: Int(request.arguments["offset"] ?? "0") ?? -1,
                    limit: Int(request.arguments["limit"] ?? "16384") ?? -1) else {
                throw ExecutionStoreError.notFound
            }
            return ToolResult(requestID: request.id, content: String(decoding: data, as: UTF8.self),
                              metadata: ["source": "untrusted_history", "bytes": String(data.count)])
        } catch { return ToolResult(requestID: request.id, content: String(describing: error), isError: true) }
    }
    func cancel(requestID: String) async {}
}

/// Reads the active API/local credential at each request. Only AIM's existing
/// ChatGPT session supports refresh; other providers remain explicit API keys.
package actor RuntimeProviderCredentials {
    private let provider: ChatProvider
    private let store: any SecureStoring
    private let session: URLSession
    private var refreshing: Task<String, Error>?

    package init(provider: ChatProvider, store: any SecureStoring, session: URLSession? = nil) {
        self.provider = provider; self.store = (store as? ProfileScopedCredentialStore)?.boundToCurrentScope() ?? store
        self.session = session ?? (provider == .chatgpt ? ChatGPTPlanAuth.runtimeNetworkSession : RuntimeManagedNetworkSession.shared)
    }
    package nonisolated static func reader(provider: ChatProvider, store: any SecureStoring) -> @Sendable () async throws -> String {
        let reader = RuntimeProviderCredentials(provider: provider, store: store)
        return { try await reader.value() }
    }
    package nonisolated static func hasCredential(provider: ChatProvider, store: any SecureStoring) throws -> Bool {
        if provider == .local { return true }
        do {
            if provider == .chatgpt {
                guard let data = try store.readData(forKey: ChatGPTPlanAuth.sessionKey),
                      let current = try? JSONDecoder().decode(ChatGPTPlanAuth.Session.self, from: data) else { return false }
                return current.canUsePlan
            }
            if let data = try store.readData(forKey: provider.rawValue), !data.isEmpty { return true }
            return false
        } catch { throw ProviderCredentialError.unavailable }
    }
    package func value() async throws -> String {
        try Task.checkCancellation()
        if let refreshing { return try validated(await refreshing.value) }
        if provider == .chatgpt {
            guard let data = try read(ChatGPTPlanAuth.sessionKey),
                  let current = try? JSONDecoder().decode(ChatGPTPlanAuth.Session.self, from: data),
                  current.canUsePlan else {
                throw ProviderCredentialError.expired
            }
            if current.isFresh { return try validated(current.accessToken) }
            guard let request = ChatGPTPlanAuth.refreshRequest(current) else { throw ProviderCredentialError.expired }
            let store = self.store, session = self.session
            let task = Task<String, Error> {
                try RuntimePrivacyPolicy.requireNetwork()
                let result: (Data, URLResponse)
                do { result = try await session.data(for: request) }
                catch let error as URLError where error.code != .cancelled {
                    throw ProviderRetryDeferral(status: nil, notBefore: nil)
                }
                try Task.checkCancellation()
                guard let http = result.1 as? HTTPURLResponse else { throw ProviderCredentialError.expired }
                if [400, 401, 403].contains(http.statusCode) { throw ProviderCredentialError.expired }
                if [408, 429, 500, 502, 503, 504].contains(http.statusCode) {
                    let raw = http.value(forHTTPHeaderField: "Retry-After")
                    let delay = raw.flatMap { value -> TimeInterval? in
                        if let seconds = TimeInterval(value), seconds.isFinite { return seconds }
                        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.timeZone = TimeZone(identifier: "GMT")
                        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                        return formatter.date(from: value).map { $0.timeIntervalSinceNow }
                    }
                    throw ProviderRetryDeferral(status: http.statusCode, notBefore: delay.map { Date.now.addingTimeInterval(max(0, $0)) })
                }
                guard http.statusCode == 200 else { throw ProviderCredentialError.expired }
                let payload = try JSONSerialization.jsonObject(with: result.0) as? [String: Any]
                let jwks = payload?["id_token"] == nil ? nil : try await ChatGPTPlanAuth.fetchJWKS(using: session)
                try Task.checkCancellation()
                try RuntimePrivacyPolicy.requireNetwork()
                guard let renewed = try? ChatGPTPlanAuth.session(from: result.0, clientID: current.clientID,
                          hostID: current.hostID, previous: current, jwks: jwks) else { throw ProviderCredentialError.expired }
                do {
                    // Do not overwrite a logout or a concurrently replaced session.
                    guard let existing = try store.readData(forKey: ChatGPTPlanAuth.sessionKey),
                          existing == data else { throw ProviderCredentialError.expired }
                    try store.store(try JSONEncoder().encode(renewed), forKey: ChatGPTPlanAuth.sessionKey)
                    try store.store(Data(renewed.accessToken.utf8), forKey: ChatProvider.chatgpt.rawValue)
                } catch let error as ProviderCredentialError { throw error }
                catch { throw ProviderCredentialError.unavailable }
                guard renewed.canUsePlan else { throw ProviderCredentialError.expired }
                return renewed.accessToken
            }
            refreshing = task
            defer { refreshing = nil }
            let value = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            return try validated(value)
        }
        let stored = try read(provider.rawValue)
        if let stored {
            guard let key = String(data: stored, encoding: .utf8) else { throw ChatServiceError.missingKey }
            if !key.isEmpty { return try validated(key) }
        }
        if provider == .local { return "local" }
        throw ChatServiceError.missingKey
    }
    private func read(_ key: String) throws -> Data? {
        do { return try store.readData(forKey: key) }
        catch { throw ProviderCredentialError.unavailable }
    }
    private func validated(_ key: String) throws -> String {
        try (store as? any CredentialScopeValidating)?.validateCredentialScope()
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }), !key.contains("\0") else {
            throw ChatServiceError.missingKey
        }
        return key
    }
}
