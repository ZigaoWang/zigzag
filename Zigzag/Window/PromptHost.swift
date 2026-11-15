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
        if let controller = controller(for: window) { return controller }
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
    func promptToast(_ text: String, symbol: String, duration: TimeInterval) { Toast.show(text, symbol: symbol, duration: duration, in: self) }
}

/// The top of a page holds one thing at a time. A page's questions (a site's permission, Save password?) take turns
/// there: one shows, the next waits hidden until it's answered or set aside. A toast that comes while a question is
/// up shows under it, and moves up once the question goes.
@MainActor enum PageQuestions {
    /// The question showing at the top of a page in `overlay`, other than `except`; with `over`, only one where it
    /// would cover that frame.
    static func showing(in overlay: NSView, except: NSView? = nil, over frame: NSRect? = nil) -> FloatingPanelView? {
        overlay.subviews.lazy.compactMap { $0 as? FloatingPanelView }.first { view in
            view !== except && (view is PermissionPrompt || view is SavePasswordPrompt) && !view.isHidden && !view.dismissing
                && frame.map { view.frame.intersects($0) } != false
        }
    }

    /// Whether `question`, placed where it would show, may come up now: no other question is showing there. Questions
    /// on different panes of a split show together.
    static func mayShow(_ question: NSView, in overlay: NSView) -> Bool {
        showing(in: overlay, except: question, over: question.frame) == nil
    }

    /// What a toast at the top of `area` keeps clear of: a question or the update note showing there.
    static func occupied(in overlay: NSView) -> NSRect? {
        if let question = showing(in: overlay) { return question.frame }
        return overlay.subviews.lazy.compactMap { $0 as? WhatsNewOffer }.first { !$0.isHidden && !$0.dismissing }?.frame
    }

    /// `area` with the top cut off down to the bottom of `taken`, for a toast to sit under what's there.
    static func area(_ area: NSRect, below taken: NSRect?) -> NSRect {
        guard let taken, taken.intersects(area), taken.maxY > area.minY else { return area }
        var below = area
        below.origin.y = taken.maxY
        below.size.height = max(0, area.maxY - taken.maxY)
        return below
    }

    /// A question came up: the update note, which only informs, makes way for it, and a toast showing moves under it.
    static func cameUp(in host: PromptHost) {
        guard let controller = host as? BrowserWindowController else { return }
        WhatsNewOffer.close(in: controller)
        Toast.reposition(in: controller)
    }

    /// A question went, or stepped aside for another tab: the oldest one waiting for this page comes up, and a toast
    /// under it moves back up.
    static func turnFreed(in host: PromptHost) {
        for view in host.promptOverlay.subviews {
            // One already sliding out has had its answer.
            if (view as? FloatingPanelView)?.dismissing == true { continue }
            (view as? PermissionPrompt)?.followTab()
            (view as? SavePasswordPrompt)?.followTab()
        }
        if let controller = host as? BrowserWindowController { Toast.reposition(in: controller) }
    }
}
