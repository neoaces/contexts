import AppKit
import SwiftMath

/// The LaTeX source of a math block: plain, monospaced, no `$` delimiters.
enum LaTeX {
    static var sourceFont: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }

    static var sourceAttributes: [NSAttributedString.Key: Any] {
        [.font: sourceFont, .foregroundColor: NSColor.labelColor]
    }

    static func parses(_ latex: String) -> Bool {
        var error: NSError?
        _ = MTMathListBuilder.build(fromString: renderable(latex), error: &error)
        return error == nil
    }

    /// The source as TeX reads it: each line break, with the spaces around it, is
    /// one space, so a `\` ending a line is a control space rather than an error.
    static func renderable(_ latex: String) -> String {
        latex.replacing(/[ \t]*\R[ \t]*/, with: " ")
    }
}
