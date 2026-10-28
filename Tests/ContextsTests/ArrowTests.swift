import AppKit
import Testing
@testable import Contexts

/// Typing `->`, `<-` and the like in rich text makes an arrow, the way autocorrect would.
@MainActor @Suite struct ArrowTests {
    @Test(arguments: [("->", "→"), ("<-", "←"), ("<->", "↔"), ("=>", "⇒"), ("<=>", "⇔")])
    func typedPairBecomesAnArrow(_ typed: String, arrow: String) {
        let editing = ArrowEditing(text: "a ")

        editing.type(typed)

        #expect(editing.string == "a \(arrow)")
    }

    @Test func lessThanOrEqualStaysAsTyped() {
        let editing = ArrowEditing(text: "a ")

        editing.type("<= b")

        #expect(editing.string == "a <= b")
    }

    @Test func arrowAtTheStartOfABlock() {
        let editing = ArrowEditing(text: "")

        editing.type("->")

        #expect(editing.string == "→")
    }

    @Test func arrowInTheMiddleOfText() {
        let editing = ArrowEditing(text: "ab")
        editing.select(NSRange(location: 1, length: 0))

        editing.type("<-")

        #expect(editing.string == "a←b")
    }

    @Test func caretEndsRightAfterTheArrow() {
        let editing = ArrowEditing(text: "ab")
        editing.select(NSRange(location: 1, length: 0))

        editing.type("<=>")

        #expect(editing.textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func typingGoesOnAfterTheArrow() {
        let editing = ArrowEditing(text: "")

        editing.type("a -> b")

        #expect(editing.string == "a → b")
    }

    @Test func arrowAfterAnEmoji() {
        let editing = ArrowEditing(text: "😀")

        editing.type("-><-")

        #expect(editing.string == "😀→←")
    }

    @Test func blockStoresTheArrow() {
        let editing = ArrowEditing(text: "a")

        editing.type("->")

        #expect(editing.content == .text([TextRun(text: "a→")]))
    }

    @Test func mathSourceStaysASCII() {
        let editing = ArrowEditing(.math(latex: "x "))

        editing.type("-> <- <-> => <=>")

        #expect(editing.string == "x -> <- <-> => <=>")
    }

    /// Drop and Services insert through `readSelection`, as paste does.
    @Test func pastedPairStaysAsTyped() throws {
        let editing = ArrowEditing(text: "x ")

        try editing.paste("a->b")

        #expect(editing.string == "x a->b")
    }

    @Test func pastedCharacterDoesNotFinishAPair() throws {
        let editing = ArrowEditing(text: "a-")

        try editing.paste(">")

        #expect(editing.string == "a->")
    }

    @Test func textInsertedAtOnceStaysAsTyped() {
        let editing = ArrowEditing(text: "a")

        editing.textView.insertText("->", replacementRange: editing.textView.selectedRange())

        #expect(editing.string == "a->")
    }

    /// An input method commits its marked text with `insertText`.
    @Test func inputMethodTextStaysAsTyped() {
        let editing = ArrowEditing(text: "a-")
        let notFound = NSRange(location: NSNotFound, length: 0)

        editing.textView.setMarkedText(">", selectedRange: NSRange(location: 1, length: 0), replacementRange: notFound)
        editing.textView.insertText(">", replacementRange: notFound)

        #expect(editing.string == "a->")
    }

    /// `unmarkText` commits marked text when composing ends some other way, such as a click.
    @Test func inputMethodTextCommittedByUnmarkStaysAsTyped() {
        let editing = ArrowEditing(text: "a-")

        editing.textView.setMarkedText(">", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editing.textView.unmarkText()

        #expect(editing.string == "a->")
    }

    @Test func typingOverASelectionHoldingTheFirstCharacterStaysAsTyped() {
        let editing = ArrowEditing(text: "a-b")
        editing.select(NSRange(location: 1, length: 2))

        editing.type(">")

        #expect(editing.string == "a>")
    }

    /// Only a `←` that typing just made widens to `↔`.
    @Test func greaterThanAfterAPastedLeftArrowStaysAsTyped() throws {
        let editing = ArrowEditing(text: "a")
        try editing.paste("←")

        editing.type(">")

        #expect(editing.string == "a←>")
    }

    @Test func greaterThanAfterTypingAndDeletingStaysAsTyped() {
        let editing = ArrowEditing(text: "a")

        editing.type("<-x\u{7F}>")

        #expect(editing.string == "a←>")
    }

    @Test func greaterThanAfterTheCaretMovesStaysAsTyped() {
        let editing = ArrowEditing(text: "a")
        editing.type("<-")
        editing.select(NSRange(location: 0, length: 0))
        editing.select(NSRange(location: 2, length: 0))

        editing.type(">")

        #expect(editing.string == "a←>")
    }

    @Test func greaterThanInALaterEditStaysAsTyped() {
        let editing = ArrowEditing(text: "a")
        editing.type("<-")
        editing.textView.setEditing(false)
        editing.textView.setEditing(true)
        editing.select(NSRange(location: 2, length: 0))

        editing.type(">")

        #expect(editing.string == "a←>")
    }

    // MARK: Undo

    @Test func undoGivesBackTheTypedPair() {
        let editing = ArrowEditing(text: "a")
        editing.type("->")

        editing.undo()

        #expect(editing.string == "a->")
        #expect(editing.textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func undoPutsTheCaretAfterThePairWhereverItWas() {
        let editing = ArrowEditing(text: "a")
        editing.type("->")
        editing.select(NSRange(location: 0, length: 0))

        editing.undo()

        #expect(editing.string == "a->")
        #expect(editing.textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func blockStoresThePairAfterUndo() {
        let editing = ArrowEditing(text: "a")
        editing.type("->")

        editing.undo()

        #expect(editing.content == .text([TextRun(text: "a->")]))
    }

    @Test func typingAfterUndoGoesOnAfterThePair() {
        let editing = ArrowEditing(text: "a")
        editing.type("->")
        editing.undo()

        editing.type("b")

        #expect(editing.string == "a->b")
    }

    @Test func secondUndoRemovesTheTyping() {
        let editing = ArrowEditing(text: "a")
        editing.type("->")

        editing.undo()
        editing.undo()

        #expect(editing.string == "a")
    }

    /// Here `>` starts a fresh typing step in the same event as the arrow.
    @Test func undoGivesBackAPairFinishedOnExistingText() {
        let editing = ArrowEditing(text: "a-")
        editing.type(">")

        editing.undo()
        #expect(editing.string == "a->")

        editing.undo()
        #expect(editing.string == "a-")
    }

    @Test func undoAfterWideningGivesBackTheLeftArrow() {
        let editing = ArrowEditing(text: "a")
        editing.type("<->")

        editing.undo()

        #expect(editing.string == "a←>")
    }

    @Test func redoMakesTheArrowAgain() {
        let editing = ArrowEditing(text: "a")
        editing.type("=>")

        editing.undo()
        editing.redo()

        #expect(editing.string == "a⇒")
    }

    @Test func undoAndRedoGoBackAndForthRepeatedly() {
        let editing = ArrowEditing(text: "a")
        editing.type("=>")
        editing.undo()
        editing.redo()

        editing.undo()
        editing.undo()
        #expect(editing.string == "a")

        editing.redo()
        editing.redo()
        #expect(editing.string == "a⇒")
    }

    @Test func typingAfterTheArrowIsItsOwnUndoStep() {
        let editing = ArrowEditing(text: "a")
        editing.type("->b")

        editing.undo()

        #expect(editing.string == "a→")
    }

    // MARK: Style

    @Test func arrowKeepsTheStyleItReplaces() {
        let editing = ArrowEditing(runs: [TextRun(text: "a")])
        editing.textView.toggleBold(nil)

        editing.type("->")

        #expect(editing.runs == [TextRun(text: "a"), TextRun(text: "→", isBold: true)])
        #expect(RichText.runs(from: RichText.attributedString(from: editing.runs)) == editing.runs)
    }

    @Test func arrowKeepsItalicAndUnderline() {
        let editing = ArrowEditing(runs: [TextRun(text: "x", isItalic: true, isUnderlined: true)])

        editing.type("<->")

        #expect(editing.runs == [TextRun(text: "x↔", isItalic: true, isUnderlined: true)])
    }

    @Test func arrowKeepsTheStoredStyle() throws {
        let editing = ArrowEditing(runs: [TextRun(text: "x", isBold: true, isItalic: true)])

        editing.type("=>")

        let storage = try #require(editing.textView.textStorage)
        #expect(storage.attribute(RichText.styleKey, at: 1, effectiveRange: nil) as? Int == RichText.Style([.bold, .italic]).rawValue)
    }

    @Test func textTypedAfterTheArrowKeepsItsStyle() {
        let editing = ArrowEditing(runs: [TextRun(text: "x", isBold: true)])

        editing.type("->y")

        #expect(editing.runs == [TextRun(text: "x→y", isBold: true)])
    }

    @Test func arrowTakesTheStyleOfTheFirstCharacter() {
        let editing = ArrowEditing(text: "a")
        editing.textView.toggleBold(nil)
        editing.type("-")
        editing.textView.toggleBold(nil)

        editing.type(">")

        #expect(editing.runs == [TextRun(text: "a"), TextRun(text: "→", isBold: true)])
    }

    /// A ⌘B between the two characters still applies to what's typed after the arrow.
    @Test func styleToggledWithinThePairCarriesOn() {
        let editing = ArrowEditing(text: "a-")
        editing.textView.toggleBold(nil)

        editing.type(">x")

        #expect(editing.runs == [TextRun(text: "a→"), TextRun(text: "x", isBold: true)])
    }
}

/// A block's text view being edited in a window, caret at the end. Each
/// character is a key press of its own, through the standard key bindings.
@MainActor
fileprivate final class ArrowEditing {
    let textView = BlockTextView(usingTextLayoutManager: false)
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
    private var coordinator: BlockEditor.Coordinator!
    /// What the block last stored.
    private(set) var content: Block.Content

    /// US layout key codes, and whether Shift is down, for the characters the tests type.
    private static let keys: [Character: (code: UInt16, shift: Bool)] = [
        "a": (0, false), "b": (11, false), "x": (7, false), "y": (16, false), " ": (49, false),
        "-": (27, false), "=": (24, false), "<": (43, true), ">": (47, true),
        "\u{7F}": (51, false),
    ]

    init(_ content: Block.Content) {
        self.content = content
        coordinator = BlockEditor.Coordinator(BlockEditor(
            content: content, isEditing: true, onActivate: { true },
            onChange: { [unowned self] in self.content = $0 }, onCommit: {}
        ))
        textView.configure(richText: content.isRichText)
        textView.textStorage?.setAttributedString(content.editableText)
        textView.delegate = coordinator
        window.contentView = textView
        textView.setEditing(true)
        endEvent()
    }

    convenience init(text: String) { self.init(runs: text.isEmpty ? [] : [TextRun(text: text)]) }
    convenience init(runs: [TextRun]) { self.init(.text(runs)) }

    var string: String { textView.string }
    var runs: [TextRun] { RichText.runs(from: textView.attributedString()) }

    func type(_ characters: String) {
        for character in characters {
            let key = Self.keys[character]!
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: key.shift ? .shift : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: key.code
            )!
            textView.keyDown(with: event)
            endEvent()
        }
    }

    func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        endEvent()
    }

    /// As ⌘Z does from the Edit menu.
    func undo() {
        #expect(textView.tryToPerform(Selector(("undo:")), with: nil))
        endEvent()
    }

    func redo() {
        #expect(textView.tryToPerform(Selector(("redo:")), with: nil))
        endEvent()
    }

    func paste(_ string: String) throws {
        let pasteboard = NSPasteboard(name: .init("ContextsTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        try #require(textView.readSelection(from: pasteboard))
        endEvent()
    }

    /// Lets the run loop turn, which closes the undo group of the event just handled.
    private func endEvent() {
        RunLoop.current.run(mode: .default, before: .now)
    }
}
