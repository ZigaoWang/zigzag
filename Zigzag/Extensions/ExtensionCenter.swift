import AppKit
import WebKit

/// What the app tells extensions, passed on to the profile it concerns. A tab's news goes to its own profile's
/// extensions; a window's goes to every profile's, since one window shows spaces of several, and each profile's
/// extensions are then shown only their own tabs in it.
@available(macOS 15.4, *)
enum ExtensionCenter {
    /// Some profile's extensions loaded, went, were turned on or off or pinned: for views that only need to draw
    /// again. Sent once a turn of the run loop however many changes came in it (`noteChanged`).
    static let changed = Signal<Void>()
    /// An extension's button changed its icon, title or badge: for the tab given, or every tab for none. A busy ad
    /// blocker counts every request it blocks, in every tab, so this comes often; only buttons look at it.
    static let actionUpdated = Signal<Tab?>()
    private static let changes = Coalescer()

    /// Says `changed` once, at the next turn of the run loop.
    static func noteChanged() { changes.schedule { changed.send() } }

    /// Whether an update to a button for `updated` (every tab for nil) can change what a window showing `selected`
    /// draws.
    static func update(for updated: AnyObject?, concerns selected: AnyObject?) -> Bool {
        updated == nil || updated === selected
    }
    /// Some profile's extension popup opened or closed.
    static let popupsChanged = Signal<Void>()

    /// The extensions that are up: the first profile's, and those of each profile used since Zigzag started. A
    /// profile's that come up later are told of the windows already open as they load.
    private static var hosts: [ExtensionHost] {
        Profiles.shared.all.compactMap { $0.isDefault ? $0.extensions : $0.startedExtensions }
    }

    /// The extension an extension's own page belongs to, to name the page and give it its icon. Any profile that has
    /// it loaded will do: the same address is the same extension in each.
    static func webExtension(ofPage url: URL?) -> WKWebExtension? {
        for host in hosts { if let context = host.context(forPage: url) { return context.webExtension } }
        return nil
    }

    // MARK: Tabs

    /// A tab is told to its profile's extensions once, as soon as it's made (pinned pages and favorites too, before
    /// their page loads), and its closing to the extensions that know of it: a tab that changes profile closes for
    /// one set and opens for the other. One they came to know otherwise (by its being shown or listed) still has its
    /// closing told to its profile's extensions, as long as they're up.
    static func tabOpened(_ tab: Tab) {
        guard let host = tab.extensionHost, tab.toldTo !== host else { return }
        tab.toldTo?.tabClosed(tab)
        tab.toldTo = host
        host.tabOpened(tab)
    }

    static func tabClosed(_ tab: Tab, windowClosing: Bool = false) {
        let known = tab.toldTo ?? (tab.isPrivate ? nil : tab.profile.startedExtensions)
        known?.tabClosed(tab, windowClosing: windowClosing)
        tab.toldTo = nil
    }
    static func tabActivated(_ tab: Tab, previous: Tab?) { tab.extensionHost?.tabActivated(tab, previous: previous) }
    /// Moved into another window (#167), at `index` among the old window's tabs: to extensions that know of it, it
    /// leaves that window for the one it's in now; to others, it's new.
    static func tabMoved(_ tab: Tab, from index: Int, in window: BrowserWindowController) {
        guard let host = tab.extensionHost, tab.toldTo === host else { tabOpened(tab); return }
        host.tabMoved(tab, from: index, in: window)
    }
    static func tabChanged(_ tab: Tab, _ change: Tab.Change) { tab.extensionHost?.tabChanged(tab, change) }

    // MARK: Windows

    static func windowOpened(_ window: BrowserWindowController) { hosts.forEach { $0.windowOpened(window) } }
    static func windowClosed(_ window: BrowserWindowController) { hosts.forEach { $0.windowClosed(window) } }
    static func windowFocused(_ window: BrowserWindowController?) { hosts.forEach { $0.windowFocused(window) } }

    // A sign-in popup is one page, so it belongs to one profile: the one its page was made in.
    static func popupOpened(_ popup: PopupWindowController) { host(of: popup)?.popupOpened(popup) }
    static func popupChanged(_ popup: PopupWindowController, _ change: WKWebExtension.TabChangedProperties) { host(of: popup)?.popupChanged(popup, change) }
    static func popupFocused(_ popup: PopupWindowController) { host(of: popup)?.popupFocused(popup) }
    static func popupClosed(_ popup: PopupWindowController) { host(of: popup)?.popupClosed(popup) }

    static func miniOpened(_ mini: MiniWindowController) {
        guard let host = mini.tab.extensionHost else { return }
        mini.tab.toldTo = host
        host.miniOpened(mini)
    }
    static func miniFocused(_ mini: MiniWindowController) { mini.tab.extensionHost?.miniFocused(mini) }
    static func miniClosed(_ mini: MiniWindowController) { mini.tab.extensionHost?.miniClosed(mini) }

    private static func host(of popup: PopupWindowController) -> ExtensionHost? {
        Profiles.shared.profile(of: popup.webView)?.extensions
    }

    // MARK: Keys and popups

    /// A shortcut an extension declared, for the extensions of the page you're on.
    static func performCommand(for event: NSEvent) -> Bool {
        let host: ExtensionHost?
        switch event.window?.windowController {
        case let window as BrowserWindowController: host = window.tabManager.selectedTab?.extensionHost
        case let popup as PopupWindowController: host = self.host(of: popup)
        default: host = Profiles.shared.default.extensions
        }
        return host?.performCommand(for: event) ?? false
    }

    static func closePopups(in window: NSWindow?) { hosts.forEach { $0.closePopups(in: window) } }
    static func holdsSidebar(in window: NSWindow?) -> Bool { hosts.contains { $0.holdsSidebar(in: window) } }
    static func repositionPinPopups(of controller: BrowserWindowController) { hosts.forEach { $0.repositionPinPopups(of: controller) } }
}
