import AIMCore
import Foundation

/// Only conversations explicitly owned by this account are published. Older local
/// history remains intact and requires explicit adoption; no guessed account mapping.
public actor AccountChatSync {
    public struct Result: Sendable { public var favorites: Set<String>; public var addedModels: Set<String>; public var preferences: AccountChatPreferences; public var changed: Bool }
    private struct State: Codable { var owners: [UUID: UUID] = [:]; var revisions: [UUID: Int] = [:]; var lastPayload: [UUID: String] = [:]; var lastFavorites: Set<String>?; var lastAddedModels: Set<String>?; var lastPreferences: AccountChatPreferences?; var readReceipts: ConversationReadReceipts?; var executionDeviceIDs: [UUID: [String]]?; var responseVersions: [UUID: ConversationResponseVersion]?; var deletedProjects: Set<UUID>? }
    private let repository: any ConversationRepository
    private let projects: any ProjectRepository
    private let runs: (any WorkspaceRunRepository)?
    private let metrics: SQLiteMessageMetricsRepository
    private let secureStore: any SecureStoring
    private var busy = false
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    public init(repository: any ConversationRepository, projects: any ProjectRepository, metrics: SQLiteMessageMetricsRepository, secureStore: any SecureStoring, runs: (any WorkspaceRunRepository)? = nil) {
        self.runs = runs; self.repository = repository; self.projects = projects; self.metrics = metrics; self.secureStore = secureStore
    }
    private func load(accountID: UUID) throws -> State {
        guard let data = try secureStore.readData(forKey: "account-chat-sync.v1." + accountID.uuidString) else { var state = State(); state.owners = try loadOwners(); return state }
        var state = try JSONDecoder().decode(State.self, from: data)
        state.owners = try loadOwners(); return state
    }
    private func loadOwners() throws -> [UUID: UUID] {
        guard let data = try secureStore.readData(forKey: "account-chat-owners.v1") else { return [:] }
        return try JSONDecoder().decode([UUID: UUID].self, from: data)
    }
    public func markOwned(_ id: UUID, accountID: UUID) throws {
        guard try loadLocalOwners()[id] == nil else { throw AccountServiceError.conflict }
        var owners = try loadOwners()
        guard owners[id] == nil || owners[id] == accountID else { throw AccountServiceError.conflict }
        owners[id] = accountID; try secureStore.store(JSONEncoder().encode(owners), forKey: "account-chat-owners.v1")
    }
    private func loadLocalOwners() throws -> [UUID: UUID] {
        guard let data = try secureStore.readData(forKey: "local-chat-owners.v1") else { return [:] }
        return try JSONDecoder().decode([UUID: UUID].self, from: data)
    }
    public func markOwned(_ id: UUID, identity: AppIdentity) throws {
        if let account = identity.authenticatedUser {
            guard try loadLocalOwners()[id] == nil else { throw AccountServiceError.conflict }
            try markOwned(id, accountID: account.id)
        } else {
            guard try loadOwners()[id] == nil else { throw AccountServiceError.conflict }
            var owners = try loadLocalOwners()
            guard owners[id] == nil || owners[id] == identity.storageID else { throw AccountServiceError.conflict }
            owners[id] = identity.storageID
            try secureStore.store(JSONEncoder().encode(owners), forKey: "local-chat-owners.v1")
        }
    }
    public func isVisible(_ id: UUID, identity: AppIdentity?) throws -> Bool {
        guard let identity else { return false }
        if let owner = try loadOwners()[id] {
            guard identity.authenticatedUser?.id == owner else { return false }
            return !(try load(accountID: owner).deletedProjects ?? []).contains(id)
        }
        guard identity.isLocal else { return false }
        // Unowned historical data remains local and is never adopted at sign-in.
        return try loadLocalOwners()[id].map { $0 == identity.storageID } ?? true
    }
    public func isVisible(_ id: UUID, accountID: UUID?) throws -> Bool {
        if let owner = try loadOwners()[id] {
            guard owner == accountID else { return false }
            return !(try load(accountID: owner).deletedProjects ?? []).contains(id)
        }
        return accountID == nil
    }
    private func save(_ state: State, accountID: UUID) throws {
        var state = state
        if let latestData = try secureStore.readData(forKey: "account-chat-sync.v1." + accountID.uuidString),
           let latest = try? JSONDecoder().decode(State.self, from: latestData) {
            state.deletedProjects = (state.deletedProjects ?? []).union(latest.deletedProjects ?? [])
            state.readReceipts = (state.readReceipts ?? .init()).merging(latest.readReceipts ?? .init())
            var devices = latest.executionDeviceIDs ?? [:]
            for (id, values) in state.executionDeviceIDs ?? [:] { devices[id] = Array(Set((devices[id] ?? []) + values)).sorted() }
            state.executionDeviceIDs = devices
            var responses = latest.responseVersions ?? [:]
            for (id, response) in state.responseVersions ?? [:] where responses[id] == nil || responses[id]!.completedAt <= response.completedAt { responses[id] = response }
            state.responseVersions = responses
        }
        var owners = try loadOwners()
        for (id, owner) in state.owners {
            guard owners[id] == nil || owners[id] == owner else { throw AccountServiceError.conflict }
            owners[id] = owner
        }
        try secureStore.store(JSONEncoder().encode(owners), forKey: "account-chat-owners.v1")
        try secureStore.store(JSONEncoder().encode(state), forKey: "account-chat-sync.v1." + accountID.uuidString)
    }
    public struct ContinuityState: Sendable {
        public var receipts: ConversationReadReceipts
        public var executionDeviceIDs: [UUID: [String]]
        public var responseVersions: [UUID: ConversationResponseVersion]
    }
    public func continuityState(accountID: UUID) throws -> ContinuityState {
        try Self.cachedContinuityState(accountID: accountID, secureStore: secureStore)
    }
    /// Read-only metadata shared with the headless host; this neither adopts nor synchronizes content.
    public static func cachedContinuityState(accountID: UUID, secureStore: any SecureStoring) throws -> ContinuityState {
        let data = try secureStore.readData(forKey: "account-chat-sync.v1." + accountID.uuidString)
        let state = try data.map { try JSONDecoder().decode(State.self, from: $0) } ?? State()
        let runtime = try RuntimeConversationContinuity.load(accountID: accountID, store: secureStore)
        var devices = state.executionDeviceIDs ?? [:], responses = state.responseVersions ?? [:]
        for (id, values) in runtime.executionDeviceIDs { devices[id] = Array(Set((devices[id] ?? []) + values)).sorted() }
        for (id, version) in runtime.responseVersions where responses[id] == nil || responses[id]!.completedAt <= version.completedAt { responses[id] = version }
        return .init(receipts: state.readReceipts ?? .init(), executionDeviceIDs: devices, responseVersions: responses)
    }
    /// Bridge established local read metadata without adopting history or inventing an execution device.
    public func restoreKnownLegacyReadState(accountID: UUID) async throws {
        let known = try await metrics.knownLegacyReadState()
        var state = try load(accountID: accountID), changed = false
        var responses = state.responseVersions ?? [:], receipts = state.readReceipts ?? .init()
        for (id, legacy) in known where responses[id] == nil && (state.owners[id] == nil || state.owners[id] == accountID) {
            responses[id] = legacy.response
            if legacy.wasRead { receipts.acknowledge(conversationID: id.uuidString, response: legacy.response) }
            changed = true
        }
        if changed { state.responseVersions = responses; state.readReceipts = receipts; try save(state, accountID: accountID) }
    }
    public func recordExecution(conversationID: UUID, deviceID: String, accountID: UUID) throws {
        var state = try load(accountID: accountID)
        guard state.owners[conversationID] == nil || state.owners[conversationID] == accountID else { return }
        var devices = state.executionDeviceIDs ?? [:]
        devices[conversationID] = Array(Set((devices[conversationID] ?? []) + [deviceID])).sorted()
        state.executionDeviceIDs = devices; try save(state, accountID: accountID)
    }
    public func recordResponse(conversationID: UUID, response: ConversationResponseVersion, accountID: UUID) throws {
        var state = try load(accountID: accountID)
        guard state.owners[conversationID] == nil || state.owners[conversationID] == accountID else { return }
        var responses = state.responseVersions ?? [:]; responses[conversationID] = response
        state.responseVersions = responses; try save(state, accountID: accountID)
    }
    public func acknowledge(conversationID: UUID, response: ConversationResponseVersion, accountID: UUID) throws {
        var state = try load(accountID: accountID)
        var receipts = state.readReceipts ?? .init(); receipts.acknowledge(conversationID: conversationID.uuidString, response: response)
        state.readReceipts = receipts; try save(state, accountID: accountID)
    }
    public func synchronizeReadReceipts(accountID: UUID, service: any AccountContentSyncing,
                                        currentAccount: @Sendable () async -> UUID?) async throws -> ContinuityState {
        let initial = try load(accountID: accountID).readReceipts ?? .init()
        let incoming = try await ConversationReadReceiptSync.synchronize(initial, accountID: accountID, service: service, currentAccount: currentAccount)
        guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
        // Re-read after awaits: a foreground opening may have acknowledged another answer meanwhile.
        var state = try load(accountID: accountID)
        state.readReceipts = (state.readReceipts ?? .init()).merging(incoming)
        try save(state, accountID: accountID)
        return try continuityState(accountID: accountID)
    }
    public func synchronize(accountID: UUID, service: any AccountContentSyncing, favorites: Set<String>, preferences: AccountChatPreferences, addedModels: Set<String> = [],
                            currentAccount: @Sendable () async -> UUID?) async throws -> Result {
        guard !busy else { return .init(favorites: favorites, addedModels: addedModels, preferences: preferences, changed: false) }
        busy = true; defer { busy = false }
        var state = try load(accountID: accountID), changed = false
        // C101 is the added-model library on iPhone; pins have their own C103 document.
        let addedID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C101")!
        let favoritesID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C103")!
        let preferencesID = UUID(uuidString: "C49C4ED4-1E53-4A29-92C7-39A4D8D3C102")!
        var mergedFavorites = favorites, mergedAdded = addedModels, mergedPreferences = preferences
        let cloud = try await service.documents(accountID: accountID)
        guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
        let tombstones = Set(cloud.filter { $0.kind == "project" && $0.deleted }.map(\.id))
        if !tombstones.isEmpty {
            let prior = state.deletedProjects ?? []
            state.deletedProjects = prior.union(tombstones)
            for doc in cloud where tombstones.contains(doc.id) { state.revisions[doc.id] = doc.revision }
            try save(state, accountID: accountID) // Durable before any subsequent await/publication.
            changed = !tombstones.isSubset(of: prior)
        }
        // Keep project/source rows recoverable; do not invoke the repository's cascading delete.
        // Only account-owned conversations may be detached by this account's tombstones.
        for var conversation in try await repository.list(includeArchived: true) where state.owners[conversation.id] == accountID {
            if let project = conversation.projectID, (state.deletedProjects ?? []).contains(project) {
                guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
                conversation.projectID = nil; conversation.updatedAt = max(conversation.updatedAt, .now)
                try await repository.save(conversation); changed = true
            }
        }
        for doc in cloud.sorted(by: { ($0.kind == "project" ? 0 : 1) < ($1.kind == "project" ? 0 : 1) }) where !doc.deleted {
            guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
            state.revisions[doc.id] = doc.revision
            let data = Data(doc.payload.utf8)
            if doc.id == addedID, let remote = try? JSONDecoder().decode(Set<String>.self, from: data) {
                let baseline = state.lastAddedModels ?? []
                mergedAdded = remote.union(addedModels.subtracting(baseline)).subtracting(baseline.subtracting(addedModels))
            } else if doc.id == favoritesID, let remote = try? JSONDecoder().decode(Set<String>.self, from: data) {
                let baseline = state.lastFavorites ?? []
                mergedFavorites = remote.union(favorites.subtracting(baseline)).subtracting(baseline.subtracting(favorites))
            } else if doc.id == preferencesID, let remote = try? JSONDecoder().decode(AccountChatPreferences.self, from: data) {
                if state.lastPreferences == nil || preferences == state.lastPreferences { mergedPreferences = remote }
            } else if doc.kind == "project", let incoming = try? JSONDecoder().decode(NativeChatProject.self, from: data), incoming.id == doc.id {
                guard !(state.deletedProjects ?? []).contains(incoming.id) else { continue }
                let local = try await projects.list().first { $0.id == incoming.id }
                guard local == nil || state.owners[incoming.id] == accountID else { continue }
                // Old clients omit these keys. Missing metadata must not reset a known
                // project-only policy or pin when an older client edits a project name.
                let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let hasScope = fields?["memoryScope"] as? String != nil
                let hasPin = fields?["isPinned"] as? Bool != nil
                var value: AIMProject
                if let local, incoming.updatedAt < local.updatedAt {
                    value = local
                    if value.usesGlobalMemory == nil, hasScope { value.usesGlobalMemory = incoming.memoryScope == .default }
                    if value.isPinned == nil, hasPin { value.isPinned = incoming.isPinned }
                } else {
                    value = AIMProject(id: incoming.id, name: incoming.name, instructions: incoming.instructions, createdAt: incoming.createdAt, updatedAt: incoming.updatedAt)
                    value.usesGlobalMemory = hasScope ? incoming.memoryScope == .default : local?.usesGlobalMemory
                    value.isPinned = hasPin ? incoming.isPinned : local?.isPinned
                }
                if local != value {
                    guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
                    try await projects.save(value); changed = true
                }
                state.owners[incoming.id] = accountID; state.lastPayload[doc.id] = doc.payload
            } else if doc.kind == "chat", let incoming = try? JSONDecoder().decode(NativeChatConversation.self, from: data), incoming.id == doc.id {
                let local = try await repository.conversation(id: incoming.id)
                guard local == nil || state.owners[incoming.id] == accountID else { continue }
                let original: NativeChatConversation?
                if let local { original = try await snapshot(local, lastPayload: state.lastPayload[local.id]) } else { original = nil }
                var merged = original?.merging(incoming) ?? incoming
                if let project = merged.projectID.flatMap(UUID.init(uuidString:)), (state.deletedProjects ?? []).contains(project) {
                    merged.projectID = nil; merged.updatedAt = max(merged.updatedAt, .now)
                }
                guard let sqlite = repository as? SQLiteConversationRepository else { continue }
                guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
                try await sqlite.mergePlainChat(merged)
                let existingMetrics = try await metrics.metrics(conversationID: merged.id)
                for turn in merged.turns where turn.completedAt != nil && existingMetrics[turn.id] == nil {
                    let message = merged.messages.first { $0.id == turn.id }
                    try await metrics.save(.init(provider: merged.provider.rawValue, modelID: merged.modelID, mode: "chat", startedAt: message?.createdAt ?? merged.updatedAt, usage: turn.usage, totalSeconds: 0, characters: message?.text.count ?? 0, costUSD: turn.estimatedUSD), messageID: turn.id, conversationID: merged.id)
                }
                state.owners[doc.id] = accountID; state.lastPayload[doc.id] = doc.payload; changed = true
                if let devices = merged.executionDeviceIDs {
                    var all = state.executionDeviceIDs ?? [:]; all[doc.id] = Array(Set((all[doc.id] ?? []) + devices)).sorted(); state.executionDeviceIDs = all
                }
                if let version = merged.latestResponseVersion {
                    var all = state.responseVersions ?? [:]
                    if all[doc.id] == nil || all[doc.id]!.completedAt <= version.completedAt { all[doc.id] = version }
                    state.responseVersions = all
                }
            }
        }
        guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
        for conversation in try await repository.list(includeArchived: true) where conversation.mode == .chat && state.owners[conversation.id] == accountID {
            guard let value = try await snapshot(conversation, lastPayload: state.lastPayload[conversation.id], executionDeviceIDs: state.executionDeviceIDs?[conversation.id], responseVersion: state.responseVersions?[conversation.id]) else { continue }
            let payload = String(decoding: try encode(value), as: UTF8.self)
            guard payload.utf8.count <= 16_000_000 else { throw NativeDocumentError.synchronizationLimit }
            if payload != state.lastPayload[value.id] {
                guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
                let saved = try await service.save(.init(id: value.id, kind: "chat", payload: payload, revision: state.revisions[value.id] ?? 0), accountID: accountID)
                state.lastPayload[value.id] = payload; state.revisions[value.id] = saved.revision
            }
        }
        for project in try await projects.list() where state.owners[project.id] == accountID && !(state.deletedProjects ?? []).contains(project.id) {
            let value = NativeChatProject(id: project.id, name: project.name, instructions: project.instructions, isPinned: project.isPinned ?? false, memoryScope: project.usesGlobalMemory == false ? .projectOnly : .default, createdAt: project.createdAt, updatedAt: project.updatedAt)
            let payload = String(decoding: try encode(value), as: UTF8.self)
            if payload != state.lastPayload[value.id] {
                guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
                let saved = try await service.save(.init(id: value.id, kind: "project", payload: payload, revision: state.revisions[value.id] ?? 0), accountID: accountID)
                state.lastPayload[value.id] = payload; state.revisions[value.id] = saved.revision
            }
        }
        for (id, kind, payload) in [(addedID, "favorites", String(decoding: try encode(mergedAdded.sorted()), as: UTF8.self)),
                                    (favoritesID, "favorites", String(decoding: try encode(mergedFavorites.sorted()), as: UTF8.self)),
                                    (preferencesID, "preferences", String(decoding: try encode(mergedPreferences), as: UTF8.self))] {
            if cloud.first(where: { $0.id == id })?.payload != payload {
                guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
                let saved = try await service.save(.init(id: id, kind: kind, payload: payload, revision: state.revisions[id] ?? 0), accountID: accountID); state.revisions[id] = saved.revision
            }
        }
        state.lastAddedModels = mergedAdded; state.lastFavorites = mergedFavorites; state.lastPreferences = mergedPreferences; try save(state, accountID: accountID)
        return .init(favorites: mergedFavorites, addedModels: mergedAdded, preferences: mergedPreferences, changed: changed)
    }
    private func snapshot(_ conversation: Conversation, lastPayload: String?, executionDeviceIDs: [String]? = nil, responseVersion: ConversationResponseVersion? = nil) async throws -> NativeChatConversation? {
        guard let provider = conversation.provider, let model = conversation.modelID else { return nil }
        let original = try await repository.messages(conversationID: conversation.id)
        let histories = try await runs?.history(conversationID: conversation.id, limit: 100) ?? []
        let messages = ConversationActionProjection.apply(histories, to: original)
        // Input snapshots are portable; generated videos and tool histories keep their separate contract.
        guard messages.allSatisfy({ ($0.role == .user || $0.role == .assistant) && ($0.videos ?? []).isEmpty && ($0.role == .user || (($0.attachments ?? []).isEmpty && ($0.images ?? []).isEmpty)) }) else { return nil }
        let prior = lastPayload.flatMap { try? JSONDecoder().decode(NativeChatConversation.self, from: Data($0.utf8)) }
        let reports = try await metrics.metrics(conversationID: conversation.id)
        return NativeChatConversation(id: conversation.id, title: conversation.title, provider: provider, modelID: model,
            messages: messages.map { message in
                let previous = prior?.messages.first { $0.id == message.id }
                let report = reports[message.id]
                return .init(id: message.id, role: message.role == .user ? .user : .assistant, text: message.content, createdAt: message.createdAt,
                    webSearchUsage: report?.webSearchUsage ?? previous?.webSearchUsage,
                    webSearchActivities: report?.webSearchActivities ?? previous?.webSearchActivities,
                    skillActivities: previous?.skillActivities,
                    mediaAssetIDs: previous?.mediaAssetIDs,
                    attachments: portableInputs(message).isEmpty ? previous?.attachments : portableInputs(message),
                    actions: ConversationAction.merge(message.actions, previous?.actions), visualReport: message.visualReport ?? previous?.visualReport, sources: ConversationSource.merge(message.sources ?? report?.sources, previous?.sources), routeAttempts: ConversationRouteAttempt.merge(message.routeAttempts ?? report?.routeAttempts, previous?.routeAttempts), timeline: TurnTimeline.merge(previous?.timeline, message.timeline))
            },
            turns: messages.filter { $0.role == .assistant }.map { message in
                let report = reports[message.id]
                return .init(id: message.id, usage: report?.usage ?? .init(), estimatedUSD: report?.costUSD,
                    completedAt: message.completionStatus == nil && !message.content.isEmpty ? prior?.turns.first(where: { $0.id == message.id })?.completedAt ?? message.createdAt : nil)
            }, projectID: conversation.projectID?.uuidString, updatedAt: conversation.updatedAt, executionDeviceIDs: executionDeviceIDs ?? prior?.executionDeviceIDs, latestResponseVersion: responseVersion ?? prior?.latestResponseVersion, lastTurnStatus: messages.last(where: { $0.role == .assistant })?.completionStatus == .failed ? "failed" : "idle")
    }
    private func portableInputs(_ message: ConversationMessage) -> [NativeChatAttachment] {
        (message.attachments ?? []).map { .init(id: $0.id, name: $0.name, kind: .document, mimeType: "text/plain", text: $0.content, video: $0.video) }
        + (message.images ?? []).map { .init(id: $0.id, name: $0.name, kind: .image, mimeType: $0.mimeType, data: $0.data) }
    }

}

extension AccountChatSync {
    public struct LocalCopyItem: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let messages: [NativeChatMessage]
        public let projectName: String?
        public let projectInstructions: String?
    }
    public struct LocalCopyPreview: Sendable {
        public let id: UUID
        public let accountID: UUID
        public let items: [LocalCopyItem]
        public let skippedConversations: Int
        fileprivate let profile: LocalProfile
        fileprivate let snapshots: [UUID: NativeChatConversation]
        fileprivate let projectSnapshots: [UUID: AIMProject]
    }
    private struct LocalCopyPlan: Codable {
        var conversations: [UUID: UUID]
        var projects: [UUID: UUID]
        var messages: [UUID: UUID]
    }

    /// Explicitly preview local and historical ownerless chat. Sign-in never calls this.
    /// Runtime state, machine paths and linked project files are excluded.
    public func previewLocalCopy(profile: LocalProfile, accountID: UUID,
        currentAccount: @Sendable () async -> UUID?) async throws -> LocalCopyPreview {
        guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
        let identity = AppIdentity.local(profile)
        let allProjects = try await projects.list()
        var snapshots: [UUID: NativeChatConversation] = [:], projectSnapshots: [UUID: AIMProject] = [:]
        var items: [LocalCopyItem] = [], skipped = 0
        for conversation in try await repository.list(includeArchived: true) {
            guard try isVisible(conversation.id, identity: identity) else { continue }
            guard conversation.mode == .chat,
                  let value = try await snapshot(conversation, lastPayload: nil), !value.messages.isEmpty,
                  try encode(value).count <= 16_000_000 else { skipped += 1; continue }
            let project = allProjects.first { $0.id == conversation.projectID }
            if let project {
                guard try isVisible(project.id, identity: identity) else { skipped += 1; continue }
                projectSnapshots[project.id] = project
            }
            snapshots[value.id] = value
            items.append(.init(id: value.id, title: value.title, messages: value.messages,
                projectName: project?.name, projectInstructions: project?.instructions))
        }
        guard await currentAccount() == accountID else { throw AccountServiceError.revoked }
        return .init(id: UUID(), accountID: accountID, items: items, skippedConversations: skipped,
            profile: profile, snapshots: snapshots, projectSnapshots: projectSnapshots)
    }

    /// Copies only the reviewed selection into fresh account-owned IDs. Original
    /// local rows/ownership remain intact. Retrying the same preview is idempotent.
    /// A failure may retain already copied account rows; it never deletes either side.
    public func copyLocalToAccount(_ preview: LocalCopyPreview, selectedIDs: Set<UUID>,
        currentAccount: @Sendable () async -> UUID?) async throws -> Int {
        guard !busy, !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(preview.items.map(\.id))),
              await currentAccount() == preview.accountID,
              let sqlite = repository as? SQLiteConversationRepository else { throw AccountServiceError.conflict }
        busy = true; defer { busy = false }
        let sourceIdentity = AppIdentity.local(preview.profile)
        let currentProjects = try await projects.list()
        for id in selectedIDs {
            guard try isVisible(id, identity: sourceIdentity),
                  let conversation = try await repository.conversation(id: id), conversation.mode == .chat,
                  let latest = try await snapshot(conversation, lastPayload: nil),
                  let reviewed = preview.snapshots[id], try encode(latest) == encode(reviewed) else { throw AccountServiceError.conflict }
            if let projectID = conversation.projectID {
                guard currentProjects.first(where: { $0.id == projectID }) == preview.projectSnapshots[projectID] else { throw AccountServiceError.conflict }
            }
        }
        guard await currentAccount() == preview.accountID else { throw AccountServiceError.revoked }
        let key = "local-chat-copy.v1." + preview.accountID.uuidString + "." + preview.id.uuidString
        let plan: LocalCopyPlan
        if let data = try secureStore.readData(forKey: key) { plan = try JSONDecoder().decode(LocalCopyPlan.self, from: data) }
        else {
            plan = .init(conversations: Dictionary(uniqueKeysWithValues: preview.items.map { ($0.id, UUID()) }),
                projects: Dictionary(uniqueKeysWithValues: preview.projectSnapshots.keys.map { ($0, UUID()) }),
                messages: Dictionary(uniqueKeysWithValues: preview.snapshots.values.flatMap(\.messages).map { ($0.id, UUID()) }))
            try secureStore.store(JSONEncoder().encode(plan), forKey: key)
        }
        var copiedProjects: Set<UUID> = []
        for id in selectedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard await currentAccount() == preview.accountID else { throw AccountServiceError.revoked }
            guard var value = preview.snapshots[id], let destinationID = plan.conversations[id] else { throw AccountServiceError.conflict }
            if let sourceProjectID = value.projectID.flatMap(UUID.init(uuidString:)),
               var project = preview.projectSnapshots[sourceProjectID], let destinationProjectID = plan.projects[sourceProjectID] {
                if copiedProjects.insert(sourceProjectID).inserted {
                    project.id = destinationProjectID
                    // Machine folders and source documents require their own permissioned transfer.
                    if try await projects.list().contains(where: { $0.id == project.id }) == false {
                        try markOwned(project.id, accountID: preview.accountID)
                        try await projects.save(project)
                    }
                }
                value.projectID = destinationProjectID.uuidString
            }
            value.id = destinationID
            for index in value.messages.indices {
                let originalID = value.messages[index].id
                guard let messageID = plan.messages[originalID] else { throw AccountServiceError.conflict }
                value.messages[index].id = messageID
                var actionIDs: [String: String] = [:]
                value.messages[index].actions = value.messages[index].actions?.map { original in
                    var action = original
                    action.id = destinationID.uuidString + ":" + original.id
                    actionIDs[original.id] = action.id
                    action.conversationID = destinationID
                    action.turnID = plan.messages[original.turnID] ?? messageID
                    return action
                }
                if var timeline = value.messages[index].timeline {
                    for entry in timeline.entries.indices {
                        if let old = timeline.entries[entry].actionID { timeline.entries[entry].actionID = actionIDs[old] ?? old }
                    }
                    value.messages[index].timeline = timeline
                }
            }
            value.turns = value.turns.map { .init(id: plan.messages[$0.id] ?? $0.id, usage: $0.usage, estimatedUSD: $0.estimatedUSD, completedAt: $0.completedAt) }
            // Copying history is not a new execution on any device.
            value.executionDeviceIDs = nil; value.latestResponseVersion = nil
            if try await repository.conversation(id: destinationID) != nil {
                guard try isVisible(destinationID, accountID: preview.accountID) else { throw AccountServiceError.conflict }
                continue // A retry never overwrites a destination the person may have edited.
            }
            try markOwned(destinationID, accountID: preview.accountID)
            guard await currentAccount() == preview.accountID else { throw AccountServiceError.revoked }
            try await sqlite.mergePlainChat(value)
            for turn in value.turns where turn.completedAt != nil {
                let message = value.messages.first { $0.id == turn.id }
                try await metrics.save(.init(provider: value.provider.rawValue, modelID: value.modelID, mode: "chat",
                    startedAt: message?.createdAt ?? value.updatedAt, usage: turn.usage, totalSeconds: 0,
                    characters: message?.text.count ?? 0, costUSD: turn.estimatedUSD), messageID: turn.id, conversationID: destinationID)
            }
        }
        return selectedIDs.count
    }
}
