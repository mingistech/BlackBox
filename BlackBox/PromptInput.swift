import SwiftUI

struct PromptInput: View {
    @Binding var text: String
    let isEnabled: Bool
    let send: () -> Void
    let previous: () -> String?
    let next: () -> String?
    @State private var height: CGFloat = 48

    var body: some View {
        PromptTextEditor(text: $text, height: $height, isEnabled: isEnabled,
                         send: send, previous: previous, next: next)
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Describe a task or ask a question")
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }
            .help("Return to send. Shift-Return for a new line. Up/Down to browse sent prompts at the first/last line.")
    }
}

private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEnabled: Bool
    let send: () -> Void
    let previous: () -> String?
    let next: () -> String?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = HistoryTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Describe a task or ask a question")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? HistoryTextView else { return }
        editor.isEditable = isEnabled
        editor.sendPrompt = send
        editor.previousPrompt = previous
        editor.nextPrompt = next
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        context.coordinator.measure(editor)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextEditor
        init(parent: PromptTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let size = min(112, max(48, ceil(layout.usedRect(for: container).height)))
            if parent.height != size {
                DispatchQueue.main.async { [weak self] in self?.parent.height = size }
            }
        }
    }
}

private final class HistoryTextView: NSTextView {
    var sendPrompt: (() -> Void)?
    var previousPrompt: (() -> String?)?
    var nextPrompt: (() -> String?)?

    override func keyDown(with event: NSEvent) {
        // Arrow events carry function/numeric-pad flags on macOS. Only actual
        // shortcut modifiers should prevent plain Up/Down history navigation.
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if isEditable, !hasMarkedText(), modifiers.isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 {
                sendPrompt?()
                return
            }
            let up = event.keyCode == 126
            if (up || event.keyCode == 125), atBoundary(up: up),
               let recalled = up ? previousPrompt?() : nextPrompt?() {
                string = recalled
                setSelectedRange(NSRange(location: (recalled as NSString).length, length: 0))
                didChangeText()
                scrollRangeToVisible(selectedRange())
                return
            }
        }
        super.keyDown(with: event)
    }

    private func atBoundary(up: Bool) -> Bool {
        let text = string as NSString
        let selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return false }
        // Compare rendered line positions so soft-wrapped lines also retain navigation.
        let caret = up ? selection.location : NSMaxRange(selection)
        let edge = up ? 0 : text.length
        let caretRect = firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        let edgeRect = firstRect(forCharacterRange: NSRange(location: edge, length: 0), actualRange: nil)
        return abs(caretRect.minY - edgeRect.minY) < 1
    }
}
