import Foundation

// Contexts patch: SwiftPM's generated `Bundle.module` only searches the .app's
// root folder (which can't be code-signed) or this machine's build folder.
// Look in the app's Resources first; fall back to `Bundle.module` for `swift run`.
enum MathFontBundle {
    static let url: URL? = Bundle.main.url(forResource: "mathFonts", withExtension: "bundle")
        ?? Bundle.module.url(forResource: "mathFonts", withExtension: "bundle")
}
