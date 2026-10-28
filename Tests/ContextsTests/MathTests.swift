import AppKit
import Foundation
import Testing
@testable import Contexts

/// A math block's LaTeX source may span lines (Shift-Return adds one).
@Suite struct MathTests {
    static let multiLine = "a + b \\\\\n c"

    @Test func multiLineLatexSurvivesWriteAndRead() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let block = mathBlock(Self.multiLine)

        try tmp.syncFolder().write([block])
        let read = try #require(try tmp.syncFolder().readOwn())

        #expect(read == [block])
        #expect(read.first?.content == .math(latex: Self.multiLine))
    }

    @MainActor @Test func multiLineLatexSurvivesStoreSaveAndReload() throws {
        let tmp = try TempFolder()
        defer { tmp.remove() }
        let block = mathBlock("x")
        try tmp.syncFolder().write([block])

        let store = BlockStore(folder: tmp.syncFolder(), legacyFileURL: nil)
        store.update(block.id, content: .math(latex: Self.multiLine))
        store.saveIfNeeded()

        let reloaded = BlockStore(folder: tmp.syncFolder(), legacyFileURL: nil)
        #expect(reloaded.block(block.id)?.content == .math(latex: Self.multiLine))
    }

    @Test(arguments: ["x\n= y", "a + b \\\\\n c", "\\frac{1}\n{2}", "x\r\n+ y", "\\alpha\n\\beta"])
    func multiLineLatexParses(_ latex: String) {
        #expect(LaTeX.parses(latex))
    }

    @Test func invalidLatexStillFailsAcrossLines() {
        #expect(!LaTeX.parses("\\frac{1}\n{2"))
    }

    /// As in TeX, a line break and the spaces around it read as one space.
    @Test func backslashEndingALineIsAControlSpace() {
        #expect(LaTeX.renderable("a \\  \n  b") == "a \\ b")
        #expect(LaTeX.parses("a \\\nb"))
    }

    @Test func editedSourceKeepsLineBreaks() {
        let edited = Block.Content.math(latex: "").replacingText(with: NSAttributedString(string: "a\nb"))
        #expect(edited == .math(latex: "a\nb"))
    }

    // MARK: Keys

    /// Shift-Return is the documented one; Option- and Ctrl-Return come from the standard key bindings.
    @MainActor @Test(arguments: [NSEvent.ModifierFlags.shift, .option, .control])
    func modifiedReturnAddsALineBreak(_ modifiers: NSEvent.ModifierFlags) {
        let editing = MathEditing("y=")

        editing.pressReturn(with: modifiers)

        #expect(editing.textView.string == "y=\n")
        #expect(editing.commits == 0)
    }

    @MainActor @Test func returnConfirmsTheBlock() {
        let editing = MathEditing("y=")

        editing.pressReturn(with: [])

        #expect(editing.textView.string == "y=")
        #expect(editing.commits == 1)
    }

    /// Menu items and other key bindings send these; each adds a plain `\n`.
    @MainActor @Test(arguments: ["insertNewlineIgnoringFieldEditor:", "insertLineBreak:", "insertParagraphSeparator:"])
    func lineBreakCommandsInsertANewline(_ command: String) {
        let editing = MathEditing("y=")

        editing.textView.doCommand(by: Selector(command))

        #expect(editing.textView.string == "y=\n")
        #expect(editing.commits == 0)
    }

    /// Drop and Services insert through `readSelection`; the source keeps the
    /// pasted line breaks and its own monospaced style.
    @MainActor @Test func pastedTextKeepsLineBreaksAndSourceStyle() throws {
        let textView = BlockTextView(usingTextLayoutManager: false)
        textView.configure(richText: false)
        textView.textStorage?.setAttributedString(Block.Content.math(latex: "y = ").editableText)
        textView.setEditing(true)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let pasteboard = NSPasteboard(name: .init("ContextsTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([styledForeignText("a\nb")])

        #expect(textView.readSelection(from: pasteboard))

        let storage = try #require(textView.textStorage)
        #expect(storage.string == "y = a\nb")
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            #expect(attributes[.font] as? NSFont == LaTeX.sourceFont, "font at \(range)")
            #expect(attributes[.foregroundColor] as? NSColor == NSColor.labelColor, "color at \(range)")
            #expect(attributes[.underlineStyle] == nil, "underline at \(range)")
        }
    }
}

/// A math block's text view being edited, caret at the end. It sits in a window
/// so key presses go through the standard key bindings, as in the app.
@MainActor
fileprivate final class MathEditing {
    let textView = BlockTextView(usingTextLayoutManager: false)
    private(set) var commits = 0
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
    private var coordinator: BlockEditor.Coordinator!

    init(_ latex: String) {
        let content = Block.Content.math(latex: latex)
        coordinator = BlockEditor.Coordinator(BlockEditor(
            content: content, isEditing: true, onActivate: { true }, onChange: { _ in },
            onCommit: { [unowned self] in commits += 1 }
        ))
        textView.configure(richText: false)
        textView.textStorage?.setAttributedString(content.editableText)
        textView.delegate = coordinator
        window.contentView = textView
        textView.setEditing(true)
    }

    func pressReturn(with modifiers: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
        textView.keyDown(with: event)
    }
}

fileprivate func mathBlock(_ latex: String) -> Block {
    var block = Block(content: .math(latex: latex), device: "mac", at: 1_000)
    block.id = UUID(uuidString: "6F1C7C2E-3D5B-4E8A-9B1F-2A7D0C4E5B6A")!
    return block
}

/// Rich text as another app would put it on the pasteboard.
fileprivate func styledForeignText(_ string: String) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [
        .font: NSFont(name: "Times-Bold", size: 30) ?? .boldSystemFont(ofSize: 30),
        .foregroundColor: NSColor.systemRed,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
    ])
}
