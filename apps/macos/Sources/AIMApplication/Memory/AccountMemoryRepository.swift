import AIMCore
import Foundation

public struct AccountMemoryBinding: Sendable {
    public let accountID: UUID
    public let service: any AccountContentSyncing
    public init(accountID: UUID, service: any AccountContentSyncing) { self.accountID = accountID; self.service = service }
}
public enum AccountMemoryOwner: Equatable, Sendable {
    case local
    case account(UUID)
}

/// Local historical entries stay in the original repository. An account adopts only selected entries.
///
/// Local first (Round 37): the account's memory is kept on this Mac. Agents read it without waiting
/// for the network (refreshed in the background); a change made while the account is unreachable is
/// kept here and sent later instead of failing. A real conflict (another device changed the same
/// memory) still refuses the write and the copy is read again.
public actor AccountMemoryRepository: MemoryRepository {
    private let legacy: any MemoryRepository
    private let binding: @Sendable () async throws -> AccountMemoryBinding?
    private let cache: (any AccountMemoryCaching)?
    private var refreshing: Set<UUID> = []
    private var lastFlushAttempt: [UUID: Date] = [:]
    /// A copy younger than this is used without asking the account.
    static let freshness: TimeInterval = 30
    public init(legacy: any MemoryRepository, binding: @escaping @Sendable () async throws -> AccountMemoryBinding?,
                cache: (any AccountMemoryCaching)? = nil) {
        self.legacy = legacy; self.binding = binding; self.cache = cache
    }
    /// The account's memory as the account holds it now (Settings): asked from the account, with
    /// this Mac's copy (and its unsent changes) when the account cannot be reached.
    public func snapshot() async throws -> AccountMemorySnapshot? {
        guard let bound = try await binding() else { return nil }
        await flushIfNeeded(bound)
        do { return try await load(bound) }
        catch let error where Self.isUnreachable(error) {
            guard let copy = try? await cache?.record(accountID: bound.accountID)?.effective else { throw error }
            return copy
        }
    }
    /// What agents read: this Mac's copy at once, refreshed in the background when older than
    /// `freshness`; the account is asked directly only when no copy exists yet.
    private func readable(_ bound: AccountMemoryBinding) async throws -> AccountMemorySnapshot {
        if let cache, let record = try? await cache.record(accountID: bound.accountID), let copy = record.effective {
            if Date.now.timeIntervalSince(record.refreshedAt) > Self.freshness { startRefresh(bound) }
            return copy
        }
        return try await load(bound)
    }
    private func startRefresh(_ bound: AccountMemoryBinding) {
        guard refreshing.insert(bound.accountID).inserted else { return }
        Task { [self] in
            await flushIfNeeded(bound, force: true)
            _ = try? await load(bound)
            await finishRefresh(bound.accountID)
        }
    }
    private func finishRefresh(_ accountID: UUID) { refreshing.remove(accountID) }
    private func load(_ bound: AccountMemoryBinding) async throws -> AccountMemorySnapshot {
        let value = try await AccountMemoryService(accountID: bound.accountID, service: bound.service).load()
        guard try await binding()?.accountID == bound.accountID else { throw AccountServiceError.conflict }
        await remember(value, accountID: bound.accountID)
        return value
    }
    private func commit(_ snapshot: AccountMemorySnapshot, bound: AccountMemoryBinding) async throws {
        guard try await binding()?.accountID == bound.accountID else { throw AccountServiceError.conflict }
        do {
            let saved = try await AccountMemoryService(accountID: bound.accountID, service: bound.service).save(snapshot)
            await remember(saved, accountID: bound.accountID)
        } catch AccountServiceError.conflict {
            // Another device changed it: this copy is out of date and is read again next time.
            try? await cache?.remove(accountID: bound.accountID)
            throw AccountServiceError.conflict
        }
    }
    /// Keeps the account's latest memory on this Mac, with any change still waiting to be sent.
    private func remember(_ snapshot: AccountMemorySnapshot, accountID: UUID) async {
        guard let cache else { return }
        let pending = (try? await cache.record(accountID: accountID))?.pending ?? []
        try? await cache.store(.init(snapshot: snapshot, pending: pending, refreshedAt: .now), accountID: accountID)
    }
    /// A timeout or network failure, not a refusal: the change can wait on this Mac.
    static func isUnreachable(_ error: Error) -> Bool {
        if case AccountServiceError.unavailable = error { return true }
        return error is URLError
    }
    /// Keeps changes made while the account is unreachable; they are sent by `flushPending`.
    private func keepForLater(_ changes: [AccountMemoryPendingChange], bound: AccountMemoryBinding,
                              base: AccountMemorySnapshot?) async throws {
        guard let cache, !changes.isEmpty else { throw AccountServiceError.unavailable }
        var record = (try? await cache.record(accountID: bound.accountID)) ?? AccountMemoryCacheRecord(snapshot: base, pending: [], refreshedAt: .distantPast)
        if record.snapshot == nil { record.snapshot = base ?? AccountMemorySnapshot() }
        record.pending += changes
        try await cache.store(record, accountID: bound.accountID)
    }
    /// Sends the changes kept while the account was unreachable, replayed on its latest memory.
    /// Called in the background (account sync, reads); a failure leaves them for the next attempt.
    public func flushPending() async {
        guard let bound = try? await binding() else { return }
        await flushIfNeeded(bound, force: true)
    }
    private func flushIfNeeded(_ bound: AccountMemoryBinding, force: Bool = false) async {
        guard let cache, let record = try? await cache.record(accountID: bound.accountID), !record.pending.isEmpty else { return }
        if !force, let last = lastFlushAttempt[bound.accountID], Date.now.timeIntervalSince(last) < 30 { return }
        lastFlushAttempt[bound.accountID] = .now
        for _ in 0..<3 {
            guard let remote = try? await AccountMemoryService(accountID: bound.accountID, service: bound.service).load(),
                  (try? await binding())??.accountID == bound.accountID else { return }
            let merged = AccountMemoryPendingChange.apply(record.pending, to: remote)
            do {
                let saved = merged == remote ? remote
                    : try await AccountMemoryService(accountID: bound.accountID, service: bound.service).save(merged)
                // Changes made meanwhile on this Mac stay pending.
                let latest = (try? await cache.record(accountID: bound.accountID))?.pending ?? []
                try? await cache.store(.init(snapshot: saved, pending: Array(latest.dropFirst(record.pending.count)), refreshedAt: .now),
                                       accountID: bound.accountID)
                return
            } catch AccountServiceError.conflict { continue }
            catch { return }
        }
    }
    public func setEnabled(_ enabled: Bool, expectedRevision: Int?, expectedOwner: AccountMemoryOwner? = nil) async throws {
        guard let bound = try await binding() else { return }
        try checkOwner(expectedOwner, bound: bound)
        var snapshot = try await load(bound)
        if let expectedRevision, snapshot.revision != expectedRevision { throw AccountServiceError.conflict }
        snapshot.enabled = enabled
        try await commit(snapshot, bound: bound)
    }
    public func list(status: MemoryStatus?) async throws -> [MemoryItem] {
        guard let bound = try await binding() else { return try await legacy.list(status: status) }
        return try await readable(bound).entries.compactMap(Self.item).filter { status == nil || $0.status == status }
    }
    /// An automatic proposal never gains a newer revision by re-reading before save.
    /// Reviewed facts, archives and corrections are preserved by the shared merge policy.
    public func saveCaptured(_ proposals: [MemoryItem], expectedOwner: AccountMemoryOwner?, explicit: Bool = false) async throws -> Int {
        let current = try await binding()
        try checkOwner(expectedOwner, bound: current)
        let original: AccountMemorySnapshot
        if let current {
            do { original = try await load(current) }
            catch let error where Self.isUnreachable(error) {
                // Unreachable account: the capture is applied to this Mac's copy and sent later.
                guard let copy = try? await cache?.record(accountID: current.accountID)?.effective else { throw error }
                let proposed = AccountMemoryCapture.adding(proposals.map(Self.entry), to: copy, explicit: explicit)
                let existing = Dictionary(copy.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let changed = proposed.entries.filter { existing[$0.id] != $0 }
                try await keepForLater(changed.map(AccountMemoryPendingChange.upsert), bound: current, base: copy)
                return changed.count
            }
        } else {
            var local = AccountMemorySnapshot(); local.enabled = true
            local.entries = try await legacy.list(status: nil).map(Self.entry)
            original = local
        }
        try Task.checkCancellation()
        let proposed = AccountMemoryCapture.adding(proposals.map(Self.entry), to: original, explicit: explicit)
        guard proposed != original else { return 0 }
        let existing = Dictionary(original.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = proposed.entries.filter { existing[$0.id] != $0 }
        if let current {
            try Task.checkCancellation()
            try await commit(proposed, bound: current)
        } else {
            // Historical local capture stays local even if login occurs during a legacy actor call.
            for entry in changed {
                try Task.checkCancellation()
                guard try await binding() == nil, let item = Self.item(entry) else { throw AccountServiceError.conflict }
                try await legacy.save(item)
            }
        }
        return changed.count
    }
    public func save(_ item: MemoryItem) async throws { try await save(item, expectedRevision: nil, expectedOwner: nil, allowDisabled: false) }
    public func save(_ item: MemoryItem, expectedRevision: Int?, expectedOwner: AccountMemoryOwner? = nil) async throws {
        try await save(item, expectedRevision: expectedRevision, expectedOwner: expectedOwner, allowDisabled: true)
    }
    private func save(_ item: MemoryItem, expectedRevision: Int?, expectedOwner: AccountMemoryOwner?, allowDisabled: Bool) async throws {
        try MemoryContext.validate(item)
        let current = try await binding()
        try checkOwner(expectedOwner, bound: current)
        guard let bound = current else { return try await legacy.save(item) }
        let entry = Self.entry(item)
        var snapshot: AccountMemorySnapshot
        do { snapshot = try await load(bound) }
        catch let error where Self.isUnreachable(error) && expectedRevision == nil {
            // An agent's or capture's save while the account is unreachable waits on this Mac.
            let copy = try? await cache?.record(accountID: bound.accountID)?.effective
            guard copy?.enabled ?? true || allowDisabled else { throw AccountServiceError.unavailable }
            try await keepForLater([.upsert(entry)], bound: bound, base: copy)
            return
        }
        guard snapshot.enabled || allowDisabled else { throw AccountServiceError.unavailable }
        if let expectedRevision, snapshot.revision != expectedRevision { throw AccountServiceError.conflict }
        if let i = snapshot.entries.firstIndex(where: { $0.id == item.id }) { snapshot.entries[i] = entry }
        else { snapshot.entries.append(entry) }
        do { try await commit(snapshot, bound: bound) }
        catch let error where Self.isUnreachable(error) && expectedRevision == nil {
            try await keepForLater([.upsert(entry)], bound: bound, base: snapshot)
        }
    }
    public func archive(id: UUID) async throws {
        guard let bound = try await binding() else { return try await legacy.archive(id: id) }
        var snapshot: AccountMemorySnapshot
        do { snapshot = try await load(bound) }
        catch let error where Self.isUnreachable(error) {
            guard let copy = try? await cache?.record(accountID: bound.accountID)?.effective else { throw error }
            snapshot = copy
        }
        guard let i = snapshot.entries.firstIndex(where: { $0.id == id }) else { throw AccountServiceError.conflict }
        snapshot.entries[i].archived = true; snapshot.entries[i].reviewStatus = "archived"; snapshot.entries[i].updatedAt = .now
        do { try await commit(snapshot, bound: bound) }
        catch let error where Self.isUnreachable(error) {
            try await keepForLater([.upsert(snapshot.entries[i])], bound: bound, base: snapshot)
        }
    }
    public func delete(id: UUID) async throws {
        guard let bound = try await binding() else { return try await legacy.delete(id: id) }
        do {
            var snapshot = try await load(bound); snapshot.entries.removeAll { $0.id == id }
            try await commit(snapshot, bound: bound)
        } catch let error where Self.isUnreachable(error) {
            try await keepForLater([.remove(id)], bound: bound, base: try? await cache?.record(accountID: bound.accountID)?.effective)
        }
    }
    public func consolidateDuplicates(keeping: UUID, archiving: [UUID]) async throws {
        guard let bound = try await binding() else { return try await legacy.consolidateDuplicates(keeping: keeping, archiving: archiving) }
        var snapshot = try await load(bound)
        let ids = Set(archiving + [keeping]), items = snapshot.entries.filter { ids.contains($0.id) }.compactMap(Self.item)
        guard items.count == ids.count, let original = items.first(where: { $0.id == keeping }),
              items.allSatisfy({ $0.kind == original.kind && $0.scope == original.scope && $0.scopeKey == original.scopeKey && $0.content == original.content }) else { throw MemoryConsolidationError.staleProposal }
        for i in snapshot.entries.indices where ids.contains(snapshot.entries[i].id) {
            snapshot.entries[i].archived = snapshot.entries[i].id != keeping
            snapshot.entries[i].reviewed = snapshot.entries[i].id == keeping
            snapshot.entries[i].reviewStatus = snapshot.entries[i].id == keeping ? "verified" : "archived"
            snapshot.entries[i].updatedAt = .now
        }
        try await commit(snapshot, bound: bound)
    }
    public func search(_ query: String, limit: Int) async throws -> [MemoryItem] { try await searchScoped(query, projectID: nil, includeGlobal: true, limit: limit) }
    public func searchScoped(_ query: String, projectID: UUID?, includeGlobal: Bool, limit: Int) async throws -> [MemoryItem] {
        guard let bound = try await binding() else { return try await legacy.searchScoped(query, projectID: projectID, includeGlobal: includeGlobal, limit: limit) }
        let snapshot = try await readable(bound)
        guard snapshot.enabled else { return [] }
        return HybridMemorySearch.ranked(Self.active(snapshot), query: query, projectID: projectID, includeGlobal: includeGlobal, limit: limit)
    }
    public func contextCandidates(_ query: String, projectID: UUID?, includeGlobal: Bool) async throws -> [MemoryItem] {
        guard let bound = try await binding() else { return try await legacy.contextCandidates(query, projectID: projectID, includeGlobal: includeGlobal) }
        let snapshot = try await readable(bound)
        guard snapshot.enabled else { return [] }
        return HybridMemorySearch.ranked(Self.active(snapshot), query: query, projectID: projectID, includeGlobal: includeGlobal,
                                         limit: 48, includeProfile: true)
    }
    /// Reviewed and AI-extracted entries alike (the context labels them); never archived ones.
    private static func active(_ snapshot: AccountMemorySnapshot) -> [MemoryItem] {
        snapshot.entries.filter { !$0.archived && $0.reviewStatus != "archived" }.compactMap(item)
    }
    public func legacyPreview() async throws -> [MemoryItem] { try await legacy.list(status: nil) }
    public func importSelected(_ ids: Set<UUID>, expectedRevision: Int?, expectedOwner: AccountMemoryOwner? = nil) async throws {
        guard let bound = try await binding() else { throw AccountServiceError.unavailable }
        try checkOwner(expectedOwner, bound: bound)
        var snapshot = try await load(bound)
        if let expectedRevision, snapshot.revision != expectedRevision { throw AccountServiceError.conflict }
        for item in try await legacy.list(status: nil) where ids.contains(item.id) && !snapshot.entries.contains(where: { $0.id == item.id }) {
            try MemoryContext.validate(item); snapshot.entries.append(Self.entry(item))
        }
        try await commit(snapshot, bound: bound)
    }
    private func checkOwner(_ expected: AccountMemoryOwner?, bound: AccountMemoryBinding?) throws {
        guard let expected else { return }
        let current = bound.map { AccountMemoryOwner.account($0.accountID) } ?? .local
        guard expected == current else { throw AccountServiceError.conflict }
    }
    public static func entry(_ item: MemoryItem) -> AccountMemoryEntry {
        .init(id: item.id, subject: item.subjectKey, content: item.content,
            projectID: item.scope == "project" ? UUID(uuidString: item.scopeKey) : nil,
            sourceID: item.sourceMessageID?.uuidString, evidence: item.evidenceQuote,
            reviewed: item.status == .verified, pinned: item.isPinned, archived: item.status == .archived,
            kind: item.kind.rawValue, scope: item.scope, scopeKey: item.scopeKey, reviewStatus: item.status.rawValue,
            confidence: item.confidence, createdAt: item.createdAt, updatedAt: item.updatedAt)
    }
    public static func item(_ entry: AccountMemoryEntry) -> MemoryItem? {
        guard entry.scope == nil || ["global", "project"].contains(entry.scope!) else { return nil }
        let status = entry.reviewStatus.flatMap(MemoryStatus.init(rawValue:)) ?? (entry.archived ? .archived : (entry.reviewed ? .verified : .provisional))
        return .init(id: entry.id, kind: entry.kind.flatMap(MemoryKind.init(rawValue:)) ?? .fact,
            scope: entry.projectID == nil ? "global" : "project", scopeKey: entry.projectID?.uuidString ?? entry.scopeKey ?? "self",
            subjectKey: entry.subject, content: entry.content, evidenceQuote: entry.evidence,
            sourceMessageID: entry.sourceID.flatMap(UUID.init(uuidString:)), status: status, confidence: entry.confidence ?? 1,
            isPinned: entry.pinned, createdAt: entry.createdAt ?? .distantPast, updatedAt: entry.updatedAt ?? .distantPast)
    }
}
