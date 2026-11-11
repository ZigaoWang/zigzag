import AppKit

/// Window › Keep on Top: a window stays above every other window, other apps' included, until it's turned off or the
/// window closes. Meant for small windows you watch while working elsewhere (a site's pop-up, Zigzag Mini), which also
/// follow you to every desktop and over a full-screen app; a browser window simply floats where it is. Per window,
/// never saved.
enum KeepOnTop {
    /// A window's Keep on Top changed: the object is the window.
    static let changed = Notification.Name("ZigzagKeepOnTopChanged")

    /// What each window's collection behavior was before Keep on Top changed it, to give it back exactly.
    private static var original: [ObjectIdentifier: NSWindow.CollectionBehavior] = [:]

    static func isOn(_ window: NSWindow) -> Bool { window.level == .floating }

    /// The window Window › Keep on Top is for: the one you're in, else the front one of Zigzag's that can be kept on
    /// top (Zigzag in the background).
    static var frontWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && applies(to: $0) }
    }

    /// Whether the window can be kept on top: an ordinary titled window, not a panel or a sheet.
    static func applies(to window: NSWindow?) -> Bool {
        guard let window, window.styleMask.contains(.titled), !(window is NSPanel), window.sheetParent == nil else { return false }
        return true
    }

    static func toggle(_ window: NSWindow) {
        set(!isOn(window), for: window)
    }

    static func set(_ on: Bool, for window: NSWindow) {
        guard on != isOn(window) else { return }
        let id = ObjectIdentifier(window)
        if on {
            original[id] = window.collectionBehavior
            window.collectionBehavior = behavior(from: window.collectionBehavior, on: true)
        } else {
            window.collectionBehavior = original.removeValue(forKey: id) ?? window.collectionBehavior
        }
        window.level = on ? .floating : .normal
        NotificationCenter.default.post(name: changed, object: window)
    }

    /// Where a window kept on top may show: on every desktop and over a full-screen app, unless it's one that goes
    /// full screen itself (a browser window), which stays on its own desktop.
    nonisolated static func behavior(from current: NSWindow.CollectionBehavior, on: Bool) -> NSWindow.CollectionBehavior {
        guard on, !current.contains(.fullScreenPrimary) else { return current }
        var behavior = current
        behavior.remove(.moveToActiveSpace)
        behavior.insert(.canJoinAllSpaces)
        behavior.insert(.fullScreenAuxiliary)
        return behavior
    }

    /// The menu item's and the buttons' name.
    static var title: String {
        String(localized: "Keep on Top", comment: "Window menu item and the pin button's tooltip in a pop-up and Zigzag Mini: keeps the window above all other windows, other apps' too. Checked while on.")
    }

    /// The pin in a pop-up's or Zigzag Mini's top strip: filled while the window is kept on top.
    static func refresh(_ button: IconButton, for window: NSWindow?) {
        let on = window.map(isOn) ?? false
        button.symbol = on ? "pin.fill" : "pin"
        button.showsFillAtRest = on
        button.setAccessibilityValue(on ? 1 : 0)
    }
}
