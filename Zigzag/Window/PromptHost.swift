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
    /// Where page toasts go: the flipped overlay and the area in it. Windows with something over the page (the desk, an
    /// AI app's bar) override this; everything else comes from `promptToast`, so all windows show toasts the same way.
    var promptToastPlace: (over: NSView, area: NSRect) { get }
}

extension PromptHost {
    /// Default: over the pages, full width, below any question.
    var promptToastPlace: (over: NSView, area: NSRect) {
        (promptOverlay, PageQuestions.area(promptOverlay.bounds, below: PageQuestions.occupied(in: promptOverlay)))
    }

    /// A toast over the page. `action` adds a button (title and handler) for offers (Allow Once, Try Again), which stay
    /// longer; `closes` adds a ×. The button ignores clicks for its first half second so a click meant for the page
    /// can't hit it.
    func promptToast(_ text: String, symbol: String, duration: TimeInterval,
                     action: (title: String, run: () -> Void)? = nil, closes: Bool = false) {
        let place = promptToastPlace
        Toast.show(text, symbol: symbol, action: action, duration: duration, closes: closes,
                   over: place.over, area: place.area)
    }
}

extension WindowManager {
    /// The window that asks questions for a page in `window`: a browser window, Zigzag Mini, or an installed app's
    /// window. Without the last, a web app's camera, location or notification request was denied without asking.
    func promptHost(for window: NSWindow?) -> PromptHost? {
        guard let window else { return nil }
        if let controller = controller(for: window) { return controller }
        if let mini = MiniWindowController.all.first(where: { $0.window === window }) { return mini }
        return WebAppWindowController.all.first { $0.window === window }
    }

    /// The window holding `tab`, found by page rather than window, with the same three cases as `promptHost(for:)`.
    /// Installed app windows were missing here, so their Save password offers never appeared.
    func promptHost(holding tab: Tab) -> PromptHost? {
        if let controller = window(of: tab) { return controller }
        if let mini = MiniWindowController.all.first(where: { $0.tab === tab }) { return mini }
        return WebAppWindowController.all.first { $0.tab === tab }
    }
}

extension BrowserWindowController: PromptHost {
    var promptOverlay: NSView { root.overlay }
    var promptFrontTab: Tab? { tabManager.selectedTab }
    func promptHolds(_ tab: Tab) -> Bool { tabManager.allTabs.contains { $0 === tab } && holds(tab) }
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
    /// Browser window toasts avoid the open desk and an AI app's bar over the page.
    var promptToastPlace: (over: NSView, area: NSRect) { (root.overlay, Toast.area(in: self)) }
}

/// The top of a page shows one question at a time (a site permission, Save password?); the next waits hidden until it's
/// answered or dismissed. Toasts that arrive meanwhile show below it and move up once it goes.
@MainActor enum PageQuestions {
    /// The question shown at the top of a page in `overlay`, other than `except`; with `over`, only one covering that
    /// frame.
    static func showing(in overlay: NSView, except: NSView? = nil, over frame: NSRect? = nil) -> FloatingPanelView? {
        overlay.subviews.lazy.compactMap { $0 as? FloatingPanelView }.first { view in
            view !== except && (view is PermissionPrompt || view is SavePasswordPrompt) && !view.isHidden && !view.dismissing
                && frame.map { view.frame.intersects($0) } != false
        }
    }

    /// Whether `question` may show now: no other question is shown there. Questions in different split panes show
    /// together.
    static func mayShow(_ question: NSView, in overlay: NSView) -> Bool {
        showing(in: overlay, except: question, over: question.frame) == nil
    }

    /// What a top toast avoids in `area`: a shown question or the update note.
    static func occupied(in overlay: NSView) -> NSRect? {
        if let question = showing(in: overlay) { return question.frame }
        return overlay.subviews.lazy.compactMap { $0 as? WhatsNewOffer }.first { !$0.isHidden && !$0.dismissing }?.frame
    }

    /// `area` trimmed from the top to below `taken`.
    static func area(_ area: NSRect, below taken: NSRect?) -> NSRect {
        guard let taken, taken.intersects(area), taken.maxY > area.minY else { return area }
        var below = area
        below.origin.y = taken.maxY
        below.size.height = max(0, area.maxY - taken.maxY)
        return below
    }

    /// A question appeared: the update note gives way, and a toast moves below it.
    static func cameUp(in host: PromptHost) {
        if let controller = host as? BrowserWindowController {
            WhatsNewOffer.close(in: controller)
            Toast.reposition(in: controller)
        } else {
            // Mini and app windows have no desk or agent bar, but their toast still moves below the question.
            Toast.reposition(in: host)
        }
    }

    /// A question closed or yielded to another tab: show the oldest waiting one for this page, and move a toast back
    /// up.
    static func turnFreed(in host: PromptHost) {
        for view in host.promptOverlay.subviews {
            // Skip one already dismissing.
            if (view as? FloatingPanelView)?.dismissing == true { continue }
            (view as? PermissionPrompt)?.followTab()
            (view as? SavePasswordPrompt)?.followTab()
        }
        if let controller = host as? BrowserWindowController { Toast.reposition(in: controller) }
        else { Toast.reposition(in: host) }
    }
}
