import AppKit

/// A window a page's own questions show in: a site's permission question and Save password? come up over the page
/// that asked, in a browser window or Zigzag Mini alike. This is all they need to know about where they are.
protocol PromptHost: AnyObject {
    var window: NSWindow? { get }
    /// The flipped layer over the pages where floating things go.
    var promptOverlay: NSView { get }
    /// Where `tab`'s page is, in the overlay's coordinates; nil while it isn't in front.
    func pageFrame(showing tab: Tab) -> NSRect?
    /// The page you're in (its pane, in a split), in the overlay's coordinates.
    var focusedPaneFrame: NSRect { get }
    /// The tab in front.
    var promptFrontTab: Tab? { get }
    /// The tab is still in this window.
    func promptHolds(_ tab: Tab) -> Bool
    /// The tab is in front: the selected one, or either side of its split.
    func promptShows(_ tab: Tab) -> Bool
    var promptIsPrivate: Bool { get }
    /// The color the window's buttons are in.
    var promptAccent: NSColor { get }
    /// Calls `body` whenever a different tab may be in front (selection, tabs, spaces); nil where that never changes.
    func observePromptTabs(_ body: @escaping () -> Void) -> SignalToken?
    /// Views that move the pages when they move or resize, for a question to stay on its page.
    var promptPageViews: [NSView] { get }
    /// Puts away whatever floats over the page, for a question to come up clear of it.
    func clearForPrompt()
    /// Something over the question (the command bar) that keeps its own clicks and Esc.
    var promptIsCovered: Bool { get }
    /// The address the question hangs from: a click there doesn't put it off.
    var promptAnchor: NSView? { get }
    /// A short notice over the page.
    func promptToast(_ text: String, symbol: String, duration: TimeInterval)
}

extension WindowManager {
    /// The window a page in `window` asks its questions in: a browser window, or Zigzag Mini.
    func promptHost(for window: NSWindow?) -> PromptHost? {
        guard let window else { return nil }
        if let controller = controllers.first(where: { $0.window === window }) { return controller }
        return MiniWindowController.all.first { $0.window === window }
    }

    /// The window `tab` lives in, wherever it's showing.
    func promptHost(holding tab: Tab) -> PromptHost? {
        if let controller = controllers.first(where: { $0.tabManager.allTabs.contains { $0 === tab } }) { return controller }
        return MiniWindowController.all.first { $0.tab === tab }
    }
}

extension BrowserWindowController: PromptHost {
    var promptOverlay: NSView { root.overlay }
    var promptFrontTab: Tab? { tabManager.selectedTab }
    func promptHolds(_ tab: Tab) -> Bool { tabManager.allTabs.contains { $0 === tab } }
    func promptShows(_ tab: Tab) -> Bool {
        let front = tabManager.selectedTab
        return front === tab || front.map { tabManager.partner(of: $0) === tab } == true
    }
    var promptIsPrivate: Bool { tabManager.isPrivate }
    var promptAccent: NSColor { Brand.Theme.of(tabManager.currentSpace).accent }
    func observePromptTabs(_ body: @escaping () -> Void) -> SignalToken? {
        tabManager.changed.observe { change in
            if change == .selection || change == .structure || change == .space { body() }
        }
    }
    var promptPageViews: [NSView] { [root.card, root.secondCard] }
    func clearForPrompt() {
        closeFloatingPanels()
        Toast.hide(in: self)
        WhatsNewOffer.close(in: self)
    }
    var promptIsCovered: Bool { commandBar.isVisible }
    var promptAnchor: NSView? { sidebar.address }
    func promptToast(_ text: String, symbol: String, duration: TimeInterval) { Toast.show(text, symbol: symbol, duration: duration, in: self) }
}
