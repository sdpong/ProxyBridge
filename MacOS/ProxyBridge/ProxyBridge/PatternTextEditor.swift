import SwiftUI
import AppKit

// A text box that takes several lines and marks the entries that are wrong.
//
// SwiftUI's TextEditor cannot color part of its text, so this is an NSTextView
// with a red background behind the entries that cannot work, the way a spell
// checker marks a wrong word. The red is the same red the problem list under
// the box uses, so the two read as one thing.
struct PatternTextEditor: NSViewRepresentable {
    @Binding var text: String
    // the entries that are marked, in the text of the editor
    var highlights: [NSRange] = []
    // a red frame around the whole box, when something in it is wrong
    var isInvalid: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 60)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // setting the string throws the attributes away, so the marks have to
        // be put on again afterwards
        if textView.string != text {
            textView.string = text
            context.coordinator.applied = []
        }
        context.coordinator.apply(highlights, to: textView)
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PatternTextEditor
        weak var textView: NSTextView?
        // the marks that are on the text right now
        var applied: [NSRange] = []

        init(_ parent: PatternTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
        }

        func apply(_ ranges: [NSRange], to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let wanted = ranges.filter { NSMaxRange($0) <= storage.length }
            if applied == wanted { return }

            let selection = textView.selectedRanges
            storage.beginEditing()
            for range in applied where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            for range in wanted {
                storage.addAttribute(.backgroundColor,
                                    value: NSColor.systemRed.withAlphaComponent(0.30),
                                    range: range)
            }
            storage.endEditing()
            applied = wanted
            textView.selectedRanges = selection
        }
    }
}
