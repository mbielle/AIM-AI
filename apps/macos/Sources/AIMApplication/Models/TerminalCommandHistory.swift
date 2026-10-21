import Foundation

/// Session-only history: never persisted, uploaded or shared across workspaces.
public struct TerminalCommandHistory: Sendable {
    public private(set) var commands: [String] = []
    private var position: Int?
    private var draft = ""
    public init() {}

    public mutating func record(_ command: String) {
        position = nil; draft = ""
        guard !command.isEmpty, command.utf8.count <= 4_096, commands.last != command else { return }
        commands.append(command)
        if commands.count > 50 { commands.removeFirst(commands.count - 50) }
    }
    public mutating func previous(current: String) -> String? {
        guard !commands.isEmpty else { return nil }
        if position == nil { draft = current; position = commands.count }
        position = max(0, position! - 1)
        return commands[position!]
    }
    public mutating func next() -> String? {
        guard let position else { return nil }
        if position + 1 >= commands.count { self.position = nil; return draft }
        self.position = position + 1
        return commands[position + 1]
    }
    public mutating func resetNavigation() { position = nil; draft = "" }
    public mutating func clear() { self = .init() }
}
