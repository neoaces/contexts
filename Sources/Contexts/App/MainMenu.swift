import AppKit

/// The menu bar is never visible (accessory app), but its key equivalents
/// are what route ⌘C, ⌘Z, ⌘B… to the focused text view.
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addSubmenu("Contexts", items: [
            item("Quit Contexts", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu.addSubmenu("Edit", items: [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu.addSubmenu("Format", items: [
            item("Bold", #selector(BlockTextView.toggleBold(_:)), "b"),
            item("Italic", #selector(BlockTextView.toggleItalic(_:)), "i"),
            item("Underline", #selector(NSText.underline(_:)), "u"),
        ])
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}

private extension NSMenu {
    func addSubmenu(_ title: String, items: [NSMenuItem]) {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
    }
}
