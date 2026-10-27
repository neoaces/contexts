import AppKit
import SwiftUI

/// The text view behind every block. Rich text uses it for both reading and
/// editing, so a block never jumps when selected and the selecting click also
/// places the caret. Math uses it only for the one-line LaTeX source.
/// Return confirms the block; Shift-Return adds a line (rich text only).
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
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertParagraphSeparator(_:)):
                return !parent.content.isRichText  // LaTeX source stays on one line
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

    /// Shift-Return is the only way to start a new line; plain Return confirms the block.
    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // While an input method is composing, Return belongs to it.
        if isReturn, isRichText, event.modifierFlags.contains(.shift), !hasMarkedText() {
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

    /// Pasted text adopts the block's style rather than the source app's fonts and colors.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// Paste, drop and Services all land here; the LaTeX source flattens line breaks into spaces.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard !isRichText, let string = pboard.string(forType: .string) else {
            return super.readSelection(from: pboard, type: type)
        }
        let oneLine = String(String.UnicodeScalarView(string.unicodeScalars.map {
            CharacterSet.newlines.contains($0) ? " " : $0
        }))
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: oneLine) else { return false }
        replaceCharacters(in: range, with: oneLine)
        didChangeText()
        return true
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

    private func toggle(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard isEditable, isRichText, let textStorage else { return }
        let range = selectedRange()
        let reference = range.length > 0
            ? textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            : typingAttributes[.font] as? NSFont
        let shouldAdd = !(reference ?? RichText.bodyFont).fontDescriptor.symbolicTraits.contains(trait)
        let convert = { (font: NSFont) in font.with(trait, enabled: shouldAdd) }

        if range.length > 0, shouldChangeText(in: range, replacementString: nil) {
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                textStorage.addAttribute(.font, value: convert(value as? NSFont ?? RichText.bodyFont), range: subrange)
            }
            textStorage.endEditing()
            didChangeText()
        }
        typingAttributes[.font] = convert(reference ?? RichText.bodyFont)
    }
}

private extension NSFont {
    func with(_ trait: NSFontDescriptor.SymbolicTraits, enabled: Bool) -> NSFont {
        var traits = fontDescriptor.symbolicTraits
        if enabled { traits.insert(trait) } else { traits.remove(trait) }
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}
