import AppKit
import Testing
@testable import Contexts

@Suite struct RichTextTests {
    // MARK: Legacy RTF

    @Test func legacyRTFKeepsBoldItalicAndUnderline() throws {
        let rtf = try legacyRTF([
            ("plain ", .plain),
            ("bold ", .bold),
            ("italic ", .italic),
            ("underlined ", .underlined),
            ("all", [.bold, .italic, .underlined]),
        ])

        #expect(RichText.runs(fromLegacyRTF: rtf) == [
            TextRun(text: "plain "),
            TextRun(text: "bold ", isBold: true),
            TextRun(text: "italic ", isItalic: true),
            TextRun(text: "underlined ", isUnderlined: true),
            TextRun(text: "all", isBold: true, isItalic: true, isUnderlined: true),
        ])
    }

    @Test func legacyRTFMergesAdjacentRunsWithTheSameStyle() throws {
        let rtf = try legacyRTF([
            ("red ", .bold, .systemRed),
            ("blue", .bold, .systemBlue),
            (" plain", .plain, nil),
        ])

        #expect(RichText.runs(fromLegacyRTF: rtf) == [
            TextRun(text: "red blue", isBold: true),
            TextRun(text: " plain"),
        ])
    }

    @Test func emptyLegacyRTFHasNoRuns() {
        #expect(RichText.runs(fromLegacyRTF: Data()) == [])
    }

    // MARK: Round trip

    @Test(arguments: [
        ("mixed styles", [
            TextRun(text: "plain "),
            TextRun(text: "bold ", isBold: true),
            TextRun(text: "italic ", isItalic: true),
            TextRun(text: "underlined ", isUnderlined: true),
            TextRun(text: "bold italic ", isBold: true, isItalic: true),
            TextRun(text: "all three", isBold: true, isItalic: true, isUnderlined: true),
        ]),
        ("emoji", [
            TextRun(text: "Coding 👩‍💻 in 🇨🇦 "),
            TextRun(text: "and 🇯🇵 too 👍🏽", isBold: true),
        ]),
        ("CJK", [
            TextRun(text: "日本語と"),
            TextRun(text: "中文", isItalic: true),
            TextRun(text: " 한국어", isUnderlined: true),
        ]),
        ("newlines", [
            TextRun(text: "first line\n"),
            TextRun(text: "second\nthird", isBold: true),
            TextRun(text: "\n\nlast", isUnderlined: true),
        ]),
    ] as [(String, [TextRun])])
    func runsSurviveARoundTrip(_ name: String, runs: [TextRun]) {
        #expect(RichText.runs(from: RichText.attributedString(from: runs)) == runs, "\(name)")
    }

    /// Emoji and CJK inside styled text keep its style once fonts are substituted.
    @Test(arguments: [
        ("emoji inside", [TextRun(text: "ship 👩‍💻 it 🇨🇦", isBold: true)]),
        ("CJK inside", [TextRun(text: "say 日本語 now", isBold: true, isItalic: true)]),
        ("emoji first", [TextRun(text: "🇯🇵 first", isBold: true)]),
        ("CJK first", [TextRun(text: "中文 first", isItalic: true)]),
        ("only CJK", [TextRun(text: "日本語", isBold: true)]),
        ("between styles", [
            TextRun(text: "plain 😀 "),
            TextRun(text: "bold 日本 ", isBold: true),
            TextRun(text: "italic 🇨🇦", isItalic: true),
        ]),
    ] as [(String, [TextRun])])
    func fallbackFontsKeepTheSurroundingStyle(_ name: String, runs: [TextRun]) {
        #expect(RichText.runs(from: withFallbackFonts(runs)) == runs, "\(name)")
    }

    /// Fallback text on a style boundary keeps its own style, not its neighbor's,
    /// and emoji-only text keeps bold with no neighbor to take it from.
    @Test(arguments: [
        ("plain CJK after bold", [TextRun(text: "bold", isBold: true), TextRun(text: "日本")]),
        ("plain emoji after bold", [TextRun(text: "bold", isBold: true), TextRun(text: "😀")]),
        ("bold CJK before plain", [TextRun(text: "日本", isBold: true), TextRun(text: " plain")]),
        ("only emoji", [TextRun(text: "👍🏽👩‍💻", isBold: true)]),
    ] as [(String, [TextRun])])
    func fallbackFontsOnAStyleBoundaryKeepTheirOwnStyle(_ name: String, runs: [TextRun]) {
        #expect(RichText.runs(from: withFallbackFonts(runs)) == runs, "\(name)")
    }

    // MARK: Editing

    @MainActor @Test(arguments: ["👍🏽👩‍💻", "日本語", "ship 👩‍💻 日本 it"])
    func boldTogglesOnAndOffForAnySelection(_ text: String) {
        let editing = RichTextEditing([TextRun(text: text)])
        editing.select(NSRange(location: 0, length: editing.length))

        editing.textView.toggleBold(nil)
        #expect(editing.runs == [TextRun(text: text, isBold: true)])

        editing.textView.toggleBold(nil)
        #expect(editing.runs == [TextRun(text: text)])
    }

    @MainActor @Test func italicTogglesWithoutTouchingBold() {
        let editing = RichTextEditing([TextRun(text: "日本", isBold: true), TextRun(text: " ok")])
        editing.select(NSRange(location: 0, length: editing.length))

        editing.textView.toggleItalic(nil)

        #expect(editing.runs == [TextRun(text: "日本", isBold: true, isItalic: true), TextRun(text: " ok", isItalic: true)])
    }

    /// The first selected character decides: a bold start turns the whole selection plain.
    @MainActor @Test func selectionStartingOnBoldEmojiTurnsBoldOff() {
        let editing = RichTextEditing([TextRun(text: "😀 bold", isBold: true), TextRun(text: " plain")])
        editing.select(NSRange(location: 0, length: editing.length))

        editing.textView.toggleBold(nil)

        #expect(editing.runs == [TextRun(text: "😀 bold plain")])
    }

    @MainActor @Test func typingAfterBoldIsOffStaysPlain() {
        let editing = RichTextEditing([TextRun(text: "bold", isBold: true)])
        editing.select(NSRange(location: editing.length, length: 0))

        editing.textView.toggleBold(nil)
        editing.textView.insertText("日本😀", replacementRange: editing.textView.selectedRange())

        #expect(editing.runs == [TextRun(text: "bold", isBold: true), TextRun(text: "日本😀")])
    }

    @MainActor @Test func typingAfterBoldTextContinuesBold() {
        let editing = RichTextEditing([TextRun(text: "bold", isBold: true)])
        editing.select(NSRange(location: editing.length, length: 0))

        editing.textView.insertText(" 日本😀", replacementRange: editing.textView.selectedRange())

        #expect(editing.runs == [TextRun(text: "bold 日本😀", isBold: true)])
    }
}

/// A rich text block's text view being edited, as the panel sets it up.
@MainActor
fileprivate final class RichTextEditing {
    let textView = BlockTextView(usingTextLayoutManager: false)

    init(_ runs: [TextRun]) {
        textView.configure(richText: true)
        textView.textStorage?.setAttributedString(Block.Content.text(runs).editableText)
        textView.setEditing(true)
    }

    var length: Int { (textView.string as NSString).length }
    var runs: [TextRun] { RichText.runs(from: textView.attributedString()) }

    func select(_ range: NSRange) {
        textView.setSelectedRange(range)
        // As NSTextView does when the selection moves: type in the style before the caret.
        if range.length == 0, range.location > 0, let storage = textView.textStorage {
            textView.typingAttributes = storage.attributes(at: range.location - 1, effectiveRange: nil)
        }
    }
}

fileprivate extension RichTextTests {
    /// What the text view holds after AppKit swaps in fallback fonts for characters
    /// the system font can't draw (Apple Color Emoji, PingFang, ...).
    func withFallbackFonts(_ runs: [TextRun]) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: RichText.attributedString(from: runs))
        text.fixAttributes(in: NSRange(location: 0, length: text.length))
        return text
    }

    struct Style: OptionSet {
        let rawValue: Int
        static let plain: Style = []
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let underlined = Style(rawValue: 4)
    }

    func legacyRTF(_ stretches: [(String, Style)]) throws -> Data {
        try legacyRTF(stretches.map { ($0.0, $0.1, nil) })
    }

    /// RTF as version 1 stored it: the text view's system font, plus whatever color was pasted in.
    func legacyRTF(_ stretches: [(String, Style, NSColor?)]) throws -> Data {
        let text = NSMutableAttributedString()
        for (string, style, color) in stretches {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if style.contains(.bold) { traits.insert(.bold) }
            if style.contains(.italic) { traits.insert(.italic) }
            let base = NSFont.systemFont(ofSize: 14)
            let font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 14) ?? base
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if style.contains(.underlined) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let color { attributes[.foregroundColor] = color }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        let range = NSRange(location: 0, length: text.length)
        return try #require(text.rtf(from: range, documentAttributes: [:]))
    }
}
