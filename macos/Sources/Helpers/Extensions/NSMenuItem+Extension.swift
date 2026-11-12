import AppKit

extension NSMenuItem {
    /// Sets the image property from a symbol if we want images on our menu items.
    func setImageIfDesired(systemSymbolName symbol: String) {
        // We only set on macOS 26 when icons on menu items became the norm.
        if #available(macOS 26, *) {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            // vigil: macOS 27 hides menu item images unless the item asks
            // (upstream has not adopted `preferredImageVisibility` yet); the
            // sidebar's menus show theirs, so the menu bar's do too.
            preferredImageVisibility = .visible
        }
    }
}
