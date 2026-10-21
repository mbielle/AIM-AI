import Foundation
import Darwin

/// Local, two-phase edits. Preparing never writes; callers must present the exact
/// before/after text and obtain approval before applying the opaque proposal ID.
public actor WorkspaceEditService {
    public struct Proposal: Codable, Identifiable, Sendable {
        public let id: UUID
        public let path: String
        public let before: String
        public let after: String
        public var isCreation: Bool = false
        public var isDeletion: Bool = false
    }

    /// Several files changed together: applied all-or-nothing, undone together.
    public struct PatchProposal: Codable, Identifiable, Sendable {
        public let id: UUID
        public let files: [Proposal]
    }

    public enum EditError: LocalizedError {
        case invalidPath, unsupportedFile, oversized, ambiguousMatch, overlappingEdits, stale, unknownProposal, capacity, tooManyEdits
        public var errorDescription: String? {
            switch self {
            case .invalidPath: "Choose a regular file inside the workspace; symbolic links are not editable."
            case .unsupportedFile: "Only UTF-8 text files with a single hard link can be edited."
            case .oversized: "This edit exceeds the 1 MB text limit."
            case .ambiguousMatch: "Each text to replace must occur exactly once in the current file (read it again and include more context)."
            case .overlappingEdits: "Two replacements overlap; merge them into one edit."
            case .tooManyEdits: "One edit holds at most 50 replacements; split them into several edits, or use propose_patch."
            case .stale: "The file changed after the preview. Prepare a new edit; nothing was overwritten."
            case .unknownProposal: "This edit is no longer available."
            case .capacity: "Too many prepared edits are waiting; apply or abandon some before preparing more (a patch holds at most 30 files)."
            }
        }
    }

    private struct Snapshot: Codable {
        let data: Data
        let permissions: Int
        let inode: UInt64
        let device: UInt64
    }
    private struct Entry: Codable {
        let proposal: Proposal
        let root: URL
        let url: URL
        let original: Snapshot?
        var applied: Snapshot?
    }
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private struct PatchEntry: Codable {
        let proposal: PatchProposal
        let items: [Entry]
        var applied: [Snapshot?]?
    }
    private var patches: [UUID: PatchEntry] = [:]
    private let limit = 1_000_000
    /// Unapplied proposals at once; applied ones are kept (for undo) up to `undoHistory`.
    private let pendingLimit = 32
    private let undoHistory = 200
    public init() {}

    private struct DurableState: Codable {
        var version: Int = 1
        var entries: [UUID: Entry]
        var order: [UUID]
        var patches: [UUID: PatchEntry]
    }
    public func exportState() throws -> Data {
        try JSONEncoder().encode(DurableState(entries: entries, order: order, patches: patches))
    }
    public func restoreState(_ data: Data, workspace: String) throws {
        let state = try JSONDecoder().decode(DurableState.self, from: data)
        guard state.version == 1, state.order.count <= undoHistory,
              state.entries.count + state.patches.count <= undoHistory else { throw EditError.capacity }
        let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let all = Array(state.entries.values) + state.patches.values.flatMap(\.items)
        for entry in all {
            guard entry.root == root, try target(root: root, path: entry.proposal.path, missingLeaf: true) == entry.url,
                  entry.proposal.before.utf8.count <= limit, entry.proposal.after.utf8.count <= limit,
                  (entry.original?.data.count ?? 0) <= limit, (entry.applied?.data.count ?? 0) <= limit else { throw EditError.invalidPath }
        }
        guard state.entries.allSatisfy({ $0.key == $0.value.proposal.id }),
              state.patches.allSatisfy({ $0.key == $0.value.proposal.id && $0.value.items.count == $0.value.proposal.files.count }) else { throw EditError.unknownProposal }
        entries = state.entries; order = state.order; patches = state.patches
    }

    /// Observation only. A partial or changed target stays ambiguous and is never replayed.
    public func reconcileApplied(_ id: UUID) throws -> Bool {
        if var entry = entries[id], !entry.proposal.isDeletion {
            guard try target(root: entry.root, path: entry.proposal.path, missingLeaf: true) == entry.url else { return false }
            let current = try snapshot(entry.url)
            guard current.data == Data(entry.proposal.after.utf8) else { return false }
            entry.applied = current; entries[id] = entry; return true
        }
        guard var patch = patches[id] else { return false }
        var observations: [Snapshot?] = []
        for entry in patch.items {
            let url = try target(root: entry.root, path: entry.proposal.path, missingLeaf: true)
            guard url == entry.url else { return false }
            if entry.proposal.isDeletion {
                var info = stat()
                guard lstat(url.path, &info) != 0, errno == ENOENT else { return false }
                observations.append(nil)
            } else {
                let current = try snapshot(url)
                guard current.data == Data(entry.proposal.after.utf8) else { return false }
                observations.append(current)
            }
        }
        patch.applied = observations; patches[id] = patch; return true
    }

    private func reserveCapacity() throws {
        let pending = entries.values.filter { $0.applied == nil }.count + patches.values.filter { $0.applied == nil }.count
        guard pending < pendingLimit else { throw EditError.capacity }
        while order.count >= undoHistory, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
            patches.removeValue(forKey: oldest)
        }
    }

    private func remember(_ id: UUID) { order.append(id) }

    public func prepare(workspace: String, path: String, replacing old: String, with replacement: String) throws -> Proposal {
        try prepare(workspace: workspace, path: path, edits: [(old, replacement)])
    }

    /// Several replacements in one file, each matched exactly once against the
    /// current text and not overlapping; all are applied together.
    public func prepare(workspace: String, path: String, edits: [(old: String, new: String)]) throws -> Proposal {
        try reserveCapacity()
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        let url = try target(root: root, path: path)
        let original = try snapshot(url)
        guard let before = String(data: original.data, encoding: .utf8), !original.data.contains(0) else { throw EditError.unsupportedFile }
        guard !edits.isEmpty else { throw EditError.ambiguousMatch }
        guard edits.count <= 50 else { throw EditError.tooManyEdits }
        var ranges: [(Range<String.Index>, String)] = []
        for edit in edits {
            guard !edit.old.isEmpty, before.components(separatedBy: edit.old).count == 2,
                  let range = before.range(of: edit.old) else { throw EditError.ambiguousMatch }
            ranges.append((range, edit.new))
        }
        ranges.sort { $0.0.lowerBound < $1.0.lowerBound }
        for (previous, next) in zip(ranges, ranges.dropFirst()) where previous.0.upperBound > next.0.lowerBound {
            throw EditError.overlappingEdits
        }
        var after = before
        for (range, replacement) in ranges.reversed() {
            let lower = after.index(after.startIndex, offsetBy: before.distance(from: before.startIndex, to: range.lowerBound))
            let upper = after.index(lower, offsetBy: before.distance(from: range.lowerBound, to: range.upperBound))
            after.replaceSubrange(lower..<upper, with: replacement)
        }
        guard after.utf8.count <= limit, !after.utf8.contains(0) else { throw EditError.oversized }
        let proposal = Proposal(id: UUID(), path: path, before: before, after: after)
        entries[proposal.id] = Entry(proposal: proposal, root: root, url: url, original: original)
        remember(proposal.id)
        return proposal
    }

    public func discard(_ id: UUID) { entries.removeValue(forKey: id) }

    public func prepareCreation(workspace: String, path: String, content: String) throws -> Proposal {
        try reserveCapacity()
        guard content.utf8.count <= limit, !content.utf8.contains(0) else { throw EditError.oversized }
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        let url = try target(root: root, path: path, missingLeaf: true)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else { throw EditError.stale }
        let proposal = Proposal(id: UUID(), path: path, before: "", after: content, isCreation: true)
        entries[proposal.id] = Entry(proposal: proposal, root: root, url: url, original: nil)
        remember(proposal.id)
        return proposal
    }

    /// Prepares a multi-file patch; nothing is written until applyPatch.
    public func preparePatch(workspace: String, changes: [WorkspacePatch.Change]) throws -> PatchProposal {
        try reserveCapacity()
        guard (1...30).contains(changes.count) else { throw EditError.capacity }
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        var items: [Entry] = []
        for change in changes {
            switch change {
            case .add(let path, let content):
                guard content.utf8.count <= limit, !content.utf8.contains(0) else { throw EditError.oversized }
                let url = try target(root: root, path: path, missingLeaf: true)
                guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else { throw EditError.stale }
                items.append(Entry(proposal: Proposal(id: UUID(), path: path, before: "", after: content, isCreation: true),
                                   root: root, url: url, original: nil))
            case .update(let path, let chunks):
                let url = try target(root: root, path: path)
                let original = try snapshot(url)
                guard let before = String(data: original.data, encoding: .utf8), !original.data.contains(0) else { throw EditError.unsupportedFile }
                let after = try WorkspacePatch.apply(chunks, to: before, path: path)
                guard after.utf8.count <= limit else { throw EditError.oversized }
                items.append(Entry(proposal: Proposal(id: UUID(), path: path, before: before, after: after),
                                   root: root, url: url, original: original))
            case .delete(let path):
                let url = try target(root: root, path: path)
                let original = try snapshot(url)
                let before = String(data: original.data, encoding: .utf8) ?? "(binary file)"
                items.append(Entry(proposal: Proposal(id: UUID(), path: path, before: before, after: "", isDeletion: true),
                                   root: root, url: url, original: original))
            }
        }
        guard Set(items.map(\.url)).count == items.count else { throw EditError.invalidPath }
        let proposal = PatchProposal(id: UUID(), files: items.map(\.proposal))
        patches[proposal.id] = PatchEntry(proposal: proposal, items: items, applied: nil)
        remember(proposal.id)
        return proposal
    }

    public func patchProposal(_ id: UUID) -> PatchProposal? { patches[id]?.proposal }
    public func isPatchApplied(_ id: UUID) -> Bool { patches[id]?.applied != nil }

    /// Checks every file first, then writes them; a failure restores what was written.
    public func applyPatch(_ id: UUID) throws {
        guard var patch = patches[id], patch.applied == nil else { throw EditError.unknownProposal }
        try Task.checkCancellation()
        for item in patch.items {
            if let original = item.original {
                let current = try snapshot(try target(root: item.root, path: item.proposal.path))
                guard current.data == original.data, current.inode == original.inode else { throw EditError.stale }
            } else {
                _ = try target(root: item.root, path: item.proposal.path, missingLeaf: true)
                guard (try? FileManager.default.attributesOfItem(atPath: item.url.path)) == nil else { throw EditError.stale }
            }
        }
        var written: [(Entry, Snapshot?)] = []
        do {
            for item in patch.items {
                if item.proposal.isDeletion, let original = item.original {
                    try trashCreatedFile(item, expected: original)
                    written.append((item, nil))
                } else if let original = item.original {
                    written.append((item, try replace(item, expected: original, data: Data(item.proposal.after.utf8))))
                } else {
                    written.append((item, try create(item)))
                }
            }
        } catch {
            for (item, snapshot) in written.reversed() { try? restore(item, from: snapshot) }
            throw error
        }
        patch.applied = written.map(\.1)
        patches[id] = patch
    }

    public func undoPatch(_ id: UUID) throws {
        guard let patch = patches[id], let applied = patch.applied else { throw EditError.unknownProposal }
        for (item, snapshot) in zip(patch.items, applied).reversed() { try restore(item, from: snapshot) }
        patches.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    /// Reverts one file of a patch to its original state.
    private func restore(_ item: Entry, from applied: Snapshot?) throws {
        if item.proposal.isDeletion, let original = item.original {
            // The file went to the Trash; recreate it with its original bytes and mode.
            guard (try? FileManager.default.attributesOfItem(atPath: item.url.path)) == nil else { throw EditError.stale }
            try original.data.write(to: item.url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: original.permissions], ofItemAtPath: item.url.path)
        } else if let original = item.original, let applied {
            _ = try replace(item, expected: applied, data: original.data)
        } else if let applied {
            try trashCreatedFile(item, expected: applied)
        }
    }

    public func apply(_ id: UUID) throws {
        guard var entry = entries[id], entry.applied == nil else { throw EditError.unknownProposal }
        try Task.checkCancellation()
        let result: Snapshot
        if let original = entry.original {
            result = try replace(entry, expected: original, data: Data(entry.proposal.after.utf8))
        } else {
            result = try create(entry)
        }
        entry.applied = result
        entries[id] = entry
    }

    public func undo(_ id: UUID) throws {
        guard let entry = entries[id], let applied = entry.applied else { throw EditError.unknownProposal }
        try Task.checkCancellation()
        if let original = entry.original {
            _ = try replace(entry, expected: applied, data: original.data)
        } else {
            try trashCreatedFile(entry, expected: applied)
        }
        entries.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    private func replace(_ entry: Entry, expected: Snapshot, data: Data) throws -> Snapshot {
        // Coordinates with document-based editors. This is not a sandbox against
        // hostile processes that ignore NSFileCoordinator and mutate paths concurrently.
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var outcome: Result<Snapshot, Error>?
        coordinator.coordinate(writingItemAt: entry.url, options: .forReplacing, error: &coordinationError) { url in
            outcome = Result {
                guard try target(root: entry.root, path: entry.proposal.path) == entry.url else { throw EditError.invalidPath }
                let current = try snapshot(url)
                guard current.data == expected.data, current.inode == expected.inode,
                      current.device == expected.device, current.permissions == expected.permissions else { throw EditError.stale }
                try Task.checkCancellation()
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: expected.permissions], ofItemAtPath: url.path)
                return try snapshot(url)
            }
        }
        if let outcome { return try outcome.get() }
        throw coordinationError ?? NSError(domain: "WorkspaceEdit", code: 1)
    }

    private func create(_ entry: Entry) throws -> Snapshot {
        let url = try target(root: entry.root, path: entry.proposal.path, missingLeaf: true)
        // Fully write a private sibling before publishing. link() fails if any
        // destination entry exists, including a dangling symlink; no overwrite race.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".aim-create-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: Data(entry.proposal.after.utf8))
        try handle.synchronize()
        try Task.checkCancellation()
        _ = try target(root: entry.root, path: entry.proposal.path, missingLeaf: true)
        guard Darwin.link(temporary.path, url.path) == 0 else {
            if errno == EEXIST { throw EditError.stale }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.removeItem(at: temporary)
        return try snapshot(url)
    }

    private func trashCreatedFile(_ entry: Entry, expected: Snapshot) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: entry.url, options: .forDeleting, error: &coordinationError) { url in
            outcome = Result {
                _ = try target(root: entry.root, path: entry.proposal.path)
                let current = try snapshot(url)
                guard current.data == expected.data, current.inode == expected.inode,
                      current.device == expected.device, current.permissions == expected.permissions else { throw EditError.stale }
                try Task.checkCancellation()
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        if let outcome { return try outcome.get() }
        throw coordinationError ?? NSError(domain: "WorkspaceEdit", code: 2)
    }

    private func target(root: URL, path: String, missingLeaf: Bool = false) throws -> URL {
        guard !path.isEmpty, !path.contains("\0") else { throw EditError.invalidPath }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw EditError.invalidPath }
        var component = missingLeaf ? url.deletingLastPathComponent() : url
        while component != root {
            let attributes = try FileManager.default.attributesOfItem(atPath: component.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw EditError.invalidPath }
            component.deleteLastPathComponent()
        }
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else { throw EditError.invalidPath }
        return url
    }

    private func snapshot(_ url: URL) throws -> Snapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw EditError.unsupportedFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw EditError.oversized }
        return Snapshot(data: data, permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600,
                        inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                        device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}
