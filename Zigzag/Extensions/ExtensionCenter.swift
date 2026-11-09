import AppKit
import WebKit

/// What the app tells extensions, passed on to the profile it concerns. A tab's news goes to its own profile's
/// extensions; a window's goes to every profile's, since one window shows spaces of several, and each profile's
/// extensions are then shown only their own tabs in it.
@available(macOS 15.4, *)
enum ExtensionCenter {
    /// Some profile's extensions loaded or changed their buttons: for views that only need to draw again.
    static let changed = Signal<Void>()
    /// Some profile's extension popup opened or closed.
    static let popupsChanged = Signal<Void>()

    private static var hosts: [ExtensionHost] { Profiles.shared.all.map(\.extensions) }

    // MARK: Tabs

    static func tabOpened(_ tab: Tab) { tab.extensionHost?.tabOpened(tab) }
    static func tabClosed(_ tab: Tab, windowClosing: Bool = false) { tab.extensionHost?.tabClosed(tab, windowClosing: windowClosing) }
    static func tabActivated(_ tab: Tab, previous: Tab?) { tab.extensionHost?.tabActivated(tab, previous: previous) }
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

    static func miniOpened(_ mini: MiniWindowController) { mini.tab.extensionHost?.miniOpened(mini) }
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
