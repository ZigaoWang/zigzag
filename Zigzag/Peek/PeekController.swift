import AppKit
import WebKit

/// The peek's top strip, on the panel's glass: back and forward once the peek has history, the site, then "Open as
/// Tab" and close. As slim as a split view pane's
/// strip (`Tokens.Pane`), so the page gets the room.
final class PeekHeaderView: NSView {
    let back = PeekHeaderView.button("chevron.left", toolTip: Shortcuts.tooltip(String(localized: "Back", comment: "Tooltip of the sidebar's back button."), for: #selector(BrowserWindowController.goBack(_:))))
    let forward = PeekHeaderView.button("chevron.right", toolTip: Shortcuts.tooltip(String(localized: "Forward", comment: "Tooltip of the sidebar's forward button."), for: #selector(BrowserWindowController.goForward(_:))))
    let icon = FaviconView()
    let host = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText), color: Tokens.Color.textPrimary)
    let expandButton = PeekHeaderView.button("arrow.up.left.and.arrow.down.right", toolTip: String(localized: "Open Peek as Tab", comment: "Tooltip of the button in Peek's top strip that keeps the page as a tab."))
    let closeButton = PeekHeaderView.button("xmark", toolTip: String(localized: "Close Peek", comment: "Tooltip of the close button in Peek's top strip."))

    private static func button(_ symbol: String, toolTip: String) -> IconButton {
        IconButton(symbol: symbol, size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph, toolTip: toolTip)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [back, forward, icon, host, expandButton, closeButton].forEach { addSubview($0) }
        back.setAccessibilityLabel(String(localized: "Back", comment: "Tooltip of the sidebar's back button."))
        forward.setAccessibilityLabel(String(localized: "Forward", comment: "Tooltip of the sidebar's forward button."))
        showHistory(back: false, forward: false)
        // Out of the strip, "Close" alone doesn't say what closes.
        expandButton.setAccessibilityLabel(String(localized: "Open Peek as Tab", comment: "Tooltip of the button in Peek's top strip that keeps the page as a tab."))
        closeButton.setAccessibilityLabel(String(localized: "Close Peek", comment: "Tooltip of the close button in Peek's top strip."))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Peek", comment: "Accessibility label of Peek's top strip. Peek shows a link's page in a panel over the current one."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Whether back and forward show: only once there's a page to go back or forward to (#463).
    var showsHistory: Bool { !back.isHidden }

    /// Back and forward appear together once either has somewhere to go, each enabled by its own.
    func showHistory(back canGoBack: Bool, forward canGoForward: Bool) {
        let shows = canGoBack || canGoForward
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        guard shows == back.isHidden else { return }
        back.isHidden = !shows
        forward.isHidden = !shows
        needsLayout = true
    }

    /// The color under the strip: the peeked page's (nil: the panel's own surface). Its icons and text turn light or
    /// dark, whichever reads more clearly on it, as a split view pane's strip does (`PaneHeaderView.ground`).
    var ground: NSColor? {
        didSet {
            guard ground != oldValue else { return }
            appearance = PageBar.inkAppearance(on: ground).flatMap(NSAppearance.init(named:))
            [back, forward, expandButton, closeButton].forEach { $0.isOnPage = ground != nil; $0.ground = ground }
        }
    }

    override func layout() {
        super.layout()
        // Close sits as far from the panel's side as from its top, so its corner runs with the panel's
        // (`FloatingPanelView` fits it); the favicon mirrors it at the leading end, where a button would be.
        let b = Tokens.Pane.button
        let edge = (bounds.height - b) / 2
        closeButton.frame = NSRect(x: bounds.width - edge - b, y: edge, width: b, height: b)
        expandButton.frame = NSRect(x: closeButton.frame.minX - b, y: edge, width: b, height: b)
        [back, forward, expandButton, closeButton].forEach { $0.radius = max(Tokens.Radius.control, Tokens.Radius.large - edge) }
        // Back and forward take the leading corner, as the pane strip's do; the favicon follows them.
        back.frame = NSRect(x: edge, y: edge, width: b, height: b)
        forward.frame = NSRect(x: back.frame.maxX, y: edge, width: b, height: b)
        let iconSize = Tokens.Pane.favicon
        let iconSlot = showsHistory ? forward.frame.maxX + Tokens.Space.x1 : edge
        icon.frame = NSRect(x: iconSlot + (b - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let x = icon.frame.maxX + Tokens.Space.x2 - Label.inset
        let h = host.lineHeight
        host.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, expandButton.frame.minX - x - Tokens.Space.x2), height: h)
    }
}

/// Peek: a page in a floating card over the current one. Close it and it's gone; one click makes it a real tab.
final class PeekController {
    private weak var controller: BrowserWindowController?
    private let scrim = ScrimView()
    private let panel = FloatingPanelView()
    /// Clips the strip and the page to the card's rounded corners.
    private let clip = FlippedView()
    /// The peek's window, for pointing at it (the Getting started guide).
    var panelView: NSView { panel }
    private let header = PeekHeaderView()
    /// The strip, for tests.
    var headerView: PeekHeaderView { header }
    private let content = NSView()
    private(set) var tab: Tab?
    /// The tab the Peek opened over, for extensions: active again when the Peek goes, unless you've moved on.
    private weak var under: Tab?
    private var token: SignalToken?
    private(set) var isVisible = false {
        didSet {
            // A translation's toasts are for the page in view: the peeked one now, or the tab under it again.
            if isVisible != oldValue { controller?.translationViewChanged() }
            guard !isVisible else { return }
            stopEsc()
            // Getting started's Peek step is done once a peek closes again, in whichever window it was.
            if oldValue { Tutorial.complete("peek") }
        }
    }
    private var escMonitor: Any?
    /// Every page a Peek covers, with the window it's covered in: a page that leaves that window (shown in another
    /// window that shares tabs, moved there) takes the pointer again at once (`pageMoved`).
    private static let covered = NSMapTable<WKWebView, NSWindow>.weakToWeakObjects()

    private func stopEsc() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    init(controller: BrowserWindowController) {
        self.controller = controller
        // A big floating surface holding a rounded page: the large radius, the page inset in it concentrically.
        panel.radius = Tokens.Radius.large
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        clip.addSubview(header)
        clip.addSubview(content)
        panel.addSubview(clip)
        // A firmer dim than other panels: the peek is a layer above the page, and should read as one.
        scrim.color = Tokens.Color.peekScrim
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        scrim.onClick = { [weak self] in self?.close() }
        header.closeButton.onClick = { [weak self] _ in self?.close() }
        header.expandButton.onClick = { [weak self] _ in self?.openAsTab() }
        header.back.onClick = { [weak self] _ in self?.goBack() }
        header.forward.onClick = { [weak self] _ in self?.goForward() }
        // A mouse plugged in or out, or Show scroll bars changed, switches the Mac between the two styles.
        scrollerStyleObserver = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScrollbars() }
        }
    }

    private var scrollerStyleObserver: NSObjectProtocol?

    isolated deinit {
        if let scrollerStyleObserver { NotificationCenter.default.removeObserver(scrollerStyleObserver) }
    }

    /// The slim bar on the peeked page while the Mac shows classic scroll bars, none otherwise (`PeekScrollbars`).
    private func refreshScrollbars() {
        guard let tab, let webView = tab.webView, !tab.isLoading else { return }
        let ground = tab.pageColor ?? webView.underPageBackgroundColor
        PeekScrollbars.apply(to: webView, style: NSScroller.preferredScrollerStyle, dark: ground.map(PageBar.isDark) ?? false)
    }

    private var headerHeight: CGFloat { Tokens.Metric.peekHeaderHeight }
    /// From the glass's edge to the page in it, at the sides and bottom.
    static let inset = Tokens.Metric.peekInset

    private func panelFrame() -> NSRect {
        guard let controller else { return .zero }
        let card = controller.root.cardFrame
        let dx = max(Tokens.Space.x8, Tokens.Space.snap(card.width * Tokens.Metric.peekInsetRatio))
        let dy = max(Tokens.Space.x6, Tokens.Space.snap(card.height * Tokens.Metric.peekInsetRatio * 0.6))
        return card.insetBy(dx: dx, dy: dy)
    }

    private func layoutPanel() {
        clip.frame = panel.bounds
        header.frame = NSRect(x: 0, y: 0, width: panel.bounds.width, height: headerHeight)
        let inset = Self.inset
        content.frame = NSRect(x: inset, y: headerHeight, width: panel.bounds.width - inset * 2, height: panel.bounds.height - headerHeight - inset)
        content.layer?.cornerRadius = panel.radius - inset
        if let holder = tab?.pageHolder, holder.superview === content { holder.frame = content.bounds }
    }

    /// Shows a URL in peek. With a configuration (from window.open), the page keeps its opener.
    @discardableResult
    func show(url: URL?, configuration: WKWebViewConfiguration?, opener: Tab?, by sender: Tab.LoadSender = .zigzag) -> WKWebView? {
        guard let controller else { return nil }
        // A new peek replaces the old one rather than stacking.
        let replaced = tab
        if let existing = replaced {
            if #available(macOS 15.4, *) { ExtensionCenter.peekClosed(existing, backTo: nil) }
            existing.close()
        }
        // With a configuration from the page that opened it, it's in that page's profile, so in its space.
        let spaceID = (configuration != nil ? opener?.spaceID : nil) ?? controller.tabManager.currentSpaceID
        let tab = Tab(url: url, spaceID: spaceID, configuration: configuration)
        // A peek in a private window is private too: its own store, nothing written down.
        tab.privateStore = controller.tabManager.privateStore
        tab.host = controller
        tab.opener = opener
        tab.isPeek = true
        tab.firstLoad.sender = sender
        self.tab = tab
        token = tab.changed.observe { [weak self] change in self?.tabChanged(change) }
        // Told before its page starts, as a new tab is, so its content scripts' first messages come from a known tab.
        under = controller.tabManager.selectedTab
        if #available(macOS 15.4, *) { ExtensionCenter.peekOpened(tab, over: replaced == nil ? under : nil) }
        let webView = tab.ensureWebView()
        // Until the new page paints, show the colour of the page you came from, not a flash of white.
        let behind = opener?.webView.flatMap { $0.themeColor ?? $0.underPageBackgroundColor }
        content.layer?.backgroundColor = behind?.cgColor
        webView.setValue(false, forKey: "drawsBackground")
        content.subviews.forEach { $0.removeFromSuperview() }
        if let holder = tab.pageHolder {
            holder.frame = content.bounds
            holder.autoresizingMask = [.width, .height]
            content.addSubview(holder)
        }
        refreshHeader()
        refreshGround()

        if !isVisible {
            isVisible = true
            scrim.frame = controller.root.cardFrame
            controller.root.overlay.addSubview(scrim)
            controller.root.overlay.addSubview(panel)
            panel.frame = panelFrame()
            // The scrim comes with the card even from a key, as it leaves with it.
            scrim.show(evenFromKeyboard: true)
            grow()
            // Esc puts the peek away, the way it does a sheet; other keys go to the page as usual.
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible, event.keyCode == 53, event.window === self.controller?.window,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                self.close()
                return nil
            }
        }
        coverPages()
        controller.window?.makeFirstResponder(webView)
        return webView
    }

    /// Pointer moves reach every page under the pointer, covered or not: the ones under the card ignore them.
    private func coverPages() {
        guard let controller, let window = controller.window else { return }
        for case let page? in controller.root.paneCards.map(\.webView) where page !== tab?.webView && page.window === window {
            cover(page, in: window)
        }
    }

    private func cover(_ page: WKWebView, in window: NSWindow) {
        Self.covers(page, true)
        Self.covered.setObject(window, forKey: page)
    }

    /// Gives the pointer back to every page this window's Peek covered, wherever it is now.
    private func uncoverPages() {
        let window = controller?.window
        for page in Self.covered.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
            let at = Self.covered.object(forKey: page)
            guard at == nil || at === window else { continue }
            Self.covers(page, false)
            Self.covered.removeObject(forKey: page)
        }
    }

    /// A page came into a window or left one. Out of the window whose Peek covered it, it takes the pointer again;
    /// into a window with Peek up, it's under the card there.
    static func pageMoved(_ page: WKWebView) {
        // Only Peek covers pages, so one covered with no Peek in its window behind it is let go too.
        let at = covered.object(forKey: page)
        if at.map({ $0 !== page.window }) ?? isCovered(page) {
            covers(page, false)
            covered.removeObject(forKey: page)
        }
        guard let window = page.window, let peek = (window.windowController as? BrowserWindowController)?.peek,
              peek.isVisible, let peeked = peek.tab?.webView, page !== peeked, !page.isDescendant(of: peek.panel) else { return }
        peek.cover(page, in: window)
    }

    /// WebKit's switch for a covered page: no pointer moves, hover, clicks or drops.
    static func covers(_ page: WKWebView, _ on: Bool) {
        let set = NSSelectorFromString("_setIgnoresNonWheelEvents:")
        guard page.responds(to: set) else { return }
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(page.method(for: set), to: SetBool.self)(page, set, on)
    }

    static func isCovered(_ page: WKWebView) -> Bool {
        let get = NSSelectorFromString("_ignoresNonWheelEvents")
        guard page.responds(to: get) else { return false }
        typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(page.method(for: get), to: GetBool.self)(page, get)
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .url, .favicon, .title, .loading, .navigation: refreshHeader()
        default: break
        }
        switch change {
        case .loading, .themeColor, .pdf, .settings: refreshGround()
        case .darkPage: refreshGround(); refreshScrollbars()
        default: break
        }
        // Painted: pages that leave their background to the browser get white again.
        if change == .loading, let tab, !tab.isLoading, let webView = tab.webView {
            webView.setValue(true, forKey: "drawsBackground")
            // Unless dark pages keep it clear, so the dark under it shows (#134).
            DarkPages.restoreGround(of: webView)
            content.layer?.backgroundColor = nil
            refreshScrollbars()
        }
    }

    /// The strip's name for a page: its host, or with none (a local file) its sidebar name, never an empty strip.
    static func stripName(for url: URL?, title: String) -> String {
        let host = url.map(HistoryStore.normalizedHost) ?? ""
        let name = host.isEmpty ? AddressView.name(of: url) : host
        return name.isEmpty ? title : name
    }

    private func refreshHeader() {
        guard let tab else { return }
        header.host.stringValue = Self.stripName(for: tab.url, title: tab.displayTitle)
        // Cut from the start, so the domain that says whose site it is stays whole (#189).
        header.host.lineBreakMode = AddressView.lineBreak(forName: header.host.stringValue)
        header.icon.image = tab.favicon
        header.icon.isLoading = tab.isLoading
        header.showHistory(back: tab.canGoBack, forward: tab.canGoForward)
    }

    /// The panel and its strip in the page's own color, as a split view pane's card and strip are (and a zoomed
    /// pane, in Peek's look): over a page drawn dark, no light band across its top. Until the page has a color,
    /// the panel's own surface.
    private func refreshGround() {
        let color = tab?.pageColor
        panel.tintStrength = color == nil ? nil : 1
        panel.surfaceTint = color
        header.ground = color
    }

    /// The link you clicked, if the pointer is over the page: the peek opens from there.
    private func clickPoint() -> NSPoint? {
        guard let controller, let window = controller.window else { return nil }
        let point = controller.root.overlay.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controller.root.cardFrame.contains(point) ? point : nil
    }

    /// Where the link you clicked is on the card (0 to 1 from its top left), for the card to open out of; its middle
    /// when the pointer isn't over the page.
    private func growPoint() -> CGPoint {
        let b = panel.bounds
        guard let point = clickPoint(), b.width > 0, b.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let local = panel.convert(point, from: panel.superview)
        let y = panel.isFlipped ? local.y : b.height - local.y
        return CGPoint(x: min(max(local.x / b.width, 0), 1), y: min(max(y / b.height, 0), 1))
    }

    /// Opens out of the link, so you see where it came from: from a little smaller, never from nothing, as a menu
    /// grows out of its button.
    private func grow() {
        panel.layoutSubtreeIfNeeded()
        panel.growsFrom = growPoint()
        panel.present()
    }

    /// Settles back a touch, in place, and fades: quick and quiet, nothing flying across the page. Peeked again
    /// meanwhile, the card turns around and stays.
    private func shrink(_ done: @escaping () -> Void) {
        panel.growsFrom = CGPoint(x: 0.5, y: 0.5)
        panel.dismiss(completion: done)
    }

    func reposition() {
        guard isVisible, let controller else { return }
        scrim.frame = controller.root.cardFrame
        panel.frame = panelFrame()
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        token = nil
        // Esc too: the dimming goes with the card, as the card leaves.
        scrim.hide(evenFromKeyboard: true)
        let closing = tab
        tab = nil
        if #available(macOS 15.4, *), let closing {
            // Another tab selected already told extensions it's the active one.
            let back = under.flatMap { $0 === controller?.tabManager.selectedTab ? $0 : nil }
            ExtensionCenter.peekClosed(closing, backTo: back)
        }
        uncoverPages()
        shrink { closing?.close() }
        if let controller, let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
    }

    /// Promotes the peeked page to a real tab, without reloading it.
    func openAsTab() {
        guard isVisible, let controller, let tab else { return }
        // Extensions saw it last, after the window's tabs in every space.
        let place = controller.tabManager.tabsForExtensions.count
        isVisible = false
        token = nil
        self.tab = nil
        tab.isPeek = false
        uncoverPages()
        // Promoted before it finished loading: it never gets the peek's "painted" step, so it draws its own
        // background from here on, like any tab.
        tab.webView?.setValue(true, forKey: "drawsBackground")
        if let webView = tab.webView {
            DarkPages.restoreGround(of: webView)
            // A tab keeps the Mac's own scroll bars, as in Safari.
            PeekScrollbars.remove(from: webView)
        }
        content.layer?.backgroundColor = nil
        let target = controller.root.cardFrame
        scrim.hide()
        Tokens.Motion.animate(Tokens.Motion.snappy, moves: true, {
            self.panel.animator().frame = target
        }, completion: {
            if !self.isVisible { self.panel.removeFromSuperview() }
            self.panel.alphaValue = 1
            // The window closed while it grew: the page goes with it, rather than living on with no window.
            guard WindowManager.shared.controllers.contains(where: { $0 === controller }) else {
                if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab, windowClosing: true) }
                tab.close()
                return
            }
            controller.tabManager.insert(tab)
            // The same tab to extensions, from the Peek's place to its own in the list.
            if #available(macOS 15.4, *) { ExtensionCenter.tabMoved(tab, from: place, in: controller) }
        })
    }

    var contentFrame: NSRect { panel.frame }

    func goBack() { tab?.goBack() }
    func goForward() { tab?.goForward() }
}

/// Peek's slim scroll bar. A Mac that shows classic scroll bars gives every page a wide track, heavy in a small card:
/// there a peeked page gets a slim bar floating over it instead, unless it styles its own. With overlay scroll bars,
/// and in tabs, pages keep WebKit's own, as in Safari.
enum PeekScrollbars {
    static let styleID = "zigzag-peek-scrollbars"

    /// Only for the Mac's classic scroll bars.
    static func wanted(for style: NSScroller.Style) -> Bool { style == .legacy }

    /// The slim bar's sheet, its thumb dark on a light page and light on a dark one.
    static func css(dark: Bool) -> String {
        let thumb = dark ? "255,255,255" : "0,0,0"
        return "::-webkit-scrollbar{width:10px;height:10px;background:transparent}"
            + "::-webkit-scrollbar-track,::-webkit-scrollbar-corner{background:transparent}"
            + "::-webkit-scrollbar-thumb{background:rgba(\(thumb),.35);border-radius:6px;border:3px solid transparent;background-clip:content-box}"
            + "::-webkit-scrollbar-thumb:hover{background-color:rgba(\(thumb),.55)}"
    }

    static func apply(to webView: WKWebView, style: NSScroller.Style, dark: Bool) {
        Task { _ = await run(in: webView, want: wanted(for: style), dark: dark) }
    }

    static func remove(from webView: WKWebView) {
        Task { _ = await run(in: webView, want: false, dark: false) }
    }

    /// Adds, updates or removes the bar: "added", "updated", "removed", "own" (the page styles its own) or "none".
    static func run(in webView: WKWebView, want: Bool, dark: Bool) async -> String? {
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let args: [String: Any] = ["id": styleID, "want": want, "css": css(dark: dark), "native": Double(width)]
        return try? await webView.callAsyncJavaScript(script, arguments: args, in: nil, contentWorld: .defaultClient) as? String
    }

    // A page styles its own if its root or body sets scrollbar-width or -color, a readable sheet has scrollbar
    // rules, or its root's bar is wider or narrower than the Mac's.
    private static let script = """
    const old = document.getElementById(id);
    const root = document.documentElement;
    // WebKit styles a scroll bar as it makes it: the page's are made again for a change to show.
    const remake = () => {
      if (!root) return;
      const x = scrollX, y = scrollY, overflow = root.style.overflow;
      root.style.overflow = 'hidden';
      void root.offsetWidth;
      root.style.overflow = overflow;
      void root.offsetWidth;
      scrollTo(x, y);
    };
    if (!want) { if (old) { old.remove(); remake(); return 'removed'; } return 'none'; }
    if (old) { if (old.textContent !== css) { old.textContent = css; remake(); } return 'updated'; }
    if (!root) return 'none';
    for (const el of [root, document.body]) {
      if (!el) continue;
      const s = getComputedStyle(el);
      if ((s.scrollbarWidth && s.scrollbarWidth !== 'auto') || (s.scrollbarColor && s.scrollbarColor !== 'auto')) return 'own';
    }
    const bar = innerWidth - root.clientWidth;
    if (bar > 0 && Math.abs(bar - native) > 0.5) return 'own';
    const styles = (rules) => {
      for (const r of rules) {
        if (r.selectorText && r.selectorText.includes('-webkit-scrollbar')) return true;
        if (r.style && (r.style.getPropertyValue('scrollbar-width') || r.style.getPropertyValue('scrollbar-color'))) return true;
        let inner = null;
        try { inner = r.cssRules; } catch (e) {}
        if (inner && inner.length && styles(inner)) return true;
      }
      return false;
    };
    for (const sheet of document.styleSheets) {
      let rules = null;
      try { rules = sheet.cssRules; } catch (e) { continue; }
      if (rules && styles(rules)) return 'own';
    }
    const style = document.createElement('style');
    style.id = id;
    style.textContent = css;
    (document.head || root).appendChild(style);
    remake();
    return 'added';
    """
}
