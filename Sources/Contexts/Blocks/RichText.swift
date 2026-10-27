import AppKit

/// RTF is the storage format. Colors are stripped on save and re-applied on load,
/// so text always follows the system appearance instead of freezing black or white.
enum RichText {
    static var bodyFont: NSFont { .systemFont(ofSize: 14) }

    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor]
    }

    static func decode(_ rtf: Data) -> NSAttributedString {
        guard !rtf.isEmpty, let text = NSMutableAttributedString(rtf: rtf, documentAttributes: nil) else {
            return NSAttributedString()
        }
        text.restoreSystemFont()
        text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: text.fullRange)
        return text
    }

    static func encode(_ text: NSAttributedString) -> Data {
        let text = NSMutableAttributedString(attributedString: text)
        text.removeAttribute(.foregroundColor, range: text.fullRange)
        text.removeAttribute(.backgroundColor, range: text.fullRange)
        return text.rtf(from: text.fullRange, documentAttributes: [:]) ?? Data()
    }

    static func isBlank(_ rtf: Data) -> Bool {
        decode(rtf).string.allSatisfy(\.isWhitespace)
    }
}

private extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}

private extension NSMutableAttributedString {
    /// RTF stores the system font as Helvetica Neue; map runs back, keeping size and bold/italic.
    func restoreSystemFont() {
        let body = RichText.bodyFont
        enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let font = value as? NSFont ?? body
            let descriptor = body.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits)
            addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? body, range: range)
        }
    }
}
