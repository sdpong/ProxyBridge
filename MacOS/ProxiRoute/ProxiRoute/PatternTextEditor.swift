import SwiftUI
import AppKit

// A text box that takes several lines and marks the entries that are wrong.
//
// SwiftUI's TextEditor cannot color part of its text, so this is an NSTextView
// with a red background behind the entries that cannot work, the way a spell
// checker marks a wrong word. The red is the same red the problem list under
// the box uses, so the two read as one thing.
//
// The entries that another rule already names are marked in yellow instead:
// they are not wrong, but the user should know they are named twice.
struct PatternTextEditor: NSViewRepresentable {
    @Binding var text: String
    // the entries that are marked, in the text of the editor
    var highlights: [NSRange] = []
    // the entries another rule names, in the text of the editor
    var notes: [NSRange] = []
    // a red frame around the whole box, when something in it is wrong
    var isInvalid: Bool = false
    // the user clicked in the text, at this character index
    var onTextClick: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let textView = ClickAwareTextView()
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
        // the click is reported in the character index, so the caller can tell
        // which entry the user pointed at
        let coordinator = context.coordinator
        textView.onClick = { [weak coordinator] index in
            coordinator?.parent.onTextClick?(index)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // setting the string throws the attributes away, so the marks have to
        // be put on again afterwards
        if textView.string != text {
            textView.string = text
            context.coordinator.appliedErrors = []
            context.coordinator.appliedNotes = []
        }
        context.coordinator.apply(highlights, notes, to: textView)
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PatternTextEditor
        weak var textView: NSTextView?
        // the marks that are on the text right now
        var appliedErrors: [NSRange] = []
        var appliedNotes: [NSRange] = []

        init(_ parent: PatternTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            parent.text = textView.string
        }

        func apply(_ errors: [NSRange], _ notes: [NSRange], to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let wantedErrors = errors.filter { NSMaxRange($0) <= storage.length }
            let wantedNotes = notes.filter { NSMaxRange($0) <= storage.length }
            if appliedErrors == wantedErrors && appliedNotes == wantedNotes { return }

            let selection = textView.selectedRanges
            storage.beginEditing()
            for range in appliedErrors where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            for range in appliedNotes where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            // the yellow goes on first, the red of an entry that is wrong lies
            // on top of it
            for range in wantedNotes {
                storage.addAttribute(.backgroundColor,
                                    value: NSColor.systemYellow.withAlphaComponent(0.38),
                                    range: range)
            }
            for range in wantedErrors {
                storage.addAttribute(.backgroundColor,
                                    value: NSColor.systemRed.withAlphaComponent(0.30),
                                    range: range)
            }
            storage.endEditing()
            appliedErrors = wantedErrors
            appliedNotes = wantedNotes
            textView.selectedRanges = selection
        }
    }
}

// A text view that tells its owner where the user clicked, so a click on an
// entry another rule names can bring a warning.
final class ClickAwareTextView: NSTextView {
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        // The click is reported before the text view takes it over. Its own
        // handling runs a tracking loop that waits for the button to come back
        // up, so a report made afterwards can be late or lost when the window
        // is rebuilt while the loop is running.
        let point = convert(event.locationInWindow, from: nil)
        onClick?(characterIndexForInsertion(at: point))
        super.mouseDown(with: event)
    }
}
