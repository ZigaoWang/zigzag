import AppKit
import WebKit

/// Zigzag Mini: one page in a small, quiet window of its own, with no sidebar, for a link from another app or a
/// quick look-up. A slim strip on top in the page's own color (`PageBar`), the page under it edge to edge: the space
/// it goes to, the page's site, Keep on Top, Copy Link and Open in. Its page is a real tab, so
/// history, blocking, autofill and extensions work as they do anywhere; Open in moves that same live page into a
/// browser window, in the space chosen on the strip. Quitting lets it go, as Arc did; an update's restart brings it
/// back (`UpdateRelaunch`).
/// The docked Mini's chrome: the page fills the card, and the strip drops over the top edge when needed.
enum MiniChromeLayout {
    static func cardFrame(in bounds: NSRect, stripHeight: CGFloat, overlays: Bool) -> NSRect {
        guard !overlays else { return bounds }
        return NSRect(x: bounds.minX, y: bounds.minY + stripHeight, width: bounds.width,
                      height: max(0, bounds.height - stripHeight))
    }

    /// The pointer's place in the flipped view: zero is the top, so the strip comes down near the top edge.
    static func revealsChrome(at point: NSPoint, in bounds: NSRect, stripHeight: CGFloat) -> Bool {
        let reach = stripHeight + Tokens.Space.x2
        return point.x >= bounds.minX && point.x <= bounds.maxX
            && point.y >= bounds.minY && point.y <= bounds.minY + reach
    }
}

/// Where the docked Mini sits in the page, and how its frame follows a resized page.
enum MiniDockLayout {
    /// The frame the old Peek used: 8% of the page card in from each side, 4.8% above and below.
    static func frame(in pane: NSRect) -> NSRect {
        let dx = min(max(Tokens.Space.x8, Tokens.Space.snap(pane.width * Tokens.Metric.miniPeekInsetRatio)),
                     max(0, (pane.width - 1) / 2))
        let dy = min(max(Tokens.Space.x6, Tokens.Space.snap(pane.height * Tokens.Metric.miniPeekInsetRatio * 0.6)),
                     max(0, (pane.height - 1) / 2))
        return pane.insetBy(dx: dx, dy: dy).integral
    }
}

/// The dim under a Mini docked in a page. A click puts the Mini away and never reaches the page behind it.
final class MiniPeekDimView: ColorView {
    var onClick: (() -> Void)?
    /// The Mini has gone and the dim is only fading: the page behind is live again, so clicks pass through.
    var passesClicks = false

    override init(color: NSColor? = nil) {
        super.init(color: color)
        layer?.cornerRadius = Tokens.Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// A wheel over the dimmed page stays there: the page behind the Mini doesn't move under it.
    override func scrollWheel(with event: NSEvent) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicks ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class MiniWindowController: NSWindowController, NSWindowDelegate {
    /// The last to be asked about a key: one nothing took goes by quietly (`QuietKeys`).
    override func noResponder(for eventSelector: Selector) {
        if QuietKeys.passQuietly(eventSelector, NSApp.currentEvent) { return }
        super.noResponder(for: eventSelector)
    }

    /// Open ones, oldest first, for placing the next one and for extensions.
    private(set) static var all: [MiniWindowController] = []
    /// The one you're in, if any.
    static var key: MiniWindowController? { all.first { $0.window?.isKeyWindow == true } }

    /// What the feature is called wherever Zigzag names it.
    static var name: String { String(localized: "Zigzag Mini", comment: "The name of Zigzag's small window for one page, without the sidebar (Arc called it Little Arc). Kept in Latin letters, like the app's name.") }

    let tab: Tab
    let root = MiniRootView()
    private var strip: MiniStripView { root.strip }
    /// The Mini is presented in the page: dimmed page, click-out and Esc, the same root and page.
    private(set) var isDockedInPage = false
    /// The browser whose page this Mini is docked in, while it is.
    private weak var dockedBrowser: BrowserWindowController?
    /// Where the docked Mini sits on screen, kept for anything that asks while the child window is ordered out.
    private(set) var dockedScreenFrame: NSRect?
    /// The dim under the docked Mini.
    private var inPageMiniDim: MiniPeekDimView?
    /// The browser's chrome covers the page card (revealed sidebar, The Whole Screen's bar): the child is out.
    private(set) var isCoveredInDock = false
    /// The edge sidebar is tucking back in: the child stays out until it has finished.
    private var isSidebarTucking = false
    private var sidebarTuckWork: DispatchWorkItem?
    /// The browser window is going in or out of full screen: the child waits until it has landed.
    private var isTransitioningWithParent = false
    private var dockedParentObservers: [NSObjectProtocol] = []
    private var chromePointerToken: Any?
    /// The host clears its record when the docked Mini closes or is promoted.
    var onInPageMiniClosed: (() -> Void)?
    var onInPageMiniDetached: (() -> Void)?
    /// Where floating things go over the page: the link under the pointer, a site's question, a toast.
    var overlay: PassthroughView { root.overlay }
    private lazy var linkStatus = LinkStatusController(overlay: overlay)
    /// ⌘L: the browser window's own command bar, over the page's site.
    private lazy var commandBar = CommandBarController(host: self)
    /// ⌘F: the find bar over the page.
    private var findBar: FindBarController {
        if let madeFindBar { return madeFindBar }
        let made = FindBarController(window: self)
        madeFindBar = made
        return made
    }
    /// Created lazily so closing a window without one doesn't create one.
    private var madeFindBar: FindBarController?
    private var tokens: [SignalToken] = []
    /// The page went into a browser window: closing this one must leave it alone.
    private var movedOut = false
    /// Sent once the page has left (into a browser window, or closed with the window), so questions over it go too.
    private let pageGone = Signal<Void>()
    /// Sent when the window becomes or stops being key, which shows or holds its page's queued question.
    private let promptFrontChanged = Signal<Void>()
    private var isClosing = false

    /// Questions waiting while the page can't show them (window not key or not visible); drives the edge glow.
    private var questionsWaitingForPage: Int {
        guard let window, !movedOut, !isClosing else { return 0 }
        guard PendingQuestions.waits(tabID: tab.id, isFront: window.isKeyWindow, windowVisible: window.isVisible) else { return 0 }
        return PendingQuestions.count(tabID: tab.id)
    }
    /// Fading away before it closes or moves into Zigzag: nothing more to do in it.
    private var isLeaving = false
    /// Opened for a link from another app.
    private var fromAnotherApp = false
    /// Opened from a link on a page (⇧-click, Open Link in Zigzag Mini): the window and tab it came from.
    private(set) weak var source: BrowserWindowController?
    private weak var sourceTab: Tab?
    private(set) var fromPage = false
    /// From a private window: its own store, nothing written down.
    var isPrivate: Bool { tab.isPrivate }

    /// Settings › Zigzag Mini: links from other apps open here instead of a tab, as in Little Arc. On by default.
    static var opensExternalLinks: Bool {
        get { opensExternalLinks(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: "OpensExternalLinksInMini") }
    }

    /// The setting from `defaults`; on when unset.
    nonisolated static func opensExternalLinks(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "OpensExternalLinksInMini") as? Bool ?? true
    }

    /// Whether a page another app hands over goes to Zigzag Mini: only web links, only with the setting on, and
    /// never before onboarding is done, whose first window is where you start.
    nonisolated static func takes(_ url: URL, settingOn: Bool, needsOnboarding: Bool) -> Bool {
        settingOn && !needsOnboarding && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Whether the note on the first external link is still to come.
    nonisolated static func needsLinksNote(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: "MiniLinksExplained")
    }

    /// The note answered: it never shows again, and Use Tabs Instead turns the setting off.
    nonisolated static func answerLinksNote(useTabs: Bool, in defaults: UserDefaults) {
        defaults.set(true, forKey: "MiniLinksExplained")
        if useTabs { defaults.set(false, forKey: "OpensExternalLinksInMini") }
    }

    /// Undo on the toast after Use Tabs Instead.
    nonisolated static func undoUseTabs(in defaults: UserDefaults) {
        defaults.set(true, forKey: "OpensExternalLinksInMini")
    }

    /// The note on the first external link, while it's up.
    private var linksNote: MiniLinksNote?

    /// On the first external link: what Zigzag Mini is, ⌘O, and the choice of tabs instead.
    private func explainLinks() {
        guard Self.needsLinksNote(in: .standard) else { return }
        // After the window's open animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.enter * Tokens.Motion.debugSlowdown + 0.3) { [weak self] in
            guard let self, !self.movedOut, !self.isLeaving, !self.isClosing, Self.needsLinksNote(in: .standard),
                  !Self.all.contains(where: { $0.linksNote != nil }) else { return }
            let note = MiniLinksNote(accent: self.promptAccent)
            note.anchor = { [weak self] in
                guard let self, !self.strip.openButton.isHidden else { return nil }
                return self.overlay.convert(self.strip.openButton.bounds, from: self.strip.openButton)
            }
            note.onAnswer = { [weak self] useTabs in self?.answerLinksNote(useTabs: useTabs) }
            self.linksNote = note
            note.show(over: self.overlay)
        }
    }

    private func answerLinksNote(useTabs: Bool) {
        guard let note = linksNote else { return }
        linksNote = nil
        note.takeDown()
        Self.answerLinksNote(useTabs: useTabs, in: .standard)
        guard useTabs else { return }
        moveOut { target in
            Toast.show(String(localized: "Links from other apps will open as tabs.", comment: "Toast in the browser window after Use Tabs Instead on the note shown the first time a link from another app opened in Zigzag Mini. The page has moved into a tab."),
                       action: (String(localized: "Undo", comment: "Toast button"), { MiniWindowController.undoUseTabs(in: .standard) }),
                       duration: Toast.undoDuration, in: target)
        }
    }

    /// The page left or the window closed with the note up: it goes quietly, as Got It.
    private func settleLinksNote() {
        guard let note = linksNote else { return }
        linksNote = nil
        note.takeDown(instantly: true)
        Self.answerLinksNote(useTabs: false, in: .standard)
    }

    /// Opens at the last user-set size, as Little Arc does, never below the minimum; the default until then.
    static func size(remembered: NSSize?) -> NSSize {
        guard let remembered, remembered.width >= Tokens.Metric.miniWindowMinSize.width,
              remembered.height >= Tokens.Metric.miniWindowMinSize.height else { return Tokens.Metric.miniWindowSize }
        return NSSize(width: round(remembered.width), height: round(remembered.height))
    }

    /// The size after the last manual resize.
    private static var rememberedSize: NSSize? {
        get { UserDefaults.standard.string(forKey: "MiniWindowSize").map(NSSizeFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: "MiniWindowSize") }
    }

    /// Size for the next window.
    static var openingSize: NSSize { size(remembered: rememberedSize) }

    /// Opens one on `url`. `origin`: where it grows from (the quick open bar); without it, screen center, cascaded
    /// below existing ones. `httpFallback`: `url` is https for a scheme-less address, retried over http if unreachable
    /// (`CommandRanker.Destination`).
    @discardableResult
    static func open(url: URL, isSearch: Bool = false, from origin: NSRect? = nil, overFullScreen: Bool? = nil, fromAnotherApp: Bool = false,
                     httpFallback: Bool = false) -> MiniWindowController {
        let screen = origin.flatMap { o in NSScreen.screens.first { $0.frame.intersects(o) } } ?? NSApp.keyWindow?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        let size = openingSize
        let frame = origin.map { Self.frame(size: size, under: $0, in: area) }
            ?? Self.frame(size: size, in: area, taken: Self.all.compactMap { $0.window?.frame })
        let tab = Tab(url: url, spaceID: MiniQuickOpen.space.id)
        tab.isSearchTab = isSearch
        // Before the window is created, since it loads during setup.
        tab.firstLoad.httpFallback = httpFallback
        let controller = MiniWindowController(tab: tab, frame: frame, overFullScreen: overFullScreen ?? (NSApp.keyWindow?.styleMask.contains(.fullScreen) == true))
        all.append(controller)
        Diagnostics.note("Zigzag Mini opened", site: url.host())
        controller.appear(from: origin)
        if #available(macOS 15.4, *) { ExtensionCenter.miniOpened(controller) }
        if let webView = controller.tab.webView { controller.window?.makeFirstResponder(webView) }
        if fromAnotherApp {
            // From a link in another app, as Little Arc: only this window comes forward, the browser windows stay
            // where they were, and closing it goes back to the app the link came from.
            controller.fromAnotherApp = true
            controller.returnTo = AppSwitching.lastOtherApp
            if !NSApp.isActive { NSRunningApplication.current.activate(options: []) }
            MiniLinkWake.linkOpenedInMini()
            controller.explainLinks()
        }
        return controller
    }

    /// Open in Zigzag Mini, from a tab's menu or a tab ⌥-dragged out of every window: the tab's page, live (the same
    /// history, nothing reloads), in a Zigzag Mini window of its own, as if it had been opened there. It wears the
    /// tab's space. The tab has already left the list (`TabManager.release`). `browser`: the window it came from,
    /// which it opens over the middle of; `point`: where on screen it was let go, which its strip's middle goes to.
    @discardableResult
    static func open(moving tab: Tab, from browser: NSWindow?, at point: NSPoint? = nil) -> MiniWindowController {
        let screen = point.flatMap { p in NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } } ?? browser?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        let size = openingSize
        let taken = Self.all.compactMap { $0.window?.frame }
        let frame = point.map { Self.frame(size: size, under: NSRect(origin: $0, size: .zero), in: area) }
            ?? Self.frame(size: size, in: area, taken: taken, around: browser.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) })
        tab.pageHolder?.removeFromSuperview()
        let controller = MiniWindowController(tab: tab, frame: frame, overFullScreen: browser?.styleMask.contains(.fullScreen) == true)
        all.append(controller)
        Diagnostics.note("Zigzag Mini opened", site: tab.url?.host())
        // The page has the keyboard before the window comes forward: given it as the window becomes key, WebKit takes
        // it for a Tab from the end and focuses the page's last link, scrolling down to it.
        if let webView = controller.tab.webView { controller.window?.makeFirstResponder(webView) }
        controller.appear(from: nil)
        if #available(macOS 15.4, *) { ExtensionCenter.miniOpened(controller) }
        return controller
    }

    /// Opens one for a link on a page (⇧-click, Open Link in Zigzag Mini), over the middle of that window's page, in the
    /// page's profile and space, private from a private window. With a configuration (from WebKit), the page keeps its
    /// opener and the returned controller's web view is the one WebKit asked for.
    @discardableResult
    static func open(fromPage url: URL?, configuration: WKWebViewConfiguration?, opener: Tab?, in browser: BrowserWindowController,
                     by sender: Tab.LoadSender = .page, dockedIn: BrowserWindowController? = nil) -> MiniWindowController {
        let window = browser.window
        let root = browser.root
        let page = window.map { $0.convertToScreen(root.convert(root.cardFrame, to: nil)) }
        let screen = page.flatMap { p in NSScreen.screens.first { $0.frame.contains(NSPoint(x: p.midX, y: p.midY)) } } ?? window?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        let frame = Self.frame(size: openingSize, in: area, taken: all.compactMap { $0.window?.frame }, around: page.map { NSPoint(x: $0.midX, y: $0.midY) })
        // With a configuration from the page that opened it, it's in that page's profile, so in its space.
        let spaceID = (configuration != nil ? opener?.spaceID : nil) ?? browser.tabManager.currentSpaceID
        let tab = Tab(url: url, spaceID: spaceID, configuration: configuration)
        tab.privateStore = browser.tabManager.privateStore
        tab.opener = opener
        tab.firstLoad.sender = sender
        let controller = MiniWindowController(tab: tab, frame: frame, overFullScreen: window?.styleMask.contains(.fullScreen) == true)
        controller.fromPage = true
        controller.source = browser
        controller.sourceTab = opener
        all.append(controller)
        Diagnostics.note("Zigzag Mini opened", site: url?.host(), "from a page", isPrivate: tab.isPrivate)
        if let host = dockedIn {
            controller.attachDocked(in: host)
            if controller.isDockedInPage {
                // The docked Mini is still a Mini window for extensions, as the standalone one is.
                if #available(macOS 15.4, *) { ExtensionCenter.miniOpened(controller) }
                return controller
            }
            // No browser window to be a child of after all: the standalone Mini, as if it had never been docked.
        }
        if let webView = controller.tab.webView { controller.window?.makeFirstResponder(webView) }
        controller.appear(from: nil)
        if #available(macOS 15.4, *) { ExtensionCenter.miniOpened(controller) }
        return controller
    }

    // MARK: - In the page

    /// Presents this Mini in `browser`'s page, over the page card, with a dim. The Mini keeps its own window, root, tab
    /// and web view: only the presentation changes. Its window becomes a borderless child of the browser window, bound
    /// to the page card, so menus, `window.close()`, questions, find and the command bar all see the right window while
    /// it looks like part of the page.
    func attachDocked(in browser: BrowserWindowController) {
        guard let window, let parent = browser.window else { return }
        isDockedInPage = true
        dockedBrowser = browser
        root.chromeOverlay = true
        root.setChromeRevealed(false, animated: false)
        strip.trafficLightsWidth = 0
        refreshStrip()
        let dim = MiniPeekDimView(color: Tokens.Color.peekScrim)
        dim.onClick = { [weak self] in self?.closeInPage() }
        inPageMiniDim = dim
        browser.root.showInPageMiniDim(dim, owner: self)
        // A borderless child over the page card: no title bar, no shadow, never a main window or one to manage.
        window.styleMask = [.borderless]
        (window as? BrowserWindow)?.isOverlayChild = true
        window.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        window.minSize = .zero
        window.level = .normal
        window.hasShadow = false
        window.animationBehavior = .none
        window.isMovableByWindowBackground = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        root.isPageOverlay = true
        root.autoresizingMask = [.width, .height]
        parent.addChildWindow(window, ordered: .above)
        observeDockedParent()
        layoutInDock(pane: browser.root.cardFrame, force: true)
        installChromePointerMonitor()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.webView)
    }

    /// The browser page moved or resized: keep the same share of it. While the browser's own chrome is over the card, or
    /// the window is going in or out of full screen, the child is ordered out, since a separate window is composited
    /// above the whole parent and cannot be covered by a sibling view.
    func layoutInDock(pane: NSRect, force: Bool = false) {
        guard isDockedInPage, let browser = dockedBrowser, let window, let parent = browser.window else { return }
        let card = MiniDockLayout.frame(in: pane)
        let screen = parent.convertToScreen(browser.root.convert(card, to: nil))
        dockedScreenFrame = screen
        guard !isTransitioningWithParent else { return }
        if force || window.frame != screen { window.setFrame(screen, display: false) }
        let covered = browser.root.coversInPageMini || isSidebarTucking
        guard covered != isCoveredInDock || force else { return }
        isCoveredInDock = covered
        if covered { window.orderOut(nil) } else { window.orderFront(nil) }
    }

    /// Takes the Mini out of the page only if `owner` still owns the slot.
    func unembed(owner: AnyObject) {
        dockedBrowser?.root.hideInPageMiniDim(owner: owner)
        inPageMiniDim = nil
    }

    /// Expands the docked Mini into its own window, with the same root, tab and web view.
    func promoteFromPage() {
        guard isDockedInPage, !isLeaving, let window else { return }
        let card = window.frame
        endDockPresentation()
        let size = NSSize(width: card.width, height: card.height + Tokens.Metric.miniStripHeight)
        window.setFrame(window.frameRect(forContentRect: NSRect(origin: card.origin, size: size)), display: true)
        onInPageMiniDetached?()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.webView)
    }

    /// Closes the docked Mini and its page, and gives the keyboard back to the browser's page. The window closes first,
    /// so the page still exists when the extension host hears `tabClosed`; the window's own close closes the page.
    @discardableResult
    func closeInPage(focusBack: Bool = true, animated: Bool = true) -> Bool {
        guard isDockedInPage, !isLeaving, let browser = dockedBrowser, let window else { return false }
        isLeaving = true
        onInPageMiniClosed?()
        let finish = { [weak self, weak browser, weak window] in
            guard let self else { return }
            if focusBack, let page = browser?.tabManager.selectedTab?.webView {
                browser?.window?.makeFirstResponder(page)
            }
            self.endDockPresentation()
            window?.close()
        }
        // Ordered out under the browser's chrome or before its first frame, there is nothing on screen to fade away.
        guard animated, let dim = inPageMiniDim, window.isVisible, window.alphaValue > 0.001 else {
            finish()
            return true
        }
        dim.passesClicks = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.reduceMotion ? 0 : Tokens.Motion.exit
            window.animator().alphaValue = 0
            dim.animator().alphaValue = 0
        }, completionHandler: finish)
        return true
    }

    /// Lets go of the docked presentation without making the window a standalone one again: it is closing.
    private func releaseDock() {
        if let window {
            window.parent?.removeChildWindow(window)
            window.acceptsMouseMovedEvents = false
        }
        removeChromePointerMonitor()
        removeDockedParentObservers()
        dockedBrowser?.root.hideInPageMiniDim(owner: self)
        inPageMiniDim = nil
        dockedBrowser = nil
        isDockedInPage = false
        isCoveredInDock = false
        isTransitioningWithParent = false
        dockedScreenFrame = nil
        sidebarTuckWork?.cancel()
        sidebarTuckWork = nil
        isSidebarTucking = false
        root.isPageOverlay = false
    }

    /// Back to a window of its own: a title bar, its traffic lights, a shadow and its place in the Window menu.
    private func endDockPresentation() {
        guard let window else { return }
        // A standalone Mini never goes full screen itself; one taken out over a full-screen browser stays in that Space.
        let overFullScreen = dockedBrowser?.window?.styleMask.contains(.fullScreen) == true
        releaseDock()
        // A child of a Keep on Top browser window inherits its level; out of the page it is an ordinary window again.
        window.level = .normal
        root.chromeOverlay = false
        root.setChromeRevealed(true, animated: false)
        (window as? BrowserWindow)?.isOverlayChild = false
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.minSize = Tokens.Metric.miniWindowMinSize
        window.collectionBehavior.remove(.transient)
        window.collectionBehavior.remove(.ignoresCycle)
        window.collectionBehavior.remove(.fullScreenPrimary)
        if overFullScreen {
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            window.collectionBehavior.remove(.fullScreenAuxiliary)
        }
        window.hasShadow = true
        window.animationBehavior = .documentWindow
        window.isMovableByWindowBackground = true
        window.isExcludedFromWindowsMenu = false
        refreshTrafficLightsRoom(animated: false)
        // The root was kept clear for the child; now the window is a window again and the space paints it as one.
        root.paint(space, isPrivate: isPrivate, animated: false)
        refreshStrip()
    }

    /// The browser window's moves that do not come through the page's own layout: full screen, resizes and screens.
    private func observeDockedParent() {
        guard let parent = dockedBrowser?.window, dockedParentObservers.isEmpty else { return }
        func observe(_ name: NSNotification.Name, _ handler: @escaping @Sendable (Notification) -> Void) {
            dockedParentObservers.append(NotificationCenter.default.addObserver(forName: name, object: parent,
                                                                               queue: .main, using: handler))
        }
        observe(NSWindow.willEnterFullScreenNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.parentTransition(waiting: true) }
        }
        observe(NSWindow.willExitFullScreenNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.parentTransition(waiting: true) }
        }
        observe(NSWindow.didEnterFullScreenNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.parentTransition(waiting: false) }
        }
        observe(NSWindow.didExitFullScreenNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.parentTransition(waiting: false) }
        }

        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            observe(name) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayoutAfterParent() }
            }
        }
    }

    private func removeDockedParentObservers() {
        dockedParentObservers.forEach(NotificationCenter.default.removeObserver)
        dockedParentObservers = []
    }

    /// Going in or out of full screen: the child waits until the browser window has landed, so it never lags the frame.
    private func parentTransition(waiting: Bool) {
        guard isDockedInPage else { return }
        isTransitioningWithParent = waiting
        if waiting {
            window?.orderOut(nil)
        } else {
            relayoutAfterParent()
        }
    }

    /// A full-screen transition that failed never sends did-enter or did-exit: the Mini comes back instead of
    /// staying ordered out forever.
    func parentFullScreenTransitionFailed() { parentTransition(waiting: false) }

    /// Whether the docked Mini is waiting for the browser window's full-screen transition to land, for tests.
    var isWaitingForParentFullScreen: Bool { isTransitioningWithParent }

    private func relayoutAfterParent() {
        guard isDockedInPage, let browser = dockedBrowser else { return }
        layoutInDock(pane: browser.root.cardFrame, force: true)
    }

    /// The edge sidebar started out or back. Out, the child goes at once, before the slide's first frame; back, it
    /// waits until the tuck has finished, so it never sits over the sidebar while it moves.
    func sidebarSlid(show: Bool, duration: TimeInterval) {
        guard isDockedInPage else { return }
        sidebarTuckWork?.cancel()
        sidebarTuckWork = nil
        if show {
            isSidebarTucking = false
            guard !isCoveredInDock else { return }
            isCoveredInDock = true
            window?.orderOut(nil)
            return
        }
        isSidebarTucking = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isSidebarTucking = false
            self.sidebarTuckWork = nil
            self.relayoutAfterParent()
        }
        sidebarTuckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration) + 0.02, execute: work)
    }

    /// The pointer over the browser or the docked Mini: near the top the strip comes down; away from it, it goes back up.
    private func installChromePointerMonitor() {
        guard chromePointerToken == nil else { return }
        // The child is the key window while you're in the Mini, so its tracking areas alone would not bring moves in.
        window?.acceptsMouseMovedEvents = true
        chromePointerToken = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, !self.isLeaving, let window = self.window else { return event }
            guard let point = self.pointInDock(from: event) else { return event }
            if self.strip.isEditing {
                self.root.setChromeRevealed(true, animated: false)
            } else {
                self.root.pointerMoved(to: point)
            }
            return event
        }
    }

    /// A move in either window, in the docked Mini's own root coordinates.
    private func pointInDock(from event: NSEvent) -> NSPoint? {
        guard let window, let source = event.window, source === window || source === dockedBrowser?.window else { return nil }
        if source === window { return root.convert(event.locationInWindow, from: nil) }
        let onScreen = source.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        let inMini = window.convertFromScreen(NSRect(origin: onScreen, size: .zero)).origin
        return root.convert(inMini, from: nil)
    }

    private func removeChromePointerMonitor() {
        if let chromePointerToken { NSEvent.removeMonitor(chromePointerToken) }
        chromePointerToken = nil
    }

    /// Whether a tab's page can go into Zigzag Mini: an ordinary tab's web page or file. Not a pinned page's or a
    /// favorite's, which belong to the sidebar, nor Zigzag's own pages, nor a private window's: Zigzag Mini isn't
    /// private.
    nonisolated static func canTake(_ url: URL?, isPinned: Bool, isPrivate: Bool) -> Bool {
        guard !isPinned, !isPrivate, let url else { return false }
        return ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The app a link came from, to go back to when this closes, if you're still only here. Using a browser window
    /// in between means you're in Zigzag now, so closing this stays in Zigzag.
    private var returnTo: NSRunningApplication? {
        didSet {
            browserKeyToken.map(NotificationCenter.default.removeObserver)
            browserKeyToken = nil
            guard returnTo != nil else { return }
            browserKeyToken = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow, window is BrowserWindow else { return }
                // Its own window turns key as Zigzag comes forward for the link: that isn't using another one.
                MainActor.assumeIsolated {
                    guard let self, window !== self.window else { return }
                    self.returnTo = nil
                }
            }
        }
    }
    private var browserKeyToken: NSObjectProtocol?
    private var keepOnTopToken: NSObjectProtocol?

    private init(tab: Tab, frame: NSRect, overFullScreen: Bool) {
        self.tab = tab
        // Zigzag's own PDF viewer and Back to the page that opened it belong to a browser window's tabs; here the page
        // is shown outside a tab list, and becomes a full tab once it moves.
        tab.isOutsideTabList = true

        let window = BrowserWindow(contentRect: frame)
        window.minSize = Tokens.Metric.miniWindowMinSize
        window.collectionBehavior.remove(.fullScreenPrimary)
        // Opened over a full-screen window, it stays there in the same Space instead of opening off in another one.
        if overFullScreen { window.collectionBehavior.insert(.fullScreenAuxiliary) }
        window.setFrame(frame, display: false)
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        window.eventInterceptor = { [weak self] event in
            guard let self else { return false }
            if self.linksNote?.takes(event) == true { return true }
            return self.noteEscape(event)
        }
        window.setAccessibilityTitle(Self.name)
        // A waiting question while the window isn't key: the edge glows, and clicking it brings the window forward.
        root.attentionWaiting = { [weak self] in self?.questionsWaitingForPage ?? 0 }
        root.attentionClicked = { [weak self] in
            NSApp.activate()
            self?.window?.makeKeyAndOrderFront(nil)
        }

        strip.openButton.onClick = { [weak self] _ in self?.openInZigzag() }
        strip.title.onClick = { [weak self] _ in self?.openLocation(nil) }
        strip.title.drop.onDrop = { [weak self] destination in
            guard let self else { return false }
            self.tab.load(destination.url, httpFallback: destination.httpFallback)
            return true
        }
        strip.copyButton.onClick = { [weak self] _ in self?.copyPageURL(nil) }
        strip.expandButton.onClick = { [weak self] _ in self?.promoteFromPage() }
        strip.siteButton.onClick = { [weak self] _ in self?.showSiteControls() }
        strip.pinButton.onClick = { [weak self] _ in
            guard let self, !self.isDockedInPage, let window = self.window else { return }
            KeepOnTop.toggle(window)
        }
        keepOnTopToken = NotificationCenter.default.addObserver(forName: KeepOnTop.changed, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStrip() }
        }
        strip.spaceChip.onClick = { [weak self] _ in self?.showSpaceMenu() }
        strip.backButton.onClick = { [weak self] _ in self?.goBack(nil) }
        strip.forwardButton.onClick = { [weak self] _ in self?.goForward(nil) }
        // Right-click or hold Back or Forward: the pages that way, to jump several at once, as in a browser window.
        BrowserWindowController.showsHistory(strip.backButton, back: true) { [weak self] in self?.tab.webView }
        BrowserWindowController.showsHistory(strip.forwardButton, back: false) { [weak self] in self?.tab.webView }
        strip.reloadButton.onClick = { [weak self] _ in
            guard let self, !self.isLeaving else { return }
            self.tab.isLoading ? self.tab.stopLoading() : self.tab.reload()
        }
        root.card.showLoading(of: tab)

        tab.host = self
        tokens.append(tab.changed.observe { [weak self] change in self?.tabChanged(change) })
        // The space's color or name changed, or the space went: the window follows, as a browser window does.
        tokens.append(Library.shared.changed.observe { [weak self] in
            self?.settleProfile()
            self?.paint(animated: true)
            self?.refreshStrip()
        })
        // A shortcut changed in Settings: the button says the new one.
        tokens.append(Shortcuts.changed.observe { [weak self] in self?.refreshStrip() })
        paint(animated: false)
        showPage()
        refreshStrip()
        refreshBar(animated: false)
        window.trafficLightOrigin = NSPoint(x: Tokens.Sidebar.lightsX, y: round((Tokens.Metric.miniStripHeight - window.trafficLightHeight) / 2))
        strip.trafficLightsWidth = window.trafficLightsWidth
        window.onTrafficLightsOnScreenChange = { [weak self] in self?.refreshTrafficLightsRoom(animated: true) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The lights' room in the strip, none while full screen's title bar is up (#542).
    private func refreshTrafficLightsRoom(animated: Bool) {
        guard !isDockedInPage, let window = window as? BrowserWindow else { return }
        let width = window.trafficLightsOnScreen ? window.trafficLightsWidth : 0
        guard width != strip.trafficLightsWidth else { return }
        guard animated else { strip.trafficLightsWidth = width; return }
        Tokens.Motion.animate(Tokens.Motion.gentle, evenFromKeyboard: true, moves: true) {
            self.strip.trafficLightsWidth = width
            self.strip.layoutSubtreeIfNeeded()
        }
    }

    /// Where a new one goes: its size, cut to fit, centered on the screen's usable area, or on `middle` (the middle
    /// of the browser window its page came from) as far as the area allows. One already at that spot moves it a step
    /// down and right, and so on, the way a Mac cascades windows; past the screen's edge it goes back to the middle.
    static func frame(size: NSSize, in area: NSRect, taken: [NSRect], around middle: NSPoint? = nil) -> NSRect {
        let size = NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
        let mid = middle ?? NSPoint(x: area.midX, y: area.midY)
        let center = NSRect(x: min(max(area.minX, round(mid.x - size.width / 2)), area.maxX - size.width),
                            y: min(max(area.minY, round(mid.y - size.height / 2)), area.maxY - size.height),
                            width: size.width, height: size.height)
        let step = Tokens.Space.x6
        var frame = center
        func isTaken(_ frame: NSRect) -> Bool {
            taken.contains { abs($0.minX - frame.minX) < 2 && abs($0.maxY - frame.maxY) < 2 }
        }
        while isTaken(frame) {
            frame = frame.offsetBy(dx: step, dy: -step)
            guard area.contains(frame) else { return center }
        }
        return frame
    }

    /// Where one opened from the quick open bar goes: centered under the bar, its top where the bar's was, inside the
    /// screen's usable area.
    static func frame(size: NSSize, under bar: NSRect, in area: NSRect) -> NSRect {
        let size = NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
        let x = min(max(area.minX, round(bar.midX - size.width / 2)), area.maxX - size.width)
        let y = min(max(area.minY, bar.maxY - size.height), area.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The space it wears and Open in moves its page to: the one you were in as it opened, or the one chosen on the
    /// strip; the first one if that space has gone.
    var space: SpaceInfo { Library.shared.space(tab.spaceID) ?? Library.shared.spaces[0] }

    private func paint(animated: Bool) {
        root.paint(space, isPrivate: isPrivate, animated: animated)
        strip.refreshColors()
    }

    /// The spaces, from the strip's space: the one chosen is where Open in takes the page, and the window wears it.
    private func showSpaceMenu() {
        // A private page keeps to its private window's space.
        guard !isLeaving, !isPrivate else { return }
        let current = space.id
        func entry(_ other: SpaceInfo) -> MenuPanel.Entry {
            let symbol = other.icon.flatMap { IconChoice.isSymbol($0) ? $0 : nil }
            let image = symbol == nil ? MiniSpaceChip.picture(of: other, size: DropdownButton.iconSide) : nil
            return .item(.init(title: other.name, image: image, symbol: symbol, isChecked: other.id == current) { [weak self] in
                self?.choose(space: other.id)
            })
        }
        // Under their profiles' names once there's more than one: a space on another profile reloads the page there.
        let entries: [MenuPanel.Entry] = Library.shared.hasManyOfYourProfiles
            ? Library.shared.spaceGroups().flatMap { group in [.header(group.profile.displayName)] + group.spaces.map(entry) }
            : Library.shared.yourSpaces.map(entry)
        strip.spaceChip.isSelected = true
        MenuPanel.show(entries, from: strip.spaceChip) { [weak self] in self?.strip.spaceChip.isSelected = false }
    }

    private func choose(space id: UUID) {
        guard !isPrivate, id != tab.spaceID, Library.shared.space(id) != nil, let host = window?.contentView else { return }
        // To a space on another profile the page reloads there: asked first, as in a browser window.
        ProfileSheets.confirmCrossing([tab], to: id, in: host) { [weak self] in
            guard let self else { return }
            self.move(to: Profiles.shared.profile(forSpace: id)) { self.tab.setSpace(id) }
            self.paint(animated: true)
            self.refreshStrip()
        }
    }

    /// Its space was put on another profile, or its profile was removed: the page is rebuilt where it now belongs,
    /// as a browser window's tabs are.
    func settleProfile() { move(to: tab.homeProfile) { tab.settleProfile() } }

    /// Does something that takes the page to `target`'s profile. If that's another profile, this window is then
    /// that profile's extensions' to know, not the one it left: it closes for one set and opens for the other.
    private func move(to target: Profile, _ change: () -> Void) {
        let crossing = target !== tab.profile
        if #available(macOS 15.4, *), crossing { ExtensionCenter.miniClosed(self) }
        change()
        if #available(macOS 15.4, *), crossing { ExtensionCenter.miniOpened(self) }
    }

    // MARK: Coming and going

    /// Fades in at the window server while its content grows the last few percent toward you, out of the bar it came
    /// from or its own top middle. With Reduce Motion it only fades.
    private func appear(from origin: NSRect?) {
        guard let window else { return }
        window.alphaValue = 0
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.enter * Tokens.Motion.debugSlowdown
            context.timingFunction = Tokens.Motion.easeOut
            window.animator().alphaValue = 1
        }
        guard !Tokens.Motion.reduceMotion, let layer = root.layer else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Tokens.Motion.scale(Tokens.Motion.enterScale, of: layer, around: CGPoint(x: 0.5, y: 0), flipped: false))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = Tokens.Motion.enter * Tokens.Motion.debugSlowdown
        grow.timingFunction = Tokens.Motion.easeOut
        layer.add(grow, forKey: "appear")
    }

    /// The one way it leaves, closing or moving into Zigzag: a quick fade as it eases a touch smaller, quieter than
    /// it came.
    private func fadeAway(then done: @escaping @MainActor () -> Void) {
        guard let window else { done(); return }
        isLeaving = true
        // Open in pressed before the window finished fading in has no alpha to animate away. AppKit then never calls
        // the group's completion, so the page would wait for an animation that can't run. The same goes for a window
        // ordered out under the browser's chrome.
        guard window.isVisible, window.alphaValue > 0.001 else {
            window.alphaValue = 0
            done()
            return
        }
        if !Tokens.Motion.reduceMotion, let layer = root.layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: Tokens.Motion.scale(Tokens.Motion.exitScale, of: layer, flipped: false))
            shrink.duration = Tokens.Motion.exit * Tokens.Motion.debugSlowdown
            shrink.timingFunction = Tokens.Motion.easeOut
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "leave")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.exit * Tokens.Motion.debugSlowdown
            context.timingFunction = Tokens.Motion.easeOut
            window.animator().alphaValue = 0
        }, completionHandler: Tokens.Motion.completion(done))
    }

    // MARK: The page

    private func showPage() {
        root.card.show(tab.ensureWebView())
        root.card.hidePlaceholder()
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .url, .loading, .title, .favicon, .webView, .navigation:
            refreshStrip()
            window?.title = tab.displayTitle
            // A new web view (the page crashed and came back, or crossed into an extension's page) takes the old one's place.
            if change == .webView, tab.webView != nil, !movedOut { showPage() }
            if change == .webView || change == .loading { refreshBar(animated: false) }
        case .themeColor, .darkPage:
            refreshBar(animated: true)
        default: break
        }
    }

    /// The strip in the page's own color (`PageBar`), its ink light or dark to read on it.
    private func refreshBar(animated: Bool) {
        root.bar.show(bar: PageBar.color(for: tab), page: tab.pageColor, animated: animated)
        strip.appearance = root.bar.inkAppearance
        strip.refreshColors()
    }

    /// "Open in Work": what the button and ⌘O's menu item say, with the space the page goes to.
    private var openTitle: String {
        String(localized: "Open in \(placeName)", comment: "The button in Zigzag Mini's top strip, and the File menu item in place of Open File… while it's in front: moves its page into a browser window as a tab, in this space. The placeholder is the space's name.")
    }

    /// Where Open in takes the page: its space, or Private as a private window's sidebar heads itself.
    private var placeName: String {
        isPrivate ? String(localized: "Private", comment: "The heading at the top of a private window's sidebar, where a space's name would be.") : space.name
    }

    private func refreshStrip() {
        strip.title.show(tab)
        strip.spaceChip.show(space, name: isPrivate ? placeName : nil)
        // A private page keeps to its window's space: nothing to choose.
        strip.spaceChip.isEnabled = !isPrivate
        strip.openButton.show(openTitle, keys: Shortcuts.keys(for: #selector(openDocument(_:))))
        strip.refreshTips()
        strip.openButton.isEnabled = tab.url != nil
        strip.copyButton.isEnabled = tab.url != nil
        strip.siteButton.isEnabled = tab.url != nil
        strip.showNavigation(canGoBack: tab.canGoBack, canGoForward: tab.canGoForward, isLoading: tab.isLoading)
        KeepOnTop.refresh(strip.pinButton, for: window)
        // Docked, the pin has nothing to keep on top of: it steps aside rather than explaining itself.
        strip.hidesPin = isDockedInPage
        strip.expandButton.isHidden = !isDockedInPage
        strip.needsLayout = true
    }

    // MARK: Typing an address

    /// ⌘T from the Mini: the new tab belongs to the browser, and a docked Mini steps aside first so the bar it opens
    /// isn't hidden under the page it was over.
    @objc func newTab(_ sender: Any?) {
        let target = browserTarget
        if isDockedInPage { closeInPage(focusBack: false, animated: false) }
        target.newTab(sender)
        Self.bringForward(target)
    }

    /// ⌘L: the command bar over the page's site, the address in it to change; again, it goes.
    @objc func openLocation(_ sender: Any?) {
        guard !isLeaving else { return }
        if commandBar.isVisible { commandBar.dismiss(); return }
        commandBar.show(mode: .editCurrent)
    }

    /// Esc puts Zigzag Mini away, as it does Spotlight or Quick Look: it's there for a quick look. Only an Esc the page
    /// left alone gets here, and the command bar and Zigzag's questions over the page take their own. It stays when the
    /// page has a dialog of its own open (many close on Esc without telling WebKit they took it), and in a field you're
    /// typing in, also inside a frame or a web component, the first Esc only leaves the field, so a half-written reply
    /// never goes on a stray key.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        escape()
    }

    override func cancelOperation(_ sender: Any?) { escape() }

    /// Docked, the Mini is still its own window (a child of the browser's), and that is the window menus, questions,
    /// `window.close()`, find and the command bar have to see.
    private var presentationWindow: NSWindow? { window }

    private func closeFromEscape() {
        if isDockedInPage { closeInPage() } else { window?.performClose(nil) }
    }

    private func escape() {
        guard !isLeaving, !commandBar.isVisible, !overlay.subviews.contains(where: { $0 is PermissionPrompt || $0 is SavePasswordPrompt }) else { return }
        guard let webView = tab.webView, let focused = presentationWindow?.firstResponder as? NSView,
              focused.isDescendant(of: webView) else {
            closeFromEscape()
            return
        }
        // What the page was doing as Esc arrived (noted before the page saw it, in `noteEscape`), since by now its
        // handler may have closed its dialog. Typing: the field lets go of the focus, and the window stays. Asked in
        // Zigzag's own script world, where the page can't see the note or change what the script finds.
        let decide = """
            (() => {
              const was = window.__zigzagEsc ?? (\(Self.escapeState));
              delete window.__zigzagEsc;
              if (was === 'typing') {
                let e = document.activeElement;
                while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
                e?.blur();
              }
              return was;
            })()
            """
        webView.evaluateJavaScript(decide, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard (try? result.get()) as? String == "" else { return }
                self?.closeFromEscape()
            }
        }
    }

    /// Whether the page is in the middle of something Esc shouldn't end: "typing" in a field (inside a frame or a web
    /// component too), "dialog" with one of its own dialogs open, or "" when it's just a page.
    private static let escapeState = """
        (() => {
          let e = document.activeElement;
          while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
          // Only a field with something in it: many sites put the cursor in their empty search box on load.
          if (e && e.isContentEditable && e.textContent.trim()) return 'typing';
          if (e && /^(input|textarea)$/i.test(e.tagName) && e.value) return 'typing';
          if (e && /^iframe$/i.test(e.tagName)) return 'typing';
          // Only a dialog you can see: many sites keep theirs in the page, hidden, until they're needed.
          const shown = (d) => { const r = d.getBoundingClientRect(); const s = getComputedStyle(d);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0'; };
          return [...document.querySelectorAll('dialog[open], [aria-modal="true"]')].some(shown) ? 'dialog' : '';
        })()
        """

    /// When the last Esc came, for a second one close behind it.
    private var lastEscape: TimeInterval = 0
    private static let doubleEscape: TimeInterval = 0.6

    /// Called as Esc comes in, before the page gets it: WebKit runs this script ahead of the key, so the note says
    /// what the page looked like before its own Esc handler ran.
    func noteEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53, !event.isARepeat else { return false }
        // Esc twice in a row always closes it, whatever the page did with the first (some take it for themselves).
        let now = event.timestamp
        defer { lastEscape = now }
        if now - lastEscape < Self.doubleEscape, !isLeaving, !commandBar.isVisible,
           !overlay.subviews.contains(where: { $0 is PermissionPrompt || $0 is SavePasswordPrompt }) {
            closeFromEscape()
            return true
        }
        guard !commandBar.isVisible, !isLeaving, let webView = tab.webView,
              let focused = presentationWindow?.firstResponder as? NSView, focused.isDescendant(of: webView),
              !overlay.subviews.contains(where: { $0 is PermissionPrompt || $0 is SavePasswordPrompt }) else { return false }
        // Asked before the page gets the key, as some sites keep Esc for themselves (Bing's search box): just a page,
        // and Esc closes Zigzag Mini; typing in a box with text, or a dialog of the site's showing, it goes to the page.
        webView.evaluateJavaScript(Self.escapeState, in: nil, in: .defaultClient) { [weak self, weak webView] result in
            MainActor.assumeIsolated {
                guard let self, let webView else { return }
                let state = (try? result.get()) as? String ?? ""
                if state.isEmpty {
                    self.closeFromEscape()
                } else {
                    // Noted for the Esc the page leaves alone, which comes back to `escape`: typing, the field lets go.
                    webView.evaluateJavaScript("window.__zigzagEsc = '\(state)'", in: nil, in: .defaultClient)
                    webView.keyDown(with: event)
                }
            }
        }
        return true
    }

    #if DEBUG
    var debugAddressDrop: AddressDrop { strip.title.drop }

    func debugEnter(_ text: String) {
        if !commandBar.isVisible { commandBar.show(mode: .editCurrent) }
        commandBar.debugType(text)
        commandBar.debugEnter()
    }

    /// minibar [text]: the command bar over the page, with this typed in it.
    func debugBar(_ text: String) {
        if !commandBar.isVisible { commandBar.show(mode: .editCurrent) }
        if !text.isEmpty { commandBar.debugType(text) }
    }

    /// minispace [name]: the strip's space menu, or that space chosen from it.
    func debugSpace(_ name: String) {
        if let id = Library.shared.yourSpaces.first(where: { $0.name == name })?.id { choose(space: id) } else { showSpaceMenu() }
    }

    /// minifind [text]: opens the find bar with this text; minifind close closes it.
    func debugFind(_ text: String) {
        if text == "close" { findBar.hide() } else { findBar.show(query: text.isEmpty ? nil : text) }
    }

    /// mininote gotit|tabs: answers the links note as its buttons do.
    func debugLinksNote(_ answer: String) {
        guard linksNote != nil else { return }
        answerLinksNote(useTabs: answer == "tabs")
    }

    func debugHoverStrip(_ name: String) { strip.debugHover(name) }

    func debugEscape() {
        if commandBar.isVisible { commandBar.debugEscape() } else { cancelOperation(nil) }
    }

    var debugState: [String: Any] {
        ["editing": commandBar.isVisible, "private": isPrivate, "fromPage": fromPage,
         "sourceWindow": source?.window?.windowNumber ?? 0, "titleShown": !strip.title.isHidden, "title": strip.title.text,
         "space": space.name, "profile": Library.shared.directory.profile(tab.profile.id)?.name ?? "",
         "store": tab.webView?.configuration.websiteDataStore.identifier?.uuidString ?? (tab.webView == nil ? "no page" : "default"),
         "open": strip.openButton.title, "openEnabled": strip.openButton.isEnabled,
         "backEnabled": strip.backButton.isEnabled, "forwardEnabled": strip.forwardButton.isEnabled, "reload": strip.reloadButton.symbol,
         "strip": strip.debugFrames, "webViewHere": tab.webView?.window === window, "movedOut": movedOut,
         "loading": tab.isLoading, "alpha": window?.alphaValue ?? 0,
         "fullScreenAuxiliary": window?.collectionBehavior.contains(.fullScreenAuxiliary) == true, "glass": root.debugGlass]
    }
    #endif

    // MARK: Moving into Zigzag

    /// The browser window this one's pages go to: the front everyday window on this desktop, else the front one
    /// anywhere, else the session brought back, else a new one. Never a private window: Zigzag Mini isn't private.
    static func browserWindow() -> BrowserWindowController {
        let manager = WindowManager.shared
        let key = manager.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        let everyday = manager.controllers.filter { !$0.tabManager.isPrivate }
        let frontToBack = NSApp.orderedWindows.compactMap { window in everyday.first { $0.window === window } }
        let here = Self.window(front: key, frontToBack: frontToBack) { controller in
            guard let window = controller.window else { return false }
            return window.isOnActiveSpace && window.isVisible && !window.isMiniaturized
        }
        return here ?? key ?? everyday.last ?? manager.restoreIfNoWindows() ?? manager.newWindow(showCommandBar: false)
    }

    /// The window in front when it's on this desktop, else the frontmost one that is; nil when none is.
    nonisolated static func window<W>(front: W?, frontToBack: [W], isHere: (W) -> Bool) -> W? {
        if let front, isHere(front) { return front }
        return frontToBack.first(where: isHere)
    }

    /// Zigzag comes forward with the window the page went to, switching to its desktop when it's on another one.
    private static func bringForward(_ target: BrowserWindowController) {
        guard let window = target.window else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !NSApp.isActive {
            // Only this window comes up, not every browser window held for a link.
            MiniLinkWake.activatingForOneWindow()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The window it came from while that's open, minimized or hidden too: its pages and private store stay with it.
    private var openSource: BrowserWindowController? {
        guard let source, source.window != nil, !source.windowClosed else { return nil }
        return source
    }

    /// Where this one's pages go: from a page, the window it came from while it's open; private, only a private window.
    var browserTarget: BrowserWindowController {
        if let openSource { return openSource }
        if isPrivate {
            return WindowManager.shared.controllers.last { $0.tabManager.isPrivate } ?? WindowManager.shared.newWindow(showCommandBar: false, isPrivate: true)
        }
        return Self.browserWindow()
    }

    /// Moves the page, live, into a browser window as its selected tab, in the space chosen on the strip: this window
    /// fades away first, then the page is there.
    @objc func openInZigzag(_ sender: Any? = nil) { moveOut() }

    /// `then`: runs in the browser window the page went to.
    private func moveOut(then: ((BrowserWindowController) -> Void)? = nil) {
        guard tab.url != nil, !movedOut, !isLeaving else { return }
        // You're going to Zigzag, not back to the app the link came from.
        returnTo = nil
        commandBar.dismiss(restoringFocus: false)
        linkStatus.hide()
        fadeAway { [weak self] in
            guard let target = self?.moveIntoZigzag() else { return }
            then?(target)
        }
    }

    @discardableResult
    private func moveIntoZigzag() -> BrowserWindowController {
        let target = browserTarget
        // Site routes (#286): move the page itself when the space shares the profile, else reopen it there with that
        // space's sign-ins. Never for a private page.
        let routed = isPrivate ? nil : tab.url.flatMap { SiteRoutes.target(for: $0, arrival: .fromMini, from: space.id, place: .mini, routes: Library.shared.siteRoutes) }
            .flatMap { Library.shared.space($0) != nil ? $0 : nil }
        if let routed, let url = tab.url, Library.shared.profileID(ofSpace: routed) != Library.shared.profileID(ofSpace: space.id) {
            // The page has the other profile's cookies: close this window and reopen it there.
            window?.close()
            target.tabManager.switchToSpace(routed)
            target.tabManager.newTab(url: url, spaceID: routed, by: .zigzag)
            Self.bringForward(target)
            target.toastRouted(to: routed)
            return target
        }
        let spaceID = routed ?? space.id
        letGo()
        target.tabManager.switchToSpace(spaceID)
        // From a page: right after the tab it came from, when that's still in this space.
        let placed = fromPage && routed == nil && target === source && sourceTab.map { target.tabManager.insert(tab, after: $0) } == true
        if !placed { target.tabManager.insertAsNewTab(tab) }
        window?.close()
        Self.bringForward(target)
        if let routed { target.toastRouted(to: routed) }
        return target
    }

    /// The page is leaving for a browser window: this window lets go of it, and closing leaves it open.
    private func letGo() {
        if SitePanel.isOpen(in: window) { SitePanel.closeCurrent() }
        settleLinksNote()
        movedOut = true
        madeFindBar?.hide()
        pageGone.send()
        tokens.removeAll()
        Autofill.shared.forget(windowOf: window)
        if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
        tab.pageHolder?.removeFromSuperview()
        tab.isOutsideTabList = false
    }

    /// ⌘Z after Open in Zigzag Mini: the page goes back to the browser window it came from, and this window closes at
    /// once. Returns the tab, or nil if the page has gone already (moved into Zigzag, or closing).
    func handBack() -> Tab? {
        guard !movedOut, !isLeaving, !isClosing, !tab.isClosed else { return nil }
        commandBar.dismiss(restoringFocus: false)
        linkStatus.hide()
        letGo()
        window?.close()
        return tab
    }

    /// ⌘O, as in Arc: Open File… becomes Open in (the space) while this window is in front.
    @objc func openDocument(_ sender: Any?) { openInZigzag(sender) }

    /// The strip's Copy Link, and ⇧⌘C: the page's address, with the toast a browser window shows.
    @objc func copyPageURL(_ sender: Any?) {
        guard let url = tab.url, !isLeaving else { return }
        CleanLink.write(url, title: tab.displayTitle)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", over: overlay, area: overlay.bounds)
    }

    /// The strip's Site Controls: the browser window's site panel for this page, Dark page and all (#225).
    func showSiteControls() {
        guard !isLeaving, !movedOut else { return }
        SitePanel.toggle(in: self, from: strip.siteButton)
    }

    /// The site panel's Clear Cookies and Clear Cache, asking first over the page as a browser window does.
    func confirmClear(_ kind: WebsiteData.Kind, of tab: Tab) {
        BrowserWindowController.confirmClear(kind, of: tab, over: overlay) { [weak self] text in
            guard let self else { return }
            Toast.show(text, symbol: "checkmark.circle", over: self.overlay, area: self.overlay.bounds)
        }
    }

    // MARK: Menu commands while it's in front

    /// ⌘W closes the page, and with it the window: it holds nothing else.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
    @objc func goBack(_ sender: Any?) { tab.goBack() }
    @objc func goForward(_ sender: Any?) { tab.goForward() }
    @objc func reloadPage(_ sender: Any?) { tab.reload() }
    @objc func reloadPageFromOrigin(_ sender: Any?) { tab.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { tab.stopLoading() }

    @objc func printPage(_ sender: Any?) {
        guard let webView = tab.webView, !movedOut, !isLeaving else { return }
        PagePrinting.print(webView, in: window, completion: {})
    }

    @objc func showFindBar(_ sender: Any?) { findBar.toggle() }

    /// Its page still shows here: not moved into a browser window, not closing.
    var holdsPage: Bool { !movedOut && !isClosing }

    /// The browser window that translates this page, with its toasts over this one: the window it came from, else an
    /// open one of the same privacy.
    var translator: BrowserWindowController? {
        if let openSource { return openSource }
        return WindowManager.shared.controllers.last { $0.tabManager.isPrivate == isPrivate }
    }

    /// View › Translate Page, and the page's menu: translates the page here, or shows it as it was.
    @objc func translatePage(_ sender: Any?) {
        guard !isLeaving, holdsPage else { return }
        translator?.translatePage(tab: tab)
    }

    /// The Zigzag Mini a window is, for a page's menu that asks to translate.
    static func showing(_ window: NSWindow?) -> MiniWindowController? {
        window.flatMap { window in all.first { $0.window === window } }
    }
    @objc func findNextMatch(_ sender: Any?) { findBar.next(backwards: false) }
    @objc func findPreviousMatch(_ sender: Any?) { findBar.next(backwards: true) }
    @objc func useSelectionForFind(_ sender: Any?) {
        tab.webView?.runOwnScript("window.getSelection().toString()") { [weak self] answer in
            let result = try? answer.get()
            MainActor.assumeIsolated {
                guard let text = result as? String, !text.isEmpty else { return }
                self?.findBar.show(query: text)
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(ZoomLevels.step(webView.pageZoom, by: 1))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(ZoomLevels.step(webView.pageZoom, by: -1))
    }

    @objc func actualSize(_ sender: Any?) {
        setZoom(ZoomLevels.defaultZoom)
        tab.webView?.magnification = 1
    }

    /// The same zoom a tab keeps for the site, so the page looks the same once it moves into Zigzag.
    private func setZoom(_ zoom: CGFloat) {
        guard let webView = tab.webView, let url = tab.url else { return }
        webView.pageZoom = zoom
        ZoomLevels.set(zoom, for: url)
    }

    @objc func showWebInspector(_ sender: Any?) {
        guard let webView = tab.webView, webView.responds(to: NSSelectorFromString("_inspector")),
              let inspector = webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")) else { return }
        inspector.perform(NSSelectorFromString("show"))
    }

    // MARK: Closing

    /// Closing fades it away first, however it's closed (⌘W, the red light, an extension); the page goes with it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isLeaving else { return false }
        // Opened from another app and closed straight from here: back to that app, before this one fades, so no
        // browser window comes forward in its place.
        if let app = returnTo, !app.isTerminated, NSApp.keyWindow === window, Self.all.count == 1 {
            app.activate()
        }
        commandBar.dismiss(restoringFocus: false)
        fadeAway { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Closed from the keyboard, a menu or the app quitting while docked: the dim and the host's record go with it.
        if isDockedInPage {
            onInPageMiniClosed?()
            releaseDock()
        }
        removeChromePointerMonitor()
        returnTo = nil
        isClosing = true
        settleLinksNote()
        madeFindBar?.hide()
        if SitePanel.isOpen(in: window) { SitePanel.closeCurrent() }
        pageGone.send()
        linkStatus.hide()
        Autofill.shared.forget(windowOf: window)
        if !movedOut {
            tokens.removeAll()
            if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab, windowClosing: true) }
            tab.close()
        }
        if #available(macOS 15.4, *) { ExtensionCenter.miniClosed(self) }
        // Getting started's ⇧-click step is done once a Mini from a page closes or moves into a tab.
        if fromPage { Tutorial.complete("peek") }
        keepOnTopToken.map(NotificationCenter.default.removeObserver)
        keepOnTopToken = nil
        Self.all.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if #available(macOS 15.4, *) { ExtensionCenter.miniFocused(self) }
        // Became key: show a held question.
        promptFrontChanged.send()
    }

    func windowDidResignKey(_ notification: Notification) {
        // No longer key: the question waits and the edge glows.
        promptFrontChanged.send()
    }

    /// Remember the manual size for the next one.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let size = window?.frame.size else { return }
        Self.rememberedSize = size
    }

    // MARK: Handing off to an app

    /// Whether a Zigzag Mini closes after its page opened a Mac app: always when it has no page (the link went straight
    /// to the app), and for external links when the page got there itself, not by a click (a sign-in returning to the
    /// app, a meeting link).
    nonisolated static func closesAfterOpeningApp(hasPage: Bool, fromAnotherApp: Bool, isMainFrame: Bool, linkClick: Bool) -> Bool {
        !hasPage || (fromAnotherApp && isMainFrame && !linkClick)
    }

    /// A page opened an app (`ExternalLinks`): close its Zigzag Mini when there's nothing left to show, leaving the app
    /// in front.
    static func pageOpenedApp(_ webView: WKWebView, isMainFrame: Bool, linkClick: Bool) {
        guard let mini = all.first(where: { $0.tab.webView === webView }), !mini.isLeaving, !mini.movedOut else { return }
        let hasPage = webView.backForwardList.currentItem != nil && webView.url.map { $0.absoluteString != "about:blank" } ?? false
        guard closesAfterOpeningApp(hasPage: hasPage, fromAnotherApp: mini.fromAnotherApp, isMainFrame: isMainFrame, linkClick: linkClick) else { return }
        // The opened app comes forward, not the link's source app.
        mini.returnTo = nil
        mini.window?.performClose(nil)
    }
}

// MARK: - Through an update's restart

extension MiniWindowController {
    /// This window as an update's restart brings it back: its page, back/forward list, space, place and Keep on Top.
    var savedForRelaunch: UpdateRelaunch.Mini? {
        // A docked Mini belongs to its page: reopening it as a window would strand a second copy of the page.
        guard !isLeaving, !isDockedInPage, !isPrivate, let window, let url = tab.url else { return nil }
        let frame = window.frame
        return UpdateRelaunch.Mini(url: url, title: tab.title, spaceID: tab.spaceID,
                                   frame: [frame.origin.x, frame.origin.y, frame.width, frame.height],
                                   keepOnTop: KeepOnTop.isOn(window), interactionState: tab.interactionStateForSaving)
    }

    /// Opens one again as it was before an update's restart. A space that's gone gives way to the one Zigzag Mini
    /// uses now; a place on a screen no longer there, to the middle of the screen.
    @discardableResult
    static func reopen(_ saved: UpdateRelaunch.Mini) -> MiniWindowController {
        let space = Library.shared.space(saved.spaceID) != nil ? saved.spaceID : MiniQuickOpen.space.id
        let tab = Tab(url: saved.url, title: saved.title, spaceID: space, interactionState: saved.interactionState)
        let f = saved.frame
        let area = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        var frame = f.count == 4 ? NSRect(x: f[0], y: f[1], width: f[2], height: f[3]) : nil
        if let rect = frame, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { frame = nil }
        let controller = MiniWindowController(tab: tab, frame: frame ?? Self.frame(size: openingSize, in: area, taken: all.compactMap { $0.window?.frame }),
                                              overFullScreen: false)
        all.append(controller)
        controller.appear(from: nil)
        if #available(macOS 15.4, *) { ExtensionCenter.miniOpened(controller) }
        if saved.keepOnTop, let window = controller.window { KeepOnTop.set(true, for: window) }
        return controller
    }
}

extension MiniWindowController: SideButtonHistory {
    func sideButtonHistory(back: Bool) -> NSMenu? { BrowserWindowController.historyMenu(of: tab.webView, back: back) }
}

extension MiniWindowController: SitePanelPageHost {
    var listsExtensions: Bool { false }
}

// MARK: - Its menu items

extension MiniWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openDocument(_:)):
            item.title = openTitle
            return tab.url != nil && !isLeaving
        case #selector(copyPageURL(_:)): return tab.url != nil && !isLeaving
        case #selector(goBack(_:)): return tab.canGoBack
        case #selector(goForward(_:)): return tab.canGoForward
        case #selector(stopLoading(_:)): return tab.isLoading
        case #selector(printPage(_:)): return tab.webView != nil && !movedOut && !isLeaving
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)): return !isLeaving && madeFindBar?.hasQuery == true
        case #selector(translatePage(_:)):
            item.title = tab.isTranslated ? String(localized: "Show Original", comment: "Menu bar item: shows the translated page as it was.")
                                          : String(localized: "Translate Page", comment: "Menu bar item: translates the page.")
            return tab.url != nil && !isLeaving && holdsPage && translator != nil
        default: return !isLeaving
        }
    }
}

// MARK: - Find on its page

extension MiniWindowController: FindBarHost {
    var findBarHeaderHeight: CGFloat { 0 }
    var findBarOverlay: NSView { overlay }
    var findBarIsCovered: Bool { commandBar.isVisible }
    var findableWebView: WKWebView? { movedOut ? nil : tab.webView }
    var findablePDF: PDFViewerView? { nil }
}

// MARK: - Its space

extension MiniWindowController: SpaceTinted {
    var tintSpace: SpaceInfo? { space }
}

/// Over the whole window, as in a browser window.
extension MiniWindowController: SwipeArrowHost {
    var swipeArrowLayer: NSView { root.barLayer }
}

// MARK: - The command bar over it

extension MiniWindowController: CommandBarHost {
    var commandBarOverlay: NSView { root.barLayer }
    var commandBarPageFrame: NSRect { root.card.frame }
    /// Always over the page's site, in the middle of the strip, whatever opened it.
    func commandBarAnchor(asked: NSView?) -> NSView? { strip.anchor }
    var commandBarCentersOnAnchor: Bool { true }
    var commandBarFitsAnchor: Bool { true }
    var commandBarTabs: TabManager? { isPrivate ? source?.tabManager : MiniQuickOpen.tabs }
    var commandBarProfile: Profile { tab.profile }
    var commandBarTab: Tab? { tab }
    var commandBarSpace: SpaceInfo? { space }
    var commandBarIsPrivate: Bool { isPrivate }

    func commandBarWillShow() {
        linkStatus.hide()
        strip.title.isHidden = true
        strip.isEditing = true
        strip.layoutSubtreeIfNeeded()
    }

    func commandBarRestoreFocus() {
        if let webView = tab.webView { window?.makeFirstResponder(webView) }
    }

    func commandBarDidHide() {
        strip.title.isHidden = false
        strip.isEditing = false
    }

    /// The field takes the strip's light or dark, not the window's: it sits in the strip.
    var commandBarAppearance: NSAppearance? { strip.effectiveAppearance }

    /// What you choose opens here, in place of this page; an open tab is gone to in its browser window.
    func commandBarOpen(_ kind: CommandResult.Kind, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool {
        if MiniQuickOpen.switchToTab(kind) { return true }
        guard let page = MiniQuickOpen.page(for: kind) else { return true }
        tab.isSearchTab = page.search
        tab.load(page.url, by: .you, httpFallback: page.httpFallback)
        strip.title.isHidden = false
        commandBarRestoreFocus()
        return true
    }
}

// MARK: - Its page's requests

extension MiniWindowController: TabHost {
    var hostWindow: NSWindow? { window }

    /// One page lives here: a link that asks for a tab of its own goes to a browser window, as a sign-in popup's does.
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition, by sender: Tab.LoadSender = .page) {
        // A page's link (Tab sends only links to the web here): the page's doing wherever it opens.
        switch disposition {
        case .currentTab, .mini:
            tab.load(url, by: sender)
        case .newWindow, .privateWindow:
            WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: isPrivate || disposition == .privateWindow, by: sender)
        case .foregroundTab, .backgroundTab:
            // Docked, a tab that comes to the front takes this window's focus and closes the peek. It stays here; a
            // background tab does not take the focus, so it is still a tab.
            if isDockedInPage, disposition == .foregroundTab {
                tab.load(url, by: sender)
                return
            }
            let target = browserTarget
            target.open(url, disposition: disposition, allowSwitch: false, by: sender)
            if disposition == .foregroundTab { target.window?.makeKeyAndOrderFront(nil) }
        }
    }

    /// Whether a link that asks for a window of its own stays in the docked peek instead. The line is focus: anything
    /// that would select a tab in the same browser window closes the peek, so it goes where the click did. A background
    /// tab, another window, a menu command (`pending`) or a sized popup does not take this window's focus, and needs no
    /// reroute.
    nonisolated static func keepsDockedLink(navigationType: WKNavigationType, opensInBackground: Bool,
                                            hasWindowFeatures: Bool, hasPendingCommand: Bool, loads: Bool) -> Bool {
        guard !opensInBackground, !hasPendingCommand, !hasWindowFeatures, loads else { return false }
        return navigationType == .linkActivated || navigationType == .other
    }

    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView? {
        let pending = BrowserWebView.takePendingDisposition(for: tab.webView)
        // Open Link in Zigzag Mini, in Zigzag Mini: the link opens right here, as a ⇧-click on it does.
        if pending == .mini, let url = action.request.url {
            tab.load(url, by: .page)
            return nil
        }
        // Docked: only a request that would take this window's focus is rerouted into the peek. A background tab,
        // another window, a menu command or a sized popup is left to do what it says.
        let hasFeatures = features.width != nil || features.height != nil || features.toolbarsVisibility?.boolValue == false
        let opensInBackground = (action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift))
            || (action.buttonNumber == 4 && !action.modifierFlags.contains(.shift))
        if isDockedInPage, let url = action.request.url,
           Self.keepsDockedLink(navigationType: action.navigationType, opensInBackground: opensInBackground,
                                hasWindowFeatures: hasFeatures, hasPendingCommand: pending != nil,
                                loads: Tab.route(forPageLink: url, from: tab.url) == .load) {
            tab.load(url, by: .page)
            return nil
        }
        if pending == .newWindow || pending == .privateWindow, let url = action.request.url {
            if Tab.route(forPageLink: url, from: tab.url) == .load {
                WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: isPrivate || pending == .privateWindow, by: .page)
            } else {
                tab.openFromPage(url, isClick: true, asker: action.sourceFrame.securityOrigin)
            }
            return nil
        }
        // Sized window.open() calls are sign-in and payment popups: their own small window, over this one.
        if pending == nil, features.width != nil || features.height != nil || features.toolbarsVisibility?.boolValue == false {
            return PopupWindowController.open(configuration: configuration, features: features, parent: window, opener: tab)
        }
        // A link for a new tab (target=_blank, ⌘-click, Open Link in New Tab) opens in the browser window; ⌘ and the
        // menu's own items leave you here. Docked, the middle button opens it behind too, and a plain click was
        // handled above.
        let background = pending != nil || (action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift))
            || (isDockedInPage && action.buttonNumber == 4 && !action.modifierFlags.contains(.shift))
        let target = browserTarget
        let newTab = target.tabManager.newTab(url: nil, select: !background, configuration: configuration, site: action.request.url)
        if !background { target.window?.makeKeyAndOrderFront(nil) }
        return newTab.ensureWebView()
    }

    func tabDidRequestClose(_ tab: Tab) { window?.performClose(nil) }
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tabWantsToBeShown(_ tab: Tab) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func tab(_ tab: Tab, hoveringLink url: URL?) {
        linkStatus.show(url, in: overlay.bounds)
    }
}

// MARK: - The window's content

/// Zigzag Mini's content: the slim strip on top in the page's own color (`PageBar`), and the page under it edge to
/// edge, meeting the strip as one surface, as a web app's window is in Chrome or Safari; the window rounds its own
/// corners. The space it goes to is the strip's chip, and the window's light or dark (`SpaceFrameView`) its own.
final class MiniRootView: SpaceFrameView {
    let bar = PageBarView()
    let strip = MiniStripView()
    let card = PageCardView()
    /// Over the page: the link under the pointer, a site's question, a toast.
    let overlay = PassthroughView()
    /// Over the whole window: the command bar.
    let barLayer = PassthroughView()
    /// Glow on the window edge while a question waits and the window isn't key; there's no sidebar dot here.
    let attentionEdge = AttentionEdge()
    /// Questions waiting while the page can't show them (0 when it can).
    var attentionWaiting: (() -> Int)?
    /// Clicking the glow focuses the window so the question shows.
    var attentionClicked: (() -> Void)?
    /// True while the Mini is docked: the page fills the card and the strip is an overlay.
    var chromeOverlay = false {
        didSet {
            orderChrome()
            needsLayout = true
        }
    }
    /// Docked in a page: the Mini's window is a borderless child, so the window itself stays clear and the rounded card
    /// is the root's own shape.
    var isPageOverlay = false { didSet { applyPageOverlay() } }
    private(set) var chromeRevealed = true

    private func applyPageOverlay() {
        guard isPageOverlay else {
            layer?.cornerRadius = 0
            layer?.masksToBounds = false
            return
        }
        wantsLayer = true
        window?.setSeeThrough(shadow: false)
        layer?.cornerRadius = Tokens.Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    /// The space's paint makes its window solid again; docked, it has to stay clear under the card's rounded shape.
    @discardableResult
    override func paint(_ space: SpaceInfo, isPrivate: Bool, animated: Bool,
                        crossFadesMode: Bool = true) -> (color: NSColor, end: NSColor?) {
        let painted = super.paint(space, isPrivate: isPrivate, animated: animated, crossFadesMode: crossFadesMode)
        applyPageOverlay()
        return painted
    }
    private var chromeHideWork: DispatchWorkItem?

    private var tokens: [SignalToken] = []
    private var keyTokens: [NSObjectProtocol] = []

    private var chromeViews: [NSView] { [bar, strip] }

    init() {
        super.init(color: SpaceColor.sky.background)
        // The standalone Mini's order, as it has always been: bar, strip, page, then what floats over it.
        [bar, strip, card, overlay].forEach(addSubview)
        addSubview(attentionEdge)
        addSubview(barLayer)
        attentionEdge.isHidden = true
        attentionEdge.onClick = { [weak self] in self?.attentionClicked?() }
        card.isEdgeToEdge = true
        // Questions arriving or answered toggle the glow.
        tokens.append(PendingQuestions.changed.observe { [weak self] _ in self?.needsLayout = true })
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Docked, the page fills the window under the strip, so the card goes behind it; standalone, the strip sits above
    /// the page as it always has.
    private func orderChrome() {
        if chromeOverlay {
            addSubview(card, positioned: .below, relativeTo: bar)
        } else {
            addSubview(bar, positioned: .below, relativeTo: card)
            addSubview(strip, positioned: .below, relativeTo: card)
        }
    }

    var cardFrame: NSRect {
        MiniChromeLayout.cardFrame(in: bounds, stripHeight: Tokens.Metric.miniStripHeight, overlays: chromeOverlay)
    }

    /// The pointer's place in the Mini: near the top the strip comes down; away from it, it goes back up.
    func pointerMoved(to point: NSPoint) {
        guard chromeOverlay else { return }
        if MiniChromeLayout.revealsChrome(at: point, in: bounds, stripHeight: Tokens.Metric.miniStripHeight) {
            chromeHideWork?.cancel()
            chromeHideWork = nil
            if !chromeRevealed { setChromeRevealed(true, animated: true) }
        } else {
            scheduleChromeHide()
        }
    }

    /// Drops the strip down, or takes it back above the page. In full chrome it is always down.
    func setChromeRevealed(_ revealed: Bool, animated: Bool) {
        chromeHideWork?.cancel()
        chromeHideWork = nil
        guard chromeOverlay else {
            chromeRevealed = true
            let frame = NSRect(x: bounds.minX, y: 0, width: bounds.width, height: Tokens.Metric.miniStripHeight)
            for view in chromeViews {
                view.isHidden = false
                view.alphaValue = 1
                view.frame = frame
            }
            return
        }
        chromeRevealed = revealed
        let height = Tokens.Metric.miniStripHeight
        let target = NSRect(x: bounds.minX, y: revealed ? 0 : -height, width: bounds.width, height: height)
        for view in chromeViews { view.isHidden = false }
        let duration = animated && !Tokens.Motion.reduceMotion ? Tokens.Motion.state : 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration * Tokens.Motion.debugSlowdown
            context.timingFunction = Tokens.Motion.easeOut
            for view in chromeViews {
                view.animator().frame = target
                view.animator().alphaValue = revealed ? 1 : 0
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.chromeRevealed else { return }
                for view in self.chromeViews { view.isHidden = true }
            }
        })
    }

    private func scheduleChromeHide() {
        guard chromeOverlay, chromeRevealed else { return }
        chromeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.chromeOverlay, self.chromeRevealed else { return }
                self.setChromeRevealed(false, animated: true)
            }
        }
        chromeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The bar and the page cover it all: a see-through space's glass has nothing to show through.
    override var glassFrame: NSRect { .zero }

    /// Key state decides between showing and glowing, so the glow tracks it as well as the questions.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let centre = NotificationCenter.default
        keyTokens.forEach(centre.removeObserver)
        keyTokens = []
        guard let window else { return }
        keyTokens = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            centre.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = Tokens.Metric.miniStripHeight
        let y = chromeOverlay && !chromeRevealed ? -height : 0
        let chromeFrame = NSRect(x: bounds.minX, y: y, width: bounds.width, height: height)
        bar.frame = chromeFrame
        strip.frame = chromeFrame
        card.frame = cardFrame
        overlay.frame = card.frame
        attentionEdge.frame = AttentionEdge.frame(forPage: card.frame, sidebarOnRight: BrowserRootView.sidebarOnRight)
        let waiting = attentionWaiting?() ?? 0
        attentionEdge.waiting = waiting
        attentionEdge.isHidden = waiting == 0
        barLayer.frame = bounds
    }
}

// MARK: - The top strip

/// The strip on top, as slim as a split view pane's: the traffic lights, back, forward and reload after them as in an
/// installed app's strip, the space the page goes to, the page's site in the middle, and Site Controls, Keep on Top, Copy Link and
/// Open in at the right end, lined up with the page's edge. Dragging it moves the window.
final class MiniStripView: NSView {
    /// The narrowest the address field opens: below this between the space and the buttons, it takes more of the strip.
    static let narrowestField: CGFloat = 160
    /// Back, forward and reload: the browser window's own three, with its tooltips, at a pane strip's size.
    let backButton = MiniStripView.button("chevron.left", toolTip: MiniStripView.backTip)
    let forwardButton = MiniStripView.button("chevron.right", toolTip: MiniStripView.forwardTip)
    let reloadButton = MiniStripView.button("arrow.clockwise", toolTip: SidebarView.reloadTip(loading: false))
    let spaceChip = MiniSpaceChip()
    let title = MiniTitleView()
    let copyButton = MiniStripView.button("link", toolTip: MiniStripView.copyTip)
    /// Expand a docked Mini into a window of its own; hidden in a standalone Mini.
    let expandButton = MiniStripView.button("arrow.up.left.and.arrow.down.right",
                                            toolTip: String(localized: "Open in Window", comment: "Tooltip on the button that turns the Mini docked in a page into a window of its own."))
    /// Docked in a page: no Keep on Top pin, since the Mini goes with the page's window.
    var hidesPin = false { didSet { needsLayout = true } }

    private static var backTip: String { Shortcuts.tooltip(String(localized: "Back", comment: "Tooltip of the sidebar's back button."), for: #selector(MiniWindowController.goBack(_:))) }
    private static var forwardTip: String { Shortcuts.tooltip(String(localized: "Forward", comment: "Tooltip of the sidebar's forward button."), for: #selector(MiniWindowController.goForward(_:))) }
    private static var copyTip: String { Shortcuts.tooltip(String(localized: "Copy Link", comment: "Edit menu item."), for: #selector(MiniWindowController.copyPageURL(_:))) }

    /// The tooltips with the keys as Settings › Shortcuts has them now.
    func refreshTips() {
        backButton.toolTip = Self.backTip
        forwardButton.toolTip = Self.forwardTip
        copyButton.toolTip = Self.copyTip
    }
    /// Window › Keep on Top for this window: a pin, filled while it's on.
    let pinButton = MiniStripView.button("pin", toolTip: KeepOnTop.title)
    /// Site Controls, as by a browser window's address: the site panel for this page (#225).
    let siteButton = MiniStripView.button("slider.horizontal.3", toolTip: String(localized: "Site Controls", comment: "Name of the button by the address that opens the site panel: its tooltip and VoiceOver name."))

    static func button(_ symbol: String, toolTip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: Tokens.Pane.stripButton, symbolSize: Tokens.Pane.glyph, toolTip: toolTip)
        // On the page's color: the neutral fills, which show on any color.
        button.isOnPage = true
        return button
    }
    let openButton = MiniOpenButton()
    /// Where ⌘L's command bar opens: the address field's size, in the middle of the strip.
    let anchor = NSView()
    /// The traffic lights' width, kept clear on the left.
    var trafficLightsWidth: CGFloat = 52 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        anchor.isHidden = true
        expandButton.isHidden = true
        [anchor, expandButton, backButton, forwardButton, reloadButton, spaceChip, title, siteButton, pinButton, copyButton, openButton].forEach(addSubview)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func refreshColors() { [spaceChip, title, openButton].forEach { $0.stateDidChange(animated: false) } }

    /// Back and Forward only when there's a page that way, dimmed otherwise, as in a browser window; Reload is Stop
    /// while the page loads, with what it does now in its tooltip.
    func showNavigation(canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        reloadButton.symbol = isLoading ? "xmark" : "arrow.clockwise"
        reloadButton.toolTip = SidebarView.reloadTip(loading: isLoading)
    }

    #if DEBUG
    var debugFrames: [String: [CGFloat]] {
        let views: [(String, NSView)] = [("back", backButton), ("forward", forwardButton), ("reload", reloadButton), ("space", spaceChip),
                                         ("title", title), ("site", siteButton), ("pin", pinButton), ("copy", copyButton), ("open", openButton)]
        return Dictionary(uniqueKeysWithValues: views.map { ($0.0, [$0.1.frame.minX, $0.1.frame.width]) })
    }
    #endif

    /// While the address is being edited the space's name gives the field room, rather than lying under it.
    var isEditing = false { didSet { if isEditing != oldValue { needsLayout = true } } }

    override func layout() {
        super.layout()
        // Every button and pill is the address's height, as far from the strip's top and bottom as from each other.
        let h = Tokens.Pane.addressHeight, b = Tokens.Pane.stripButton, gap = Tokens.Pane.stripGap
        let y = round((bounds.height - h) / 2)
        // Back, forward and reload right after the lights, as in an installed app's strip.
        var x = Tokens.Sidebar.lightsX + trafficLightsWidth + Tokens.Space.x2
        if !expandButton.isHidden {
            expandButton.frame = NSRect(x: x, y: y, width: b, height: b)
            x += b + gap
        }
        for button in [backButton, forwardButton, reloadButton] {
            button.frame = NSRect(x: x, y: y, width: b, height: b)
            x += b + gap
        }
        let left = x - gap + Tokens.Space.x2
        // Open in sits in the window's top right corner concentric with it: as far in from the right edge as from the
        // top, a pill whose curve runs alongside the window's own (`MiniOpenButton`).
        let right = bounds.width - y
        let icons = b * 3 + gap * 2 + Tokens.Space.x2
        // Narrow, the shortcut goes first, then the space's name shortens.
        openButton.showsKeys = true
        if right - left < spaceChip.fittingWidth + icons + openButton.fittingWidth + Tokens.Space.x4 { openButton.showsKeys = false }
        let openWidth = min(openButton.fittingWidth, max(0, right - left - icons))
        openButton.frame = NSRect(x: right - openWidth, y: y, width: openWidth, height: h)
        copyButton.frame = NSRect(x: openButton.frame.minX - Tokens.Space.x2 - b, y: y, width: b, height: b)
        pinButton.frame = NSRect(x: copyButton.frame.minX - gap - b, y: y, width: b, height: b)
        // Site Controls first of the strip's end, as it ends the address in a browser window.
        // Docked, the pin is hidden: Site Controls takes its place beside Copy Link.
        let beforeSite = hidesPin ? copyButton.frame.minX : pinButton.frame.minX
        siteButton.frame = NSRect(x: beforeSite - gap - b, y: y, width: b, height: b)
        let buttons = siteButton.frame.minX
        // At the narrowest the space's name gives way before anything overlaps; Open in still names the space. While
        // editing it also leaves the field its narrowest.
        let field = isEditing ? Self.narrowestField + Tokens.Space.x2 : 0
        var chipWidth = max(0, min(spaceChip.fittingWidth, buttons - Tokens.Space.x2 - left - field))
        if chipWidth < Tokens.Space.x8 { chipWidth = 0 }
        spaceChip.frame = NSRect(x: left, y: y, width: chipWidth, height: h)
        spaceChip.isHidden = chipWidth == 0
        // The site stays in the middle of the window, as wide on both sides as the room beside it allows; with too
        // little room it steps aside.
        let half = max(0, min(bounds.midX - spaceChip.frame.maxX, buttons - bounds.midX) - Tokens.Space.x2)
        var width = title.width(in: half * 2)
        if width < Tokens.Space.x10 { width = 0 }
        title.frame = NSRect(x: round(bounds.midX - width / 2), y: y, width: width, height: h)
        // With no room it has no width, and its not-secure mark mustn't show over the buttons.
        title.alphaValue = width > 0 ? 1 : 0
        // Editing the address opens in the room between the space and Site Controls, centered on the window where it
        // can be, and never past either.
        var fieldLeft = (chipWidth > 0 ? spaceChip.frame.maxX : left - Tokens.Space.x2) + Tokens.Space.x2
        var fieldRight = buttons - Tokens.Space.x2
        // Too narrow even so: the buttons beside it step aside while you type, rather than lie under the field.
        let crowded = isEditing && fieldRight - fieldLeft < Self.narrowestField
        for view in [siteButton, pinButton, copyButton, openButton] as [NSView] {
            view.isHidden = crowded || (view === pinButton && hidesPin)
        }
        if crowded {
            spaceChip.isHidden = true
            fieldLeft = left
            fieldRight = right
        }
        let room = max(0, fieldRight - fieldLeft)
        let fieldWidth = min(Tokens.Metric.miniAddressWidth, room)
        let fieldX = min(max(fieldLeft, round(bounds.midX - fieldWidth / 2)), fieldRight - fieldWidth)
        anchor.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: h)
    }

    #if DEBUG
    /// minihover <name>|off: shows one of the strip's controls as under the pointer, for screenshots.
    func debugHover(_ name: String) {
        let views: [String: InteractiveView] = ["back": backButton, "forward": forwardButton, "reload": reloadButton, "space": spaceChip,
                                                "title": title, "site": siteButton, "pin": pinButton, "copy": copyButton, "open": openButton]
        for (key, view) in views { view.isHovered = key == name }
    }
    #endif
}

/// The space Open in moves the page to, after the traffic lights: its icon, when it has one, and name, quiet, in
/// the sidebar's small type. A click opens the spaces to choose another; the window takes its color.
final class MiniSpaceChip: InteractiveView {
    private let picture = NSImageView()
    private let label = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText, weight: .medium), color: Tokens.Color.textSecondary)
    private static let pad = Tokens.Space.x2 - 2
    private static let side = Tokens.Sidebar.rowGlyph + 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A menu opens as the button goes down, as a pop-up button's does.
        clicksOnMouseDown = true
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        picture.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingTail
        [picture, label].forEach(addSubview)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(String(localized: "Space", comment: "VoiceOver name of the space in Zigzag Mini's top strip, the one Open in moves the page to. Its value is the space's name."))
        setAccessibilityHelp(String(localized: "Chooses the space the page opens in", comment: "VoiceOver hint of the space in Zigzag Mini's top strip."))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A space's own picture where a symbol can't stand for it, its emoji; none when it has no icon, as in the sidebar.
    static func picture(of space: SpaceInfo, size: CGFloat) -> NSImage? {
        space.icon.map { IconChoice.image($0, size: size) }
    }

    func show(_ space: SpaceInfo, name: String? = nil) {
        picture.image = name == nil ? Self.picture(of: space, size: Self.side) : nil
        picture.isHidden = picture.image == nil
        label.stringValue = name ?? space.name
        setAccessibilityValue(label.stringValue)
        needsLayout = true
    }

    /// The picture's room, when the space has one.
    private var pictureRoom: CGFloat { picture.isHidden ? 0 : Self.side + Tokens.Space.x1 + 2 }

    var fittingWidth: CGFloat { Self.pad * 2 + pictureRoom + label.inkWidth + 2 }

    override func layout() {
        super.layout()
        picture.frame = NSRect(x: Self.pad, y: round((bounds.height - Self.side) / 2), width: Self.side, height: Self.side)
        let x = Self.pad + pictureRoom
        let h = label.lineHeight
        label.frame = NSRect(x: x - Label.inset, y: label.centeredY(in: bounds.height), width: max(0, bounds.width - Self.pad - x + Label.inset * 2), height: h)
    }

    override func stateDidChange(animated: Bool) {
        // Plain on the strip at rest; under the pointer and while its menu is open, the buttons' neutral wash, which
        // shows on the page's color whatever it is. Its ink is the strip's, light or dark for that color.
        let lit = isEnabled && (isHovered || isSelected)
        let fill: NSColor? = isEnabled && isPressed ? Tokens.Color.pressedFill : lit ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
        let ink = lit ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        label.textColor = ink
        picture.contentTintColor = ink
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }
}

/// The page's site in the middle of the strip, small and quiet, with the not-secure mark on a plain http page. Under
/// the pointer it shows the address field's soft fill, and a click opens the command bar over it, as the sidebar's
/// address does.
final class MiniTitleView: InteractiveView {

    // MARK: Dropping a link or words (#182)

    /// Where a link, an address or words dropped on the field go (`AddressDrop`).
    private(set) lazy var drop = AddressDrop(self)
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { drop.entered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { drop.exited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drop.perform(sender) }
    private let mark = NSImageView()
    private let label = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText), color: Tokens.Color.textSecondary)
    private var themeToken: SignalToken?
    private static let pad = Tokens.Space.x2 + 2
    var text: String { label.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        mark.imageScaling = .scaleNone
        mark.image = Tokens.Symbol.image(SitePanel.notSecureSymbol, size: Tokens.Symbol.inline)
        mark.toolTip = SitePanel.notSecure
        mark.isHidden = true
        label.lineBreakMode = .byTruncatingMiddle
        [mark, label].forEach(addSubview)
        _ = drop
        setAccessibilityRole(.button)
        setAccessibilityHelp(String(localized: "Opens the command bar", comment: "Accessibility help of the address in the sidebar."))
        themeToken = Brand.themeChanged.observe { [weak self] in self?.stateDidChange(animated: false) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The full address when it fits (`FullAddress.shown`), else the site.
    private var fullAddress: FullAddress.Parts?

    func show(_ tab: Tab) {
        let name = AddressView.name(of: tab.url)
        label.stringValue = name.isEmpty ? tab.displayTitle : name
        // A long host loses its start, never the domain that says whose site it is (#189).
        label.lineBreakMode = name.isEmpty ? .byTruncatingTail : AddressView.lineBreak(forName: name)
        fullAddress = name.isEmpty ? nil : FullAddress.parts(of: tab.url)
        mark.isHidden = !tab.isNotSecure
        let spoken = fullAddress?.whole ?? label.stringValue
        setAccessibilityLabel(mark.isHidden ? spoken
                              : String(localized: "\(spoken), \(SitePanel.notSecure)", comment: "Accessibility label of the address in the sidebar on a plain http page: the site, then that it's not secure."))
        needsLayout = true
    }

    /// Width for the mark and full address, plus padding.
    var fittingWidth: CGFloat {
        let font = label.font ?? Tokens.Font.body()
        let ink = fullAddress.map { ceil(($0.whole as NSString).size(withAttributes: [.font: font]).width) } ?? label.inkWidth
        return chrome + ink
    }

    /// Non-text width: padding, plus the not-secure mark when shown.
    private var chrome: CGFloat { Self.pad * 2 + 2 + (mark.isHidden ? 0 : Tokens.Space.x3 + Tokens.Space.x1) }

    /// Field width in `available`: the full address's width, or the site's alone when only it fits
    /// (`FullAddress.shown`), keeping the site centered with no gap.
    func width(in available: CGFloat) -> CGFloat {
        let whole = fittingWidth
        guard let fullAddress, whole > available else { return min(whole, available) }
        let font = label.font ?? Tokens.Font.body()
        func measure(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        guard FullAddress.shown(fullAddress, room: available - chrome, measure: measure) == .host else { return available }
        return min(chrome + measure(fullAddress.host), available)
    }

    override func layout() {
        super.layout()
        var x = Self.pad
        if !mark.isHidden {
            mark.frame = NSRect(x: x, y: 0, width: Tokens.Space.x3, height: bounds.height)
            x = mark.frame.maxX + Tokens.Space.x1
        }
        let h = label.lineHeight
        label.frame = NSRect(x: x - Label.inset, y: label.centeredY(in: bounds.height), width: max(0, bounds.width - Self.pad - x + Label.inset * 2), height: h)
        showFullAddress()
    }

    /// The full address if it fits, else the site: site in primary color, the rest secondary, brighter on hover.
    private func showFullAddress() {
        guard let fullAddress else { return }
        FullAddress.show(fullAddress, in: label, room: label.frame.width - Label.inset * 2, color: Tokens.Color.textPrimary,
                         quiet: isHovered ? Tokens.Color.textSecondary : Tokens.Color.textTertiary)
    }

    override func stateDidChange(animated: Bool) {
        // Plain on the strip at rest; under the pointer, a page's neutral field, a step deeper when pressed.
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.fieldFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        label.textColor = isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        showFullAddress()
        mark.contentTintColor = Tokens.Color.textSecondary
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }
}

/// Open in at the strip's right end: what it does in words, "Open in Work", and its shortcut after it in quieter
/// type, on the sidebar address's soft field with a hairline edge.
final class MiniOpenButton: InteractiveView {
    private let label = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText, weight: .medium), color: Tokens.Color.textPrimary)
    private let keys = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText), color: Tokens.Color.textSecondary)
    /// In from the pill's round ends, so the words and the shortcut clear its curves.
    private static let pad = Tokens.Space.x3
    var title: String { label.stringValue }
    /// Whether the shortcut shows after the words; a narrow window leaves it to the tooltip.
    var showsKeys = true { didSet { keys.isHidden = !showsKeys || keys.stringValue.isEmpty; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressSinks = true
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        label.lineBreakMode = .byTruncatingTail
        [label, keys].forEach(addSubview)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ title: String, keys shortcut: String) {
        label.stringValue = title
        keys.stringValue = shortcut
        keys.isHidden = !showsKeys || shortcut.isEmpty
        setAccessibilityLabel(title)
        toolTip = shortcut.isEmpty ? title : String(localized: "\(title) (\(shortcut))", comment: "A button's tooltip: its name, then its keyboard shortcut in parentheses, like “Reload (⌘R)”.")
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        var width = Self.pad * 2 + label.inkWidth + 2
        if !keys.isHidden { width += Tokens.Space.x1 + 2 + keys.inkWidth + 2 }
        return width
    }

    override func layout() {
        super.layout()
        // A pill: in the window's corner, its curve runs alongside the window's (the window's radius less the inset).
        layer?.cornerRadius = bounds.height / 2
        let h = label.lineHeight
        let keysInk = keys.isHidden ? 0 : keys.inkWidth + 2
        let keysRoom = keys.isHidden ? 0 : keysInk + Tokens.Space.x1 + 2
        label.frame = NSRect(x: Self.pad - Label.inset, y: label.centeredY(in: bounds.height),
                             width: max(0, bounds.width - Self.pad * 2 - keysRoom + Label.inset * 2), height: h)
        keys.frame = NSRect(x: bounds.width - Self.pad - keysInk - Label.inset, y: label.frame.minY, width: keysInk + Label.inset * 2, height: h)
    }

    override func stateDidChange(animated: Bool) {
        // A page's neutral field, which shows on the page's color whatever it is, a step on under the pointer and
        // when pressed, with a hairline so it still reads as a button on a white page.
        let fill = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill
        layer?.set(backgroundColor: cgColor(fill), animated: false)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = Tokens.Metric.hairline
            layer?.borderColor = cgColor(Tokens.Color.separator)
        }
        label.textColor = Tokens.Color.textPrimary
        keys.textColor = Tokens.Color.textSecondary
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let event = NSApp.currentEvent else { return false }
        onClick?(event)
        return true
    }
}

// MARK: - As extensions see it

/// Zigzag Mini, for extensions: a popup-type window holding its one tab, as a sign-in popup is.
@available(macOS 15.4, *)
extension MiniWindowController: WKWebExtensionWindow {
    // A private page is listed only to an extension allowed in private windows.
    private func hides(from context: WKWebExtensionContext) -> Bool { movedOut || !PrivateAccess.sees(isPrivate: isPrivate, allowed: context.hasAccessToPrivateData) }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { hides(from: context) ? [] : [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { hides(from: context) ? nil : tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { window?.isMiniaturized == true ? .minimized : .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivate }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}

// MARK: - Its page's questions

/// A site's permission question and Save password? come up here over the one page, as they do in a browser window.
extension MiniWindowController: PromptHost {
    var promptOverlay: NSView { overlay }
    func pageFrame(showing tab: Tab) -> NSRect? { promptHolds(tab) ? overlay.bounds : nil }
    var focusedPaneFrame: NSRect { overlay.bounds }
    var promptFrontTab: Tab? { movedOut || isClosing ? nil : tab }
    func promptHolds(_ tab: Tab) -> Bool { tab === self.tab && !movedOut && !isClosing }
    /// Its page is front only while the window is key: questions asked meanwhile wait and the edge glows.
    func promptShows(_ tab: Tab) -> Bool {
        #if DEBUG
        // A test copy kept behind is never key.
        if Self.debugPromptsShow { return promptHolds(tab) }
        #endif
        return promptHolds(tab) && window?.isKeyWindow == true
    }
    #if DEBUG
    /// Debug bridge: questions show in Zigzag Mini though its window isn't key.
    static var debugPromptsShow = false
    #endif
    var promptIsPrivate: Bool { isPrivate }
    var promptAccent: NSColor { Brand.Theme.of(space).accent }
    /// The page never changes; only key state does, which is when a held question shows (see `promptShows`).
    func observePromptTabs(_ body: @escaping () -> Void) -> SignalToken? {
        let gone = pageGone.observe { _ in body() }
        let front = promptFrontChanged.observe { _ in body() }
        return SignalToken {
            gone.cancel()
            front.cancel()
        }
    }
    var promptPageViews: [NSView] { [root.card] }
    func clearForPrompt() {
        linkStatus.hide()
        commandBar.dismiss()
    }
    var promptIsCovered: Bool { commandBar.isVisible }
    var promptAnchor: NSView? { strip }
}

/// The app you were in before Zigzag: where a link for Zigzag Mini came from, to go back to when it closes.
enum AppSwitching {
    private(set) static var lastOtherApp: NSRunningApplication?
    private static var token: NSObjectProtocol?

    static func start() {
        guard token == nil else { return }
        lastOtherApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            MainActor.assumeIsolated { lastOtherApp = app }
        }
    }
}

// MARK: - The first link's note

/// Shown the first time a link from another app opens in Zigzag Mini, pointing at Open in: what Zigzag Mini is for,
/// how to keep the page, and a choice to keep tabs instead. It stays until answered; Return and Esc are Got It.
final class MiniLinksNote: FloatingPanelView {
    private let title = Label(String(localized: "Links from other apps open here", comment: "Title of the note shown once in Zigzag Mini (the small window for one page), the first time a link from another app opens there. The note points at the Open in button."),
                              font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let line = Label(MiniLinksNote.text(keys: Shortcuts.keys(for: #selector(MiniWindowController.openDocument(_:)))),
                             font: Tokens.Font.body(), color: Tokens.Color.textSecondary)

    /// The note's line, with Open in's keys as Settings › Shortcuts has them, or without when it has none.
    static func text(keys: String) -> String {
        keys.isEmpty ? String(localized: "Glance, then get back to what you were doing. To keep the page, use this button.", comment: "Text of the note shown once in Zigzag Mini, the first time a link from another app opens there. The note points at the Open in button, which moves the page into a tab of a browser window.")
            : String(localized: "Glance, then get back to what you were doing. To keep the page, use this button or press \(keys).", comment: "Text of the note shown once in Zigzag Mini, the first time a link from another app opens there. The note points at the Open in button, which (like its keys, such as ⌘O) moves the page into a tab of a browser window.")
    }
    private let buttons = DialogButtons()
    private let useTabs = PillButton(title: String(localized: "Use Tabs Instead", comment: "Button on the note shown the first time a link from another app opens in Zigzag Mini: links from other apps open as tabs from now on, and this page moves into a tab."), style: .quiet)
    private let gotIt = PillButton(title: String(localized: "Got It", comment: "Button on the note shown the first time a link from another app opens in Zigzag Mini: puts the note away and keeps using Zigzag Mini."), style: .prominent)
    /// True for Use Tabs Instead.
    var onAnswer: ((Bool) -> Void)?
    /// The button it points at, in the overlay's coordinates.
    var anchor: () -> NSRect? = { nil }
    private var shownAt = Date.distantFuture
    /// Typed or clicked in the page since it came up: Return is the page's from then on.
    private var pageTouched = false
    private var frameToken: NSObjectProtocol?

    private static let pad = CardOverThePage.pad
    private static let width: CGFloat = 320
    /// From the window's edges.
    private static let margin = Tokens.Space.x2

    init(accent: NSColor) {
        super.init(frame: .zero)
        for label in [title, line] {
            label.usesSingleLineMode = false
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = false
        }
        gotIt.tint = accent
        buttons.trailing = [useTabs, gotIt]
        [title, line, buttons].forEach(addSubview)
        // No click for the first half second, so one meant for the page can't land on a button.
        useTabs.onClick = { [weak self] _ in self?.clicked(useTabs: true) }
        gotIt.onClick = { [weak self] _ in self?.clicked(useTabs: false) }
        radius = Tokens.Radius.panel
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title.stringValue)
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(over overlay: NSView) {
        overlay.addSubview(self)
        place()
        // Follows the button as the window resizes, once the strip has laid out.
        overlay.postsFrameChangedNotifications = true
        frameToken = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: overlay, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.place()
                DispatchQueue.main.async { self?.place() }
            }
        }
        shownAt = Date()
        // Out of the button it points at.
        growsFrom = CGPoint(x: (arrowX ?? bounds.midX) / max(1, bounds.width), y: 0)
        present(arrival: .pop)
        Announcement.post(title.stringValue + ". " + line.stringValue, priority: .high)
    }

    func takeDown(instantly: Bool = false) {
        frameToken.map(NotificationCenter.default.removeObserver)
        frameToken = nil
        onAnswer = nil
        dismiss(instantly: instantly)
    }

    private func clicked(useTabs: Bool) {
        guard Toast.acceptsAction(shownAt: shownAt) else { return }
        onAnswer?(useTabs)
    }

    /// From the window, before the page: Esc is Got It, and Return too until the page has been typed or clicked in.
    func takes(_ event: NSEvent) -> Bool {
        guard !dismissing, superview != nil else { return false }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { pageTouched = true }
            return false
        }
        guard event.type == .keyDown else { return false }
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        // The command bar or the find bar has the keys.
        let typing = window?.firstResponder is NSText
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if plain, !typing, event.keyCode == 53 || (isReturn && !pageTouched) {
            onAnswer?(false)
            return true
        }
        if plain { pageTouched = true }
        return false
    }

    private func textHeight(_ label: Label, width: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width + Label.inset * 2, height: 1000)).height ?? label.lineHeight)
    }

    /// The title's top, so its caps start `pad` below the arrow, as the text starts `pad` in.
    private var titleTop: CGFloat {
        let font = title.font ?? Tokens.Font.body(.semibold)
        let line = title.lineHeight
        let capTop = line / 2 + Label.capsBelowMiddle(of: font, lineHeight: line) - font.capHeight / 2
        let scale = window?.backingScaleFactor ?? 2
        return ((Self.arrowHeight + Self.pad - capTop) * scale).rounded() / scale
    }

    private func height(for width: CGFloat) -> CGFloat {
        let text = width - Self.pad * 2
        return titleTop + textHeight(title, width: text) + 2 + textHeight(line, width: text) + Tokens.Space.x4 + DialogButtons.height + Self.pad
    }

    /// Under the button, inside the window, the arrow on the button's middle.
    private func place() {
        guard let room = superview?.bounds else { return }
        let width = min(Self.width, room.width - Self.margin * 2)
        let target = anchor() ?? NSRect(x: room.maxX - Self.margin - width / 2, y: room.minY, width: 0, height: 0)
        let x = min(max(room.minX + Self.margin, round(target.midX - width / 2)), room.maxX - Self.margin - width)
        let y = max(room.minY, target.maxY) + Tokens.Space.x1
        frame = NSRect(x: x, y: y, width: width, height: height(for: width))
        arrowX = target.midX - x
        needsLayout = true
    }

    private func layoutContent() {
        let pad = Self.pad, text = bounds.width - pad * 2
        title.frame = NSRect(x: pad - Label.inset, y: titleTop, width: text + Label.inset * 2, height: textHeight(title, width: text))
        line.frame = NSRect(x: pad - Label.inset, y: title.frame.maxY + 2, width: text + Label.inset * 2, height: textHeight(line, width: text))
        buttons.frame = NSRect(x: pad, y: bounds.height - pad - DialogButtons.height, width: text, height: DialogButtons.height)
    }
}
