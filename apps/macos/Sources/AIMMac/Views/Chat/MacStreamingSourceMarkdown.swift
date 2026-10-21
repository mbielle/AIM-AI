import AIMApplication
import AIMCore
import SwiftUI

struct MacStreamingSourceMarkdown: View {
    let text: String
    let sources: [ConversationSource]?
    let appearance: ConversationAppearance
    let searchQuery: String
    let messageID: UUID
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var display = StreamingTextPresentation()
    @State private var mounted = false
    var body: some View {
        MacSourceMarkdown(text: mounted ? display.visible : text, sources: sources, appearance: appearance,
                          searchQuery: searchQuery, messageID: messageID)
            .onAppear { display.update(text, animated: false); mounted = true }
            .onChange(of: text) { _, text in display.update(text, animated: live && !reduceMotion) }
            .onChange(of: reduceMotion) { _, reduced in if reduced { display.update(text, animated: false) } }
            .task(id: live) {
                guard live else { display.update(text, animated: false); return }
                while !Task.isCancelled {
                    if !display.isSettled { display.advance() }
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                }
            }
    }
}
