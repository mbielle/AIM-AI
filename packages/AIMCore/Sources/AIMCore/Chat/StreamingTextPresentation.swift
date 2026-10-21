import Foundation

/// Presentation only: reveal bursts over at most six display frames. The stored
/// response and transport events are never slowed, truncated or rewritten.
public struct StreamingTextPresentation: Sendable {
    public private(set) var visible = ""
    private var target = ""
    private var characters: [Character] = []
    private var count = 0
    private var frames = 0
    public init() {}
    public var isSettled: Bool { count == characters.count }

    public mutating func update(_ text: String, animated: Bool) {
        guard text != target else {
            if !animated { visible = text; count = characters.count; frames = 0 }
            return
        }
        let extendsVisible = text.hasPrefix(visible)
        target = text; characters = Array(text)
        if !animated || !extendsVisible {
            visible = text; count = characters.count; frames = 0
        } else {
            frames = 6
        }
    }

    public mutating func advance() {
        guard !isSettled else { return }
        let remaining = characters.count - count
        let step = max(1, (remaining + max(1, frames) - 1) / max(1, frames))
        visible.append(contentsOf: characters[count..<min(characters.count, count + step)])
        count += step; frames = max(0, frames - 1)
    }
}
