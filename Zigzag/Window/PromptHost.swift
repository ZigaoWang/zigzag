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
    /// Where a short notice over the page goes: the flipped layer over the pages, and the room in it. A window with
    /// something else over its page (the desk, an AI app's bar) says so by answering this; everything else about a
    /// notice comes from `promptToast` below, so every window says one the same way.
    var promptToastPlace: (over: NSView, area: NSRect) { get }
}

extension PromptHost {
    /// Where a notice goes by default: over the pages, edge to edge.
    var promptToastPlace: (over: NSView, area: NSRect) { (promptOverlay, promptOverlay.bounds) }

    /// A short notice over the page. `action` adds a button — a title and what pressing it does — for a notice with
    /// something to offer (Allow Once, Try Again); one of those stays long enough to read and act on, and a `closes`
    /// × for an offer you may want gone before it goes on its own. The button takes no click for its first half
    /// second, so a click meant for the page can't land on it. `image` stands in for a symbol where the picture is
    /// something's own (a site's icon, on a notification).
    func promptToast(_ text: String, symbol: String, image: NSImage? = nil, duration: TimeInterval,
                     action: (title: String, run: () -> Void)? = nil, closes: Bool = false) {
        let place = promptToastPlace
        Toast.show(text, symbol: symbol, image: image, action: action, duration: duration, closes: closes,
                   over: place.over, area: place.area)
    }

    /// An automation's own notice, in the same place and the same shape every other notice over a page has — a browser
    /// window, Zigzag Mini and an installed app's window alike, which is what lets a rule that fires in a background
    /// tab say so in *its* window rather than in the one you are looking at. Repeats of the same notice collapse into
    /// one with a count while it is up.
    func promptAutomation(_ text: String, symbol: String) {
        let place = promptToastPlace
        Toast.notice(text, symbol: symbol, over: place.over, area: place.area)
    }
}

extension WindowManager {
    /// The window a page in `window` asks its questions in: a browser window, Zigzag Mini, or an installed app's own
    /// window. Without the last, a web app's camera, location or notification request would be answered no without
    /// being asked.
    func promptHost(for window: NSWindow?) -> PromptHost? {
        guard let window else { return nil }
        if let controller = controller(for: window) { return controller }
        if let mini = MiniWindowController.all.first(where: { $0.window === window }) { return mini }
        return WebAppWindowController.all.first { $0.window === window }
    }

    /// The window `tab` lives in, wherever it's showing: the same three `promptHost(for:)` answers, found by the page
    /// instead of by the window. An installed app's window was missing here, so a login captured in one offered to be
    /// saved in a window that was never looked for, and the offer never came up.
    func promptHost(holding tab: Tab) -> PromptHost? {
        if let controller = controllers.first(where: { $0.tabManager.allTabs.contains { $0 === tab } }) { return controller }
        if let mini = MiniWindowController.all.first { $0.tab === tab } { return mini }
        return WebAppWindowController.all.first { $0.tab === tab }
    }
}

extension BrowserWindowController: PromptHost {
    var promptOverlay: NSView { root.overlay }
    var promptFrontTab: Tab? { tabManager.selectedTab }
    func promptHolds(_ tab: Tab) -> Bool { tabManager.allTabs.contains { $0 === tab } }
    func promptShows(_ tab: Tab) -> Bool {
        let front = tabManager.selectedTab
        return front.map { tabManager.panes(of: $0).contains { $0 === tab } } == true
    }
    var promptIsPrivate: Bool { tabManager.isPrivate }
    var promptAccent: NSColor { Brand.Theme.of(tabManager.currentSpace).accent }
    func observePromptTabs(_ body: @escaping () -> Void) -> SignalToken? {
        tabManager.changed.observe { change in
            if change == .selection || change == .structure || change == .space { body() }
        }
    }
    var promptPageViews: [NSView] { root.paneCards }
    func clearForPrompt() {
        closeFloatingPanels()
        Toast.hide(in: self)
        WhatsNewOffer.close(in: self)
    }
    var promptIsCovered: Bool { commandBar.isVisible }
    var promptAnchor: NSView? { sidebar.address }
    /// A notice in a browser window keeps clear of the desk when it's open, and of an AI app's bar over the page.
    var promptToastPlace: (over: NSView, area: NSRect) { (root.overlay, Toast.area(in: self)) }
}
