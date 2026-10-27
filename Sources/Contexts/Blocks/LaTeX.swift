import AppKit
import SwiftMath

/// The LaTeX source line of a math block: plain, monospaced, no `$` delimiters.
enum LaTeX {
    static var sourceFont: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }

    static var sourceAttributes: [NSAttributedString.Key: Any] {
        [.font: sourceFont, .foregroundColor: NSColor.labelColor]
    }

    static func parses(_ latex: String) -> Bool {
        var error: NSError?
        _ = MTMathListBuilder.build(fromString: latex, error: &error)
        return error == nil
    }
}
