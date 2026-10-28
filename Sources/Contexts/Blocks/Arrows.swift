/// The arrows that typing makes in rich text: `->` → `→`, `<-` → `←`, `<->` → `↔`,
/// `=>` → `⇒` and `<=>` → `⇔`. `<=` stays as typed, since it may mean ≤.
enum Arrows {
    /// The arrow that typing `typed` after `before` makes, and how many of the
    /// characters (UTF-16) before it it replaces. `afterMadeLeftArrow` is whether
    /// `before` ends with a `←` that typing just made, which `>` widens to `↔`.
    static func arrow(typing typed: String, after before: String, afterMadeLeftArrow: Bool) -> (arrow: String, replacing: Int)? {
        switch typed {
        case ">" where afterMadeLeftArrow && before.hasSuffix("←"): ("↔", 1)
        case ">" where before.hasSuffix("<="): ("⇔", 2)
        case ">" where before.hasSuffix("-"): ("→", 1)
        case ">" where before.hasSuffix("="): ("⇒", 1)
        case "-" where before.hasSuffix("<"): ("←", 1)
        default: nil
        }
    }
}
