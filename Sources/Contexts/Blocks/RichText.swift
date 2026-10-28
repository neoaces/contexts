import AppKit

/// Converts between stored runs and the attributed strings the text view edits.
/// Runs keep only meaning (bold, italic, underline); font and color are applied
/// here, so text always follows the system font and appearance.
enum RichText {
    static var bodyFont: NSFont { .systemFont(ofSize: 14) }

    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, styleKey: 0]
    }

    /// Bold and italic, as given. Fonts can't be trusted to remember them: AppKit
    /// draws emoji and CJK in fallback fonts that have neither trait.
    struct Style: OptionSet {
        let rawValue: Int
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)

        init(rawValue: Int) { self.rawValue = rawValue }

        init(bold: Bool, italic: Bool) {
            self = []
            if bold { insert(.bold) }
            if italic { insert(.italic) }
        }
    }

    /// Holds a `Style`'s raw value on every stretch the editor shows or types.
    static let styleKey = NSAttributedString.Key("ContextsStyle")

    /// The stretch's own style, or its font's when it has none (RTF from version 1).
    static func style(of attributes: [NSAttributedString.Key: Any]) -> Style {
        if let raw = attributes[styleKey] as? Int { return Style(rawValue: raw) }
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        return Style(bold: traits.contains(.bold), italic: traits.contains(.italic))
    }

    /// Sets a stretch's style and the body font that draws it.
    static func apply(_ style: Style, to attributes: inout [NSAttributedString.Key: Any]) {
        attributes[styleKey] = style.rawValue
        attributes[.font] = font(bold: style.contains(.bold), italic: style.contains(.italic))
    }

    static func attributedString(from runs: [TextRun]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for run in runs {
            var attributes = typingAttributes
            apply(Style(bold: run.isBold, italic: run.isItalic), to: &attributes)
            if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return text
    }

    /// Adjacent stretches with the same styles merge into one run. Stretches
    /// without a `styleKey` (version 1's RTF) only have fonts to go by, and
    /// characters drawn in a fallback font (emoji, CJK) carry no bold or italic
    /// of their own, so those take the style of the text around them.
    static func runs(from text: NSAttributedString) -> [TextRun] {
        var runs: [TextRun] = []
        var leadingFallback: [TextRun] = []
        let bodyFamily = bodyFont.familyName
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let font = attributes[.font] as? NSFont
            let style = style(of: attributes)
            var run = TextRun(
                text: (text.string as NSString).substring(with: range),
                isBold: style.contains(.bold),
                isItalic: style.contains(.italic),
                isUnderlined: (attributes[.underlineStyle] as? Int ?? 0) != 0
            )
            if attributes[styleKey] == nil, font != nil, font?.familyName != bodyFamily {
                guard let last = runs.last else { leadingFallback.append(run); return }
                run.isBold = last.isBold
                run.isItalic = last.isItalic
            } else {
                for var fallback in leadingFallback {
                    fallback.isBold = run.isBold
                    fallback.isItalic = run.isItalic
                    append(fallback, to: &runs)
                }
                leadingFallback.removeAll()
            }
            append(run, to: &runs)
        }
        leadingFallback.forEach { append($0, to: &runs) }
        return runs
    }

    private static func append(_ run: TextRun, to runs: inout [TextRun]) {
        if let last = runs.last, last.hasSameStyle(as: run) {
            runs[runs.count - 1].text += run.text
        } else {
            runs.append(run)
        }
    }

    /// Reads the RTF that version 1 stored, for the one-time migration.
    static func runs(fromLegacyRTF rtf: Data) -> [TextRun] {
        guard !rtf.isEmpty, let text = NSAttributedString(rtf: rtf, documentAttributes: nil) else { return [] }
        return runs(from: text)
    }

    private static func font(bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let body = bodyFont
        return NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(traits), size: body.pointSize) ?? body
    }
}
