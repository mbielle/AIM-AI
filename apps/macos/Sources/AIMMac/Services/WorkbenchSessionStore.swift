import AIMCore
import AIMApplication
import Foundation

/// Side chats are temporary but survive hiding and app restarts until their tab is closed.
struct SavedWorkbenchTab: Codable, Equatable {
    let id: UUID
    let kind: WorkbenchPanelKind
    let draft: String
    let messages: [ConversationMessage]
    /// Optional so files written before tabs belonged to conversations still load.
    var conversationID: UUID?
    var messageID: UUID?
    var focusID: String?
    @MainActor init(_ tab: WorkbenchTab) {
        id = tab.id; kind = tab.kind; draft = tab.sideChat.draft
        conversationID = tab.conversationID; messageID = tab.messageID; focusID = tab.focusID
        var restored = tab.sideChat.messages
        // A half-produced answer must not become completed model context after a restart.
        if tab.sideChat.running, let last = restored.last, last.role == .assistant {
            restored[restored.count - 1].completionStatus = .cancelled
        }
        messages = restored
    }
    private init(id: UUID, kind: WorkbenchPanelKind, draft: String, messages: [ConversationMessage]) {
        self.id = id; self.kind = kind; self.draft = draft; self.messages = messages
    }
    @MainActor func restore() -> WorkbenchTab {
        let tab = WorkbenchTab(id: id, kind: kind, conversationID: conversationID)
        tab.messageID = messageID; tab.focusID = focusID
        tab.sideChat.draft = draft; tab.sideChat.messages = messages
        return tab
    }
}

struct WorkbenchSessionStore {
    var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: AIMInstallationContext.legacyDirectoryName + "/side-chats.json")
    func load() throws -> [SavedWorkbenchTab] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SavedWorkbenchTab].self, from: Data(contentsOf: url))
    }
    func save(_ tabs: [SavedWorkbenchTab]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Other tools keep live state while mounted. Side chats hold temporary user history; a Sources
        // tab only refers to an answer. Action details are not written to disk.
        try JSONEncoder().encode(tabs.filter { $0.kind == .sideChat || $0.kind == .sources }).write(to: url, options: .atomic)
    }
}
