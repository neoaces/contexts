# Local patches to SwiftMath 1.7.3

Upstream: https://github.com/mgriebling/SwiftMath (tag 1.7.3, MIT, see LICENSE).

1. `MathBundle/MathFontBundle.swift` (new) and three call sites in
   `MathBundle/MathFont.swift` and `MathRender/MTFont.swift`: fonts load from
   `Contexts.app/Contents/Resources/mathFonts.bundle` instead of SwiftPM's
   `Bundle.module`, which only looks in the app's unsignable root folder.
2. Removed `mathFonts.bundle/math_table_to_plist.py` (a font tooling script).
3. `mathFonts.bundle` keeps only Latin Modern Math (the default font) and its
   GUST license; the other eleven fonts were removed to save about 6 MB.
   Only use the default font: `MTFont(fontWithName:)` force-unwraps, so
   asking `MTFontManager` for a removed font would crash.
