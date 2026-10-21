import AppKit
import SwiftUI

/// An actual scrolling editor, rather than a clipped multiline text field.
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    /// Settings › General: ⌘↩ sends (Return inserts a line), or Return sends.
    var sendWithCommandReturn = false
    var smartPunctuation = false
    /// `alternate`: the other send key (opposite follow-up while a task runs).
    var onSubmit: (_ alternate: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.focusRingType = .none
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = SubmitTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = .systemFont(ofSize: 16)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("aim-composer")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? SubmitTextView else { return }
        editor.submit = onSubmit
        editor.sendWithCommandReturn = sendWithCommandReturn
        if editor.isAutomaticQuoteSubstitutionEnabled != smartPunctuation {
            editor.isAutomaticQuoteSubstitutionEnabled = smartPunctuation
            editor.isAutomaticDashSubstitutionEnabled = smartPunctuation
            editor.isAutomaticTextReplacementEnabled = smartPunctuation
        }
        editor.setAccessibilityLabel(placeholder)
        if editor.string != text { editor.string = text }
        context.coordinator.measure(editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        init(_ parent: ComposerTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
            layout.ensureLayout(for: container)
            let next = min(220, max(36, ceil(layout.usedRect(for: container).height) + 10))
            if abs(parent.height - next) > 1 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = next }
            }
        }
    }
    final class SubmitTextView: NSTextView {
        var submit: ((Bool) -> Void)?
        var sendWithCommandReturn = false
        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 36 || event.keyCode == 76, !flags.contains(.shift), !hasMarkedText() else {
                super.keyDown(with: event); return
            }
            if sendWithCommandReturn {
                // ⌘↩ sends, ⌥⌘↩ is the alternate, plain Return inserts a line.
                if flags.contains(.command) { submit?(flags.contains(.option)) } else { super.keyDown(with: event) }
            } else {
                submit?(flags.contains(.command))
            }
        }
        // Smart punctuation: "..." becomes an ellipsis as you type.
        override func insertText(_ string: Any, replacementRange: NSRange) {
            super.insertText(string, replacementRange: replacementRange)
            guard isAutomaticQuoteSubstitutionEnabled, (string as? String) == ".", let storage = textStorage else { return }
            let location = selectedRange().location
            guard location >= 3, storage.string.utf16.count >= location,
                  (storage.string as NSString).substring(with: NSRange(location: location - 3, length: 3)) == "..." else { return }
            insertText("…", replacementRange: NSRange(location: location - 3, length: 3))
        }
    }
}
