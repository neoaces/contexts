import AppKit
import SwiftUI

/// The text view behind every block. Rich text uses it for both reading and
/// editing, so a block never jumps when selected and the selecting click also
/// places the caret. Math uses it only for the LaTeX source.
/// Return confirms the block; Shift-Return adds a line.
struct BlockEditor: NSViewRepresentable {
    let content: Block.Content
    let isEditing: Bool
    /// Asked on a click while read-only; returns whether editing may begin.
    let onActivate: () -> Bool
    let onChange: (Block.Content) -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BlockTextView {
        let textView = BlockTextView(usingTextLayoutManager: false)
        textView.configure(richText: content.isRichText)
        textView.textStorage?.setAttributedString(content.editableText)
        textView.delegate = context.coordinator
        textView.onActivate = onActivate
        textView.setEditing(isEditing)
        return textView
    }

    /// While read-only, the text follows the stored content, which can change
    /// underneath it when another device's edit is merged in.
    func updateNSView(_ textView: BlockTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        textView.onActivate = onActivate
        if !isEditing, !textView.isEditable, content != coordinator.shownContent {
            textView.textStorage?.setAttributedString(content.editableText)
            textView.invalidateIntrinsicContentSize()
            coordinator.clearUndoHistory()
        }
        if !isEditing { coordinator.shownContent = content }
        textView.setEditing(isEditing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: BlockTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: textView.height(fittingWidth: width))
    }

    static func dismantleNSView(_ textView: BlockTextView, coordinator: Coordinator) {
        coordinator.clearUndoHistory()
    }

    /// Owns the block's undo stack. The window's shared one would let ⌘Z in one
    /// block undo another, and would outlive (and crash on) torn-down text views.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockEditor
        /// What the text view currently displays, to notice content replaced from outside.
        var shownContent: Block.Content
        private let undoStack = UndoManager()

        init(_ parent: BlockEditor) {
            self.parent = parent
            shownContent = parent.content
        }

        func clearUndoHistory() {
            undoStack.removeAllActions()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoStack }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textView.invalidateIntrinsicContentSize()
            let content = parent.content.replacingText(with: textView.attributedString())
            shownContent = content
            parent.onChange(content)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertParagraphSeparator(_:)):
                // Ctrl-Return would put U+2028 into the LaTeX source; it breaks lines with "\n" only.
                guard !parent.content.isRichText else { return false }
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            default:
                return false
            }
        }
    }
}

final class BlockTextView: NSTextView {
    var onActivate: (() -> Bool)?
    /// Set when editing begins before the view has a window (a freshly created block).
    private var needsFocus = false
    /// Where typing just made a `←`, which a `>` typed right after widens to `↔`.
    /// Any selection change forgets it.
    private var madeLeftArrow: Int?
    /// Set while `unmarkText` commits marked text through `insertText`.
    private var isCommittingMarkedText = false

    func configure(richText: Bool) {
        isEditable = false
        isSelectable = false
        isRichText = richText
        allowsUndo = true
        usesFontPanel = false
        importsGraphics = false
        drawsBackground = false
        focusRingType = .none
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticQuoteSubstitutionEnabled = richText
        isAutomaticDashSubstitutionEnabled = richText
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        typingAttributes = richText ? RichText.typingAttributes : LaTeX.sourceAttributes
    }

    func setEditing(_ editing: Bool) {
        guard isEditable != editing else { return }
        isEditable = editing
        isSelectable = editing
        needsFocus = editing
        if editing {
            focusIfNeeded()
        } else {
            undoManager?.removeAllActions()
            if window?.firstResponder === self {
                setSelectedRange(NSRange(location: 0, length: 0))
                window?.makeFirstResponder(nil)
            }
        }
    }

    func height(fittingWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shift-Return adds a line; plain Return confirms the block.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // While an input method is composing, Return belongs to it.
        if isReturn, event.modifierFlags.contains(.shift), !hasMarkedText() {
            insertNewlineIgnoringFieldEditor(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEditable else { return super.mouseDown(with: event) }
        guard onActivate?() == true else { return }
        setEditing(true)
        super.mouseDown(with: event)
    }

    /// A single typed character can finish an arrow in rich text (see `Arrows`);
    /// paste, drop and input method text never do.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let isComposing = hasMarkedText() || isCommittingMarkedText
        let leftArrow = madeLeftArrow
        super.insertText(string, replacementRange: replacementRange)
        if isRichText, !isComposing, typed.utf16.count == 1 { makeArrow(typing: typed, leftArrow: leftArrow) }
    }

    override func unmarkText() {
        isCommittingMarkedText = true
        defer { isCommittingMarkedText = false }
        super.unmarkText()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        madeLeftArrow = nil
    }

    /// Pasted text adopts the block's style rather than the source app's fonts and colors.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    @objc func toggleBold(_ sender: Any?) { toggle(.bold) }
    @objc func toggleItalic(_ sender: Any?) { toggle(.italic) }

    private func focusIfNeeded() {
        guard needsFocus, let window else { return }
        needsFocus = false
        window.makeKey()
        window.makeFirstResponder(self)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
    }

    /// Replaces the pair just typed before the caret with its arrow, in the style
    /// of its first character. A style toggled since still applies to what follows.
    private func makeArrow(typing typed: String, leftArrow: Int?) {
        guard let textStorage else { return }
        let text = textStorage.string as NSString
        let typedAt = selectedRange().location - 1
        guard typedAt >= 0 else { return }
        let before = text.substring(with: NSRange(location: max(0, typedAt - 2), length: min(2, typedAt)))
        guard let (arrow, replacing) = Arrows.arrow(typing: typed, after: before, afterMadeLeftArrow: leftArrow == typedAt - 1)
        else { return }
        let range = NSRange(location: typedAt - replacing, length: replacing + 1)
        let attributes = textStorage.attributes(at: range.location, effectiveRange: nil)
        let typing = typingAttributes
        replaceAsUndoStep(range, with: NSAttributedString(string: arrow, attributes: attributes))
        typingAttributes = typing
        if arrow == "←" { madeLeftArrow = range.location }
    }

    /// Replaces `range` with `replacement`, caret after it, as an undo step of its
    /// own that makes the reverse replacement. So ⌘Z right after an arrow gives
    /// back what was typed, as autocorrect does, and typing on doesn't overwrite it.
    private func replaceAsUndoStep(_ range: NSRange, with replacement: NSAttributedString) {
        guard let textStorage, let undoManager else { return }
        breakUndoCoalescing()
        undoManager.disableUndoRegistration()
        let shouldChange = shouldChangeText(in: range, replacementString: replacement.string)
        undoManager.enableUndoRegistration()
        guard shouldChange else { return }

        // Undo is grouped by event, so the character just typed may be in the open
        // group. Start a new one, which the event's end still closes.
        if !undoManager.isUndoing, !undoManager.isRedoing, undoManager.groupingLevel == 1 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        let replaced = textStorage.attributedSubstring(from: range)
        undoManager.registerUndo(withTarget: self) { textView in
            textView.replaceAsUndoStep(NSRange(location: range.location, length: replacement.length), with: replaced)
        }
        textStorage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
    }

    /// Reads and sets the stored style, not font traits: emoji and CJK are drawn
    /// in fallback fonts that never report bold or italic.
    private func toggle(_ trait: RichText.Style) {
        guard isEditable, isRichText, let textStorage else { return }
        let range = selectedRange()
        let reference = range.length > 0 ? textStorage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        let shouldAdd = !RichText.style(of: reference).contains(trait)
        let convert = { (attributes: [NSAttributedString.Key: Any]) in
            var style = RichText.style(of: attributes)
            if shouldAdd { style.insert(trait) } else { style.remove(trait) }
            var converted = attributes
            RichText.apply(style, to: &converted)
            return converted
        }

        if range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            textStorage.beginEditing()
            textStorage.enumerateAttributes(in: range) { attributes, subrange, _ in
                textStorage.setAttributes(convert(attributes), range: subrange)
            }
            textStorage.endEditing()
            didChangeText()
        }
        typingAttributes = convert(reference)
    }
}
